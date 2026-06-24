// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockProposalSettlementOracle {
    mapping(address => bool) public settled;

    function setSettled(address proposal, bool value) external {
        settled[proposal] = value;
    }

    function isSettled(address proposal) external view returns (bool) {
        return settled[proposal];
    }
}
