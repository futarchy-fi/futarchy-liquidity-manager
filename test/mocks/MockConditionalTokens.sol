// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockConditionalTokens {
    mapping(bytes32 => uint256) public payoutDenominator;
    mapping(bytes32 => mapping(uint256 => uint256)) public payoutNumerators;
    mapping(bytes32 => uint256) public outcomeSlotCount;

    function setPayout(bytes32 conditionId, uint256 denom, uint256 yesNum, uint256 noNum) external {
        payoutDenominator[conditionId] = denom;
        payoutNumerators[conditionId][0] = yesNum;
        payoutNumerators[conditionId][1] = noNum;
    }

    function setOutcomeSlotCount(bytes32 conditionId, uint256 value) external {
        outcomeSlotCount[conditionId] = value;
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 slots)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, slots));
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCount[conditionId];
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        bytes32 conditionId = getConditionId(msg.sender, questionId, payouts.length);
        uint256 denom;
        for (uint256 i = 0; i < payouts.length; i++) {
            payoutNumerators[conditionId][i] = payouts[i];
            denom += payouts[i];
        }
        payoutDenominator[conditionId] = denom;
        outcomeSlotCount[conditionId] = payouts.length;
    }
}
