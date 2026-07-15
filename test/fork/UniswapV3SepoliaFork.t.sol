// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {UniswapV3LiquidityAdapter} from "../../src/adapters/UniswapV3LiquidityAdapter.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {UniV3PoolStabilityGuard} from "../../src/oracles/UniV3PoolStabilityGuard.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";

interface ISepoliaNonfungiblePositionManager is IUniswapV3NonfungiblePositionManager {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function ownerOf(uint256 tokenId) external view returns (address owner);
}

contract UniswapV3SepoliaForkTest is Test {
    uint256 private constant FORK_BLOCK = 11_254_684;
    address private constant POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;
    address private constant FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
    address private constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address private constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address private constant USDC_WETH_POOL = 0x3289680dD4d6C10bb19b899729cda5eEF58AEfF1;
    bytes32 private constant POSITION_MANAGER_CODEHASH =
        0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868;
    bytes32 private constant FACTORY_CODEHASH =
        0xacb5afea1f8877239fadd30358add13f2f9d4fb80175402c686d392295224fef;
    bytes32 private constant USDC_WETH_POOL_CODEHASH =
        0xfadf4ede8b01011fd675c19bd415a9498a66c18dd5d30c333a1d712b103f591f;

    uint24 private constant FEE = 500;
    int24 private constant FULL_RANGE_LOWER = -887_270;
    int24 private constant FULL_RANGE_UPPER = 887_270;
    uint160 private constant Q96 = 79_228_162_514_264_337_593_543_950_336;

    function testFork_adapterRoundTripsThroughRealPositionManager() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        _selectFork();
        ISepoliaNonfungiblePositionManager npm =
            ISepoliaNonfungiblePositionManager(POSITION_MANAGER);

        MockMintableERC20 tokenA = new MockMintableERC20("Fork token A", "FTA");
        MockMintableERC20 tokenB = new MockMintableERC20("Fork token B", "FTB");
        (MockMintableERC20 token0, MockMintableERC20 token1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        npm.createAndInitializePoolIfNecessary(address(token0), address(token1), FEE, Q96);

        UniswapV3LiquidityAdapter adapter =
            new UniswapV3LiquidityAdapter(npm, FULL_RANGE_LOWER, FULL_RANGE_UPPER);
        adapter.bindManager(address(this));
        token0.mint(address(this), 20 ether);
        token1.mint(address(this), 20 ether);
        token0.approve(address(adapter), type(uint256).max);
        token1.approve(address(adapter), type(uint256).max);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        (uint128 firstLiquidity,,) =
            adapter.addFullRangeLiquidity(address(token0), address(token1), 10 ether, 10 ether, "");
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        assertGt(tokenId, 0);
        assertEq(npm.ownerOf(tokenId), address(adapter));

        (uint128 secondLiquidity,,) =
            adapter.addFullRangeLiquidity(address(token0), address(token1), 5 ether, 5 ether, "");
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), tokenId);
        assertGt(secondLiquidity, 0);

        (,,,,,,, uint128 currentLiquidity,,,,) = npm.positions(tokenId);
        assertEq(currentLiquidity, firstLiquidity + secondLiquidity);
        IFutarchyLiquidityAdapter.Removal memory partialRemoval =
            adapter.removeLiquidityDetailed(address(token0), address(token1), currentLiquidity / 3);
        assertGt(partialRemoval.principal0 + partialRemoval.fees0, 0);
        assertGt(partialRemoval.principal1 + partialRemoval.fees1, 0);

        (,,,,,,, currentLiquidity,,,,) = npm.positions(tokenId);
        IFutarchyLiquidityAdapter.Removal memory finalRemoval =
            adapter.removeLiquidityDetailed(address(token0), address(token1), currentLiquidity);
        assertGt(finalRemoval.principal0 + finalRemoval.fees0, 0);
        assertGt(finalRemoval.principal1 + finalRemoval.fees1, 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
        vm.expectRevert();
        npm.ownerOf(tokenId);

        assertApproxEqAbs(token0.balanceOf(address(this)), balance0Before, 10);
        assertApproxEqAbs(token1.balanceOf(address(this)), balance1Before, 10);
        _assertAdapterEmpty(adapter, token0, token1);
    }

    function testFork_guardAcceptsMaturePoolAndRejectsFreshRealPool() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        _selectFork();
        IUniswapV3FactoryLike factory = IUniswapV3FactoryLike(FACTORY);
        UniV3PoolStabilityGuard guard = new UniV3PoolStabilityGuard(factory, FEE);

        assertEq(factory.getPool(USDC, WETH, FEE), USDC_WETH_POOL);
        assertEq(USDC_WETH_POOL.codehash, USDC_WETH_POOL_CODEHASH);
        guard.assertStablePair(WETH, USDC);

        MockMintableERC20 tokenA = new MockMintableERC20("Fresh token A", "FR-A");
        MockMintableERC20 tokenB = new MockMintableERC20("Fresh token B", "FR-B");
        (address token0, address token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        ISepoliaNonfungiblePositionManager(POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, FEE, Q96);

        vm.expectRevert(bytes("OLD"));
        guard.assertStablePair(token0, token1);
    }

    function _selectFork() private {
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string("https://sepolia.drpc.org"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(POSITION_MANAGER.codehash, POSITION_MANAGER_CODEHASH);
        assertEq(FACTORY.codehash, FACTORY_CODEHASH);
    }

    function _assertAdapterEmpty(UniswapV3LiquidityAdapter adapter, IERC20 token0, IERC20 token1)
        private
        view
    {
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), POSITION_MANAGER), 0);
        assertEq(token1.allowance(address(adapter), POSITION_MANAGER), 0);
    }
}
