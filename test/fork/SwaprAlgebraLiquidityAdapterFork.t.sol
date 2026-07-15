// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {
    SwaprAlgebraDirectConditionalAdapter
} from "../../src/adapters/SwaprAlgebraDirectConditionalAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {MockConditionalRouter} from "../mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "../mocks/MockFutarchyLiquidityAdapter.sol";
import {MockFutarchyProposalLike} from "../mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "../mocks/MockOfficialProposalSource.sol";
import {MockPoolStabilityGuard} from "../mocks/MockPoolStabilityGuard.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {IAlgebraPoolLike} from "../../src/interfaces/IAlgebraPoolLike.sol";

interface IAlgebraSwapPool {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

contract SwaprAlgebraLiquidityAdapterForkTest is Test {
    address internal constant GNOSIS_GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;

    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_740;

    receive() external payable {}

    function testFork_add_and_remove_full_range_position() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraLiquidityAdapter adapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );
        adapter.bindManager(address(this));

        deal(GNOSIS_GNO, address(this), 2 ether);
        deal(GNOSIS_WXDAI, address(this), 2 ether);

        IERC20(GNOSIS_GNO).approve(address(adapter), type(uint256).max);
        IERC20(GNOSIS_WXDAI).approve(address(adapter), type(uint256).max);

        uint256 gnoBefore = IERC20(GNOSIS_GNO).balanceOf(address(this));
        uint256 wxdaiBefore = IERC20(GNOSIS_WXDAI).balanceOf(address(this));

        (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used) = adapter.addFullRangeLiquidity(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            1 ether,
            1 ether,
            abi.encode(
                SwaprAlgebraLiquidityAdapter.AddParams({
                    tickLower: FULL_RANGE_LOWER,
                    tickUpper: FULL_RANGE_UPPER,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 20 minutes,
                    sqrtPriceX96: 0
                })
            )
        );

        assertGt(liquidityMinted, 0);
        assertGt(amount0Used, 0);
        assertGt(amount1Used, 0);

        uint256 tokenId = adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI);
        assertGt(tokenId, 0);

        (,,,,,, uint128 currentLiquidity,,,,) =
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER).positions(tokenId);
        assertEq(currentLiquidity, liquidityMinted);

        address pool = IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(GNOSIS_GNO, GNOSIS_WXDAI);
        IAlgebraSwapPool(pool)
            .swap(
                address(this),
                true,
                int256(0.01 ether),
                MIN_SQRT_PRICE,
                abi.encode(GNOSIS_GNO, GNOSIS_WXDAI)
            );

        IFutarchyLiquidityAdapter.Removal memory fees =
            adapter.removeLiquidityDetailed(GNOSIS_GNO, GNOSIS_WXDAI, 0);
        assertEq(fees.principal0, 0);
        assertEq(fees.principal1, 0);
        assertGt(fees.fees0 + fees.fees1, 0);
        (,,,,,, uint128 liquidityAfterFeeCollection,,,,) =
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER).positions(tokenId);
        assertEq(liquidityAfterFeeCollection, currentLiquidity);
        assertEq(adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI), tokenId);

        IFutarchyLiquidityAdapter.Removal memory removed =
            adapter.removeLiquidityDetailed(GNOSIS_GNO, GNOSIS_WXDAI, currentLiquidity);
        uint256 amount0Out = removed.principal0 + removed.fees0;
        uint256 amount1Out = removed.principal1 + removed.fees1;

        assertEq(removed.fees0, 0);
        assertEq(removed.fees1, 0);
        assertGt(amount0Out + amount1Out, 0);
        assertEq(adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI), 0);

        uint256 gnoAfter = IERC20(GNOSIS_GNO).balanceOf(address(this));
        uint256 wxdaiAfter = IERC20(GNOSIS_WXDAI).balanceOf(address(this));
        assertGt(gnoAfter + wxdaiAfter, gnoBefore + wxdaiBefore - 2 ether);
    }

    function testFork_oneLiquidityUnitCanRoundTripToZeroFromIntegerRounding() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        MockMintableERC20 first = new MockMintableERC20("Round A", "RA");
        MockMintableERC20 second = new MockMintableERC20("Round B", "RB");
        address token0 = address(first) < address(second) ? address(first) : address(second);
        address token1 = address(first) < address(second) ? address(second) : address(first);

        SwaprAlgebraLiquidityAdapter adapter = _newAdapter();
        adapter.bindManager(address(this));
        MockMintableERC20(token0).mint(address(this), 1);
        MockMintableERC20(token1).mint(address(this), 1);
        IERC20(token0).approve(address(adapter), 1);
        IERC20(token1).approve(address(adapter), 1);

        (uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = adapter.addFullRangeLiquidity(
            token0,
            token1,
            1,
            1,
            abi.encode(
                SwaprAlgebraLiquidityAdapter.AddParams({
                    tickLower: FULL_RANGE_LOWER,
                    tickUpper: FULL_RANGE_UPPER,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 20 minutes,
                    sqrtPriceX96: uint160(1) << 96
                })
            )
        );

        assertEq(liquidity, 1);
        assertEq(amount0Used, 1);
        assertEq(amount1Used, 1);

        IFutarchyLiquidityAdapter.Removal memory removed =
            adapter.removeLiquidityDetailed(token0, token1, liquidity);
        uint256 amount0Out = removed.principal0 + removed.fees0;
        uint256 amount1Out = removed.principal1 + removed.fees1;

        assertEq(amount0Out, 0);
        assertEq(amount1Out, 0);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
    {
        (address token0, address token1) = abi.decode(data, (address, address));
        require(msg.sender == IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(token0, token1));
        if (amount0Delta > 0) {
            require(IERC20(token0).transfer(msg.sender, uint256(amount0Delta)));
        }
        if (amount1Delta > 0) {
            require(IERC20(token1).transfer(msg.sender, uint256(amount1Delta)));
        }
    }

    function testFork_publicVaultFullUnwindDepositAndRedeemFitsGnosisGas() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraLiquidityAdapter spotAdapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );
        FutarchyLiquidityManager manager = new FutarchyLiquidityManager(
            address(this),
            IERC20(GNOSIS_GNO),
            IWrappedNative(GNOSIS_WXDAI),
            new MockOfficialProposalSource(),
            spotAdapter,
            new MockFutarchyLiquidityAdapter(),
            new MockConditionalRouter(),
            new MockPoolStabilityGuard(),
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Fork FLM", symbol: "fFLM"})
        );
        spotAdapter.bindManager(address(manager));

        deal(GNOSIS_GNO, address(this), 1 ether);
        vm.deal(address(this), 10 ether);
        IERC20(GNOSIS_GNO).approve(address(manager), type(uint256).max);
        manager.initializeFromBootstrap{value: 2 ether}(0.02 ether);

        address depositor = address(0xBEEF);
        deal(GNOSIS_GNO, depositor, 1 ether);
        vm.deal(depositor, 10 ether);
        vm.startPrank(depositor);
        IERC20(GNOSIS_GNO).approve(address(manager), type(uint256).max);
        uint256 gasBefore = gasleft();
        uint256 shares = manager.depositToSpot{value: 2 ether}(0.02 ether);
        uint256 depositGas = gasBefore - gasleft();
        gasBefore = gasleft();
        manager.redeem(shares, depositor, false);
        uint256 redeemGas = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("full-unwind deposit gas", depositGas);
        emit log_named_uint("full-unwind redeem gas", redeemGas);
        assertLt(depositGas + 750_000, 17_000_000, "deposit exceeds Gnosis block gas");
        assertLt(redeemGas + 750_000, 17_000_000, "redeem exceeds Gnosis block gas");
    }

    function testFork_publicVaultConditionalRedeemFitsGnosisGas() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        MockMintableERC20 yesCompany = new MockMintableERC20("YES GNO", "YES-GNO");
        MockMintableERC20 noCompany = new MockMintableERC20("NO GNO", "NO-GNO");
        MockMintableERC20 yesCurrency = new MockMintableERC20("YES xDAI", "YES-xDAI");
        MockMintableERC20 noCurrency = new MockMintableERC20("NO xDAI", "NO-xDAI");

        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
        proposal.setQuestionAndCondition(bytes32(uint256(1)), bytes32(uint256(0xC0DE)));
        MockConditionalRouter router = new MockConditionalRouter();
        router.setOutcomeConfig(
            address(proposal), GNOSIS_GNO, address(yesCompany), address(noCompany), true
        );
        router.setOutcomeConfig(
            address(proposal), GNOSIS_WXDAI, address(yesCurrency), address(noCurrency), true
        );
        MockOfficialProposalSource source = new MockOfficialProposalSource();
        source.createProposalExtended(
            address(proposal),
            address(0xC0DE),
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency),
            address(0),
            address(0)
        );

        SwaprAlgebraLiquidityAdapter spotAdapter = _newAdapter();
        SwaprAlgebraDirectConditionalAdapter conditionalAdapter =
            new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        MockPoolStabilityGuard guard = new MockPoolStabilityGuard();
        guard.setSqrtPriceX96(_spotPrice());
        FutarchyLiquidityManager manager = new FutarchyLiquidityManager(
            address(this),
            IERC20(GNOSIS_GNO),
            IWrappedNative(GNOSIS_WXDAI),
            source,
            spotAdapter,
            conditionalAdapter,
            router,
            guard,
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Fork FLM", symbol: "fFLM"})
        );
        spotAdapter.bindManager(address(manager));
        conditionalAdapter.bindManager(address(manager));
        source.setPoolLookup(address(conditionalAdapter));

        deal(GNOSIS_GNO, address(this), 1 ether);
        vm.deal(address(this), 10 ether);
        IERC20(GNOSIS_GNO).approve(address(manager), type(uint256).max);
        manager.initializeFromBootstrap{value: 2 ether}(0.02 ether);
        source.activate(address(manager));

        assertTrue(manager.inConditionalMode());
        assertGt(manager.conditionalYesLiquidity(), 0);
        assertGt(manager.conditionalNoLiquidity(), 0);
        assertGt(manager.activeYesPool().code.length, 0);
        assertGt(manager.activeNoPool().code.length, 0);

        uint256 shares = manager.totalSupply() / 10;
        uint256 gasBefore = gasleft();
        manager.redeem(shares, address(this), false);
        uint256 redeemGas = gasBefore - gasleft();

        emit log_named_uint("conditional partial redeem gas", redeemGas);
        assertLt(redeemGas + 750_000, 17_000_000, "conditional redeem exceeds Gnosis block gas");
    }

    function _newAdapter() internal returns (SwaprAlgebraLiquidityAdapter) {
        return new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );
    }

    function _spotPrice() internal view returns (uint160 sqrtPriceX96) {
        address pool = IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(GNOSIS_GNO, GNOSIS_WXDAI);
        (sqrtPriceX96,,,,,,) = IAlgebraPoolLike(pool).globalState();
    }
}
