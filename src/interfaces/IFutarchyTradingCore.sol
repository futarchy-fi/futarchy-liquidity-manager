// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal futarchy proposal surface needed for validation and settlement.
interface IFutarchyProposalCore {
    /// @notice Company/proposal token paired against collateral.
    function collateralToken1() external view returns (address);

    /// @notice Collateral token paired against the company/proposal token.
    function collateralToken2() external view returns (address);

    /// @notice Wrapped outcome token at the proposal-specific index.
    /// @dev FLM expects indexes 0/1 for company YES/NO and 2/3 for collateral YES/NO.
    function wrappedOutcome(uint256 index)
        external
        view
        returns (address wrapped1155, bytes memory data);

    /// @notice Reality question id used by the proposal's CTF condition.
    function questionId() external view returns (bytes32);

    /// @notice Conditional Tokens Framework condition id used by the proposal.
    function conditionId() external view returns (bytes32);
}

/// @notice Minimal Conditional Tokens Framework surface used for validation and payout reporting.
interface IConditionalTokensCore {
    /// @notice Computes the canonical condition id for an oracle/question/outcome count tuple.
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    /// @notice Returns the number of outcome slots registered for a condition.
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);

    /// @notice Returns zero until a condition has been resolved.
    function payoutDenominator(bytes32 conditionId) external view returns (uint256);

    /// @notice Returns the payout numerator for a resolved outcome slot.
    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    /// @notice Reports final payouts for the caller as condition oracle.
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

/// @notice Minimal Reality.eth surface used by proposal validation and the deadline proxy.
interface IRealityETHCore {
    /// @notice Returns the settled answer or reverts if the question is not finalized.
    function resultForOnceSettled(bytes32 questionId) external view returns (bytes32);

    /// @notice Returns stored question metadata used for validation and deadline checks.
    function questions(bytes32 questionId)
        external
        view
        returns (
            bytes32 contentHash,
            address arbitrator,
            uint32 openingTs,
            uint32 timeout,
            uint32 finalizeTs,
            bool isPendingArbitration,
            uint256 bounty,
            bytes32 bestAnswer,
            bytes32 historyHash,
            uint256 bond,
            uint256 minBond
        );
}
