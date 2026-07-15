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
    /// @notice Returns whether `proposal` has settled according to an external oracle.
    function isSettled(address proposal) external view returns (bool);
}

interface IOfficialProposalActivationTarget {
    function activateOfficialProposal(
        IFutarchyOfficialProposalSource.ProposalActivationData calldata proposal
    ) external;

    function capturedOfficialProposal()
        external
        view
        returns (IFutarchyOfficialProposalSource.ProposalActivationData memory proposal);

    function PROPOSAL_SOURCE() external view returns (address);

    function canActivateOfficialProposal() external view returns (bool);

    function COMPANY_TOKEN() external view returns (address);

    function WRAPPED_NATIVE() external view returns (address);

    function CONDITIONAL_ROUTER() external view returns (address);
}

interface IConditionalRouterBinding {
    function CONDITIONAL_TOKENS() external view returns (address);
}

interface IRealityOracleBinding {
    function conditionalTokens() external view returns (address);

    function realitio() external view returns (address);

    function maxQuestionDuration() external view returns (uint256);
}

/// @title FutarchyOfficialProposalSource
/// @notice Source of a single official proposal with atomic manager activation and optional
/// oracle-based settlement.
/// @dev The immutable lifecycle coordinator is the only official-proposal writer. When validation
/// is enabled, proposals must match the configured token, CTF, Reality, arbitrator, timing, and
/// bond policy.
contract FutarchyOfficialProposalSource is IFutarchyOfficialProposalSource, Ownable2Step {
    enum ProposalValidationFailure {
        None,
        ProposalReadFailed,
        WrongCollateralPair,
        MissingOutcomeToken,
        DuplicateOutcomeToken,
        WrongConditionId,
        WrongOutcomeSlotCount,
        MissingRealityQuestion,
        UntrustedArbitrator,
        OpeningTimeTooFar,
        TimeoutTooLow,
        TimeoutTooHigh,
        MinBondTooHigh,
        QuestionNotPristine,
        OpeningTimeTooSoon,
        ConditionalLifetimeTooShort
    }

    /// @notice Stored official proposal slot.
    struct OfficialProposal {
        uint96 id;
        address proposal;
        address creator;
        bool exists;
        bool manualSettled;
    }

    /// @notice On-chain policy used to admit official proposals.
    /// @dev A zero `realitio` selects condition-only validation; otherwise the full Reality policy
    /// is enforced in addition to the token, wrapper, and CTF condition checks.
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
        uint32 minConditionalLifetime;
        uint256 maxMinBond;
    }

    /// @notice Resolved proposal view including current settlement status and pool addresses.
    struct ProposalView {
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

    /// @notice Proposal fields loaded during validation.
    struct ValidationProposal {
        address proposal;
        address proposalToken;
        address collateralToken;
        address yesCompanyToken;
        address noCompanyToken;
        address yesCurrencyToken;
        address noCurrencyToken;
        bytes32 questionId;
        bytes32 conditionId;
    }

    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    uint32 public constant MIN_CONDITIONAL_LIFETIME = 1 days;
    address public immutable BINDING_AUTHORITY;
    address public immutable LIFECYCLE_COORDINATOR;
    address public proposalManager;
    address public officialProposer;
    address public settlementOracle;
    address public activationTarget;
    ProposalValidationConfig public proposalValidationConfig;

    OfficialProposal private _official;
    bool private _settingOfficialProposal;

    error ZeroAddress();
    error OnlyOwnerOrProposalManager();
    error OnlyBindingAuthority();
    error OnlyLifecycleCoordinator();
    error InvalidLifecycleCoordinator();
    error InvalidActivationTarget();
    error ActivationTargetAlreadyBound();
    error ActivationTargetUnbound();
    error ActivationUnavailable();
    error ReentrantOfficialProposal();
    error InvalidProposalId();
    error InvalidOfficialProposer();
    error InvalidProposalValidationConfig();
    error ProposalValidationConfigFrozen();
    error CapturedProposalMismatch();
    error ProposalValidationFailed(ProposalValidationFailure failure);

    event ProposalManagerUpdated(address indexed oldManager, address indexed newManager);
    event OfficialProposerUpdated(address indexed oldProposer, address indexed newProposer);
    event SettlementOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ProposalValidationConfigUpdated(ProposalValidationConfig config);
    event ProposalValidationConfigFrozenAtBinding(bytes32 indexed configHash);
    event ActivationTargetBound(address indexed target);
    event OfficialProposalSet(
        uint256 indexed proposalId, address indexed proposal, address indexed creator
    );
    event OfficialProposalCleared();
    event OfficialProposalManualSettlementUpdated(bool settled);

    constructor(
        address initialOwner,
        address initialProposalManager,
        address initialOfficialProposer,
        IAlgebraFactoryLike algebraFactory,
        bytes memory initialValidationConfigData
    ) Ownable() {
        if (
            initialOwner == address(0) || initialProposalManager == address(0)
                || initialOfficialProposer == address(0) || address(algebraFactory) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (initialProposalManager.code.length == 0) revert InvalidLifecycleCoordinator();

        BINDING_AUTHORITY = msg.sender;
        LIFECYCLE_COORDINATOR = initialProposalManager;
        proposalManager = initialProposalManager;
        officialProposer = initialOfficialProposer;
        ALGEBRA_FACTORY = algebraFactory;
        if (initialValidationConfigData.length != 0) {
            _setProposalValidationConfig(
                abi.decode(initialValidationConfigData, (ProposalValidationConfig))
            );
        }

        _transferOwnership(initialOwner);
    }

    modifier onlyOwnerOrProposalManager() {
        _requireOwnerOrProposalManager();
        _;
    }

    modifier onlyLifecycleCoordinator() {
        if (msg.sender != LIFECYCLE_COORDINATOR) revert OnlyLifecycleCoordinator();
        _;
    }

    modifier nonReentrantOfficialProposal() {
        if (_settingOfficialProposal) revert ReentrantOfficialProposal();
        _settingOfficialProposal = true;
        _;
        _settingOfficialProposal = false;
    }

    function _requireOwnerOrProposalManager() internal view {
        if (msg.sender != owner() && msg.sender != proposalManager) {
            revert OnlyOwnerOrProposalManager();
        }
    }

    /// @notice Updates the proposal manager that can operate proposal-source state.
    /// @dev Owner-only. The proposal manager cannot transfer ownership or change this role.
    function setProposalManager(address newProposalManager) external onlyOwner {
        if (newProposalManager == address(0)) revert ZeroAddress();
        address old = proposalManager;
        proposalManager = newProposalManager;
        emit ProposalManagerUpdated(old, newProposalManager);
    }

    /// @notice Irreversibly binds the manager activated by official-proposal writes.
    /// @dev Only the contract that deployed this source may bind the target. The reciprocal source
    /// and activation-readiness methods are checked before the binding is stored.
    function bindActivationTarget(address target) external {
        if (msg.sender != BINDING_AUTHORITY) revert OnlyBindingAuthority();
        if (activationTarget != address(0)) revert ActivationTargetAlreadyBound();
        if (target == address(0) || target.code.length == 0) revert InvalidActivationTarget();

        IOfficialProposalActivationTarget targetLike = IOfficialProposalActivationTarget(target);
        try targetLike.PROPOSAL_SOURCE() returns (address proposalSource) {
            if (proposalSource != address(this)) revert InvalidActivationTarget();
        } catch {
            revert InvalidActivationTarget();
        }
        try targetLike.canActivateOfficialProposal() returns (bool) {}
        catch {
            revert InvalidActivationTarget();
        }

        _validateFrozenPolicy(targetLike);

        activationTarget = target;
        emit ProposalValidationConfigFrozenAtBinding(keccak256(
                abi.encode(proposalValidationConfig)
            ));
        emit ActivationTargetBound(target);
    }

    /// @notice Updates the only proposal creator whose proposals should be considered official.
    /// @dev Owner/manager-only. Future official writes must identify this creator exactly.
    function setOfficialProposer(address newOfficialProposer) external onlyOwnerOrProposalManager {
        if (newOfficialProposer == address(0)) revert ZeroAddress();
        address old = officialProposer;
        officialProposer = newOfficialProposer;
        emit OfficialProposerUpdated(old, newOfficialProposer);
    }

    /// @notice Sets an optional settlement oracle used instead of manual settlement.
    /// @dev Owner/manager-only. A zero oracle reverts settlement reads back to the manual flag.
    function setSettlementOracle(address newOracle) external onlyOwnerOrProposalManager {
        address old = settlementOracle;
        settlementOracle = newOracle;
        emit SettlementOracleUpdated(old, newOracle);
    }

    /// @notice Configures on-chain validation for future official proposals.
    /// @dev Owner/manager-only. Validation does not inspect free-form Reality question text; it
    /// checks explicit on-chain fields exposed by the proposal, CTF, Reality, and Algebra factory.
    function setProposalValidationConfig(ProposalValidationConfig calldata config)
        external
        onlyOwnerOrProposalManager
    {
        if (activationTarget != address(0)) revert ProposalValidationConfigFrozen();
        _setProposalValidationConfig(config);
    }

    /// @notice Returns whether the activation binding has irreversibly committed the policy.
    function proposalValidationConfigFrozen() external view returns (bool) {
        return activationTarget != address(0);
    }

    /// @notice Sets the current official proposal.
    /// @dev Lifecycle-coordinator-only. The source write and target activation are atomic. If
    /// validation is enabled, the proposal must pass `validateProposal`.
    /// @param proposalId External proposal identifier used by the integration.
    /// @param proposal Futarchy proposal contract address.
    /// @param creator Creator address reported by the integration/proposal system.
    function setOfficialProposal(uint256 proposalId, address proposal, address creator)
        external
        onlyLifecycleCoordinator
        nonReentrantOfficialProposal
    {
        if (proposal == address(0) || creator == address(0)) revert ZeroAddress();
        if (proposalId > type(uint96).max) revert InvalidProposalId();
        if (creator != officialProposer) revert InvalidOfficialProposer();
        address target = activationTarget;
        if (target == address(0)) revert ActivationTargetUnbound();
        if (!IOfficialProposalActivationTarget(target).canActivateOfficialProposal()) {
            revert ActivationUnavailable();
        }
        (ValidationProposal memory snapshot, ProposalValidationFailure failure) =
            _readProposalForValidation(proposal);
        if (failure == ProposalValidationFailure.None && proposalValidationConfig.enabled) {
            failure = _validateProposalSnapshot(snapshot, proposalValidationConfig);
        }
        if (failure != ProposalValidationFailure.None) revert ProposalValidationFailed(failure);

        _official.id = uint96(proposalId);
        _official.proposal = proposal;
        _official.creator = creator;
        _official.exists = true;
        _official.manualSettled = false;

        IOfficialProposalActivationTarget(target)
            .activateOfficialProposal(
                IFutarchyOfficialProposalSource.ProposalActivationData({
                    proposalId: proposalId,
                    proposal: proposal,
                    conditionId: snapshot.conditionId,
                    proposalToken: snapshot.proposalToken,
                    collateralToken: snapshot.collateralToken,
                    yesCompanyToken: snapshot.yesCompanyToken,
                    noCompanyToken: snapshot.noCompanyToken,
                    yesCurrencyToken: snapshot.yesCurrencyToken,
                    noCurrencyToken: snapshot.noCurrencyToken
                })
            );
        emit OfficialProposalSet(proposalId, proposal, creator);
    }

    /// @notice Clears the registry slot without changing the manager's stored active binding.
    /// @dev Owner/manager-only emergency/admin action. CTF settlement remains source-independent.
    function clearOfficialProposal() external onlyOwnerOrProposalManager {
        delete _official;
        emit OfficialProposalCleared();
    }

    /// @notice Manually marks the official proposal settled or unsettled.
    /// @dev Owner/manager-only. Ignored when `settlementOracle` is configured.
    function setManualSettled(bool settled) external onlyOwnerOrProposalManager {
        _official.manualSettled = settled;
        emit OfficialProposalManualSettlementUpdated(settled);
    }

    /// @notice Returns a compact view of the current official proposal.
    /// @dev This omits wrapped outcome tokens. The liquidity manager uses
    /// `officialProposalExtended` instead.
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

    /// @notice Returns the current official proposal with all outcome-token addresses.
    /// @dev Settlement is resolved through `settlementOracle` when configured, otherwise through
    /// the manual settlement flag.
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
        proposalData.conditionId = p.conditionId;
        proposalData.proposalToken = p.proposalToken;
        proposalData.collateralToken = p.collateralToken;
        proposalData.yesCompanyToken = p.yesCompanyToken;
        proposalData.noCompanyToken = p.noCompanyToken;
        proposalData.yesCurrencyToken = p.yesCurrencyToken;
        proposalData.noCurrencyToken = p.noCurrencyToken;
        proposalData.yesPool = p.yesPool;
        proposalData.noPool = p.noPool;
    }

    /// @notice Returns the raw stored official proposal slot.
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

        failure = _validateProposalSnapshot(p, config);
        return (failure == ProposalValidationFailure.None, failure);
    }

    function _validateProposalSnapshot(
        ValidationProposal memory p,
        ProposalValidationConfig memory config
    ) internal view returns (ProposalValidationFailure failure) {
        failure = _validateTokenShape(p, config);
        if (failure != ProposalValidationFailure.None) return failure;

        failure = _validateConditionShape(p, config);
        if (failure != ProposalValidationFailure.None) return failure;

        if (config.realitio == address(0)) return ProposalValidationFailure.None;
        failure = _validateRealityQuestion(p.questionId, config);
        return failure;
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

    function _validateTokenShape(
        ValidationProposal memory p,
        ProposalValidationConfig memory config
    ) internal pure returns (ProposalValidationFailure) {
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
            uint32 finalizeTs,
            bool isPendingArbitration,
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
            if (finalizeTs != 0 || isPendingArbitration) {
                return ProposalValidationFailure.QuestionNotPristine;
            }
            if (openingTs <= block.timestamp) {
                return ProposalValidationFailure.OpeningTimeTooSoon;
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
            if (uint256(openingTs) + timeout < block.timestamp + config.minConditionalLifetime) {
                return ProposalValidationFailure.ConditionalLifetimeTooShort;
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

    function _setProposalValidationConfig(ProposalValidationConfig memory config) internal {
        if (config.enabled) {
            if (
                config.expectedProposalToken == address(0)
                    || config.expectedCollateralToken == address(0)
                    || config.conditionalTokens == address(0) || config.trustedOracle == address(0)
                    || (config.realitio != address(0)
                        && (config.trustedArbitrator == address(0)
                            || config.maxOpeningDelay == 0
                            || config.minTimeout == 0
                            || config.maxTimeout == 0
                            || config.minTimeout > config.maxTimeout
                            || config.minConditionalLifetime < MIN_CONDITIONAL_LIFETIME
                            || uint256(config.maxOpeningDelay) + config.maxTimeout
                                < config.minConditionalLifetime))
            ) {
                revert InvalidProposalValidationConfig();
            }
        }

        proposalValidationConfig = config;
        emit ProposalValidationConfigUpdated(config);
    }

    function _validateFrozenPolicy(IOfficialProposalActivationTarget targetLike) internal view {
        ProposalValidationConfig memory config = proposalValidationConfig;
        if (!config.enabled) revert InvalidProposalValidationConfig();

        address companyToken;
        address collateralToken;
        address conditionalRouter;
        try targetLike.COMPANY_TOKEN() returns (address value) {
            companyToken = value;
        } catch {
            revert InvalidActivationTarget();
        }
        try targetLike.WRAPPED_NATIVE() returns (address value) {
            collateralToken = value;
        } catch {
            revert InvalidActivationTarget();
        }
        try targetLike.CONDITIONAL_ROUTER() returns (address value) {
            conditionalRouter = value;
        } catch {
            revert InvalidActivationTarget();
        }
        if (
            companyToken != config.expectedProposalToken
                || collateralToken != config.expectedCollateralToken
                || conditionalRouter.code.length == 0
        ) revert InvalidProposalValidationConfig();

        address routerConditionalTokens;
        try IConditionalRouterBinding(conditionalRouter).CONDITIONAL_TOKENS() returns (
            address value
        ) {
            routerConditionalTokens = value;
        } catch {
            revert InvalidProposalValidationConfig();
        }
        if (routerConditionalTokens != config.conditionalTokens) {
            revert InvalidProposalValidationConfig();
        }

        if (config.realitio == address(0)) return;
        IRealityOracleBinding oracle = IRealityOracleBinding(config.trustedOracle);
        try oracle.conditionalTokens() returns (address value) {
            if (value != config.conditionalTokens) revert InvalidProposalValidationConfig();
        } catch {
            revert InvalidProposalValidationConfig();
        }
        try oracle.realitio() returns (address value) {
            if (value != config.realitio) revert InvalidProposalValidationConfig();
        } catch {
            revert InvalidProposalValidationConfig();
        }

        // Legacy FutarchyRealityProxy has no force deadline. New bounded proxies expose this
        // optional getter and may not make NO forceable before the committed minimum lifetime.
        try oracle.maxQuestionDuration() returns (uint256 duration) {
            if (duration < config.minConditionalLifetime) {
                revert InvalidProposalValidationConfig();
            }
        } catch {}
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

        IFutarchyOfficialProposalSource.ProposalActivationData memory captured =
            IOfficialProposalActivationTarget(activationTarget).capturedOfficialProposal();
        if (captured.proposalId != p.proposalId || captured.proposal != p.proposal) {
            revert CapturedProposalMismatch();
        }
        p.conditionId = captured.conditionId;
        p.proposalToken = captured.proposalToken;
        p.collateralToken = captured.collateralToken;
        p.yesCompanyToken = captured.yesCompanyToken;
        p.noCompanyToken = captured.noCompanyToken;
        p.yesCurrencyToken = captured.yesCurrencyToken;
        p.noCurrencyToken = captured.noCurrencyToken;

        p.yesPool = ALGEBRA_FACTORY.poolByPair(p.yesCompanyToken, p.yesCurrencyToken);
        p.noPool = ALGEBRA_FACTORY.poolByPair(p.noCompanyToken, p.noCurrencyToken);
    }
}
