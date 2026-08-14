// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "./mocks/MockOfficialProposalSource.sol";
import {MockPoolStabilityGuard} from "./mocks/MockPoolStabilityGuard.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";
import {OverusingFutarchyLiquidityAdapter} from "./mocks/OverusingFutarchyLiquidityAdapter.sol";

contract FeeOnTransferToken is ERC20 {
    address public feeRecipient;

    constructor() ERC20("Fee token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeRecipient(address recipient) external {
        feeRecipient = recipient;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (to != feeRecipient) {
            super._transfer(from, to, amount);
            return;
        }
        uint256 fee = amount / 100;
        super._transfer(from, to, amount - fee);
        _burn(from, fee);
    }
}

contract FutarchyLiquidityManagerAdapterSafetyTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockOfficialProposalSource internal source;
    OverusingFutarchyLiquidityAdapter internal overusingAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal router;
    FutarchyLiquidityManager internal manager;

    address internal bootstrapRecipient = address(0xB007);

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        source = new MockOfficialProposalSource();
        overusingAdapter = new OverusingFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        router = new MockConditionalRouter();
        MockPoolStabilityGuard stabilityGuard = new MockPoolStabilityGuard();
        manager = new FutarchyLiquidityManager(
            bootstrapRecipient,
            company,
            IWrappedNative(address(wrappedNative)),
            source,
            overusingAdapter,
            conditionalAdapter,
            router,
            stabilityGuard,
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Futarchy LP", symbol: "fLP"})
        );

        company.mint(bootstrapRecipient, 10 ether);
        vm.deal(bootstrapRecipient, 10 ether);
    }

    function test_bootstrap_reverts_when_adapter_reports_overused_input() public {
        vm.startPrank(bootstrapRecipient);
        company.approve(address(manager), type(uint256).max);
        vm.expectRevert(FutarchyLiquidityManager.AdapterOverusedInput.selector);
        manager.initializeFromBootstrap{value: 1 ether}(1 ether);
        vm.stopPrank();
    }

    function test_bootstrap_rejects_fee_on_transfer_assets() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        FutarchyLiquidityManager feeManager = new FutarchyLiquidityManager(
            bootstrapRecipient,
            feeToken,
            IWrappedNative(address(wrappedNative)),
            source,
            new MockFutarchyLiquidityAdapter(),
            conditionalAdapter,
            router,
            new MockPoolStabilityGuard(),
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Futarchy LP", symbol: "fLP"})
        );
        feeToken.mint(bootstrapRecipient, 10 ether);
        feeToken.setFeeRecipient(address(feeManager));

        vm.startPrank(bootstrapRecipient);
        feeToken.approve(address(feeManager), type(uint256).max);
        vm.expectRevert(FutarchyLiquidityManager.InvalidAssetTransfer.selector);
        feeManager.initializeFromBootstrap{value: 1 ether}(1 ether);
        vm.stopPrank();
    }

    function test_redemption_rejects_late_transfer_fee_without_burning_shares() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        MockFutarchyLiquidityAdapter spotAdapter = new MockFutarchyLiquidityAdapter();
        FutarchyLiquidityManager feeManager = new FutarchyLiquidityManager(
            bootstrapRecipient,
            feeToken,
            IWrappedNative(address(wrappedNative)),
            source,
            spotAdapter,
            conditionalAdapter,
            router,
            new MockPoolStabilityGuard(),
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "Futarchy LP", symbol: "fLP"})
        );
        feeToken.mint(bootstrapRecipient, 10 ether);
        vm.startPrank(bootstrapRecipient);
        feeToken.approve(address(feeManager), type(uint256).max);
        feeManager.initializeFromBootstrap{value: 1 ether}(1 ether);
        vm.stopPrank();

        feeToken.setFeeRecipient(bootstrapRecipient);
        vm.prank(bootstrapRecipient);
        vm.expectRevert(FutarchyLiquidityManager.InvalidAssetTransfer.selector);
        feeManager.redeem(1 ether, bootstrapRecipient, false);

        assertEq(feeManager.totalSupply(), 1 ether);
        assertEq(feeManager.balanceOf(bootstrapRecipient), 1 ether);
        assertEq(feeManager.spotLiquidity(), 1 ether);
        assertEq(spotAdapter.totalLiquidity(), 1 ether);
        assertEq(feeToken.balanceOf(bootstrapRecipient), 9 ether);

        feeToken.setFeeRecipient(address(0));
        vm.prank(bootstrapRecipient);
        feeManager.redeem(1 ether, bootstrapRecipient, false);

        assertEq(feeManager.totalSupply(), 0);
        assertEq(feeToken.balanceOf(bootstrapRecipient), 10 ether);
        assertEq(wrappedNative.balanceOf(bootstrapRecipient), 1 ether);
    }
}
