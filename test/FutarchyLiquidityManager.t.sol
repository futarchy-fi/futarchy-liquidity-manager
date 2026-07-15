// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "./mocks/MockOfficialProposalSource.sol";
import {MockPoolStabilityGuard} from "./mocks/MockPoolStabilityGuard.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract FutarchyLiquidityManagerTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockOfficialProposalSource internal proposalSource;
    MockFutarchyLiquidityAdapter internal spotAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal router;
    MockPoolStabilityGuard internal stabilityGuard;
    FutarchyLiquidityManager internal manager;

    MockMintableERC20 internal yesCompany;
    MockMintableERC20 internal noCompany;
    MockMintableERC20 internal yesCurrency;
    MockMintableERC20 internal noCurrency;
    MockFutarchyProposalLike internal proposal;

    address internal owner = address(this);
    address internal bootstrapRecipient = address(0xB007);
    address internal officialProposer = address(0x0FF1C1A1);
    address internal depositor = address(0xD0E);
    address internal secondDepositor = address(0xD0E2);

    uint256 internal constant SEED_COMPANY = 100 ether;
    uint256 internal constant SEED_NATIVE = 100 ether;
    bytes32 internal constant CONDITION_ID = bytes32(uint256(0xC0DE));

    receive() external payable {}

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        proposalSource = new MockOfficialProposalSource();
        spotAdapter = new MockFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        router = new MockConditionalRouter();
        stabilityGuard = new MockPoolStabilityGuard();

        manager = _newManager(
            company,
            IWrappedNative(address(wrappedNative)),
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            router,
            stabilityGuard
        );

        yesCompany = new MockMintableERC20("YES_COMP", "YES_COMP");
        noCompany = new MockMintableERC20("NO_COMP", "NO_COMP");
        yesCurrency = new MockMintableERC20("YES_CURR", "YES_CURR");
        noCurrency = new MockMintableERC20("NO_CURR", "NO_CURR");
        proposal = new MockFutarchyProposalLike(
            address(company),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
        proposal.setQuestionAndCondition(bytes32(uint256(1)), CONDITION_ID);
        proposalSource.setPoolLookup(address(conditionalAdapter));

        _fundAndApprove(bootstrapRecipient, manager, company, 1000 ether);
        _fundAndApprove(depositor, manager, company, 1000 ether);
        _fundAndApprove(secondDepositor, manager, company, 1000 ether);
    }

    function test_source_only_activation_and_sync_cannot_activate() public {
        _bootstrap();
        _registerProposal(true);

        FutarchyLiquidityManager.SyncAction action = manager.sync();
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.None));
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 100 ether);

        IFutarchyOfficialProposalSource.ProposalActivationData memory activation =
            IFutarchyOfficialProposalSource.ProposalActivationData({
                proposalId: proposalSource.proposalId(),
                proposal: address(proposal),
                conditionId: CONDITION_ID,
                proposalToken: address(company),
                collateralToken: address(wrappedNative),
                yesCompanyToken: address(yesCompany),
                noCompanyToken: address(noCompany),
                yesCurrencyToken: address(yesCurrency),
                noCurrencyToken: address(noCurrency)
            });
        vm.expectRevert(FutarchyLiquidityManager.OnlyProposalSource.selector);
        manager.activateOfficialProposal(activation);

        proposalSource.activate(address(manager));
        assertTrue(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);
    }

    function test_activation_binds_fresh_code_bearing_pools_back_from_source() public {
        _bootstrap();
        _registerProposal(true);

        proposalSource.activate(address(manager));

        address yesPool = manager.activeYesPool();
        address noPool = manager.activeNoPool();
        assertGt(yesPool.code.length, 0);
        assertGt(noPool.code.length, 0);
        assertTrue(yesPool != noPool);
        IFutarchyOfficialProposalSource.OfficialProposalData memory rebound =
            proposalSource.officialProposalExtended();
        assertEq(rebound.yesPool, yesPool);
        assertEq(rebound.noPool, noPool);
        assertEq(manager.activeConditionId(), CONDITION_ID);
        assertFalse(manager.canActivateOfficialProposal());
    }

    function test_activation_rejects_preexisting_pool_atomically() public {
        _bootstrap();
        _registerProposalWithPools(true, address(0xCAFE), address(0xBEEF));
        conditionalAdapter.setFreshPool(address(yesCompany), address(yesCurrency), address(0xCAFE));

        vm.expectRevert();
        proposalSource.activate(address(manager));

        _assertActivationRolledBack();
    }

    function test_activation_rejects_resolved_condition_before_removing_spot() public {
        _bootstrap();
        _registerProposal(true);
        router.setPayouts(1, 1, 0);

        vm.expectRevert(FutarchyLiquidityManager.ConditionAlreadyResolved.selector);
        proposalSource.activate(address(manager));

        _assertActivationRolledBack();
    }

    function test_activation_guard_failure_rolls_back_every_side_effect() public {
        _bootstrap();
        _registerProposal(true);
        stabilityGuard.setPairFailure(manager.TOKEN0(), manager.TOKEN1(), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                MockPoolStabilityGuard.PairRejected.selector, manager.TOKEN0(), manager.TOKEN1()
            )
        );
        proposalSource.activate(address(manager));

        _assertActivationRolledBack();
    }

    function test_fresh_pool_price_orientation_covers_both_ordering_parities() public {
        _assertFreshPriceOrientation(0, true, true);
        _assertFreshPriceOrientation(1, true, false);
        _assertFreshPriceOrientation(2, false, true);
        _assertFreshPriceOrientation(3, false, false);
    }

    function test_source_clear_and_spot_guard_failure_do_not_block_settlement() public {
        _bootstrap();
        _activateProposal(true);
        proposalSource.clearProposal();
        stabilityGuard.setPairFailure(manager.TOKEN0(), manager.TOKEN1(), true);
        router.setPayouts(1, 1, 0);

        FutarchyLiquidityManager.SyncAction action = manager.sync();

        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(company.balanceOf(address(manager)), 80 ether);
        assertEq(wrappedNative.balanceOf(address(manager)), 80 ether);
        assertEq(manager.activeProposal(), address(0));
        assertEq(manager.activeConditionId(), bytes32(0));
    }

    function test_settlement_requires_an_exact_binary_payout() public {
        _bootstrap();
        _activateProposal(true);

        router.setPayouts(0, 1, 0);
        vm.expectRevert(FutarchyLiquidityManager.InvalidSettlementOutcome.selector);
        manager.sync();

        router.setPayouts(2, 1, 1);
        vm.expectRevert(FutarchyLiquidityManager.InvalidSettlementOutcome.selector);
        manager.sync();

        router.setPayouts(2, 2, 2);
        vm.expectRevert(FutarchyLiquidityManager.InvalidSettlementOutcome.selector);
        manager.sync();

        assertTrue(manager.inConditionalMode());
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);
    }

    function test_settlement_consumes_unmatched_losing_residue() public {
        _bootstrap();
        _activateProposal(true);
        _accruePairFees(conditionalAdapter, noCompany, noCurrency, 3 ether, 5 ether);
        router.setPayouts(1, 1, 0);

        manager.sync();

        assertFalse(manager.inConditionalMode());
        assertEq(noCompany.balanceOf(address(router)), 83 ether);
        assertEq(noCurrency.balanceOf(address(router)), 85 ether);
        assertEq(yesCompany.balanceOf(address(manager)), 0);
        assertEq(noCompany.balanceOf(address(manager)), 0);
        assertEq(yesCurrency.balanceOf(address(manager)), 0);
        assertEq(noCurrency.balanceOf(address(manager)), 0);
    }

    function test_spot_redeem_is_proportional_across_principal_fees_and_idle() public {
        _bootstrap();
        vm.prank(depositor);
        manager.depositToSpot{value: 100 ether}(100 ether);
        _accruePairFees(spotAdapter, company, wrappedNative, 20 ether, 40 ether);
        company.mint(address(manager), 10 ether);
        wrappedNative.mint(address(manager), 30 ether);
        stabilityGuard.setPairFailure(manager.TOKEN0(), manager.TOKEN1(), true);
        uint256 addCallsBefore = spotAdapter.addCalls();

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(100 ether, bootstrapRecipient, false);

        assertEq(companyOut, 115 ether);
        assertEq(collateralOut, 135 ether);
        assertEq(manager.totalSupply(), 100 ether);
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(company.balanceOf(address(manager)), 15 ether);
        assertEq(wrappedNative.balanceOf(address(manager)), 35 ether);
        assertEq(spotAdapter.addCalls(), addCallsBefore);
    }

    function test_conditional_redeem_is_proportional_without_add_or_guard() public {
        _bootstrap();
        vm.prank(depositor);
        manager.depositToSpot{value: 100 ether}(100 ether);
        _activateProposal(true);

        _accruePairFees(conditionalAdapter, yesCompany, yesCurrency, 4 ether, 8 ether);
        _accruePairFees(conditionalAdapter, noCompany, noCurrency, 12 ether, 16 ether);
        yesCompany.mint(address(manager), 10 ether);
        yesCurrency.mint(address(manager), 20 ether);
        noCompany.mint(address(manager), 30 ether);
        noCurrency.mint(address(manager), 40 ether);

        stabilityGuard.setPairFailure(manager.TOKEN0(), manager.TOKEN1(), true);
        stabilityGuard.setPairFailure(address(yesCompany), address(yesCurrency), true);
        stabilityGuard.setPairFailure(address(noCompany), address(noCurrency), true);
        uint256 spotAddsBefore = spotAdapter.addCalls();
        uint256 freshAddsBefore = conditionalAdapter.addFreshCalls();
        uint256 conditionalAddsBefore = conditionalAdapter.addCalls();

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(100 ether, bootstrapRecipient, false);

        assertEq(companyOut, 107 ether);
        assertEq(collateralOut, 114 ether);
        assertEq(noCompany.balanceOf(bootstrapRecipient), 14 ether);
        assertEq(noCurrency.balanceOf(bootstrapRecipient), 14 ether);
        assertEq(manager.totalSupply(), 100 ether);
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);
        assertEq(spotAdapter.addCalls(), spotAddsBefore);
        assertEq(conditionalAdapter.addFreshCalls(), freshAddsBefore);
        assertEq(conditionalAdapter.addCalls(), conditionalAddsBefore);
    }

    function test_nonfinal_redeem_reverts_when_every_liquidity_slice_rounds_to_zero() public {
        _bootstrap();
        _activateProposal(true);
        vm.prank(bootstrapRecipient);
        manager.transfer(depositor, 1);

        vm.prank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.ZeroRedeemLiquidity.selector);
        manager.redeem(1, depositor, false);

        assertEq(manager.balanceOf(depositor), 1);
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);
    }

    function test_conditional_redeem_falls_back_to_in_kind_when_merge_reverts() public {
        _bootstrap();
        _activateProposal(true);
        router.setMergeReverts(true);

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(10 ether, bootstrapRecipient, false);

        assertEq(companyOut, 2 ether);
        assertEq(collateralOut, 2 ether);
        assertEq(yesCompany.balanceOf(bootstrapRecipient), 8 ether);
        assertEq(noCompany.balanceOf(bootstrapRecipient), 8 ether);
        assertEq(yesCurrency.balanceOf(bootstrapRecipient), 8 ether);
        assertEq(noCurrency.balanceOf(bootstrapRecipient), 8 ether);
    }

    function test_final_unresolved_redeem_does_not_block_later_settlement() public {
        _bootstrap();
        _activateProposal(true);

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(100 ether, bootstrapRecipient, false);

        assertEq(companyOut, 100 ether);
        assertEq(collateralOut, 100 ether);
        assertEq(manager.totalSupply(), 0);
        assertTrue(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);

        router.setPayouts(1, 1, 0);
        FutarchyLiquidityManager.SyncAction action = manager.sync();

        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));
        assertFalse(manager.inConditionalMode());
        assertEq(manager.activeProposal(), address(0));
        assertEq(manager.activeConditionId(), bytes32(0));
    }

    function test_deposit_mints_proportional_shares() public {
        _bootstrap();

        vm.prank(depositor);
        uint256 sharesMinted = manager.depositToSpot{value: 50 ether}(50 ether);

        assertEq(sharesMinted, 50 ether);
        assertEq(manager.balanceOf(depositor), 50 ether);
        assertEq(manager.totalSupply(), 150 ether);
        assertEq(manager.spotLiquidity(), 150 ether);
    }

    function test_bootstrap_deposit_and_redeem_with_erc20_collateral() public {
        MockMintableERC20 collateral = new MockMintableERC20("Savings DAI", "sDAI");
        MockFutarchyLiquidityAdapter localSpotAdapter = new MockFutarchyLiquidityAdapter();
        FutarchyLiquidityManager erc20Manager = _newManager(
            company,
            IWrappedNative(address(collateral)),
            proposalSource,
            localSpotAdapter,
            conditionalAdapter,
            router,
            stabilityGuard
        );

        collateral.mint(bootstrapRecipient, 1000 ether);
        vm.startPrank(bootstrapRecipient);
        company.approve(address(erc20Manager), type(uint256).max);
        collateral.approve(address(erc20Manager), type(uint256).max);
        erc20Manager.initializeFromBootstrap(SEED_COMPANY, SEED_NATIVE);
        vm.stopPrank();

        collateral.mint(depositor, 1000 ether);
        vm.startPrank(depositor);
        company.approve(address(erc20Manager), type(uint256).max);
        collateral.approve(address(erc20Manager), type(uint256).max);
        uint256 sharesMinted = erc20Manager.depositToSpot(50 ether, 50 ether);
        (uint256 companyOut, uint256 collateralOut) =
            erc20Manager.redeem(25 ether, depositor, false);
        vm.stopPrank();

        assertEq(sharesMinted, 50 ether);
        assertEq(companyOut, 25 ether);
        assertEq(collateralOut, 25 ether);
    }

    function test_emergency_arm_blocks_deposit_and_activation_but_redeem_works() public {
        _bootstrap();
        _registerProposal(true);
        manager.armEmergencyExit();

        vm.prank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.depositToSpot{value: 1 ether}(1 ether);

        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        proposalSource.activate(address(manager));

        vm.prank(bootstrapRecipient);
        (uint256 companyOut,) = manager.redeem(10 ether, bootstrapRecipient, true);
        assertEq(companyOut, 10 ether);
    }

    function test_emergency_exit_keeps_conditional_assets_redeemable() public {
        _bootstrap();
        _activateProposal(true);
        manager.armEmergencyExit();
        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitDelayActive.selector);
        manager.executeEmergencyExit();

        vm.warp(block.timestamp + manager.EMERGENCY_EXIT_DELAY());
        manager.executeEmergencyExit();

        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertTrue(manager.emergencyExitExecuted());

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(100 ether, bootstrapRecipient, true);
        assertEq(companyOut, 100 ether);
        assertEq(collateralOut, 100 ether);
    }

    function test_emergency_controls_are_owner_only() public {
        _bootstrap();

        vm.startPrank(depositor);
        vm.expectRevert();
        manager.armEmergencyExit();
        vm.expectRevert();
        manager.sweepIdleToBootstrapRecipient(true);
        vm.expectRevert();
        manager.executeEmergencyExit();
        vm.stopPrank();
    }

    function test_sweep_idle_requires_zero_share_supply() public {
        _bootstrap();
        vm.expectRevert(FutarchyLiquidityManager.SharesOutstanding.selector);
        manager.sweepIdleToBootstrapRecipient(true);

        vm.prank(bootstrapRecipient);
        manager.redeem(100 ether, bootstrapRecipient, true);
        company.mint(address(manager), 3 ether);
        wrappedNative.mint(address(manager), 4 ether);
        vm.deal(address(wrappedNative), 1000 ether);
        uint256 companyBefore = company.balanceOf(bootstrapRecipient);
        uint256 nativeBefore = bootstrapRecipient.balance;

        manager.sweepIdleToBootstrapRecipient(true);

        assertEq(company.balanceOf(bootstrapRecipient), companyBefore + 3 ether);
        assertEq(bootstrapRecipient.balance, nativeBefore + 4 ether);
    }

    function test_lifecycle_requires_bootstrap() public {
        _registerProposal(true);

        vm.prank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.NotInitialized.selector);
        manager.depositToSpot{value: 1 ether}(1 ether);

        vm.expectRevert(FutarchyLiquidityManager.NotInitialized.selector);
        proposalSource.activate(address(manager));
    }

    function test_constructor_rejects_zero_stability_guard() public {
        vm.expectRevert(FutarchyLiquidityManager.ZeroAddress.selector);
        _newManager(
            company,
            IWrappedNative(address(wrappedNative)),
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            router,
            MockPoolStabilityGuard(address(0))
        );
    }

    function test_merge_outcome_slice_is_self_only() public {
        vm.expectRevert(FutarchyLiquidityManager.OnlySelf.selector);
        manager.mergeOutcomeSlice(true, 1);
    }

    function testFuzz_spot_redeem_preserves_survivor_liquidity(
        uint96 depositSeed,
        uint96 redeemSeed
    ) public {
        _bootstrap();
        uint256 depositAmount = bound(uint256(depositSeed), 1e9, 250 ether);
        vm.prank(depositor);
        manager.depositToSpot{value: depositAmount}(depositAmount);
        uint256 shares = bound(uint256(redeemSeed), 1, depositAmount);
        uint256 supplyBefore = manager.totalSupply();
        uint128 liquidityBefore = manager.spotLiquidity();

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) = manager.redeem(shares, depositor, true);

        assertEq(companyOut, shares);
        assertEq(collateralOut, shares);
        assertEq(
            manager.spotLiquidity(),
            liquidityBefore - uint128(Math.mulDiv(liquidityBefore, shares, supplyBefore))
        );
    }

    function _newManager(
        MockMintableERC20 companyToken,
        IWrappedNative collateralToken,
        MockOfficialProposalSource source,
        MockFutarchyLiquidityAdapter spot,
        MockFutarchyLiquidityAdapter conditional,
        MockConditionalRouter conditionalRouter,
        MockPoolStabilityGuard guard
    ) internal returns (FutarchyLiquidityManager) {
        return new FutarchyLiquidityManager(
            bootstrapRecipient,
            companyToken,
            collateralToken,
            source,
            spot,
            conditional,
            conditionalRouter,
            guard,
            owner,
            FutarchyLiquidityManager.LpTokenMetadata({name: "Futarchy LP", symbol: "fLP"})
        );
    }

    function _bootstrap() internal {
        vm.prank(bootstrapRecipient);
        uint128 liquidityMinted = manager.initializeFromBootstrap{value: SEED_NATIVE}(SEED_COMPANY);
        assertEq(liquidityMinted, 100 ether);
        assertEq(manager.balanceOf(bootstrapRecipient), 100 ether);
        assertEq(manager.spotLiquidity(), 100 ether);
    }

    function _registerProposal(bool winnerIsYes) internal {
        _registerProposalWithPools(winnerIsYes, address(0), address(0));
    }

    function _registerProposalWithPools(bool winnerIsYes, address yesPool, address noPool)
        internal
    {
        proposalSource.createProposalExtended(
            address(proposal),
            officialProposer,
            address(company),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency),
            yesPool,
            noPool
        );
        router.setOutcomeConfig(
            address(proposal),
            address(company),
            address(yesCompany),
            address(noCompany),
            winnerIsYes
        );
        router.setOutcomeConfig(
            address(proposal),
            address(wrappedNative),
            address(yesCurrency),
            address(noCurrency),
            winnerIsYes
        );
    }

    function _activateProposal(bool winnerIsYes) internal {
        _registerProposal(winnerIsYes);
        proposalSource.activate(address(manager));
    }

    function _assertActivationRolledBack() internal view {
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(conditionalAdapter.addFreshCalls(), 0);
        assertEq(spotAdapter.removeDetailedCalls(), 0);
    }

    function _accruePairFees(
        MockFutarchyLiquidityAdapter adapter,
        IERC20 tokenA,
        IERC20 tokenB,
        uint256 amountA,
        uint256 amountB
    ) internal {
        MockMintableERC20(address(tokenA)).mint(address(this), amountA);
        MockMintableERC20(address(tokenB)).mint(address(this), amountB);
        tokenA.approve(address(adapter), amountA);
        tokenB.approve(address(adapter), amountB);
        if (address(tokenA) < address(tokenB)) {
            adapter.accrueFees(address(tokenA), address(tokenB), amountA, amountB);
        } else {
            adapter.accrueFees(address(tokenB), address(tokenA), amountB, amountA);
        }
    }

    function _fundAndApprove(
        address account,
        FutarchyLiquidityManager target,
        MockMintableERC20 token,
        uint256 amount
    ) internal {
        token.mint(account, amount);
        vm.deal(account, amount);
        vm.prank(account);
        token.approve(address(target), type(uint256).max);
    }

    function _assertFreshPriceOrientation(
        uint256 caseId,
        bool companyIsToken0,
        bool outcomeCompanyIsToken0
    ) internal {
        uint160 guardedSqrtPriceX96 = (uint160(3) << 95) + 17;
        uint256 base = 0x100000 + (caseId * 0x10000);
        address companyAddress = address(uint160(base + (companyIsToken0 ? 0x100 : 0x200)));
        address wrappedAddress = address(uint160(base + (companyIsToken0 ? 0x200 : 0x100)));
        address yesCompanyAddress =
            address(uint160(base + (outcomeCompanyIsToken0 ? 0x300 : 0x400)));
        address yesCurrencyAddress =
            address(uint160(base + (outcomeCompanyIsToken0 ? 0x400 : 0x300)));
        address noCompanyAddress = address(uint160(base + (outcomeCompanyIsToken0 ? 0x500 : 0x600)));
        address noCurrencyAddress =
            address(uint160(base + (outcomeCompanyIsToken0 ? 0x600 : 0x500)));

        vm.etch(companyAddress, address(company).code);
        vm.etch(wrappedAddress, address(wrappedNative).code);
        vm.etch(yesCompanyAddress, address(company).code);
        vm.etch(yesCurrencyAddress, address(company).code);
        vm.etch(noCompanyAddress, address(company).code);
        vm.etch(noCurrencyAddress, address(company).code);

        MockMintableERC20 localCompany = MockMintableERC20(companyAddress);
        MockWrappedNative localWrapped = MockWrappedNative(payable(wrappedAddress));
        MockOfficialProposalSource localSource = new MockOfficialProposalSource();
        MockFutarchyLiquidityAdapter localSpotAdapter = new MockFutarchyLiquidityAdapter();
        MockFutarchyLiquidityAdapter localConditionalAdapter = new MockFutarchyLiquidityAdapter();
        MockConditionalRouter localRouter = new MockConditionalRouter();
        MockPoolStabilityGuard localGuard = new MockPoolStabilityGuard();
        localGuard.setSqrtPriceX96(guardedSqrtPriceX96);
        localSource.setPoolLookup(address(localConditionalAdapter));
        FutarchyLiquidityManager localManager = _newManager(
            localCompany,
            IWrappedNative(address(localWrapped)),
            localSource,
            localSpotAdapter,
            localConditionalAdapter,
            localRouter,
            localGuard
        );
        MockFutarchyProposalLike localProposal = new MockFutarchyProposalLike(
            companyAddress,
            wrappedAddress,
            yesCompanyAddress,
            noCompanyAddress,
            yesCurrencyAddress,
            noCurrencyAddress
        );
        localProposal.setQuestionAndCondition(bytes32(uint256(1)), CONDITION_ID);

        localCompany.mint(bootstrapRecipient, 100 ether);
        vm.deal(bootstrapRecipient, 100 ether);
        vm.startPrank(bootstrapRecipient);
        localCompany.approve(address(localManager), type(uint256).max);
        localManager.initializeFromBootstrap{value: 100 ether}(100 ether);
        vm.stopPrank();
        localRouter.setOutcomeConfig(
            address(localProposal), companyAddress, yesCompanyAddress, noCompanyAddress, true
        );
        localRouter.setOutcomeConfig(
            address(localProposal), wrappedAddress, yesCurrencyAddress, noCurrencyAddress, true
        );
        localSource.createProposalExtended(
            address(localProposal),
            officialProposer,
            companyAddress,
            wrappedAddress,
            yesCompanyAddress,
            noCompanyAddress,
            yesCurrencyAddress,
            noCurrencyAddress,
            address(0),
            address(0)
        );
        localSource.activate(address(localManager));

        uint160 expected = companyIsToken0 == outcomeCompanyIsToken0
            ? guardedSqrtPriceX96
            : uint160(Math.ceilDiv(uint256(1) << 192, guardedSqrtPriceX96));
        assertEq(
            localConditionalAdapter.freshSqrtPriceX96ByPair(
                _pairKey(yesCompanyAddress, yesCurrencyAddress)
            ),
            expected
        );
        assertEq(
            localConditionalAdapter.freshSqrtPriceX96ByPair(
                _pairKey(noCompanyAddress, noCurrencyAddress)
            ),
            expected
        );
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
    }
}
