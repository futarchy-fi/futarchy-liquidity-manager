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
        assertEq(manager.conditionalLiquidity(), 80 ether);
        assertEq(manager.conditionalYesLiquidity(), 80 ether);
        assertEq(manager.conditionalNoLiquidity(), 80 ether);

        proposalSource.setSettled(true);
        action = manager.sync(_emptySyncParams());
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), 100 ether);
        assertEq(manager.conditionalLiquidity(), 0);
        assertEq(manager.activeProposal(), address(0));
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
        assertEq(manager.conditionalLiquidity(), 0);
        assertFalse(manager.inConditionalMode());
        assertTrue(manager.emergencyExitExecuted());

        vm.expectRevert(FutarchyLiquidityManager.EmergencyExitAlreadyExecuted.selector);
        manager.emergencyExitAllToBootstrapRecipient(true, "", "");
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
