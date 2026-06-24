// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IFutarchyOfficialProposalSource
} from "../../src/interfaces/IFutarchyOfficialProposalSource.sol";

contract MockOfficialProposalSource is IFutarchyOfficialProposalSource {
    uint256 public proposalId;
    address public proposal;
    address public creator;
    bool public exists;
    bool public settled;
    address public proposalToken;
    address public collateralToken;
    address public yesCompanyToken;
    address public noCompanyToken;
    address public yesCurrencyToken;
    address public noCurrencyToken;
    address public yesPool;
    address public noPool;

    function createProposal(
        address _creator,
        address _proposalToken,
        address _collateralToken,
        address _yesPool,
        address _noPool
    ) external returns (uint256 newProposalId) {
        newProposalId = proposalId + 1;
        proposalId = newProposalId;
        creator = _creator;
        exists = true;
        settled = false;
        proposalToken = _proposalToken;
        collateralToken = _collateralToken;
        yesPool = _yesPool;
        noPool = _noPool;

        // Deterministic non-zero placeholders for test environments.
        proposal = address(uint160(0xF000 + newProposalId));
        yesCompanyToken = address(uint160(0xA000 + (newProposalId * 10) + 1));
        noCompanyToken = address(uint160(0xA000 + (newProposalId * 10) + 2));
        yesCurrencyToken = address(uint160(0xA000 + (newProposalId * 10) + 3));
        noCurrencyToken = address(uint160(0xA000 + (newProposalId * 10) + 4));
    }

    function createProposalExtended(
        address _proposal,
        address _creator,
        address _proposalToken,
        address _collateralToken,
        address _yesCompanyToken,
        address _noCompanyToken,
        address _yesCurrencyToken,
        address _noCurrencyToken,
        address _yesPool,
        address _noPool
    ) external returns (uint256 newProposalId) {
        newProposalId = proposalId + 1;
        proposalId = newProposalId;
        proposal = _proposal;
        creator = _creator;
        exists = true;
        settled = false;
        proposalToken = _proposalToken;
        collateralToken = _collateralToken;
        yesCompanyToken = _yesCompanyToken;
        noCompanyToken = _noCompanyToken;
        yesCurrencyToken = _yesCurrencyToken;
        noCurrencyToken = _noCurrencyToken;
        yesPool = _yesPool;
        noPool = _noPool;
    }

    function setSettled(bool value) external {
        require(exists, "no proposal");
        settled = value;
    }

    function clearProposal() external {
        proposalId = 0;
        creator = address(0);
        exists = false;
        settled = false;
        proposalToken = address(0);
        collateralToken = address(0);
        proposal = address(0);
        yesCompanyToken = address(0);
        noCompanyToken = address(0);
        yesCurrencyToken = address(0);
        noCurrencyToken = address(0);
        yesPool = address(0);
        noPool = address(0);
    }

    function officialProposal()
        external
        view
        returns (uint256, address, bool, bool, address, address, address, address)
    {
        return
            (proposalId, creator, exists, settled, proposalToken, collateralToken, yesPool, noPool);
    }

    function officialProposalExtended()
        external
        view
        returns (IFutarchyOfficialProposalSource.OfficialProposalData memory proposalData)
    {
        proposalData.proposalId = proposalId;
        proposalData.proposal = proposal;
        proposalData.creator = creator;
        proposalData.exists = exists;
        proposalData.settled = settled;
        proposalData.proposalToken = proposalToken;
        proposalData.collateralToken = collateralToken;
        proposalData.yesCompanyToken = yesCompanyToken;
        proposalData.noCompanyToken = noCompanyToken;
        proposalData.yesCurrencyToken = yesCurrencyToken;
        proposalData.noCurrencyToken = noCurrencyToken;
        proposalData.yesPool = yesPool;
        proposalData.noPool = noPool;
    }
}
