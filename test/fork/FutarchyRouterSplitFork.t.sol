// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {IFutarchyProposalCore} from "../../src/interfaces/IFutarchyTradingCore.sol";

contract FutarchyRouterSplitForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;
    address internal constant DEFAULT_COMPANY_TOKEN = 0x9494C281a02c9ae5f72b224B514793ad2DD8cA17;
    address internal constant DEFAULT_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;

    function testFork_router_splits_company_and_collateral_positions() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        address proposalAddress = vm.envOr("TEST_FUTARCHY_PROPOSAL", DEFAULT_PROPOSAL);
        address companyToken = vm.envOr("TEST_COMPANY_TOKEN", DEFAULT_COMPANY_TOKEN);
        address collateralToken = vm.envOr("TEST_COLLATERAL_TOKEN", GNOSIS_WXDAI);

        IFutarchyProposalCore proposal = IFutarchyProposalCore(proposalAddress);
        (address yesCompany,) = proposal.wrappedOutcome(0);
        (address noCompany,) = proposal.wrappedOutcome(1);
        (address yesCurrency,) = proposal.wrappedOutcome(2);
        (address noCurrency,) = proposal.wrappedOutcome(3);
        bytes32 conditionId = proposal.conditionId();

        uint256 amount = 1e15;
        deal(companyToken, address(this), amount);
        deal(collateralToken, address(this), amount);

        IERC20(companyToken).approve(FUTARCHY_ROUTER, type(uint256).max);
        IERC20(collateralToken).approve(FUTARCHY_ROUTER, type(uint256).max);

        IFutarchyConditionalRouter(FUTARCHY_ROUTER)
            .splitPosition(companyToken, conditionId, yesCompany, noCompany, amount);
        IFutarchyConditionalRouter(FUTARCHY_ROUTER)
            .splitPosition(collateralToken, conditionId, yesCurrency, noCurrency, amount);

        assertEq(IERC20(yesCompany).balanceOf(address(this)), amount);
        assertEq(IERC20(noCompany).balanceOf(address(this)), amount);
        assertEq(IERC20(yesCurrency).balanceOf(address(this)), amount);
        assertEq(IERC20(noCurrency).balanceOf(address(this)), amount);
    }
}
