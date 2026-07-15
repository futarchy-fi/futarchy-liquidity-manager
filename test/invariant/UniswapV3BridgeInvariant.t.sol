// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {UniswapV3LiquidityAdapter} from "../../src/adapters/UniswapV3LiquidityAdapter.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {UniV3PoolStabilityGuard} from "../../src/oracles/UniV3PoolStabilityGuard.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "../mocks/MockUniswapV3NonfungiblePositionManager.sol";
import {MockUniswapV3FactoryLike} from "../mocks/MockUniswapV3FactoryLike.sol";
import {MockUniswapV3PoolLike} from "../mocks/MockUniswapV3PoolLike.sol";

contract UniswapV3LiquidityAdapterHandler {
    UniswapV3LiquidityAdapter public immutable adapter;
    MockUniswapV3NonfungiblePositionManager public immutable positionManager;
    MockMintableERC20 public immutable token0;
    MockMintableERC20 public immutable token1;

    constructor(
        UniswapV3LiquidityAdapter adapter_,
        MockUniswapV3NonfungiblePositionManager positionManager_,
        MockMintableERC20 token0_,
        MockMintableERC20 token1_
    ) {
        adapter = adapter_;
        positionManager = positionManager_;
        token0 = token0_;
        token1 = token1_;
        token0.approve(address(adapter), type(uint256).max);
        token1.approve(address(adapter), type(uint256).max);
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);
    }

    function add(uint96 amount0Seed, uint96 amount1Seed, uint16 usageSeed) external {
        uint256 amount0 = 1e6 + (uint256(amount0Seed) % (1e24 - 1e6 + 1));
        uint256 amount1 = 1e6 + (uint256(amount1Seed) % (1e24 - 1e6 + 1));
        positionManager.setUsageBps(uint16(9950 + (usageSeed % 51)));
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        adapter.addFullRangeLiquidity(address(token0), address(token1), amount0, amount1, "");
    }

    function remove(uint128 liquiditySeed) external {
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        if (tokenId == 0) return;
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        uint128 amount = uint128(1 + (uint256(liquiditySeed) % liquidity));
        adapter.removeLiquidityDetailed(address(token0), address(token1), amount);
    }

    function accrueAndCompound(uint96 amount0Seed, uint96 amount1Seed) external {
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        if (tokenId == 0) return;
        uint256 amount0 = 1 + (uint256(amount0Seed) % 1e20);
        uint256 amount1 = 1 + (uint256(amount1Seed) % 1e20);
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        positionManager.accrueFees(tokenId, amount0, amount1);
    }
}

contract UniswapV3LiquidityAdapterInvariantTest is StdInvariant, Test {
    int24 private constant FULL_RANGE_LOWER = -887_270;
    int24 private constant FULL_RANGE_UPPER = 887_270;

    MockUniswapV3NonfungiblePositionManager internal positionManager;
    UniswapV3LiquidityAdapter internal adapter;
    MockMintableERC20 internal token0;
    MockMintableERC20 internal token1;

    function setUp() public {
        positionManager = new MockUniswapV3NonfungiblePositionManager();
        adapter = new UniswapV3LiquidityAdapter(positionManager, FULL_RANGE_LOWER, FULL_RANGE_UPPER);
        MockMintableERC20 tokenA = new MockMintableERC20("Invariant token A", "INV-A");
        MockMintableERC20 tokenB = new MockMintableERC20("Invariant token B", "INV-B");
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        UniswapV3LiquidityAdapterHandler handler =
            new UniswapV3LiquidityAdapterHandler(adapter, positionManager, token0, token1);
        adapter.bindManager(address(handler));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 512
    function invariant_oneNftAndNoResidualAdapterAssets() public view {
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        uint256 livePositions = positionManager.mintCalls() - positionManager.burnCalls();
        assertEq(livePositions, tokenId == 0 ? 0 : 1);
        if (tokenId != 0) {
            (,, address positionToken0, address positionToken1,,,, uint128 liquidity,,,,) =
                positionManager.positions(tokenId);
            assertEq(positionToken0, address(token0));
            assertEq(positionToken1, address(token1));
            assertGt(liquidity, 0);
        }

        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(positionManager)), 0);
        assertEq(token1.allowance(address(adapter), address(positionManager)), 0);
        assertEq(positionManager.poolInitializationCalls(), 0);
    }
}

contract UniV3PoolStabilityGuardHandler {
    MockUniswapV3PoolLike public immutable pool;
    bool public expectedStable = true;

    constructor(MockUniswapV3PoolLike pool_) {
        pool = pool_;
    }

    function configure(int24 currentTick, int24 meanTick, bool hasHistory) external {
        pool.setSlot0(1, currentTick);
        pool.setTickCumulatives(0, int56(meanTick) * int56(uint56(30 minutes)));
        if (!hasHistory) pool.setHistoryLength(1);

        int256 deviation = int256(currentTick) - int256(meanTick);
        if (deviation < 0) deviation = -deviation;
        expectedStable = hasHistory && deviation <= 50;
    }
}

contract UniV3PoolStabilityGuardInvariantTest is StdInvariant, Test {
    MockUniswapV3PoolLike internal pool;
    UniV3PoolStabilityGuard internal guard;
    UniV3PoolStabilityGuardHandler internal handler;

    function setUp() public {
        MockUniswapV3FactoryLike factory = new MockUniswapV3FactoryLike();
        pool = new MockUniswapV3PoolLike();
        guard = new UniV3PoolStabilityGuard(IUniswapV3FactoryLike(address(factory)), 500);
        handler = new UniV3PoolStabilityGuardHandler(pool);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 512
    function invariant_guardMatchesDeviationAndHistoryPolicy() public view {
        (bool success,) = address(guard)
            .staticcall(abi.encodeCall(UniV3PoolStabilityGuard.assertStable, (address(pool))));
        assertEq(success, handler.expectedStable());
    }
}
