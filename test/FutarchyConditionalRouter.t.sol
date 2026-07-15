// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {FutarchyConditionalRouter} from "../src/routers/FutarchyConditionalRouter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockRouterConditionalTokens} from "./mocks/MockRouterConditionalTokens.sol";
import {
    MockRouterWrapped1155Factory,
    MockWrappedOutcome
} from "./mocks/MockRouterWrapped1155Factory.sol";

contract FutarchyConditionalRouterDeployer {
    function deploy(
        MockRouterConditionalTokens conditionalTokens,
        MockRouterWrapped1155Factory wrapped1155Factory
    ) external returns (FutarchyConditionalRouter) {
        return new FutarchyConditionalRouter(conditionalTokens, wrapped1155Factory);
    }
}

contract MalformedMetadataWrapper {
    address public immutable factory;
    address public immutable multiToken;
    uint256 public immutable tokenId;

    constructor(address factory_, address multiToken_, uint256 tokenId_) {
        factory = factory_;
        multiToken = multiToken_;
        tokenId = tokenId_;
    }

    function name() external pure returns (string memory) {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }

    function symbol() external pure returns (string memory) {
        return "OUT";
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract FutarchyConditionalRouterTest is Test {
    uint256 private constant AMOUNT = 10 ether;
    bytes32 private constant CONDITION_ID = keccak256("condition");
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockMintableERC20 private company;
    MockMintableERC20 private collateral;
    MockRouterConditionalTokens private conditionalTokens;
    MockRouterWrapped1155Factory private wrapped1155Factory;
    FutarchyConditionalRouter private router;
    address private user;
    address[4] private wrappers;
    bytes[4] private wrapperData;

    function setUp() public {
        user = makeAddr("user");
        company = new MockMintableERC20("Company", "COMP");
        collateral = new MockMintableERC20("Collateral", "COLL");
        conditionalTokens = new MockRouterConditionalTokens();
        wrapped1155Factory = new MockRouterWrapped1155Factory();
        router = new FutarchyConditionalRouter(conditionalTokens, wrapped1155Factory);
        conditionalTokens.setOutcomeSlotCount(CONDITION_ID, 2);

        _installPair(address(company), 0);
        _installPair(address(collateral), 2);
        company.mint(user, 100 ether);
        collateral.mint(user, 100 ether);
        vm.startPrank(user);
        company.approve(address(router), type(uint256).max);
        collateral.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_split_and_merge_both_collaterals_preserves_complete_sets() public {
        _assertSplitAndMerge(address(company), 0);
        _assertSplitAndMerge(address(collateral), 2);
        _assertNoRouterDust();
    }

    function test_split_pair_sends_exact_wrappers_to_contract_recipient() public {
        uint256 companyBefore = company.balanceOf(user);
        uint256 collateralBefore = collateral.balanceOf(user);

        vm.prank(user);
        router.splitPositionPairTo(
            CONDITION_ID,
            address(company),
            wrappers[0],
            wrappers[1],
            AMOUNT,
            address(collateral),
            wrappers[2],
            wrappers[3],
            AMOUNT,
            address(this)
        );

        assertEq(company.balanceOf(user), companyBefore - AMOUNT);
        assertEq(collateral.balanceOf(user), collateralBefore - AMOUNT);
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(wrappers[i]).balanceOf(address(this)), AMOUNT);
            assertEq(IERC20(wrappers[i]).balanceOf(user), 0);
        }
        _assertNoRouterDust();
    }

    function test_split_pair_rejects_non_contract_recipient_before_moving_assets() public {
        uint256 companyBefore = company.balanceOf(user);
        uint256 collateralBefore = collateral.balanceOf(user);

        vm.expectRevert(FutarchyConditionalRouter.InvalidRecipient.selector);
        vm.prank(user);
        router.splitPositionPairTo(
            CONDITION_ID,
            address(company),
            wrappers[0],
            wrappers[1],
            AMOUNT,
            address(collateral),
            wrappers[2],
            wrappers[3],
            AMOUNT,
            user
        );

        assertEq(company.balanceOf(user), companyBefore);
        assertEq(collateral.balanceOf(user), collateralBefore);
        _assertNoRouterDust();
    }

    function test_redeem_yes_returns_exact_collateral_and_leaves_no_dust() public {
        _splitBoth();
        conditionalTokens.setPayout(CONDITION_ID, 1, 1, 0);

        _approveWrapper(0);
        _approveWrapper(2);
        uint256 companyBefore = company.balanceOf(user);
        uint256 collateralBefore = collateral.balanceOf(user);
        vm.startPrank(user);
        router.redeemPositions(address(company), CONDITION_ID, wrappers[0], wrappers[1], 4 ether);
        router.redeemPositions(address(collateral), CONDITION_ID, wrappers[2], wrappers[3], 4 ether);
        vm.stopPrank();

        assertEq(company.balanceOf(user), companyBefore + 4 ether);
        assertEq(collateral.balanceOf(user), collateralBefore + 4 ether);
        assertEq(IERC20(wrappers[0]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(IERC20(wrappers[1]).balanceOf(user), AMOUNT);
        assertEq(IERC20(wrappers[2]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(IERC20(wrappers[3]).balanceOf(user), AMOUNT);
        _assertNoRouterDust();
    }

    function test_redeem_no_returns_exact_collateral_and_leaves_no_dust() public {
        _splitBoth();
        conditionalTokens.setPayout(CONDITION_ID, 1, 0, 1);

        _approveWrapper(1);
        _approveWrapper(3);
        uint256 companyBefore = company.balanceOf(user);
        uint256 collateralBefore = collateral.balanceOf(user);
        vm.startPrank(user);
        router.redeemPositions(address(company), CONDITION_ID, wrappers[0], wrappers[1], 4 ether);
        router.redeemPositions(address(collateral), CONDITION_ID, wrappers[2], wrappers[3], 4 ether);
        vm.stopPrank();

        assertEq(company.balanceOf(user), companyBefore + 4 ether);
        assertEq(collateral.balanceOf(user), collateralBefore + 4 ether);
        assertEq(IERC20(wrappers[0]).balanceOf(user), AMOUNT);
        assertEq(IERC20(wrappers[1]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(IERC20(wrappers[2]).balanceOf(user), AMOUNT);
        assertEq(IERC20(wrappers[3]).balanceOf(user), AMOUNT - 4 ether);
        _assertNoRouterDust();
    }

    function test_consume_losing_positions_burns_zero_payout_without_moving_collateral() public {
        _splitBoth();
        conditionalTokens.setPayout(CONDITION_ID, 1, 1, 0);
        _approveWrapper(1);
        _approveWrapper(3);
        uint256 companyBefore = company.balanceOf(user);
        uint256 collateralBefore = collateral.balanceOf(user);

        vm.startPrank(user);
        router.consumeLosingPositions(
            address(company), CONDITION_ID, wrappers[0], wrappers[1], 4 ether
        );
        router.consumeLosingPositions(
            address(collateral), CONDITION_ID, wrappers[2], wrappers[3], 4 ether
        );
        vm.stopPrank();

        assertEq(company.balanceOf(user), companyBefore);
        assertEq(collateral.balanceOf(user), collateralBefore);
        assertEq(IERC20(wrappers[1]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(IERC20(wrappers[3]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(conditionalTokens.balanceOf(address(router), _tokenId(address(company), 2)), 0);
        assertEq(conditionalTokens.balanceOf(address(router), _tokenId(address(collateral), 2)), 0);
        _assertNoRouterDust();
    }

    function test_redeem_discards_underlying_prefunded_before_router_deployment() public {
        _split(address(company));
        conditionalTokens.setPayout(CONDITION_ID, 1, 1, 0);

        FutarchyConditionalRouterDeployer deployer = new FutarchyConditionalRouterDeployer();
        address predicted = vm.computeCreateAddress(address(deployer), 1);
        uint256 winningTokenId = _tokenId(address(company), 1);
        uint256 donation = 1;
        conditionalTokens.mintPosition(user, winningTokenId, donation);
        vm.prank(user);
        conditionalTokens.safeTransferFrom(user, predicted, winningTokenId, donation, "");
        assertEq(predicted.code.length, 0);
        assertEq(conditionalTokens.balanceOf(predicted, winningTokenId), donation);

        FutarchyConditionalRouter prefundedRouter =
            deployer.deploy(conditionalTokens, wrapped1155Factory);
        assertEq(address(prefundedRouter), predicted);
        vm.prank(user);
        IERC20(wrappers[0]).approve(address(prefundedRouter), type(uint256).max);

        uint256 companyBefore = company.balanceOf(user);
        vm.prank(user);
        prefundedRouter.redeemPositions(
            address(company), CONDITION_ID, wrappers[0], wrappers[1], 4 ether
        );

        assertEq(company.balanceOf(user), companyBefore + 4 ether);
        assertEq(IERC20(wrappers[0]).balanceOf(user), AMOUNT - 4 ether);
        assertEq(conditionalTokens.balanceOf(address(prefundedRouter), winningTokenId), 0);
        assertEq(conditionalTokens.balanceOf(DEAD, winningTokenId), donation);
        assertEq(company.balanceOf(address(prefundedRouter)), 0);
        assertEq(IERC20(wrappers[0]).balanceOf(address(prefundedRouter)), 0);
    }

    function test_getWinningOutcomes_reports_unresolved_and_resolved_state() public {
        bool[] memory winning = router.getWinningOutcomes(CONDITION_ID);
        assertEq(winning.length, 2);
        assertFalse(winning[0]);
        assertFalse(winning[1]);

        conditionalTokens.setPayout(CONDITION_ID, 1, 0, 1);
        winning = router.getWinningOutcomes(CONDITION_ID);
        assertFalse(winning[0]);
        assertTrue(winning[1]);

        (uint256 denominator, uint256 yesNumerator, uint256 noNumerator) =
            router.getPayouts(CONDITION_ID);
        assertEq(denominator, 1);
        assertEq(yesNumerator, 0);
        assertEq(noNumerator, 1);
    }

    function test_rejects_non_binary_and_invalid_collateral() public {
        conditionalTokens.setOutcomeSlotCount(CONDITION_ID, 3);
        vm.expectRevert(FutarchyConditionalRouter.NonBinaryCondition.selector);
        vm.prank(user);
        router.splitPosition(address(company), CONDITION_ID, wrappers[0], wrappers[1], AMOUNT);

        conditionalTokens.setOutcomeSlotCount(CONDITION_ID, 2);
        vm.expectRevert(FutarchyConditionalRouter.InvalidCollateral.selector);
        vm.prank(user);
        router.splitPosition(address(0), CONDITION_ID, wrappers[0], wrappers[1], AMOUNT);
    }

    function test_rejects_wrapper_identity_mismatches_even_when_factory_mapping_matches() public {
        uint256 yesTokenId = _tokenId(address(company), 1);
        address[3] memory invalidWrappers;
        invalidWrappers[0] = address(
            new MockWrappedOutcome(
                DEAD, address(conditionalTokens), yesTokenId, "Wrapped outcome", "OUT", 18
            )
        );
        invalidWrappers[1] = address(
            new MockWrappedOutcome(
                address(wrapped1155Factory), DEAD, yesTokenId, "Wrapped outcome", "OUT", 18
            )
        );
        invalidWrappers[2] = address(
            new MockWrappedOutcome(
                address(wrapped1155Factory),
                address(conditionalTokens),
                yesTokenId + 1,
                "Wrapped outcome",
                "OUT",
                18
            )
        );

        for (uint256 i; i < invalidWrappers.length; ++i) {
            wrapped1155Factory.setWrapped1155(
                address(conditionalTokens), yesTokenId, wrapperData[0], invalidWrappers[i]
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    FutarchyConditionalRouter.InvalidWrapperMetadata.selector, invalidWrappers[i]
                )
            );
            vm.prank(user);
            router.splitPosition(
                address(company), CONDITION_ID, invalidWrappers[i], wrappers[1], AMOUNT
            );
        }
    }

    function test_rejects_long_and_malformed_wrapper_metadata() public {
        uint256 yesTokenId = _tokenId(address(company), 1);
        address longMetadata = address(
            new MockWrappedOutcome(
                address(wrapped1155Factory),
                address(conditionalTokens),
                yesTokenId,
                "12345678901234567890123456789012",
                "OUT",
                18
            )
        );
        address malformedMetadata = address(
            new MalformedMetadataWrapper(
                address(wrapped1155Factory), address(conditionalTokens), yesTokenId
            )
        );

        wrapped1155Factory.setWrapped1155(
            address(conditionalTokens), yesTokenId, wrapperData[0], longMetadata
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyConditionalRouter.InvalidWrapperMetadata.selector, longMetadata
            )
        );
        vm.prank(user);
        router.splitPosition(address(company), CONDITION_ID, longMetadata, wrappers[1], AMOUNT);

        wrapped1155Factory.setWrapped1155(
            address(conditionalTokens), yesTokenId, wrapperData[0], malformedMetadata
        );
        vm.expectRevert();
        vm.prank(user);
        router.splitPosition(address(company), CONDITION_ID, malformedMetadata, wrappers[1], AMOUNT);
    }

    function test_rejects_unresolved_ambiguous_and_fractional_winners() public {
        _split(address(company));
        _approveWrapper(0);
        _approveWrapper(1);

        vm.expectRevert(FutarchyConditionalRouter.InvalidWinningOutcome.selector);
        vm.prank(user);
        router.redeemPositions(address(company), CONDITION_ID, wrappers[0], wrappers[1], 1 ether);

        conditionalTokens.setPayout(CONDITION_ID, 2, 1, 1);
        vm.expectRevert(FutarchyConditionalRouter.InvalidWinningOutcome.selector);
        vm.prank(user);
        router.redeemPositions(address(company), CONDITION_ID, wrappers[0], wrappers[1], 1 ether);

        conditionalTokens.setPayout(CONDITION_ID, 2, 1, 0);
        vm.expectRevert(FutarchyConditionalRouter.InvalidWinningOutcome.selector);
        vm.prank(user);
        router.redeemPositions(address(company), CONDITION_ID, wrappers[0], wrappers[1], 1 ether);
    }

    function test_exact_wrapper_mint_delta_is_enforced() public {
        wrapped1155Factory.setMintShortfall(1);
        vm.expectRevert(FutarchyConditionalRouter.InvalidBalanceDelta.selector);
        vm.prank(user);
        router.splitPosition(address(company), CONDITION_ID, wrappers[0], wrappers[1], AMOUNT);
        assertEq(company.balanceOf(user), 100 ether);
        _assertNoRouterDust();
    }

    function test_unsolicited_single_and_batch_underlying_transfers_are_rejected() public {
        _split(address(company));
        uint256 yesTokenId = _tokenId(address(company), 1);
        uint256 noTokenId = _tokenId(address(company), 2);

        uint256 wrapperBefore = IERC20(wrappers[0]).balanceOf(user);
        uint256 reserveBefore = conditionalTokens.balanceOf(address(wrapped1155Factory), yesTokenId);
        vm.expectRevert();
        vm.prank(user);
        wrapped1155Factory.unwrap(
            address(conditionalTokens), yesTokenId, 1, address(router), wrapperData[0]
        );
        assertEq(IERC20(wrappers[0]).balanceOf(user), wrapperBefore);
        assertEq(
            conditionalTokens.balanceOf(address(wrapped1155Factory), yesTokenId), reserveBefore
        );

        conditionalTokens.mintPosition(user, yesTokenId, 1);
        conditionalTokens.mintPosition(user, noTokenId, 1);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = yesTokenId;
        tokenIds[1] = noTokenId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;
        vm.expectRevert();
        vm.prank(user);
        conditionalTokens.safeBatchTransferFrom(user, address(router), tokenIds, amounts, "");
        assertEq(conditionalTokens.balanceOf(user, yesTokenId), 1);
        assertEq(conditionalTokens.balanceOf(user, noTokenId), 1);
        _assertNoRouterDust();
    }

    function test_zero_amount_and_invalid_dependencies_revert() public {
        vm.expectRevert(FutarchyConditionalRouter.ZeroAmount.selector);
        vm.prank(user);
        router.splitPosition(address(company), CONDITION_ID, wrappers[0], wrappers[1], 0);

        vm.expectRevert(FutarchyConditionalRouter.InvalidDependency.selector);
        new FutarchyConditionalRouter(MockRouterConditionalTokens(address(0)), wrapped1155Factory);
    }

    function _assertSplitAndMerge(address baseToken, uint256 wrapperOffset) private {
        IERC20 base = IERC20(baseToken);
        uint256 baseBefore = base.balanceOf(user);
        _split(baseToken);
        assertEq(base.balanceOf(user), baseBefore - AMOUNT);

        for (uint256 i; i < 2; ++i) {
            uint256 wrapperIndex = wrapperOffset + i;
            uint256 tokenId = _tokenId(baseToken, i + 1);
            assertEq(IERC20(wrappers[wrapperIndex]).balanceOf(user), AMOUNT);
            assertEq(MockWrappedOutcome(wrappers[wrapperIndex]).totalSupply(), AMOUNT);
            assertEq(conditionalTokens.balanceOf(address(wrapped1155Factory), tokenId), AMOUNT);
            _approveWrapper(wrapperIndex);
        }

        vm.prank(user);
        router.mergePositions(
            baseToken, CONDITION_ID, wrappers[wrapperOffset], wrappers[wrapperOffset + 1], AMOUNT
        );
        assertEq(base.balanceOf(user), baseBefore);
        for (uint256 i; i < 2; ++i) {
            uint256 wrapperIndex = wrapperOffset + i;
            uint256 tokenId = _tokenId(baseToken, i + 1);
            assertEq(IERC20(wrappers[wrapperIndex]).balanceOf(user), 0);
            assertEq(MockWrappedOutcome(wrappers[wrapperIndex]).totalSupply(), 0);
            assertEq(conditionalTokens.balanceOf(address(wrapped1155Factory), tokenId), 0);
        }
    }

    function _splitBoth() private {
        _split(address(company));
        _split(address(collateral));
    }

    function _split(address baseToken) private {
        uint256 wrapperOffset = baseToken == address(company) ? 0 : 2;
        vm.prank(user);
        router.splitPosition(
            baseToken, CONDITION_ID, wrappers[wrapperOffset], wrappers[wrapperOffset + 1], AMOUNT
        );
    }

    function _approveWrapper(uint256 index) private {
        vm.prank(user);
        IERC20(wrappers[index]).approve(address(router), type(uint256).max);
    }

    function _installPair(address baseToken, uint256 wrapperOffset) private {
        for (uint256 i; i < 2; ++i) {
            uint256 wrapperIndex = wrapperOffset + i;
            wrapperData[wrapperIndex] = _wrapperMetadata();
            uint256 tokenId = _tokenId(baseToken, i + 1);
            wrappers[wrapperIndex] = wrapped1155Factory.requireWrapped1155(
                address(conditionalTokens), tokenId, wrapperData[wrapperIndex]
            );
        }
    }

    function _wrapperMetadata() private pure returns (bytes memory) {
        return abi.encodePacked(_toString31("Wrapped outcome"), _toString31("OUT"), uint8(18));
    }

    function _toString31(string memory value) private pure returns (bytes32 encoded) {
        uint256 length = bytes(value).length;
        require(length < 32, "string too long");
        assembly {
            encoded := mload(add(value, 0x20))
        }
        encoded &= bytes32(type(uint256).max << ((32 - length) << 3));
        encoded |= bytes32(length << 1);
    }

    function _tokenId(address baseToken, uint256 indexSet) private view returns (uint256) {
        bytes32 collectionId = conditionalTokens.getCollectionId(bytes32(0), CONDITION_ID, indexSet);
        return conditionalTokens.getPositionId(baseToken, collectionId);
    }

    function _assertNoRouterDust() private view {
        assertEq(company.balanceOf(address(router)), 0);
        assertEq(collateral.balanceOf(address(router)), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(IERC20(wrappers[i]).balanceOf(address(router)), 0);
            address baseToken = i < 2 ? address(company) : address(collateral);
            uint256 indexSet = (i % 2) + 1;
            uint256 tokenId = _tokenId(baseToken, indexSet);
            assertEq(conditionalTokens.balanceOf(address(router), tokenId), 0);
            assertEq(
                MockWrappedOutcome(wrappers[i]).totalSupply(),
                conditionalTokens.balanceOf(address(wrapped1155Factory), tokenId)
            );
        }
    }
}
