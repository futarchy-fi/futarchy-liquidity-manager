// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "./mocks/MockOfficialProposalSource.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract FutarchyLiquidityManagerTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockOfficialProposalSource internal proposalSource;
    MockFutarchyLiquidityAdapter internal spotAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal router;
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

    receive() external payable {}

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        proposalSource = new MockOfficialProposalSource();
        spotAdapter = new MockFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        router = new MockConditionalRouter();

        manager = new FutarchyLiquidityManager(
            bootstrapRecipient,
            company,
            IWrappedNative(address(wrappedNative)),
            officialProposer,
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            router,
            owner,
            "Futarchy LP",
            "fLP"
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

        company.mint(bootstrapRecipient, 1000 ether);
        vm.deal(bootstrapRecipient, 1000 ether);
        vm.startPrank(bootstrapRecipient);
        company.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        company.mint(depositor, 1000 ether);
        vm.deal(depositor, 1000 ether);
        vm.startPrank(depositor);
        company.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        company.mint(secondDepositor, 1000 ether);
        vm.deal(secondDepositor, 1000 ether);
        vm.startPrank(secondDepositor);
        company.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function test_bootstrap_migrate_and_return_to_spot() public {
        _bootstrap();
        _createOfficialProposal(true);

        FutarchyLiquidityManager.SyncAction action = manager.sync(_emptySyncParams());
        assertEq(
            uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedToConditional)
        );
        assertTrue(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 20 ether);
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);

        proposalSource.setSettled(true);
        action = manager.sync(_emptySyncParams());
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(manager.activeProposal(), address(0));
    }

    function test_deposit_reverts_in_conditional_mode_but_redeem_still_works() public {
        _bootstrap();
        _createOfficialProposal(true);
        manager.sync(_emptySyncParams());
        assertTrue(manager.inConditionalMode());

        vm.prank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.DepositsDisabledInConditionalMode.selector);
        manager.depositToSpot{value: 1 ether}(1 ether, "");

        uint256 companyBefore = company.balanceOf(bootstrapRecipient);
        uint256 nativeBefore = bootstrapRecipient.balance;

        vm.prank(bootstrapRecipient);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(10 ether, bootstrapRecipient, true, "", "");

        assertEq(companyOut, 10 ether);
        assertEq(collateralOut, 10 ether);
        assertEq(company.balanceOf(bootstrapRecipient), companyBefore + 10 ether);
        assertEq(bootstrapRecipient.balance, nativeBefore + 10 ether);
        assertEq(manager.balanceOf(bootstrapRecipient), 90 ether);
        assertEq(manager.totalSupply(), 90 ether);
        assertEq(manager.spotLiquidity(), 18 ether);
        assertEq(manager.conditionalYesLiquidity(), 72 ether);
        assertEq(manager.conditionalNoLiquidity(), 72 ether);
    }

    function test_deposit_mints_proportional_shares() public {
        _bootstrap();

        vm.prank(depositor);
        (uint128 liquidityMinted, uint256 sharesMinted) =
            manager.depositToSpot{value: 50 ether}(50 ether, "");

        assertEq(liquidityMinted, 50 ether);
        assertEq(sharesMinted, 50 ether);
        assertEq(manager.balanceOf(depositor), 50 ether);
        assertEq(manager.totalSupply(), 150 ether);
        assertEq(manager.spotLiquidity(), 150 ether);
    }

    function test_bootstrap_deposit_and_redeem_with_erc20_collateral() public {
        MockMintableERC20 collateral = new MockMintableERC20("Savings DAI", "sDAI");
        FutarchyLiquidityManager erc20Manager = _newManagerWithCollateral(collateral);

        collateral.mint(bootstrapRecipient, 1000 ether);
        vm.startPrank(bootstrapRecipient);
        company.approve(address(erc20Manager), type(uint256).max);
        collateral.approve(address(erc20Manager), type(uint256).max);
        uint128 bootstrapLiquidity =
            erc20Manager.initializeFromBootstrap(SEED_COMPANY, SEED_NATIVE, "");
        vm.stopPrank();

        assertEq(bootstrapLiquidity, 100 ether);
        assertEq(erc20Manager.balanceOf(bootstrapRecipient), 100 ether);
        assertEq(erc20Manager.spotLiquidity(), 100 ether);

        collateral.mint(depositor, 1000 ether);
        vm.startPrank(depositor);
        company.approve(address(erc20Manager), type(uint256).max);
        collateral.approve(address(erc20Manager), type(uint256).max);
        (uint128 liquidityMinted, uint256 sharesMinted) =
            erc20Manager.depositToSpot(50 ether, 50 ether, "");
        vm.stopPrank();

        assertEq(liquidityMinted, 50 ether);
        assertEq(sharesMinted, 50 ether);
        assertEq(erc20Manager.balanceOf(depositor), 50 ether);

        uint256 companyBefore = company.balanceOf(depositor);
        uint256 collateralBefore = collateral.balanceOf(depositor);

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) =
            erc20Manager.redeem(25 ether, depositor, false, "", "");

        assertEq(companyOut, 25 ether);
        assertEq(collateralOut, 25 ether);
        assertEq(company.balanceOf(depositor), companyBefore + 25 ether);
        assertEq(collateral.balanceOf(depositor), collateralBefore + 25 ether);
        assertEq(depositor.balance, 1000 ether);
    }

    function test_redeem_burns_shares_and_returns_pro_rata_assets() public {
        _bootstrap();

        vm.prank(depositor);
        manager.depositToSpot{value: 50 ether}(50 ether, "");

        uint256 companyBefore = company.balanceOf(depositor);
        uint256 nativeBefore = depositor.balance;

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(25 ether, depositor, true, "", "");

        assertEq(companyOut, 25 ether);
        assertEq(collateralOut, 25 ether);
        assertEq(company.balanceOf(depositor), companyBefore + 25 ether);
        assertEq(depositor.balance, nativeBefore + 25 ether);
        assertEq(manager.balanceOf(depositor), 25 ether);
        assertEq(manager.spotLiquidity(), 125 ether);
    }

    function testFuzz_balanced_deposits_mint_lp_shares_proportionally(
        uint96 firstSeed,
        uint96 secondSeed
    ) public {
        _bootstrap();

        uint256 firstDeposit = bound(uint256(firstSeed), 1e9, 250 ether);
        uint256 secondDeposit = bound(uint256(secondSeed), 1e9, 250 ether);

        vm.prank(depositor);
        (uint128 firstLiquidity, uint256 firstShares) =
            manager.depositToSpot{value: firstDeposit}(firstDeposit, "");

        vm.prank(secondDepositor);
        (uint128 secondLiquidity, uint256 secondShares) =
            manager.depositToSpot{value: secondDeposit}(secondDeposit, "");

        assertEq(firstLiquidity, firstDeposit);
        assertEq(firstShares, firstDeposit);
        assertEq(secondLiquidity, secondDeposit);
        assertEq(secondShares, secondDeposit);
        assertEq(manager.balanceOf(bootstrapRecipient), SEED_COMPANY);
        assertEq(manager.balanceOf(depositor), firstDeposit);
        assertEq(manager.balanceOf(secondDepositor), secondDeposit);
        assertEq(manager.totalSupply(), SEED_COMPANY + firstDeposit + secondDeposit);
        assertEq(manager.spotLiquidity(), manager.totalSupply());
    }

    function testFuzz_spot_redeem_returns_exact_pro_rata_assets_for_multi_depositor(
        uint96 firstSeed,
        uint96 secondSeed,
        uint96 redeemSeed
    ) public {
        _bootstrap();

        uint256 firstDeposit = bound(uint256(firstSeed), 1e9, 250 ether);
        uint256 secondDeposit = bound(uint256(secondSeed), 1e9, 250 ether);
        vm.prank(depositor);
        manager.depositToSpot{value: firstDeposit}(firstDeposit, "");
        vm.prank(secondDepositor);
        manager.depositToSpot{value: secondDeposit}(secondDeposit, "");

        uint256 sharesToRedeem = bound(uint256(redeemSeed), 1, firstDeposit);
        uint256 supplyBefore = manager.totalSupply();
        uint256 spotBefore = manager.spotLiquidity();
        uint256 companyBefore = company.balanceOf(depositor);
        uint256 nativeBefore = depositor.balance;

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(sharesToRedeem, depositor, true, "", "");

        assertEq(companyOut, sharesToRedeem);
        assertEq(collateralOut, sharesToRedeem);
        assertEq(company.balanceOf(depositor), companyBefore + sharesToRedeem);
        assertEq(depositor.balance, nativeBefore + sharesToRedeem);
        assertEq(manager.balanceOf(depositor), firstDeposit - sharesToRedeem);
        assertEq(manager.balanceOf(secondDepositor), secondDeposit);
        assertEq(manager.totalSupply(), supplyBefore - sharesToRedeem);
        assertEq(manager.spotLiquidity(), spotBefore - sharesToRedeem);
    }

    function testFuzz_conditional_redeem_returns_exact_pro_rata_assets_after_migration(
        uint8 depositUnitsSeed,
        uint8 redeemUnitsSeed
    ) public {
        _bootstrap();

        uint256 depositUnits = bound(uint256(depositUnitsSeed), 1, 50);
        uint256 firstDeposit = depositUnits * 5 ether;
        vm.prank(depositor);
        manager.depositToSpot{value: firstDeposit}(firstDeposit, "");

        _createOfficialProposal(true);
        manager.sync(_emptySyncParams());
        assertTrue(manager.inConditionalMode());

        uint256 redeemUnits = bound(uint256(redeemUnitsSeed), 1, depositUnits);
        uint256 sharesToRedeem = redeemUnits * 5 ether;
        uint256 supplyBefore = manager.totalSupply();
        uint256 spotBefore = manager.spotLiquidity();
        uint256 yesBefore = manager.conditionalYesLiquidity();
        uint256 noBefore = manager.conditionalNoLiquidity();
        uint256 companyBefore = company.balanceOf(depositor);
        uint256 nativeBefore = depositor.balance;

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(sharesToRedeem, depositor, true, "", "");

        assertEq(companyOut, sharesToRedeem);
        assertEq(collateralOut, sharesToRedeem);
        assertEq(company.balanceOf(depositor), companyBefore + sharesToRedeem);
        assertEq(depositor.balance, nativeBefore + sharesToRedeem);
        assertEq(manager.balanceOf(depositor), firstDeposit - sharesToRedeem);
        assertEq(manager.totalSupply(), supplyBefore - sharesToRedeem);
        assertEq(
            manager.spotLiquidity(), spotBefore - ((spotBefore * sharesToRedeem) / supplyBefore)
        );
        assertEq(
            manager.conditionalYesLiquidity(),
            yesBefore - ((yesBefore * sharesToRedeem) / supplyBefore)
        );
        assertEq(
            manager.conditionalNoLiquidity(),
            noBefore - ((noBefore * sharesToRedeem) / supplyBefore)
        );
    }

    function test_conditional_redeem_with_divergent_liquidity_preserves_future_deposits() public {
        _bootstrap();
        _createOfficialProposal(true);
        manager.sync(_emptySyncParams());

        yesCompany.mint(address(conditionalAdapter), 20 ether);
        yesCurrency.mint(address(conditionalAdapter), 20 ether);
        conditionalAdapter.setNextCompoundLiquidity(20 ether);
        manager.sync(_emptySyncParams());
        assertEq(manager.conditionalYesLiquidity(), 100 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);

        vm.prank(bootstrapRecipient);
        manager.redeem(10 ether, bootstrapRecipient, true, "", "");

        assertEq(manager.totalSupply(), 90 ether);
        assertEq(manager.spotLiquidity(), 18 ether);
        assertEq(manager.conditionalYesLiquidity(), 90 ether);
        assertEq(manager.conditionalNoLiquidity(), 72 ether);

        proposalSource.setSettled(true);
        manager.sync(_emptySyncParams());
        assertFalse(manager.inConditionalMode());
        assertEq(manager.totalSupply(), 90 ether);
        assertEq(manager.spotLiquidity(), 90 ether);

        vm.prank(secondDepositor);
        (uint128 liquidityMinted, uint256 sharesMinted) =
            manager.depositToSpot{value: 18 ether}(18 ether, "");
        assertEq(liquidityMinted, 18 ether);
        assertEq(sharesMinted, 18 ether);
        assertEq(manager.totalSupply(), 108 ether);
        assertEq(manager.spotLiquidity(), 108 ether);

        uint256 companyBefore = company.balanceOf(secondDepositor);
        uint256 nativeBefore = secondDepositor.balance;
        vm.prank(secondDepositor);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(sharesMinted, secondDepositor, true, "", "");
        assertEq(companyOut, 18 ether);
        assertEq(collateralOut, 18 ether);
        assertEq(company.balanceOf(secondDepositor), companyBefore + 18 ether);
        assertEq(secondDepositor.balance, nativeBefore + 18 ether);
    }

    function test_sync_reverts_on_official_proposal_with_wrong_tokens() public {
        _bootstrap();

        _createOfficialProposalWithWrongCompany();

        vm.expectRevert(FutarchyLiquidityManager.InvalidProposalConfig.selector);
        manager.sync(_emptySyncParams());
    }

    function test_bad_official_proposal_does_not_trap_redeem_or_poison_state() public {
        _bootstrap();

        vm.prank(depositor);
        manager.depositToSpot{value: 50 ether}(50 ether, "");

        _createOfficialProposalWithWrongCompany();

        vm.expectRevert(FutarchyLiquidityManager.InvalidProposalConfig.selector);
        manager.sync(_emptySyncParams());

        assertFalse(manager.inConditionalMode());
        assertEq(manager.activeProposal(), address(0));
        assertEq(manager.spotLiquidity(), 150 ether);
        assertEq(manager.balanceOf(depositor), 50 ether);

        uint256 companyBefore = company.balanceOf(depositor);
        uint256 nativeBefore = depositor.balance;

        vm.prank(depositor);
        (uint256 companyOut, uint256 collateralOut) =
            manager.redeem(50 ether, depositor, true, "", "");

        assertEq(companyOut, 50 ether);
        assertEq(collateralOut, 50 ether);
        assertEq(company.balanceOf(depositor), companyBefore + 50 ether);
        assertEq(depositor.balance, nativeBefore + 50 ether);
        assertEq(manager.balanceOf(depositor), 0);
        assertEq(manager.spotLiquidity(), 100 ether);

        proposalSource.clearProposal();
        _createOfficialProposal(true);
        FutarchyLiquidityManager.SyncAction action = manager.sync(_emptySyncParams());
        assertEq(
            uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedToConditional)
        );
        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeProposal(), address(proposal));
    }

    function test_emergency_arm_blocks_deposit_and_sync_but_redeem_works() public {
        _bootstrap();
        manager.armEmergencyExit();

        vm.prank(depositor);
        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.depositToSpot{value: 1 ether}(1 ether, "");

        vm.expectRevert(FutarchyLiquidityManager.EmergencyModeActive.selector);
        manager.sync(_emptySyncParams());

        uint256 companyBefore = company.balanceOf(bootstrapRecipient);
        vm.prank(bootstrapRecipient);
        (uint256 companyOut,) = manager.redeem(10 ether, bootstrapRecipient, true, "", "");
        assertEq(companyOut, 10 ether);
        assertEq(company.balanceOf(bootstrapRecipient), companyBefore + 10 ether);
    }

    function test_emergency_controls_are_owner_only() public {
        _bootstrap();

        vm.startPrank(depositor);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.armEmergencyExit();
        vm.expectRevert("Ownable: caller is not the owner");
        manager.sweepIdleToBootstrapRecipient(true);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.emergencyExitAllToBootstrapRecipient(true, "", "");
        vm.stopPrank();

        manager.armEmergencyExit();
        vm.prank(depositor);
        vm.expectRevert("Ownable: caller is not the owner");
        manager.disarmEmergencyExit();
    }

    function test_emergency_exit_after_delay_returns_assets_to_bootstrap_recipient() public {
        _bootstrap();
        _createOfficialProposal(true);
        manager.sync(_emptySyncParams());
        assertTrue(manager.inConditionalMode());

        uint256 companyBefore = company.balanceOf(bootstrapRecipient);
        uint256 nativeBefore = bootstrapRecipient.balance;

        manager.armEmergencyExit();
        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitDelayActive.selector);
        manager.emergencyExitAllToBootstrapRecipient(true, "", "");

        vm.warp(block.timestamp + manager.EMERGENCY_EXIT_DELAY());
        (uint256 companySentToBootstrap,, uint256 nativeSentToBootstrap) =
            manager.emergencyExitAllToBootstrapRecipient(true, "", "");

        assertEq(companySentToBootstrap, 100 ether);
        assertEq(nativeSentToBootstrap, 100 ether);
        assertEq(company.balanceOf(bootstrapRecipient), companyBefore + 100 ether);
        assertEq(bootstrapRecipient.balance, nativeBefore + 100 ether);
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertFalse(manager.inConditionalMode());
        assertTrue(manager.emergencyExitExecuted());

        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitAlreadyExecuted.selector);
        manager.emergencyExitAllToBootstrapRecipient(true, "", "");
    }

    function test_emergency_exit_cannot_redirect_third_party_liquidity_to_owner() public {
        _bootstrap();

        vm.prank(depositor);
        manager.depositToSpot{value: 50 ether}(50 ether, "");

        _createOfficialProposal(true);
        manager.sync(_emptySyncParams());
        assertTrue(manager.inConditionalMode());
        assertEq(manager.totalSupply(), 150 ether);
        assertEq(manager.balanceOf(depositor), 50 ether);

        uint256 bootstrapCompanyBefore = company.balanceOf(bootstrapRecipient);
        uint256 bootstrapNativeBefore = bootstrapRecipient.balance;
        uint256 ownerCompanyBefore = company.balanceOf(owner);
        uint256 ownerNativeBefore = owner.balance;
        uint256 depositorCompanyBefore = company.balanceOf(depositor);
        uint256 depositorNativeBefore = depositor.balance;

        manager.armEmergencyExit();
        vm.warp(block.timestamp + manager.EMERGENCY_EXIT_DELAY());
        (uint256 companySentToBootstrap,, uint256 nativeSentToBootstrap) =
            manager.emergencyExitAllToBootstrapRecipient(true, "", "");

        assertEq(companySentToBootstrap, 150 ether);
        assertEq(nativeSentToBootstrap, 150 ether);
        assertEq(company.balanceOf(bootstrapRecipient), bootstrapCompanyBefore + 150 ether);
        assertEq(bootstrapRecipient.balance, bootstrapNativeBefore + 150 ether);
        assertEq(company.balanceOf(owner), ownerCompanyBefore);
        assertEq(owner.balance, ownerNativeBefore);
        assertEq(company.balanceOf(depositor), depositorCompanyBefore);
        assertEq(depositor.balance, depositorNativeBefore);
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertTrue(manager.emergencyExitExecuted());
    }

    function test_sweep_idle_to_bootstrap_recipient() public {
        _bootstrap();
        company.mint(address(manager), 3 ether);
        wrappedNative.mint(address(manager), 4 ether);

        uint256 companyBefore = company.balanceOf(bootstrapRecipient);
        uint256 nativeBefore = bootstrapRecipient.balance;

        manager.sweepIdleToBootstrapRecipient(true);

        assertEq(company.balanceOf(bootstrapRecipient), companyBefore + 3 ether);
        assertEq(bootstrapRecipient.balance, nativeBefore + 4 ether);
    }

    function _bootstrap() internal {
        vm.prank(bootstrapRecipient);
        uint128 liquidityMinted =
            manager.initializeFromBootstrap{value: SEED_NATIVE}(SEED_COMPANY, "");

        assertEq(liquidityMinted, 100 ether);
        assertEq(manager.balanceOf(bootstrapRecipient), 100 ether);
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.name(), "Futarchy LP");
        assertEq(manager.symbol(), "fLP");
    }

    function _newManagerWithCollateral(MockMintableERC20 collateral)
        internal
        returns (FutarchyLiquidityManager)
    {
        return new FutarchyLiquidityManager(
            bootstrapRecipient,
            company,
            IWrappedNative(address(collateral)),
            officialProposer,
            proposalSource,
            spotAdapter,
            conditionalAdapter,
            router,
            owner,
            "Futarchy LP",
            "fLP"
        );
    }

    function _createOfficialProposal(bool winnerIsYes) internal {
        proposalSource.createProposalExtended(
            address(proposal),
            officialProposer,
            address(company),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency),
            address(0xCAFE),
            address(0xBEEF)
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

    function _createOfficialProposalWithWrongCompany() internal {
        MockMintableERC20 wrongCompany = new MockMintableERC20("Wrong", "WRONG");
        MockFutarchyProposalLike badProposal = new MockFutarchyProposalLike(
            address(wrongCompany),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
        proposalSource.createProposalExtended(
            address(badProposal),
            officialProposer,
            address(wrongCompany),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency),
            address(0xCAFE),
            address(0xBEEF)
        );
    }

    function _emptySyncParams()
        internal
        pure
        returns (FutarchyLiquidityManager.SyncParams memory params)
    {}
}
