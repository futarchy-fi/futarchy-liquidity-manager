// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyProposalCore {
    function collateralToken1() external view returns (address);

    function collateralToken2() external view returns (address);

    function wrappedOutcome(uint256 index)
        external
        view
        returns (address wrapped1155, bytes memory data);

    function questionId() external view returns (bytes32);

    function conditionId() external view returns (bytes32);
}

interface IConditionalTokensCore {
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);

    function payoutDenominator(bytes32 conditionId) external view returns (uint256);

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

interface IRealityETHCore {
    function resultForOnceSettled(bytes32 questionId) external view returns (bytes32);

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
