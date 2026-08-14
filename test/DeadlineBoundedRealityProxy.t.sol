// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeadlineBoundedRealityProxy} from "../src/oracles/DeadlineBoundedRealityProxy.sol";
import {IConditionalTokensCore, IRealityETHCore} from "../src/interfaces/IFutarchyTradingCore.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockRealityETH} from "./mocks/MockRealityETH.sol";

contract DeadlineBoundedRealityProxyTest is Test {
    MockConditionalTokens internal conditionalTokens;
    MockRealityETH internal realitio;
    DeadlineBoundedRealityProxy internal proxy;
    MockFutarchyProposalLike internal proposal;

    bytes32 internal questionId;
    bytes32 internal conditionId;
    uint32 internal openingTs;
    uint256 internal constant MAX_QUESTION_DURATION = 3 days;
    address internal arbitrator = address(0xA11B);

    function setUp() public {
        vm.warp(1_000_000);
        conditionalTokens = new MockConditionalTokens();
        realitio = new MockRealityETH();
        proxy = new DeadlineBoundedRealityProxy(
            IConditionalTokensCore(address(conditionalTokens)),
            IRealityETHCore(address(realitio)),
            MAX_QUESTION_DURATION
        );

        proposal = new MockFutarchyProposalLike(
            address(0xA001),
            address(0xA002),
            address(0xA101),
            address(0xA102),
            address(0xA103),
            address(0xA104)
        );

        questionId = keccak256("question");
        conditionId = conditionalTokens.getConditionId(address(proxy), questionId, 2);
        openingTs = uint32(block.timestamp + 1 hours);
        conditionalTokens.setOutcomeSlotCount(conditionId, 2);
        proposal.setQuestionAndCondition(questionId, conditionId);
        realitio.setQuestion(
            questionId, bytes32(uint256(1)), arbitrator, openingTs, 1 days, 1 ether
        );
    }

    function test_resolve_reports_yes_payout() public {
        realitio.setResult(questionId, bytes32(0));

        proxy.resolve(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 0);
    }

    function test_resolve_reports_no_payout_for_nonzero_answer() public {
        realitio.setResult(questionId, bytes32(uint256(1)));

        proxy.resolve(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 0);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 1);
    }

    function test_force_fail_reverts_before_deadline() public {
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeadlineBoundedRealityProxy.DeadlineNotReached.selector,
                uint256(openingTs) + MAX_QUESTION_DURATION
            )
        );
        proxy.forceFailByDeadline(address(proposal));
    }

    function test_force_fail_reports_no_after_deadline() public {
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION);

        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 0);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 1);
    }

    function test_force_fail_relays_finalized_yes_after_deadline() public {
        realitio.setResult(questionId, bytes32(0));
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION);

        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 0);
    }

    function test_force_fail_reverts_when_normal_finalized_result_is_unavailable() public {
        realitio.setQuestionState(questionId, openingTs + 1, false);
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION);

        vm.expectRevert(DeadlineBoundedRealityProxy.FinalizedResultUnavailable.selector);
        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 0);
    }

    function test_force_fail_keeps_no_fallback_for_finalized_unresolved_answer() public {
        realitio.setQuestionState(questionId, openingTs + 1, false);
        realitio.setBestAnswer(questionId, bytes32(type(uint256).max - 1));
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION);

        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 0);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 1);
    }

    function test_force_fail_reports_no_for_answer_still_inside_challenge_window() public {
        uint32 finalizeTs = openingTs + 3 days + 1;
        realitio.setQuestionState(questionId, finalizeTs, false);
        realitio.setBestAnswer(questionId, bytes32(0));
        vm.warp(uint256(finalizeTs) - 1);

        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 0);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 1);
    }

    function test_force_fail_reports_no_while_arbitration_is_pending() public {
        realitio.setQuestionState(questionId, openingTs + 1, true);
        realitio.setBestAnswer(questionId, bytes32(0));
        vm.warp(uint256(openingTs) + MAX_QUESTION_DURATION);

        proxy.forceFailByDeadline(address(proposal));

        assertEq(conditionalTokens.payoutDenominator(conditionId), 1);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 0), 0);
        assertEq(conditionalTokens.payoutNumerators(conditionId, 1), 1);
    }
}
