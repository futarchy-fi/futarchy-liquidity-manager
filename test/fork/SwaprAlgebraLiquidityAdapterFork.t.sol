// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
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

contract SwaprAlgebraLiquidityAdapterForkTest is Test {
    address internal constant GNOSIS_GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;

    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

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

        (uint256 amount0Out, uint256 amount1Out) = adapter.removeLiquidity(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            currentLiquidity,
            abi.encode(
                SwaprAlgebraLiquidityAdapter.ExitParams({
                    amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 20 minutes
                })
            )
        );

        assertGt(amount0Out + amount1Out, 0);
        assertEq(adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI), 0);

        uint256 gnoAfter = IERC20(GNOSIS_GNO).balanceOf(address(this));
        uint256 wxdaiAfter = IERC20(GNOSIS_WXDAI).balanceOf(address(this));
        assertGt(gnoAfter + wxdaiAfter, gnoBefore + wxdaiBefore - 2 ether);
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
            address(0xC0DE),
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
        uint160 spotPrice = _spotPrice();
        address yesPool =
            _initializeOutcomePool(address(yesCompany), address(yesCurrency), spotPrice);
        address noPool = _initializeOutcomePool(address(noCompany), address(noCurrency), spotPrice);

        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
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
            yesPool,
            noPool
        );

        SwaprAlgebraLiquidityAdapter spotAdapter = _newAdapter();
        SwaprAlgebraLiquidityAdapter conditionalAdapter = _newAdapter();
        FutarchyLiquidityManager manager = new FutarchyLiquidityManager(
            address(this),
            IERC20(GNOSIS_GNO),
            IWrappedNative(GNOSIS_WXDAI),
            address(0xC0DE),
            source,
            spotAdapter,
            conditionalAdapter,
            router,
            new MockPoolStabilityGuard(),
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Fork FLM", symbol: "fFLM"})
        );
        spotAdapter.bindManager(address(manager));
        conditionalAdapter.bindManager(address(manager));

        deal(GNOSIS_GNO, address(this), 1 ether);
        vm.deal(address(this), 10 ether);
        IERC20(GNOSIS_GNO).approve(address(manager), type(uint256).max);
        manager.initializeFromBootstrap{value: 2 ether}(0.02 ether);
        manager.sync();

        uint256 shares = manager.totalSupply() / 10;
        uint256 gasBefore = gasleft();
        manager.redeem(shares, address(this), false);
        uint256 redeemGas = gasBefore - gasleft();

        emit log_named_uint("conditional full-unwind redeem gas", redeemGas);
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

    function _initializeOutcomePool(address company, address currency, uint160 spotPrice)
        internal
        returns (address pool)
    {
        uint160 price = company < currency
            ? spotPrice
            : uint160((uint256(1) << 192) / uint256(spotPrice));
        address token0 = company < currency ? company : currency;
        address token1 = company < currency ? currency : company;
        pool = ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER)
            .createAndInitializePoolIfNecessary(token0, token1, price);
    }
}
