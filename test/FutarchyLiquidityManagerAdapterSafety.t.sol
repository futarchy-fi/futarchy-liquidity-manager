// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "./mocks/MockOfficialProposalSource.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";
import {OverusingFutarchyLiquidityAdapter} from "./mocks/OverusingFutarchyLiquidityAdapter.sol";

contract FutarchyLiquidityManagerAdapterSafetyTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockOfficialProposalSource internal source;
    OverusingFutarchyLiquidityAdapter internal overusingAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal router;
    FutarchyLiquidityManager internal manager;

    address internal user = address(0xCAFE);

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        source = new MockOfficialProposalSource();
        overusingAdapter = new OverusingFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        router = new MockConditionalRouter();
        manager = new FutarchyLiquidityManager(
            address(0xB007),
            company,
            IWrappedNative(address(wrappedNative)),
            address(0xC0DE),
            source,
            overusingAdapter,
            conditionalAdapter,
            router,
            address(this),
            "Futarchy LP",
            "fLP"
        );

        company.mint(user, 10 ether);
        vm.deal(user, 10 ether);
    }

    function test_deposit_reverts_when_adapter_reports_overused_input() public {
        vm.startPrank(user);
        company.approve(address(manager), type(uint256).max);
        vm.expectRevert(FutarchyLiquidityManager.AdapterOverusedInput.selector);
        manager.depositToSpot{value: 1 ether}(1 ether, "");
        vm.stopPrank();
    }
}
