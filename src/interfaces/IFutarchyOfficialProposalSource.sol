// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Read interface for the current official futarchy proposal.
/// @dev The manager consumes `officialProposalExtended` so it can validate exact outcome tokens and
/// pools before migrating liquidity.
interface IFutarchyOfficialProposalSource {
    /// @notice True once the activation binding has irreversibly committed validation policy.
    function proposalValidationConfigFrozen() external view returns (bool);

    /// @notice Static proposal fields captured once and passed atomically into FLM activation.
    struct ProposalActivationData {
        uint256 proposalId;
        address proposal;
        bytes32 conditionId;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
    }

    /// @notice Full proposal shape needed by the liquidity manager.
    struct OfficialProposalData {
        uint256 proposalId;
        address proposal;
        address creator;
        bool exists;
        bool settled;
        bytes32 conditionId;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
    }

    /// @notice Legacy compact proposal view retained for integrations that only need pool data.
    function officialProposal()
        external
        view
        returns (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPool,
            address noPool
        );

    /// @notice Returns the current official proposal and all wrapped outcome token addresses.
    function officialProposalExtended()
        external
        view
        returns (OfficialProposalData memory proposalData);
}
