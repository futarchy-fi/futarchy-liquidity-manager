// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

import {UniswapV3LiquidityAdapter} from "../src/adapters/UniswapV3LiquidityAdapter.sol";
import {IFutarchyLiquidityAdapter} from "../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockUniswapV3FactoryLike} from "./mocks/MockUniswapV3FactoryLike.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "./mocks/MockUniswapV3NonfungiblePositionManager.sol";

contract AdapterFeeOnTransferToken is ERC20 {
    constructor() ERC20("Adapter fee token", "AFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        super._transfer(from, to, amount - fee);
        _burn(from, fee);
    }
}

contract UniswapV3LiquidityAdapterTest is Test {
    int24 internal constant TICK_LOWER = -887_270;
    int24 internal constant TICK_UPPER = 887_270;
    uint160 internal constant Q96 = uint160(1) << 96;

    MockUniswapV3NonfungiblePositionManager internal positionManager;
    UniswapV3LiquidityAdapter internal adapter;
    MockMintableERC20 internal token0;
    MockMintableERC20 internal token1;

    address internal outsider = address(0xBAD);

    function setUp() public {
        positionManager = new MockUniswapV3NonfungiblePositionManager();
        adapter = _newAdapter();
        adapter.bindManager(address(this));

        MockMintableERC20 tokenA = new MockMintableERC20("Token A", "A");
        MockMintableERC20 tokenB = new MockMintableERC20("Token B", "B");
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);
        token0.approve(address(adapter), type(uint256).max);
        token1.approve(address(adapter), type(uint256).max);
    }

    function test_constructorFixesFeeRangeAndUsagePolicy() public view {
        assertEq(address(adapter.POSITION_MANAGER()), address(positionManager));
        assertEq(adapter.DEFAULT_TICK_LOWER(), TICK_LOWER);
        assertEq(adapter.DEFAULT_TICK_UPPER(), TICK_UPPER);
        assertEq(adapter.FEE(), 500);
        assertEq(adapter.TICK_SPACING(), 10);
        assertEq(adapter.MIN_USAGE_BPS(), 9950);
        assertEq(adapter.MANAGER(), address(this));
    }

    function test_constructorRejectsInvalidDependenciesAndRanges() public {
        vm.expectRevert(UniswapV3LiquidityAdapter.ZeroAddress.selector);
        new UniswapV3LiquidityAdapter(
            IUniswapV3NonfungiblePositionManager(address(0)), TICK_LOWER, TICK_UPPER
        );

        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTickRange.selector);
        new UniswapV3LiquidityAdapter(positionManager, TICK_UPPER, TICK_LOWER);

        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTickRange.selector);
        new UniswapV3LiquidityAdapter(positionManager, TICK_LOWER + 1, TICK_UPPER);

        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTickRange.selector);
        new UniswapV3LiquidityAdapter(positionManager, -887_280, TICK_UPPER);
    }

    function test_bindingIsAuthorityOnlyAndIrreversible() public {
        UniswapV3LiquidityAdapter candidate = _newAdapter();

        vm.expectRevert(UniswapV3LiquidityAdapter.UnauthorizedBindingAuthority.selector);
        vm.prank(outsider);
        candidate.bindManager(outsider);

        vm.expectRevert(UniswapV3LiquidityAdapter.ZeroAddress.selector);
        candidate.bindManager(address(0));

        candidate.bindManager(address(this));
        vm.expectRevert(UniswapV3LiquidityAdapter.ManagerAlreadyBound.selector);
        candidate.bindManager(outsider);
    }

    function test_liquidityOperationsAreManagerOnly() public {
        vm.startPrank(outsider);
        vm.expectRevert(UniswapV3LiquidityAdapter.UnauthorizedManager.selector);
        adapter.addFullRangeLiquidity(address(token0), address(token1), 0, 0, "");
        vm.expectRevert(UniswapV3LiquidityAdapter.UnauthorizedManager.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), 1);
        vm.stopPrank();
    }

    function test_rejectsEveryCallerSuppliedExecutionParameter() public {
        vm.expectRevert(UniswapV3LiquidityAdapter.UnsupportedData.selector);
        adapter.addFullRangeLiquidity(address(token0), address(token1), 1 ether, 1 ether, hex"01");

        _add(1 ether, 1 ether);
    }

    function test_firstAddUsesFixedPolicyRefundsAndClearsAllowances() public {
        positionManager.setUsageBps(9975);
        vm.warp(1_234_567);
        uint256 amount0Desired = 2 ether;
        uint256 amount1Desired = 1 ether;
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) =
            _add(amount0Desired, amount1Desired);

        assertEq(amount0Used, (amount0Desired * 9975) / 10_000);
        assertEq(amount1Used, (amount1Desired * 9975) / 10_000);
        assertEq(liquidity, amount1Used);
        assertEq(token0.balanceOf(address(this)), balance0Before - amount0Used);
        assertEq(token1.balanceOf(address(this)), balance1Before - amount1Used);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(positionManager)), 0);
        assertEq(token1.allowance(address(adapter), address(positionManager)), 0);
        assertEq(positionManager.lastFee(), 500);
        assertEq(positionManager.lastAmount0Min(), (amount0Desired * 9950) / 10_000);
        assertEq(positionManager.lastAmount1Min(), (amount1Desired * 9950) / 10_000);
        assertEq(positionManager.lastDeadline(), block.timestamp);
        assertEq(positionManager.lastRecipient(), address(adapter));
        assertEq(positionManager.mintCalls(), 1);
        assertEq(positionManager.increaseCalls(), 0);
        assertEq(positionManager.poolInitializationCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 1);
    }

    function test_freshAddCreatesPoolAndOwnsFirstNft() public {
        (address pool, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = adapter.addFreshFullRangeLiquidity(
            address(token0), address(token1), 2 ether, 1 ether, uint160(1) << 96
        );

        assertEq(pool, address(0xBEEF));
        assertEq(liquidity, 1 ether);
        assertEq(amount0Used, 2 ether);
        assertEq(amount1Used, 1 ether);
        assertEq(positionManager.poolInitializationCalls(), 1);
        assertEq(positionManager.mintCalls(), 1);
        assertEq(positionManager.lastRecipient(), address(adapter));
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 1);

        vm.expectRevert(
            abi.encodeWithSelector(UniswapV3LiquidityAdapter.PositionAlreadyExists.selector)
        );
        adapter.addFreshFullRangeLiquidity(
            address(token0), address(token1), 1 ether, 1 ether, uint160(1) << 96
        );
    }

    function test_freshAddRejectsUninitializedPoolBeforeCustody() public {
        address existingPool = address(0xCAFE);
        MockUniswapV3FactoryLike(positionManager.factory())
            .setPool(address(token0), address(token1), adapter.FEE(), existingPool);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapV3LiquidityAdapter.PoolAlreadyExists.selector, existingPool
            )
        );
        adapter.addFreshFullRangeLiquidity(
            address(token0), address(token1), 1 ether, 1 ether, uint160(1) << 96
        );

        assertEq(token0.balanceOf(address(this)), balance0Before);
        assertEq(token1.balanceOf(address(this)), balance1Before);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(positionManager.poolInitializationCalls(), 0);
        assertEq(positionManager.mintCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
    }

    function test_freshAddRejectsInitializedPoolsAtAnyPriceBeforeCustody() public {
        MockUniswapV3FactoryLike factory = MockUniswapV3FactoryLike(positionManager.factory());
        uint160[2] memory prices = [Q96, Q96 * 2];
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        for (uint256 i; i < prices.length; ++i) {
            factory.setPool(address(token0), address(token1), adapter.FEE(), address(0));
            address existingPool = positionManager.createAndInitializePoolIfNecessary(
                address(token0), address(token1), adapter.FEE(), prices[i]
            );
            assertEq(positionManager.lastPoolSqrtPriceX96(), prices[i]);
            uint256 initializationCalls = positionManager.poolInitializationCalls();

            vm.expectRevert(
                abi.encodeWithSelector(
                    UniswapV3LiquidityAdapter.PoolAlreadyExists.selector, existingPool
                )
            );
            adapter.addFreshFullRangeLiquidity(
                address(token0), address(token1), 1 ether, 1 ether, Q96
            );

            assertEq(positionManager.poolInitializationCalls(), initializationCalls);
            assertEq(token0.balanceOf(address(this)), balance0Before);
            assertEq(token1.balanceOf(address(this)), balance1Before);
            assertEq(token0.balanceOf(address(adapter)), 0);
            assertEq(token1.balanceOf(address(adapter)), 0);
        }
        assertEq(positionManager.mintCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
    }

    function test_freshAddPoolCreateAndInitializeFailuresRollBack() public {
        MockUniswapV3FactoryLike factory = MockUniswapV3FactoryLike(positionManager.factory());
        bytes4[2] memory errors = [
            MockUniswapV3NonfungiblePositionManager.PoolCreationFailed.selector,
            MockUniswapV3NonfungiblePositionManager.PoolInitializationFailed.selector
        ];
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        for (uint8 phase = 1; phase <= errors.length; ++phase) {
            positionManager.setPoolLifecycleFailure(phase);
            vm.expectRevert(errors[phase - 1]);
            adapter.addFreshFullRangeLiquidity(
                address(token0), address(token1), 1 ether, 1 ether, Q96
            );

            assertEq(factory.getPool(address(token0), address(token1), adapter.FEE()), address(0));
            assertEq(token0.balanceOf(address(this)), balance0Before);
            assertEq(token1.balanceOf(address(this)), balance1Before);
            assertEq(token0.balanceOf(address(adapter)), 0);
            assertEq(token1.balanceOf(address(adapter)), 0);
        }
        assertEq(token0.allowance(address(adapter), address(positionManager)), 0);
        assertEq(token1.allowance(address(adapter), address(positionManager)), 0);
        assertEq(positionManager.poolInitializationCalls(), 0);
        assertEq(positionManager.lastPoolSqrtPriceX96(), 0);
        assertEq(positionManager.mintCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
    }

    function test_freshAddFirstMintFailureRollsBackPoolAndCustody() public {
        positionManager.setUsageBps(9949);
        MockUniswapV3FactoryLike factory = MockUniswapV3FactoryLike(positionManager.factory());
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        vm.expectRevert();
        adapter.addFreshFullRangeLiquidity(
            address(token0), address(token1), 2 ether, 1 ether, uint160(1) << 96
        );

        assertEq(factory.getPool(address(token0), address(token1), adapter.FEE()), address(0));
        assertEq(token0.balanceOf(address(this)), balance0Before);
        assertEq(token1.balanceOf(address(this)), balance1Before);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(token0.allowance(address(adapter), address(positionManager)), 0);
        assertEq(token1.allowance(address(adapter), address(positionManager)), 0);
        assertEq(positionManager.poolInitializationCalls(), 0);
        assertEq(positionManager.mintCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
    }

    function test_secondAddIncreasesTheSameNft() public {
        (uint128 firstLiquidity,,) = _add(2 ether, 2 ether);
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        (uint128 secondLiquidity,,) = _add(1 ether, 1 ether);

        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), tokenId);
        assertEq(positionManager.mintCalls(), 1);
        assertEq(positionManager.increaseCalls(), 1);
        assertEq(positionManager.nextTokenId(), 2);
        assertEq(_positionLiquidity(tokenId), firstLiquidity + secondLiquidity);
        assertEq(positionManager.poolInitializationCalls(), 0);
    }

    function test_addRevertsAtomicallyBelowTheFixedMinimum() public {
        positionManager.setUsageBps(9949);
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        vm.expectRevert();
        _add(2 ether, 1 ether);

        assertEq(token0.balanceOf(address(this)), balance0Before);
        assertEq(token1.balanceOf(address(this)), balance1Before);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(positionManager.mintCalls(), 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
    }

    function test_exactPullRejectsFeeOnTransferTokens() public {
        AdapterFeeOnTransferToken feeToken = new AdapterFeeOnTransferToken();
        MockMintableERC20 normalToken = new MockMintableERC20("Normal", "NORM");
        (address first, address second) = address(feeToken) < address(normalToken)
            ? (address(feeToken), address(normalToken))
            : (address(normalToken), address(feeToken));
        UniswapV3LiquidityAdapter candidate = _newAdapter();
        candidate.bindManager(address(this));
        feeToken.mint(address(this), 2 ether);
        normalToken.mint(address(this), 2 ether);
        feeToken.approve(address(candidate), type(uint256).max);
        normalToken.approve(address(candidate), type(uint256).max);

        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidAssetTransfer.selector);
        candidate.addFullRangeLiquidity(first, second, 1 ether, 1 ether, "");

        assertEq(candidate.getPositionTokenId(first, second), 0);
        assertEq(positionManager.mintCalls(), 0);
    }

    function test_partialThenFullRemovalCollectsAndBurnsThePosition() public {
        (uint128 liquidity,,) = _add(10 ether, 10 ether);
        uint256 tokenId = adapter.getPositionTokenId(address(token0), address(token1));
        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);
        positionManager.accrueFees(tokenId, 1 ether, 2 ether);

        IFutarchyLiquidityAdapter.Removal memory removed =
            adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        assertEq(removed.principal0, 0);
        assertEq(removed.principal1, 0);
        assertEq(removed.fees0, 1 ether);
        assertEq(removed.fees1, 2 ether);
        assertEq(_positionLiquidity(tokenId), liquidity);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), tokenId);

        positionManager.accrueFees(tokenId, 3 ether, 4 ether);

        vm.warp(7_654_321);
        removed = adapter.removeLiquidityDetailed(address(token0), address(token1), 4 ether);
        assertEq(removed.principal0, 4 ether);
        assertEq(removed.principal1, 4 ether);
        assertEq(removed.fees0, 3 ether);
        assertEq(removed.fees1, 4 ether);
        assertEq(_positionLiquidity(tokenId), liquidity - 4 ether);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), tokenId);
        assertEq(positionManager.lastAmount0Min(), 0);
        assertEq(positionManager.lastAmount1Min(), 0);
        assertEq(positionManager.lastDeadline(), block.timestamp);
        assertEq(positionManager.lastRecipient(), address(this));
        assertEq(positionManager.burnCalls(), 0);

        removed =
            adapter.removeLiquidityDetailed(address(token0), address(token1), liquidity - 4 ether);
        assertEq(removed.principal0, 6 ether);
        assertEq(removed.principal1, 6 ether);
        assertEq(removed.fees0, 0);
        assertEq(removed.fees1, 0);
        assertEq(adapter.getPositionTokenId(address(token0), address(token1)), 0);
        assertEq(positionManager.burnCalls(), 1);
    }

    function test_removeRejectsMissingZeroAndExcessLiquidity() public {
        vm.expectRevert(UniswapV3LiquidityAdapter.PositionNotFound.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), 1);

        (uint128 liquidity,,) = _add(1 ether, 1 ether);
        adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        vm.expectRevert(UniswapV3LiquidityAdapter.InsufficientPositionLiquidity.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), liquidity + 1);
    }

    function test_rejectsZeroReversedAndEqualTokenPairs() public {
        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTokenOrder.selector);
        adapter.addFullRangeLiquidity(address(0), address(token1), 1, 1, "");
        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTokenOrder.selector);
        adapter.addFullRangeLiquidity(address(token1), address(token0), 1, 1, "");
        vm.expectRevert(UniswapV3LiquidityAdapter.InvalidTokenOrder.selector);
        adapter.getPositionTokenId(address(token0), address(token0));
    }

    function _newAdapter() internal returns (UniswapV3LiquidityAdapter) {
        return new UniswapV3LiquidityAdapter(positionManager, TICK_LOWER, TICK_UPPER);
    }

    function _add(uint256 amount0, uint256 amount1)
        internal
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        return adapter.addFullRangeLiquidity(address(token0), address(token1), amount0, amount1, "");
    }

    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }
}
