// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IFutarchyOfficialProposalSource} from "../interfaces/IFutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "../interfaces/IAlgebraFactoryLike.sol";
import {
    IConditionalTokensCore,
    IFutarchyProposalCore,
    IRealityETHCore
} from "../interfaces/IFutarchyTradingCore.sol";

interface IProposalSettlementOracle {
    function isSettled(address proposal) external view returns (bool);
}

/// @title FutarchyOfficialProposalSource
/// @notice Owner-managed source of a single official proposal with optional oracle-based
/// settlement.
/// @dev This enforces "one live official proposal" at a time. When validation is enabled, the
/// owner can only set proposals whose on-chain shape matches the configured token, CTF, Reality,
/// arbitrator, timing, bond, and pool policy.
contract FutarchyOfficialProposalSource is IFutarchyOfficialProposalSource, Ownable2Step {
    enum ProposalValidationFailure {
        None,
        ProposalReadFailed,
        WrongCollateralPair,
        MissingOutcomeToken,
        DuplicateOutcomeToken,
        MissingPool,
        WrongConditionId,
        WrongOutcomeSlotCount,
        MissingRealityQuestion,
        UntrustedArbitrator,
        OpeningTimeTooFar,
        TimeoutTooLow,
        TimeoutTooHigh,
        MinBondTooHigh
    }

    struct OfficialProposal {
        uint256 id;
        address proposal;
        address creator;
        bool exists;
        bool manualSettled;
    }

    struct ProposalValidationConfig {
        bool enabled;
        address expectedProposalToken;
        address expectedCollateralToken;
        address conditionalTokens;
        address trustedOracle;
        address realitio;
        address trustedArbitrator;
        uint32 maxOpeningDelay;
        uint32 minTimeout;
        uint32 maxTimeout;
        uint256 maxMinBond;
        bool requirePools;
    }

    struct ProposalView {
        uint256 proposalId;
        address proposal;
        address creator;
        bool exists;
        bool settled;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
    }

    struct ValidationProposal {
        address proposal;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        address yesPool;
        address noPool;
        bytes32 questionId;
        bytes32 conditionId;
    }

    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    address public officialProposer;
    address public settlementOracle;
    ProposalValidationConfig public proposalValidationConfig;

    OfficialProposal private _official;

    error ZeroAddress();
    error InvalidProposalValidationConfig();
    error ActiveOfficialProposalExists();
    error ProposalValidationFailed(ProposalValidationFailure failure);

    event OfficialProposerUpdated(address indexed oldProposer, address indexed newProposer);
    event SettlementOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ProposalValidationConfigUpdated(ProposalValidationConfig config);
    event OfficialProposalSet(
        uint256 indexed proposalId, address indexed proposal, address indexed creator
    );
    event OfficialProposalCleared();
    event OfficialProposalManualSettlementUpdated(bool settled);

    constructor(
        address initialOwner,
        address initialOfficialProposer,
        IAlgebraFactoryLike algebraFactory
    ) Ownable() {
        if (
            initialOwner == address(0) || initialOfficialProposer == address(0)
                || address(algebraFactory) == address(0)
        ) {
            revert ZeroAddress();
        }

        _transferOwnership(initialOwner);

        officialProposer = initialOfficialProposer;
        ALGEBRA_FACTORY = algebraFactory;
    }

    /// @notice Updates the only proposal creator whose proposals should be considered official.
    /// @dev Owner-only. The manager still checks that the current official proposal creator equals
    /// its immutable `OFFICIAL_PROPOSER`.
    function setOfficialProposer(address newOfficialProposer) external onlyOwner {
        if (newOfficialProposer == address(0)) revert ZeroAddress();
        address old = officialProposer;
        officialProposer = newOfficialProposer;
        emit OfficialProposerUpdated(old, newOfficialProposer);
    }

    /// @notice Sets an optional settlement oracle used instead of manual settlement.
    /// @dev Owner-only. A zero oracle reverts settlement reads back to the manual flag.
    function setSettlementOracle(address newOracle) external onlyOwner {
        address old = settlementOracle;
        settlementOracle = newOracle;
        emit SettlementOracleUpdated(old, newOracle);
    }

    /// @notice Configures on-chain validation for future official proposals.
    /// @dev Owner-only. Validation does not inspect free-form Reality question text; it checks
    /// explicit on-chain fields exposed by the proposal, CTF, Reality, and Algebra factory.
    function setProposalValidationConfig(ProposalValidationConfig calldata config)
        external
        onlyOwner
    {
        if (config.enabled) {
            if (
                config.expectedProposalToken == address(0)
                    || config.expectedCollateralToken == address(0)
                    || config.conditionalTokens == address(0) || config.trustedOracle == address(0)
                    || config.realitio == address(0) || config.trustedArbitrator == address(0)
                    || config.maxOpeningDelay == 0 || config.maxTimeout == 0
                    || config.minTimeout > config.maxTimeout
            ) {
                revert InvalidProposalValidationConfig();
            }
        }

        proposalValidationConfig = config;
        emit ProposalValidationConfigUpdated(config);
    }

    /// @notice Sets the current official proposal.
    /// @dev Owner-only. Reverts while a previous official proposal exists and is not settled.
    /// If validation is enabled, the proposal must pass `validateProposal`.
    /// @param proposalId External proposal identifier used by the integration.
    /// @param proposal Futarchy proposal contract address.
    /// @param creator Creator address reported by the integration/proposal system.
    function setOfficialProposal(uint256 proposalId, address proposal, address creator)
        external
        onlyOwner
    {
        if (proposal == address(0) || creator == address(0)) revert ZeroAddress();
        if (_official.exists && !_isSettled(_official)) revert ActiveOfficialProposalExists();
        (bool valid, ProposalValidationFailure failure) = validateProposal(proposal);
        if (!valid) revert ProposalValidationFailed(failure);

        _official.id = proposalId;
        _official.proposal = proposal;
        _official.creator = creator;
        _official.exists = true;
        _official.manualSettled = false;

        emit OfficialProposalSet(proposalId, proposal, creator);
    }

    /// @notice Clears the official proposal slot.
    /// @dev Owner-only emergency/admin action. Clearing while the manager is in conditional mode
    /// can make `sync` back to spot revert until the active proposal is restored and settled.
    function clearOfficialProposal() external onlyOwner {
        delete _official;
        emit OfficialProposalCleared();
    }

    /// @notice Manually marks the official proposal settled or unsettled.
    /// @dev Owner-only. Ignored when `settlementOracle` is configured.
    function setManualSettled(bool settled) external onlyOwner {
        _official.manualSettled = settled;
        emit OfficialProposalManualSettlementUpdated(settled);
    }

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
        )
    {
        ProposalView memory p = _resolveOfficialProposalView();
        proposalId = p.proposalId;
        creator = p.creator;
        exists = p.exists;
        settled = p.settled;
        proposalToken = p.proposalToken;
        collateralToken = p.collateralToken;
        yesPool = p.yesPool;
        noPool = p.noPool;
    }

    function officialProposalExtended()
        external
        view
        returns (IFutarchyOfficialProposalSource.OfficialProposalData memory proposalData)
    {
        ProposalView memory p = _resolveOfficialProposalView();
        proposalData.proposalId = p.proposalId;
        proposalData.proposal = p.proposal;
        proposalData.creator = p.creator;
        proposalData.exists = p.exists;
        proposalData.settled = p.settled;
        proposalData.proposalToken = p.proposalToken;
        proposalData.collateralToken = p.collateralToken;
        proposalData.yesCompanyToken = p.yesCompanyToken;
        proposalData.noCompanyToken = p.noCompanyToken;
        proposalData.yesCurrencyToken = p.yesCurrencyToken;
        proposalData.noCurrencyToken = p.noCurrencyToken;
        proposalData.yesPool = p.yesPool;
        proposalData.noPool = p.noPool;
    }

    function currentOfficialProposal() external view returns (OfficialProposal memory) {
        return _official;
    }

    /// @notice Checks whether a proposal satisfies the active validation config.
    /// @dev Returns true when validation is disabled. This is intended for pre-flight review and
    /// mirrors the check performed by `setOfficialProposal`.
    function validateProposal(address proposal)
        public
        view
        returns (bool valid, ProposalValidationFailure failure)
    {
        if (proposal == address(0)) {
            return (false, ProposalValidationFailure.ProposalReadFailed);
        }

        ProposalValidationConfig memory config = proposalValidationConfig;
        if (!config.enabled) {
            return (true, ProposalValidationFailure.None);
        }

        ValidationProposal memory p;
        (p, failure) = _readProposalForValidation(proposal);
        if (failure != ProposalValidationFailure.None) return (false, failure);

        failure = _validateTokenAndPoolShape(p, config);
        if (failure != ProposalValidationFailure.None) return (false, failure);

        failure = _validateConditionShape(p, config);
        if (failure != ProposalValidationFailure.None) return (false, failure);

        failure = _validateRealityQuestion(p.questionId, config);
        if (failure != ProposalValidationFailure.None) return (false, failure);

        return (true, failure);
    }

    function _readProposalForValidation(address proposal)
        internal
        view
        returns (ValidationProposal memory p, ProposalValidationFailure failure)
    {
        IFutarchyProposalCore proposalLike = IFutarchyProposalCore(proposal);
        p.proposal = proposal;

        try proposalLike.collateralToken1() returns (address token) {
            p.proposalToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.collateralToken2() returns (address token) {
            p.collateralToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.wrappedOutcome(0) returns (address token, bytes memory) {
            p.yesCompanyToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.wrappedOutcome(1) returns (address token, bytes memory) {
            p.noCompanyToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.wrappedOutcome(2) returns (address token, bytes memory) {
            p.yesCurrencyToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.wrappedOutcome(3) returns (address token, bytes memory) {
            p.noCurrencyToken = token;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.questionId() returns (bytes32 value) {
            p.questionId = value;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }
        try proposalLike.conditionId() returns (bytes32 value) {
            p.conditionId = value;
        } catch {
            return (p, ProposalValidationFailure.ProposalReadFailed);
        }

        return (p, ProposalValidationFailure.None);
    }

    function _validateTokenAndPoolShape(
        ValidationProposal memory p,
        ProposalValidationConfig memory config
    ) internal view returns (ProposalValidationFailure) {
        if (
            p.proposalToken != config.expectedProposalToken
                || p.collateralToken != config.expectedCollateralToken
        ) {
            return ProposalValidationFailure.WrongCollateralPair;
        }
        if (
            p.yesCompanyToken == address(0) || p.noCompanyToken == address(0)
                || p.yesCurrencyToken == address(0) || p.noCurrencyToken == address(0)
        ) {
            return ProposalValidationFailure.MissingOutcomeToken;
        }
        if (p.yesCompanyToken == p.noCompanyToken || p.yesCurrencyToken == p.noCurrencyToken) {
            return ProposalValidationFailure.DuplicateOutcomeToken;
        }
        if (config.requirePools) {
            p.yesPool = ALGEBRA_FACTORY.poolByPair(p.yesCompanyToken, p.yesCurrencyToken);
            p.noPool = ALGEBRA_FACTORY.poolByPair(p.noCompanyToken, p.noCurrencyToken);
            if (p.yesPool == address(0) || p.noPool == address(0)) {
                return ProposalValidationFailure.MissingPool;
            }
        }
        return ProposalValidationFailure.None;
    }

    function _validateConditionShape(
        ValidationProposal memory p,
        ProposalValidationConfig memory config
    ) internal view returns (ProposalValidationFailure) {
        IConditionalTokensCore conditionalTokens = IConditionalTokensCore(config.conditionalTokens);
        bytes32 expectedConditionId =
            conditionalTokens.getConditionId(config.trustedOracle, p.questionId, 2);
        if (p.conditionId != expectedConditionId) {
            return ProposalValidationFailure.WrongConditionId;
        }

        try conditionalTokens.getOutcomeSlotCount(p.conditionId) returns (
            uint256 outcomeSlotCount
        ) {
            if (outcomeSlotCount != 2) {
                return ProposalValidationFailure.WrongOutcomeSlotCount;
            }
        } catch {
            return ProposalValidationFailure.ProposalReadFailed;
        }

        return ProposalValidationFailure.None;
    }

    function _validateRealityQuestion(bytes32 questionId, ProposalValidationConfig memory config)
        internal
        view
        returns (ProposalValidationFailure)
    {
        IRealityETHCore realitio = IRealityETHCore(config.realitio);
        try realitio.questions(questionId) returns (
            bytes32 contentHash,
            address arbitrator,
            uint32 openingTs,
            uint32 timeout,
            uint32,
            bool,
            uint256,
            bytes32,
            bytes32,
            uint256,
            uint256 minBond
        ) {
            if (contentHash == bytes32(0) || arbitrator == address(0)) {
                return ProposalValidationFailure.MissingRealityQuestion;
            }
            if (arbitrator != config.trustedArbitrator) {
                return ProposalValidationFailure.UntrustedArbitrator;
            }
            if (openingTs > block.timestamp + config.maxOpeningDelay) {
                return ProposalValidationFailure.OpeningTimeTooFar;
            }
            if (timeout < config.minTimeout) {
                return ProposalValidationFailure.TimeoutTooLow;
            }
            if (timeout > config.maxTimeout) {
                return ProposalValidationFailure.TimeoutTooHigh;
            }
            if (minBond > config.maxMinBond) {
                return ProposalValidationFailure.MinBondTooHigh;
            }
        } catch {
            return ProposalValidationFailure.ProposalReadFailed;
        }

        return ProposalValidationFailure.None;
    }

    function _isSettled(OfficialProposal memory p) internal view returns (bool settled) {
        if (!p.exists || p.proposal == address(0)) return false;

        if (settlementOracle != address(0)) {
            settled = IProposalSettlementOracle(settlementOracle).isSettled(p.proposal);
            return settled;
        }

        return p.manualSettled;
    }

    function _resolveOfficialProposalView() internal view returns (ProposalView memory p) {
        OfficialProposal memory official = _official;
        p.proposalId = official.id;
        p.proposal = official.proposal;
        p.creator = official.creator;
        p.exists = official.exists;
        p.settled = _isSettled(official);

        if (!p.exists || p.proposal == address(0)) {
            return p;
        }

        IFutarchyProposalCore proposal = IFutarchyProposalCore(p.proposal);
        p.proposalToken = proposal.collateralToken1();
        p.collateralToken = proposal.collateralToken2();

        (p.yesCompanyToken,) = proposal.wrappedOutcome(0);
        (p.noCompanyToken,) = proposal.wrappedOutcome(1);
        (p.yesCurrencyToken,) = proposal.wrappedOutcome(2);
        (p.noCurrencyToken,) = proposal.wrappedOutcome(3);

        p.yesPool = ALGEBRA_FACTORY.poolByPair(p.yesCompanyToken, p.yesCurrencyToken);
        p.noPool = ALGEBRA_FACTORY.poolByPair(p.noCompanyToken, p.noCurrencyToken);
    }
}
