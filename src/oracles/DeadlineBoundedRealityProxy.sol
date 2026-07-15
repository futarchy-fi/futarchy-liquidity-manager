// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IConditionalTokensCore,
    IFutarchyProposalCore,
    IRealityETHCore
} from "../interfaces/IFutarchyTradingCore.sol";

/// @title DeadlineBoundedRealityProxy
/// @notice CTF oracle proxy that mirrors FutarchyRealityProxy and adds a forced NO deadline.
/// @dev New FLM-grade factories can use this contract as their CTF oracle. It cannot retrofit
/// deadlines onto conditions created with a different oracle address.
contract DeadlineBoundedRealityProxy {
    IConditionalTokensCore public immutable conditionalTokens;
    IRealityETHCore public immutable realitio;
    uint256 public immutable maxQuestionDuration;

    error ZeroAddress();
    error InvalidMaxQuestionDuration();
    error MissingRealityQuestion();
    error MissingOpeningTime();
    error DeadlineNotReached(uint256 deadline);
    error ConditionAlreadyResolved();

    /// @param _conditionalTokens Conditional Tokens Framework contract that receives payouts.
    /// @param _realitio Reality.eth contract that stores questions and final answers.
    /// @param _maxQuestionDuration Max seconds after Reality opening before forced NO is allowed.
    constructor(
        IConditionalTokensCore _conditionalTokens,
        IRealityETHCore _realitio,
        uint256 _maxQuestionDuration
    ) {
        if (address(_conditionalTokens) == address(0) || address(_realitio) == address(0)) {
            revert ZeroAddress();
        }
        if (_maxQuestionDuration == 0) revert InvalidMaxQuestionDuration();

        conditionalTokens = _conditionalTokens;
        realitio = _realitio;
        maxQuestionDuration = _maxQuestionDuration;
    }

    /// @notice Reports the settled Reality result for a futarchy proposal to CTF.
    /// @dev Reality answer `0` maps to YES payout `[1, 0]`; any other answer maps to NO `[0, 1]`.
    /// @param proposal Futarchy proposal exposing the Reality question id.
    function resolve(address proposal) external {
        bytes32 questionId = IFutarchyProposalCore(proposal).questionId();
        uint256 answer = uint256(realitio.resultForOnceSettled(questionId));
        _reportPayouts(questionId, answer == 0);
    }

    /// @notice Relays a finalized Reality result, or reports deterministic NO if unresolved by the
    /// deadline.
    /// @dev Reverts before `openingTs + maxQuestionDuration` and if the condition already has a
    /// payout denominator. A finalized result always wins the deadline race.
    /// @param proposal Futarchy proposal exposing the Reality question id.
    function forceFailByDeadline(address proposal) external {
        bytes32 questionId = IFutarchyProposalCore(proposal).questionId();
        bytes32 conditionId = conditionalTokens.getConditionId(address(this), questionId, 2);
        if (conditionalTokens.payoutDenominator(conditionId) != 0) {
            revert ConditionAlreadyResolved();
        }

        (bytes32 contentHash,, uint32 openingTs,,,,,,,,) = realitio.questions(questionId);
        if (contentHash == bytes32(0)) revert MissingRealityQuestion();
        if (openingTs == 0) revert MissingOpeningTime();

        uint256 deadline = uint256(openingTs) + maxQuestionDuration;
        if (block.timestamp < deadline) revert DeadlineNotReached(deadline);

        try realitio.resultForOnceSettled(questionId) returns (bytes32 answer) {
            _reportPayouts(questionId, uint256(answer) == 0);
        } catch {
            _reportPayouts(questionId, false);
        }
    }

    function _reportPayouts(bytes32 questionId, bool yesWins) internal {
        uint256[] memory payouts = new uint256[](2);
        if (yesWins) {
            payouts[0] = 1;
        } else {
            payouts[1] = 1;
        }
        conditionalTokens.reportPayouts(questionId, payouts);
    }
}
