// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockRealityETH {
    struct Question {
        bytes32 contentHash;
        address arbitrator;
        uint32 openingTs;
        uint32 timeout;
        uint32 finalizeTs;
        bool isPendingArbitration;
        uint256 bounty;
        bytes32 bestAnswer;
        bytes32 historyHash;
        uint256 bond;
        uint256 minBond;
    }

    mapping(bytes32 => Question) internal _questions;
    mapping(bytes32 => bytes32) internal _results;
    mapping(bytes32 => bool) internal _settled;

    function setQuestion(
        bytes32 questionId,
        bytes32 contentHash,
        address arbitrator,
        uint32 openingTs,
        uint32 timeout,
        uint256 minBond
    ) external {
        _questions[questionId] = Question({
            contentHash: contentHash,
            arbitrator: arbitrator,
            openingTs: openingTs,
            timeout: timeout,
            finalizeTs: 0,
            isPendingArbitration: false,
            bounty: 0,
            bestAnswer: bytes32(0),
            historyHash: bytes32(0),
            bond: 0,
            minBond: minBond
        });
    }

    function setResult(bytes32 questionId, bytes32 answer) external {
        _results[questionId] = answer;
        _settled[questionId] = true;
    }

    function resultForOnceSettled(bytes32 questionId) external view returns (bytes32) {
        require(_settled[questionId], "not settled");
        return _results[questionId];
    }

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
        )
    {
        Question memory q = _questions[questionId];
        return (
            q.contentHash,
            q.arbitrator,
            q.openingTs,
            q.timeout,
            q.finalizeTs,
            q.isPendingArbitration,
            q.bounty,
            q.bestAnswer,
            q.historyHash,
            q.bond,
            q.minBond
        );
    }
}
