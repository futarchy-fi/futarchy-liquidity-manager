// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IFutarchyFactory {
    struct CreateParams {
        string marketName;
        address companyToken;
        address currencyToken;
        string category;
        string language;
        uint256 minBond;
        uint32 openingTime;
    }

    function createProposal(CreateParams calldata params) external returns (address proposal);
}

interface IOrganization {
    function createAndAddProposalMetadata(
        address proposalAddress,
        string calldata displayNameQuestion,
        string calldata displayNameEvent,
        string calldata description,
        string calldata metadata,
        string calldata metadataURI
    ) external returns (address metadataContract);
}

interface IFutarchyOfficialProposalSourceWriter {
    function setOfficialProposal(uint256 proposalId, address proposal, address creator) external;
}

/// @notice Owner-operated bridge from a Futarchy proposal to an active FLM market.
/// @dev New-market launches require the organization owner to call
/// `organization.setEditor(address(this))` once. Existing-market launches do not.
contract FLMMarketLauncher is Ownable2Step {
    struct MarketParams {
        string marketName;
        uint256 minBond;
        uint32 openingTime;
        string displayNameQuestion;
        string displayNameEvent;
        string description;
        string metadataJson;
    }

    address public source;
    address public manager;
    address public factory;
    address public organization;
    address public companyToken;
    address public currencyToken;
    string public category;
    string public language;
    bool public bound;
    uint256 public nextProposalId;
    uint256 public pendingProposalId;
    address public pendingProposal;

    error ZeroAddress();
    error AlreadyBound();
    error MarketAlreadyPending();
    error NoPendingMarket();
    error NotBound();

    event Bound(
        address indexed source,
        address indexed manager,
        address indexed factory,
        address organization,
        address companyToken,
        address currencyToken,
        string category,
        string language
    );
    event MarketPrepared(
        uint256 indexed proposalId, address indexed proposal, address metadataContract
    );
    event MarketActivated(uint256 indexed proposalId, address indexed proposal);
    event ExistingMarketActivated(uint256 indexed proposalId, address indexed proposal);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        _transferOwnership(initialOwner);
    }

    function bind(
        address source_,
        address manager_,
        address factory_,
        address organization_,
        address companyToken_,
        address currencyToken_,
        string calldata category_,
        string calldata language_
    ) external onlyOwner {
        if (bound) revert AlreadyBound();
        if (
            source_ == address(0) || manager_ == address(0) || factory_ == address(0)
                || organization_ == address(0) || companyToken_ == address(0)
                || currencyToken_ == address(0)
        ) revert ZeroAddress();

        source = source_;
        manager = manager_;
        factory = factory_;
        organization = organization_;
        companyToken = companyToken_;
        currencyToken = currencyToken_;
        category = category_;
        language = language_;
        bound = true;
        emit Bound(
            source_,
            manager_,
            factory_,
            organization_,
            companyToken_,
            currencyToken_,
            category_,
            language_
        );
    }

    /// @notice Creates and indexes a market for activation in a separate transaction.
    /// @dev `metadataJson` is caller-supplied opaque JSON (including chain:100 and TWAP settings).
    /// The launcher holds no funds or fLP shares and has no fund-transfer or manager-redemption
    /// path.
    function prepareMarket(MarketParams calldata p)
        external
        onlyOwner
        returns (address proposal, address metadataContract, uint256 proposalId)
    {
        if (!bound) revert NotBound();
        if (pendingProposal != address(0)) revert MarketAlreadyPending();
        proposal = IFutarchyFactory(factory)
            .createProposal(
                IFutarchyFactory.CreateParams({
                    marketName: p.marketName,
                    companyToken: companyToken,
                    currencyToken: currencyToken,
                    category: category,
                    language: language,
                    minBond: p.minBond,
                    openingTime: p.openingTime
                })
            );
        metadataContract = IOrganization(organization)
            .createAndAddProposalMetadata(
                proposal,
                p.displayNameQuestion,
                p.displayNameEvent,
                p.description,
                p.metadataJson,
                ""
            );
        proposalId = nextProposalId++;
        pendingProposalId = proposalId;
        pendingProposal = proposal;
        emit MarketPrepared(proposalId, proposal, metadataContract);
    }

    /// @notice Activates the prepared market and clears the pending slot.
    function activateMarket() external onlyOwner {
        if (!bound) revert NotBound();
        address proposal = pendingProposal;
        if (proposal == address(0)) revert NoPendingMarket();
        uint256 proposalId = pendingProposalId;
        delete pendingProposalId;
        delete pendingProposal;
        IFutarchyOfficialProposalSourceWriter(source)
            .setOfficialProposal(proposalId, proposal, address(this));
        emit MarketActivated(proposalId, proposal);
    }

    /// @notice Activates an already-created proposal without creating metadata or a new market.
    /// @dev The proposal source performs the full token, condition, and policy validation before
    /// atomically activating the bound liquidity manager.
    function activateExistingMarket(uint256 proposalId, address proposal) external onlyOwner {
        if (!bound) revert NotBound();
        if (pendingProposal != address(0)) revert MarketAlreadyPending();
        IFutarchyOfficialProposalSourceWriter(source)
            .setOfficialProposal(proposalId, proposal, address(this));
        emit ExistingMarketActivated(proposalId, proposal);
    }
}
