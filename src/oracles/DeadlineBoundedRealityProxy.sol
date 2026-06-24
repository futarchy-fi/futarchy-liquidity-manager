// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IConditionalTokensCore,
    IFutarchyProposalCore,
    IRealityETHCore
} from "../interfaces/IFutarchyTradingCore.sol";

/// @notice CTF oracle proxy that mirrors FutarchyRealityProxy and adds a forced NO deadline.
/// @dev New FLM-grade factories can use this contract as their CTF oracle. It cannot retrofit
///      deadlines onto conditions created with a different oracle address.
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

    function resolve(address proposal) external {
        bytes32 questionId = IFutarchyProposalCore(proposal).questionId();
        uint256 answer = uint256(realitio.resultForOnceSettled(questionId));
        _reportPayouts(questionId, answer == 0);
    }

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

        _reportPayouts(questionId, false);
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
