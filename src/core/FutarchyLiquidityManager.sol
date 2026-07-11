// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {IFutarchyOfficialProposalSource} from "../interfaces/IFutarchyOfficialProposalSource.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../interfaces/IPoolStabilityGuard.sol";
import {IFutarchyProposalCore} from "../interfaces/IFutarchyTradingCore.sol";

interface IWrappedNative is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

/// @title FutarchyLiquidityManager
/// @notice Immutable, permissionless state machine that keeps most liquidity in spot and
///         migrates 80% of LP units to conditional markets while the official proposal is live.
contract FutarchyLiquidityManager is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIGRATION_BPS = 8000;
    uint256 public constant MAX_SYNC_LEFTOVER_BPS = 50;
    uint256 public constant EMERGENCY_EXIT_DELAY = 2 days;

    IERC20 public immutable COMPANY_TOKEN;
    IWrappedNative public immutable WRAPPED_NATIVE;
    address public immutable BOOTSTRAP_RECIPIENT;
    address public immutable OFFICIAL_PROPOSER;
    IFutarchyOfficialProposalSource public immutable PROPOSAL_SOURCE;
    IFutarchyLiquidityAdapter public immutable SPOT_ADAPTER;
    IFutarchyLiquidityAdapter public immutable CONDITIONAL_ADAPTER;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;
    IPoolStabilityGuard public immutable POOL_STABILITY_GUARD;

    address public immutable TOKEN0;
    address public immutable TOKEN1;
    bool public immutable COMPANY_IS_TOKEN0;

    bool public initializedFromBootstrap;
    bool public inConditionalMode;
    bool public emergencyExitExecuted;
    uint256 public activeProposalId;
    uint256 public emergencyExitArmedAt;
    uint128 public spotLiquidity;
    uint128 public conditionalYesLiquidity;
    uint128 public conditionalNoLiquidity;
    address public activeProposal;
    address public activeYesCompanyToken;
    address public activeNoCompanyToken;
    address public activeYesCurrencyToken;
    address public activeNoCurrencyToken;

    enum SyncAction {
        None,
        MigratedToConditional,
        MigratedBackToSpot
    }

    struct ProposalData {
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

    struct OutcomeAmounts {
        uint256 yesCompany;
        uint256 noCompany;
        uint256 yesCurrency;
        uint256 noCurrency;
    }

    struct VaultAmounts {
        uint256 company;
        uint256 collateral;
        OutcomeAmounts outcomes;
    }

    struct LpTokenMetadata {
        string name;
        string symbol;
    }

    error OnlyBootstrapRecipient();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroAddress();
    error InvalidProposalConfig();
    error ActiveProposalRequired();
    error EmergencyModeActive();
    error EmergencyExitAlreadyArmed();
    error EmergencyExitNotArmed();
    error EmergencyExitDelayActive();
    error EmergencyExitAlreadyExecuted();
    error DepositsDisabledInConditionalMode();
    error AdapterOverusedInput();
    error ExcessiveSyncLeftover(
        uint256 companyRecovered,
        uint256 collateralRecovered,
        uint256 companyUnused,
        uint256 collateralUnused
    );
    error ZeroLiquidityMinted();
    error ZeroSharesMinted();
    error InvalidShares();
    error ZeroRecipient();
    error SharesOutstanding();
    error InvalidDepositRatio();
    error InvalidAssetTransfer();
    error InvalidSettlementOutcome();
    error IncompleteOutcomeRecovery();
    error OnlySelf();

    event InitializedFromBootstrap(
        uint256 companyAmount, uint256 collateralAmount, uint128 spotLiquidityMinted
    );
    event SpotDeposited(
        address indexed sender,
        uint256 companyAmount,
        uint256 collateralAmount,
        uint256 sharesMinted
    );
    event SharesRedeemed(
        address indexed owner,
        address indexed recipient,
        uint256 sharesBurned,
        uint256 companyOut,
        uint256 collateralOut
    );
    event OutcomeTokensRedeemed(
        address indexed owner,
        address indexed recipient,
        uint256 yesCompanyOut,
        uint256 noCompanyOut,
        uint256 yesCurrencyOut,
        uint256 noCurrencyOut
    );
    event LiquidityMigratedToConditional(
        uint256 indexed proposalId, uint128 spotRemoved, uint256 conditionalAdded
    );
    event LiquidityMigratedBackToSpot(
        uint256 indexed proposalId, uint256 conditionalRemoved, uint128 spotAdded
    );
    event LiquidityRestoreDeferred();
    event EmergencyExitArmed(uint256 armedAt, uint256 executableAt);
    event EmergencyExitDisarmed();
    event EmergencyExitExecuted(uint128 spotRemoved, uint256 conditionalRemoved);
    event IdleSweptToBootstrapRecipient(
        uint256 companySentToBootstrap,
        uint256 collateralSentToBootstrap,
        uint256 nativeSentToBootstrap
    );

    /// @notice Deploys the manager with immutable token, proposal, router, and adapter wiring.
    /// @param bootstrapRecipient Account allowed to initialize and receive emergency/idle sweeps.
    /// @param companyToken Organization token paired against collateral.
    /// @param wrappedNative Collateral token used by spot and conditional pools. Native-collateral
    /// flows require this to implement `deposit()`/`withdraw(uint256)`.
    /// @param officialProposer Proposal creator whose official proposals trigger migration.
    /// @param proposalSource Source that exposes the current official proposal and settlement flag.
    /// @param spotAdapter Adapter managing the spot company/wrapped-native position.
    /// @param conditionalAdapter Adapter managing YES and NO conditional positions.
    /// @param conditionalRouter Router used to split, merge, and redeem conditional positions.
    /// @param poolStabilityGuard Shared guard enforcing spot-pool TWAP stability before migration.
    /// @param initialOwner Owner of emergency controls.
    /// @param lpTokenMetadata ERC20 name and symbol for manager shares.
    constructor(
        address bootstrapRecipient,
        IERC20 companyToken,
        IWrappedNative wrappedNative,
        address officialProposer,
        IFutarchyOfficialProposalSource proposalSource,
        IFutarchyLiquidityAdapter spotAdapter,
        IFutarchyLiquidityAdapter conditionalAdapter,
        IFutarchyConditionalRouter conditionalRouter,
        IPoolStabilityGuard poolStabilityGuard,
        address initialOwner,
        LpTokenMetadata memory lpTokenMetadata
    ) ERC20(lpTokenMetadata.name, lpTokenMetadata.symbol) {
        if (
            bootstrapRecipient == address(0) || address(companyToken) == address(0)
                || address(wrappedNative) == address(0) || officialProposer == address(0)
                || address(proposalSource) == address(0) || address(spotAdapter) == address(0)
                || address(conditionalAdapter) == address(0)
                || address(conditionalRouter) == address(0)
                || address(poolStabilityGuard) == address(0) || initialOwner == address(0)
        ) {
            revert ZeroAddress();
        }

        BOOTSTRAP_RECIPIENT = bootstrapRecipient;
        COMPANY_TOKEN = companyToken;
        WRAPPED_NATIVE = wrappedNative;
        OFFICIAL_PROPOSER = officialProposer;
        PROPOSAL_SOURCE = proposalSource;
        SPOT_ADAPTER = spotAdapter;
        CONDITIONAL_ADAPTER = conditionalAdapter;
        CONDITIONAL_ROUTER = conditionalRouter;
        POOL_STABILITY_GUARD = poolStabilityGuard;

        bool companyFirst = address(companyToken) < address(wrappedNative);
        TOKEN0 = companyFirst ? address(companyToken) : address(wrappedNative);
        TOKEN1 = companyFirst ? address(wrappedNative) : address(companyToken);
        COMPANY_IS_TOKEN0 = companyFirst;

        _transferOwnership(initialOwner);
    }

    receive() external payable {}

    /// @dev OpenZeppelin v4 SafeERC20 does not include `forceApprove`.
    ///      This helper provides the same semantics: set allowance to 0 first when needed.
    function _forceApprove(IERC20 token, address spender, uint256 value) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current != 0) {
            token.safeApprove(spender, 0);
        }
        token.safeApprove(spender, value);
    }

    /// @notice Initializes first spot liquidity and mints all initial shares to the bootstrap
    /// recipient. The adapter's immutable execution policy is used.
    function initializeFromBootstrap(uint256 companyAmount)
        external
        payable
        nonReentrant
        returns (uint128 liquidityMinted)
    {
        liquidityMinted = _initializeFromBootstrap(companyAmount, msg.value, true);
    }

    /// @notice ERC20-collateral bootstrap variant.
    function initializeFromBootstrap(uint256 companyAmount, uint256 collateralAmount)
        external
        nonReentrant
        returns (uint128 liquidityMinted)
    {
        liquidityMinted = _initializeFromBootstrap(companyAmount, collateralAmount, false);
    }

    /// @notice Deposits company token and native collateral in the vault's existing proportion.
    /// Excess input is left with the caller and the adapter's immutable policy is used.
    function depositToSpot(uint256 companyAmount)
        external
        payable
        nonReentrant
        returns (uint256 sharesMinted)
    {
        sharesMinted = _depositToSpot(companyAmount, msg.value, true);
    }

    /// @notice ERC20-collateral deposit variant.
    function depositToSpot(uint256 companyAmount, uint256 collateralAmount)
        external
        nonReentrant
        returns (uint256 sharesMinted)
    {
        sharesMinted = _depositToSpot(companyAmount, collateralAmount, false);
    }

    function _initializeFromBootstrap(
        uint256 companyAmount,
        uint256 collateralAmount,
        bool wrapNativeCollateral
    ) internal returns (uint128 liquidityMinted) {
        _assertOnlyBootstrap();
        _assertNotEmergencyMode();
        if (initializedFromBootstrap) revert AlreadyInitialized();
        initializedFromBootstrap = true;

        _pullBaseAssets(companyAmount, collateralAmount, wrapNativeCollateral);

        uint256 companyUnused;
        uint256 collateralUnused;
        (liquidityMinted, companyUnused, collateralUnused) =
            _addToSpot(companyAmount, collateralAmount, "");
        _payout(BOOTSTRAP_RECIPIENT, companyUnused, collateralUnused, wrapNativeCollateral);
        _mint(BOOTSTRAP_RECIPIENT, liquidityMinted);
        emit InitializedFromBootstrap(companyAmount, collateralAmount, liquidityMinted);
    }

    function _depositToSpot(
        uint256 companyAmount,
        uint256 collateralAmount,
        bool wrapNativeCollateral
    ) internal returns (uint256 sharesMinted) {
        _assertNotEmergencyMode();
        _assertInitialized();
        if (inConditionalMode) revert DepositsDisabledInConditionalMode();

        _consolidateVault();
        uint256 supply = totalSupply();
        uint256 companyBefore = COMPANY_TOKEN.balanceOf(address(this));
        uint256 collateralBefore = WRAPPED_NATIVE.balanceOf(address(this));
        if (companyBefore == 0 || collateralBefore == 0) revert InvalidDepositRatio();

        sharesMinted = _min(
            Math.mulDiv(companyAmount, supply, companyBefore),
            Math.mulDiv(collateralAmount, supply, collateralBefore)
        );
        if (sharesMinted == 0) revert ZeroSharesMinted();
        uint256 companyAccepted = _mulDivUp(sharesMinted, companyBefore, supply);
        uint256 collateralAccepted = _mulDivUp(sharesMinted, collateralBefore, supply);

        _pullBaseAssets(companyAccepted, collateralAccepted, wrapNativeCollateral);
        if (wrapNativeCollateral && collateralAmount > collateralAccepted) {
            payable(msg.sender).sendValue(collateralAmount - collateralAccepted);
        }
        _mint(msg.sender, sharesMinted);
        _restoreActiveLiquidity();
        emit SpotDeposited(msg.sender, companyAccepted, collateralAccepted, sharesMinted);
    }

    function _pullBaseAssets(
        uint256 companyAmount,
        uint256 collateralAmount,
        bool wrapNativeCollateral
    ) internal {
        if (companyAmount > 0) {
            uint256 companyBefore = COMPANY_TOKEN.balanceOf(address(this));
            COMPANY_TOKEN.safeTransferFrom(msg.sender, address(this), companyAmount);
            if (COMPANY_TOKEN.balanceOf(address(this)) - companyBefore != companyAmount) {
                revert InvalidAssetTransfer();
            }
        }

        if (collateralAmount == 0) return;

        uint256 collateralBefore = WRAPPED_NATIVE.balanceOf(address(this));
        if (wrapNativeCollateral) {
            WRAPPED_NATIVE.deposit{value: collateralAmount}();
        } else {
            IERC20(address(WRAPPED_NATIVE))
                .safeTransferFrom(msg.sender, address(this), collateralAmount);
        }
        if (WRAPPED_NATIVE.balanceOf(address(this)) - collateralBefore != collateralAmount) {
            revert InvalidAssetTransfer();
        }
    }

    /// @notice Burns shares and redeems the same fraction of every vault asset.
    /// @dev In conditional mode matched complete sets are merged to base assets and unmatched
    /// outcome tokens are transferred in kind. Redemption remains available during emergency mode.
    /// @param shares FLM shares to burn from the caller.
    /// @param recipient Recipient of company/collateral assets and any unmerged outcome residue.
    /// @param unwrapNative Whether wrapped collateral should be unwrapped before payout.
    /// @return companyOut Amount of company token recovered and paid out.
    /// @return collateralOut Amount of wrapped/native collateral recovered and paid out.
    function redeem(uint256 shares, address recipient, bool unwrapNative)
        external
        nonReentrant
        returns (uint256 companyOut, uint256 collateralOut)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        uint256 supply = totalSupply();
        if (shares == 0 || shares > balanceOf(msg.sender)) revert InvalidShares();
        _consolidateVault();
        VaultAmounts memory amounts = _redeemAmounts(shares, supply);
        _burn(msg.sender, shares);

        companyOut = amounts.company;
        collateralOut = amounts.collateral;
        if (inConditionalMode) {
            (uint256 mergedCompany, uint256 mergedCollateral) = _mergeRedeemSlice(amounts.outcomes);
            companyOut += mergedCompany;
            collateralOut += mergedCollateral;
            _transferOutcomeAmounts(recipient, amounts.outcomes);
            emit OutcomeTokensRedeemed(
                msg.sender,
                recipient,
                amounts.outcomes.yesCompany,
                amounts.outcomes.noCompany,
                amounts.outcomes.yesCurrency,
                amounts.outcomes.noCurrency
            );
        }

        _payout(recipient, companyOut, collateralOut, unwrapNative);
        if (totalSupply() > 0 && emergencyExitArmedAt == 0) _tryRestoreLiquidity();
        emit SharesRedeemed(msg.sender, recipient, shares, companyOut, collateralOut);
    }

    /// @notice Permissionlessly retries deployment of any share-owned idle balances.
    /// @dev Deliberately not `nonReentrant`: redemption calls this through a failure-isolated
    /// self-call so an AMM refusal can never block withdrawal. The trusted adapter is manager-only.
    function restoreLiquidity() external {
        _assertNotEmergencyMode();
        if (totalSupply() > 0) _restoreActiveLiquidity();
    }

    /// @dev Failure-isolated merge primitive. Only a self-call from redemption may invoke it.
    function mergeOutcomeSlice(bool companyAsset, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20 collateralToken = companyAsset ? COMPANY_TOKEN : IERC20(address(WRAPPED_NATIVE));
        IERC20 yesToken = IERC20(companyAsset ? activeYesCompanyToken : activeYesCurrencyToken);
        IERC20 noToken = IERC20(companyAsset ? activeNoCompanyToken : activeNoCurrencyToken);
        uint256 beforeBalance = collateralToken.balanceOf(address(this));
        _forceApprove(yesToken, address(CONDITIONAL_ROUTER), amount);
        _forceApprove(noToken, address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.mergePositions(activeProposal, address(collateralToken), amount);
        _forceApprove(yesToken, address(CONDITIONAL_ROUTER), 0);
        _forceApprove(noToken, address(CONDITIONAL_ROUTER), 0);
        if (collateralToken.balanceOf(address(this)) - beforeBalance != amount) {
            revert IncompleteOutcomeRecovery();
        }
    }

    /// @notice Permissionless, idempotent transition function.
    /// @dev Lifecycle execution uses fixed adapter defaults and manager-side ratio checks.
    /// @return action The transition performed by this call.
    function sync() external nonReentrant returns (SyncAction action) {
        _assertNotEmergencyMode();
        _assertInitialized();

        ProposalData memory proposal = _readProposal();

        bool proposalByOfficialCreator = proposal.exists && proposal.creator == OFFICIAL_PROPOSER;
        if (proposalByOfficialCreator) {
            _validateProposal(
                proposal.proposal,
                proposal.proposalToken,
                proposal.collateralToken,
                proposal.yesCompanyToken,
                proposal.noCompanyToken,
                proposal.yesCurrencyToken,
                proposal.noCurrencyToken,
                proposal.yesPool,
                proposal.noPool
            );
        }

        if (!inConditionalMode) {
            return _syncFromSpot(proposal, proposalByOfficialCreator);
        }

        return _syncFromConditional(proposal, proposalByOfficialCreator);
    }

    function previewLiquidityMigration() external view returns (uint128 liquidityToMove) {
        liquidityToMove = uint128((uint256(spotLiquidity) * MIGRATION_BPS) / BPS_DENOMINATOR);
    }

    function emergencyExitReady() public view returns (bool) {
        return
            emergencyExitArmedAt != 0
                && block.timestamp >= emergencyExitArmedAt + EMERGENCY_EXIT_DELAY;
    }

    /// @notice Arms emergency mode. Deposits and sync are blocked until disarmed; redemptions stay
    /// open. The owner may unwind positions after the delay but can never take shareholder assets.
    function armEmergencyExit() external {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt != 0) revert EmergencyExitAlreadyArmed();
        emergencyExitArmedAt = block.timestamp;
        emit EmergencyExitArmed(block.timestamp, block.timestamp + EMERGENCY_EXIT_DELAY);
    }

    /// @notice Disarms an armed emergency exit before execution.
    /// @dev Owner-only.
    function disarmEmergencyExit() external nonReentrant {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt == 0) revert EmergencyExitNotArmed();
        emergencyExitArmedAt = 0;
        if (totalSupply() > 0) _tryRestoreLiquidity();
        emit EmergencyExitDisarmed();
    }

    /// @notice Sends residual balances to `BOOTSTRAP_RECIPIENT` after every share is burned.
    /// @dev Share-owned assets can never be swept.
    /// @param unwrapNative Whether wrapped collateral should be unwrapped before transfer.
    function sweepIdleToBootstrapRecipient(bool unwrapNative)
        external
        nonReentrant
        returns (
            uint256 companySentToBootstrap,
            uint256 collateralSentToBootstrap,
            uint256 nativeSentToBootstrap
        )
    {
        _checkOwner();
        if (totalSupply() != 0) revert SharesOutstanding();
        (companySentToBootstrap, collateralSentToBootstrap, nativeSentToBootstrap) =
            _sweepIdleToBootstrapRecipient(unwrapNative);
        emit IdleSweptToBootstrapRecipient(
            companySentToBootstrap, collateralSentToBootstrap, nativeSentToBootstrap
        );
    }

    /// @notice Removes all active liquidity into the vault so shareholders can redeem in kind.
    /// @dev Owner-only, delayed, executable once, and transfers no shareholder assets.
    function executeEmergencyExit() external nonReentrant {
        _checkOwner();
        if (emergencyExitExecuted) revert EmergencyExitAlreadyExecuted();
        if (emergencyExitArmedAt == 0) revert EmergencyExitNotArmed();
        if (!emergencyExitReady()) revert EmergencyExitDelayActive();

        uint128 spotRemoved = spotLiquidity;
        uint256 conditionalRemoved = _conditionalLiquidityTotal();
        _consolidateVault();
        emergencyExitExecuted = true;
        emit EmergencyExitExecuted(spotRemoved, conditionalRemoved);
    }

    function _validateProposal(
        address proposal,
        address proposalToken,
        address collateralToken,
        address yesCompanyToken,
        address noCompanyToken,
        address yesCurrencyToken,
        address noCurrencyToken,
        address yesPool,
        address noPool
    ) internal view {
        if (
            proposal == address(0) || proposalToken != address(COMPANY_TOKEN)
                || collateralToken != address(WRAPPED_NATIVE) || yesCompanyToken == address(0)
                || noCompanyToken == address(0) || yesCurrencyToken == address(0)
                || noCurrencyToken == address(0) || yesPool == address(0) || noPool == address(0)
        ) {
            revert InvalidProposalConfig();
        }
    }

    function _readProposal() internal view returns (ProposalData memory proposal) {
        IFutarchyOfficialProposalSource.OfficialProposalData memory data =
            PROPOSAL_SOURCE.officialProposalExtended();

        proposal.proposalId = data.proposalId;
        proposal.proposal = data.proposal;
        proposal.creator = data.creator;
        proposal.exists = data.exists;
        proposal.settled = data.settled;
        proposal.proposalToken = data.proposalToken;
        proposal.collateralToken = data.collateralToken;
        proposal.yesCompanyToken = data.yesCompanyToken;
        proposal.noCompanyToken = data.noCompanyToken;
        proposal.yesCurrencyToken = data.yesCurrencyToken;
        proposal.noCurrencyToken = data.noCurrencyToken;
        proposal.yesPool = data.yesPool;
        proposal.noPool = data.noPool;
    }

    function _outcomeBalances(ProposalData memory proposal)
        internal
        view
        returns (OutcomeAmounts memory amounts)
    {
        amounts.yesCompany = IERC20(proposal.yesCompanyToken).balanceOf(address(this));
        amounts.noCompany = IERC20(proposal.noCompanyToken).balanceOf(address(this));
        amounts.yesCurrency = IERC20(proposal.yesCurrencyToken).balanceOf(address(this));
        amounts.noCurrency = IERC20(proposal.noCurrencyToken).balanceOf(address(this));
    }

    function _outcomeBalanceDeltas(
        ProposalData memory proposal,
        OutcomeAmounts memory balancesBefore
    ) internal view returns (OutcomeAmounts memory amounts) {
        OutcomeAmounts memory balancesAfter = _outcomeBalances(proposal);
        amounts.yesCompany = balancesAfter.yesCompany - balancesBefore.yesCompany;
        amounts.noCompany = balancesAfter.noCompany - balancesBefore.noCompany;
        amounts.yesCurrency = balancesAfter.yesCurrency - balancesBefore.yesCurrency;
        amounts.noCurrency = balancesAfter.noCurrency - balancesBefore.noCurrency;
    }

    function _yesOutcomeWins() internal view returns (bool) {
        bool[] memory winningOutcomes = CONDITIONAL_ROUTER.getWinningOutcomes(
            IFutarchyProposalCore(activeProposal).conditionId()
        );
        if (winningOutcomes.length != 2 || winningOutcomes[0] == winningOutcomes[1]) {
            revert InvalidSettlementOutcome();
        }
        return winningOutcomes[0];
    }

    function _syncFromSpot(ProposalData memory proposal, bool proposalByOfficialCreator)
        internal
        returns (SyncAction)
    {
        if (!proposalByOfficialCreator || proposal.settled) {
            return SyncAction.None;
        }

        _assertSpotPoolStable();
        // A previous redemption may have left the surviving holders entirely idle after a
        // best-effort re-add failed. Rebuild spot liquidity before applying the 80% migration.
        if (spotLiquidity == 0) _restoreActiveLiquidity();

        uint128 liquidityToMove =
            uint128((uint256(spotLiquidity) * MIGRATION_BPS) / BPS_DENOMINATOR);
        if (liquidityToMove > 0) {
            OutcomeAmounts memory balancesBefore = _outcomeBalances(proposal);
            (uint256 companyOut, uint256 collateralOut) = _removeFromSpot(liquidityToMove, "");

            _splitCollateral(proposal.proposal, address(COMPANY_TOKEN), companyOut);
            _splitCollateral(proposal.proposal, address(WRAPPED_NATIVE), collateralOut);

            OutcomeAmounts memory splitAmounts = _outcomeBalanceDeltas(proposal, balancesBefore);
            uint128 yesAdded = _addToConditionalPairBounded(
                proposal.yesCompanyToken,
                proposal.yesCurrencyToken,
                splitAmounts.yesCompany,
                splitAmounts.yesCurrency,
                ""
            );
            uint128 noAdded = _addToConditionalPairBounded(
                proposal.noCompanyToken,
                proposal.noCurrencyToken,
                splitAmounts.noCompany,
                splitAmounts.noCurrency,
                ""
            );
            conditionalYesLiquidity += yesAdded;
            conditionalNoLiquidity += noAdded;
            uint256 condAdded = uint256(yesAdded) + uint256(noAdded);
            emit LiquidityMigratedToConditional(proposal.proposalId, liquidityToMove, condAdded);
        }

        inConditionalMode = true;
        activeProposal = proposal.proposal;
        activeProposalId = proposal.proposalId;
        activeYesCompanyToken = proposal.yesCompanyToken;
        activeNoCompanyToken = proposal.noCompanyToken;
        activeYesCurrencyToken = proposal.yesCurrencyToken;
        activeNoCurrencyToken = proposal.noCurrencyToken;
        return SyncAction.MigratedToConditional;
    }

    function _syncFromConditional(ProposalData memory proposal, bool proposalByOfficialCreator)
        internal
        returns (SyncAction)
    {
        // If conditional mode is active, we only transition back after settlement of the active
        // proposal.
        if (!proposalByOfficialCreator || proposal.proposalId != activeProposalId) {
            revert ActiveProposalRequired();
        }
        if (!proposal.settled) return SyncAction.None;

        _assertSpotPoolStable();

        uint256 condLiq = _conditionalLiquidityTotal();
        uint128 spotAddedBack;
        bool yesWins = _yesOutcomeWins();
        if (condLiq > 0) {
            OutcomeAmounts memory removed;

            if (conditionalYesLiquidity > 0) {
                (removed.yesCompany, removed.yesCurrency) = _removeFromConditionalPair(
                    activeYesCompanyToken, activeYesCurrencyToken, conditionalYesLiquidity, ""
                );
                conditionalYesLiquidity = 0;
            }
            if (conditionalNoLiquidity > 0) {
                (removed.noCompany, removed.noCurrency) = _removeFromConditionalPair(
                    activeNoCompanyToken, activeNoCurrencyToken, conditionalNoLiquidity, ""
                );
                conditionalNoLiquidity = 0;
            }
            (uint256 companyOut, uint256 collateralOut) = _recoverSyncCollateral(removed, yesWins);

            uint256 companyUnused;
            uint256 collateralUnused;
            (spotAddedBack, companyUnused, collateralUnused) =
                _addToSpot(companyOut, collateralOut, "");
            _assertSyncLeftoverWithinBounds(
                companyOut, collateralOut, companyUnused, collateralUnused
            );
        }
        // A prior redemption may have consolidated every LP position and left the remaining
        // holders' outcomes idle after a best-effort restore failed. Recover them before clearing
        // the active token addresses even when there is no conditional LP left to remove.
        _recoverIdleOutcomeBalances(yesWins);

        emit LiquidityMigratedBackToSpot(activeProposalId, condLiq, spotAddedBack);
        _clearConditionalModeState();
        return SyncAction.MigratedBackToSpot;
    }

    function _assertSpotPoolStable() internal view {
        POOL_STABILITY_GUARD.assertStablePair(address(COMPANY_TOKEN), address(WRAPPED_NATIVE));
    }

    function _addToSpot(uint256 companyAmount, uint256 collateralAmount, bytes memory data)
        internal
        returns (uint128 liquidityMinted, uint256 companyUnused, uint256 collateralUnused)
    {
        (uint256 amount0Desired, uint256 amount1Desired) =
            _toTokenOrder(companyAmount, collateralAmount);
        _approveForAdapter(SPOT_ADAPTER, amount0Desired, amount1Desired);

        uint256 amount0Used;
        uint256 amount1Used;
        (liquidityMinted, amount0Used, amount1Used) = SPOT_ADAPTER.addFullRangeLiquidity(
            TOKEN0, TOKEN1, amount0Desired, amount1Desired, data
        );
        if (liquidityMinted == 0) revert ZeroLiquidityMinted();
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert AdapterOverusedInput();
        }

        (uint256 companyUsed, uint256 collateralUsed) = _fromTokenOrder(amount0Used, amount1Used);
        companyUnused = companyAmount - companyUsed;
        collateralUnused = collateralAmount - collateralUsed;
        if (liquidityMinted > 0) {
            spotLiquidity += liquidityMinted;
        }
    }

    function _addToConditionalPair(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        bytes memory data
    ) internal returns (uint128 liquidityMinted, uint256 amountAUnused, uint256 amountBUnused) {
        if (amountADesired == 0 || amountBDesired == 0) {
            revert ZeroLiquidityMinted();
        }
        if (tokenA < tokenB) {
            return _addSortedConditionalPair(tokenA, tokenB, amountADesired, amountBDesired, data);
        }
        (liquidityMinted, amountBUnused, amountAUnused) =
            _addSortedConditionalPair(tokenB, tokenA, amountBDesired, amountADesired, data);
    }

    function _addSortedConditionalPair(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes memory data
    ) internal returns (uint128 liquidityMinted, uint256 amount0Unused, uint256 amount1Unused) {
        _approvePairForAdapter(CONDITIONAL_ADAPTER, token0, token1, amount0Desired, amount1Desired);

        uint256 amount0Used;
        uint256 amount1Used;
        (liquidityMinted, amount0Used, amount1Used) = CONDITIONAL_ADAPTER.addFullRangeLiquidity(
            token0, token1, amount0Desired, amount1Desired, data
        );
        if (liquidityMinted == 0) revert ZeroLiquidityMinted();
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert AdapterOverusedInput();
        }
        amount0Unused = amount0Desired - amount0Used;
        amount1Unused = amount1Desired - amount1Used;
    }

    function _addToConditionalPairBounded(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        bytes memory data
    ) internal returns (uint128 liquidityMinted) {
        uint256 amountAUnused;
        uint256 amountBUnused;
        (liquidityMinted, amountAUnused, amountBUnused) =
            _addToConditionalPair(tokenA, tokenB, amountADesired, amountBDesired, data);
        _assertSyncLeftoverWithinBounds(
            amountADesired, amountBDesired, amountAUnused, amountBUnused
        );
    }

    function _removeFromSpot(uint128 liquidity, bytes memory data)
        internal
        returns (uint256 companyOut, uint256 collateralOut)
    {
        (uint256 amount0Out, uint256 amount1Out) =
            SPOT_ADAPTER.removeLiquidity(TOKEN0, TOKEN1, liquidity, data);
        spotLiquidity -= liquidity;
        (companyOut, collateralOut) = _fromTokenOrder(amount0Out, amount1Out);
    }

    function _removeFromConditionalPair(
        address tokenA,
        address tokenB,
        uint128 liquidity,
        bytes memory data
    ) internal returns (uint256 amountAOut, uint256 amountBOut) {
        if (liquidity == 0) return (0, 0);
        (address token0, address token1) = _sortPair(tokenA, tokenB);
        (uint256 amount0Out, uint256 amount1Out) =
            CONDITIONAL_ADAPTER.removeLiquidity(token0, token1, liquidity, data);
        return tokenA < tokenB ? (amount0Out, amount1Out) : (amount1Out, amount0Out);
    }

    /// @dev Full consolidation makes every fee and idle balance part of one observable vault
    /// balance before shares change. This avoids fee indices and price oracles.
    function _consolidateVault() internal {
        if (spotLiquidity > 0) _removeFromSpot(spotLiquidity, "");
        if (conditionalYesLiquidity > 0) {
            _removeFromConditionalPair(
                activeYesCompanyToken, activeYesCurrencyToken, conditionalYesLiquidity, ""
            );
            conditionalYesLiquidity = 0;
        }
        if (conditionalNoLiquidity > 0) {
            _removeFromConditionalPair(
                activeNoCompanyToken, activeNoCurrencyToken, conditionalNoLiquidity, ""
            );
            conditionalNoLiquidity = 0;
        }
    }

    function _restoreActiveLiquidity() internal {
        uint256 companyAmount = COMPANY_TOKEN.balanceOf(address(this));
        uint256 collateralAmount = WRAPPED_NATIVE.balanceOf(address(this));
        if (companyAmount > 0 && collateralAmount > 0) {
            _assertSpotPoolStable();
            _addToSpot(companyAmount, collateralAmount, "");
        }
        if (!inConditionalMode) return;

        uint256 yesCompany = IERC20(activeYesCompanyToken).balanceOf(address(this));
        uint256 yesCurrency = IERC20(activeYesCurrencyToken).balanceOf(address(this));
        if (yesCompany > 0 && yesCurrency > 0) {
            POOL_STABILITY_GUARD.assertStablePair(activeYesCompanyToken, activeYesCurrencyToken);
            (uint128 yesLiquidity,,) = _addToConditionalPair(
                activeYesCompanyToken, activeYesCurrencyToken, yesCompany, yesCurrency, ""
            );
            conditionalYesLiquidity += yesLiquidity;
        }
        uint256 noCompany = IERC20(activeNoCompanyToken).balanceOf(address(this));
        uint256 noCurrency = IERC20(activeNoCurrencyToken).balanceOf(address(this));
        if (noCompany > 0 && noCurrency > 0) {
            POOL_STABILITY_GUARD.assertStablePair(activeNoCompanyToken, activeNoCurrencyToken);
            (uint128 noLiquidity,,) = _addToConditionalPair(
                activeNoCompanyToken, activeNoCurrencyToken, noCompany, noCurrency, ""
            );
            conditionalNoLiquidity += noLiquidity;
        }
    }

    function _tryRestoreLiquidity() internal {
        // ponytail: one isolated self-call replaces fee indices and keeps AMM failure off the
        // withdrawal path; anyone can retry `restoreLiquidity` later.
        (bool restored,) = address(this).call(abi.encodeCall(this.restoreLiquidity, ()));
        if (!restored) emit LiquidityRestoreDeferred();
    }

    function _redeemAmounts(uint256 shares, uint256 supply)
        internal
        view
        returns (VaultAmounts memory amounts)
    {
        amounts.company = _shareOf(COMPANY_TOKEN.balanceOf(address(this)), shares, supply);
        amounts.collateral = _shareOf(WRAPPED_NATIVE.balanceOf(address(this)), shares, supply);
        if (!inConditionalMode) return amounts;
        amounts.outcomes.yesCompany =
            _shareOf(IERC20(activeYesCompanyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.noCompany =
            _shareOf(IERC20(activeNoCompanyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.yesCurrency =
            _shareOf(IERC20(activeYesCurrencyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.noCurrency =
            _shareOf(IERC20(activeNoCurrencyToken).balanceOf(address(this)), shares, supply);
    }

    function _mergeRedeemSlice(OutcomeAmounts memory amounts)
        internal
        returns (uint256 companyOut, uint256 collateralOut)
    {
        uint256 mergeAmount = _min(amounts.yesCompany, amounts.noCompany);
        if (mergeAmount > 0 && _tryMergeOutcomeAmount(true, mergeAmount)) {
            companyOut = mergeAmount;
            amounts.yesCompany -= mergeAmount;
            amounts.noCompany -= mergeAmount;
        }

        mergeAmount = _min(amounts.yesCurrency, amounts.noCurrency);
        if (mergeAmount > 0 && _tryMergeOutcomeAmount(false, mergeAmount)) {
            collateralOut = mergeAmount;
            amounts.yesCurrency -= mergeAmount;
            amounts.noCurrency -= mergeAmount;
        }
    }

    function _transferOutcomeAmounts(address recipient, OutcomeAmounts memory amounts) internal {
        if (amounts.yesCompany > 0) {
            IERC20(activeYesCompanyToken).safeTransfer(recipient, amounts.yesCompany);
        }
        if (amounts.noCompany > 0) {
            IERC20(activeNoCompanyToken).safeTransfer(recipient, amounts.noCompany);
        }
        if (amounts.yesCurrency > 0) {
            IERC20(activeYesCurrencyToken).safeTransfer(recipient, amounts.yesCurrency);
        }
        if (amounts.noCurrency > 0) {
            IERC20(activeNoCurrencyToken).safeTransfer(recipient, amounts.noCurrency);
        }
    }

    function _splitCollateral(address proposal, address collateralToken, uint256 amount) internal {
        if (amount == 0) return;
        _forceApprove(IERC20(collateralToken), address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.splitPosition(proposal, collateralToken, amount);
    }

    function _recoverSyncCollateral(OutcomeAmounts memory amounts, bool yesWins)
        internal
        returns (uint256 companyOut, uint256 collateralOut)
    {
        uint256 companyBefore = COMPANY_TOKEN.balanceOf(address(this));
        uint256 collateralBefore = WRAPPED_NATIVE.balanceOf(address(this));

        _recoverOutcomeAmounts(
            address(COMPANY_TOKEN),
            activeYesCompanyToken,
            activeNoCompanyToken,
            amounts.yesCompany,
            amounts.noCompany,
            yesWins
        );
        _recoverOutcomeAmounts(
            address(WRAPPED_NATIVE),
            activeYesCurrencyToken,
            activeNoCurrencyToken,
            amounts.yesCurrency,
            amounts.noCurrency,
            yesWins
        );

        companyOut = COMPANY_TOKEN.balanceOf(address(this)) - companyBefore;
        collateralOut = WRAPPED_NATIVE.balanceOf(address(this)) - collateralBefore;
        if (
            companyOut == 0 || collateralOut == 0
                || companyOut != (yesWins ? amounts.yesCompany : amounts.noCompany)
                || collateralOut != (yesWins ? amounts.yesCurrency : amounts.noCurrency)
        ) {
            revert IncompleteOutcomeRecovery();
        }
    }

    function _recoverIdleOutcomeBalances(bool yesWins) internal {
        _recoverOutcomeAmounts(
            address(COMPANY_TOKEN),
            activeYesCompanyToken,
            activeNoCompanyToken,
            IERC20(activeYesCompanyToken).balanceOf(address(this)),
            IERC20(activeNoCompanyToken).balanceOf(address(this)),
            yesWins
        );
        _recoverOutcomeAmounts(
            address(WRAPPED_NATIVE),
            activeYesCurrencyToken,
            activeNoCurrencyToken,
            IERC20(activeYesCurrencyToken).balanceOf(address(this)),
            IERC20(activeNoCurrencyToken).balanceOf(address(this)),
            yesWins
        );
    }

    function _recoverOutcomeAmounts(
        address collateralToken,
        address yesToken,
        address noToken,
        uint256 yesAmount,
        uint256 noAmount,
        bool yesWins
    ) internal {
        uint256 mergeAmount = _min(yesAmount, noAmount);
        if (mergeAmount > 0) {
            _mergeOutcomeAmount(collateralToken, yesToken, noToken, mergeAmount);
        }

        uint256 redeemAmount = yesWins ? yesAmount - mergeAmount : noAmount - mergeAmount;
        if (redeemAmount == 0) return;

        address winningToken = yesWins ? yesToken : noToken;
        _forceApprove(IERC20(winningToken), address(CONDITIONAL_ROUTER), redeemAmount);
        CONDITIONAL_ROUTER.redeemPositions(activeProposal, collateralToken, redeemAmount);
    }

    function _mergeOutcomeAmount(
        address collateralToken,
        address yesToken,
        address noToken,
        uint256 amount
    ) internal {
        _forceApprove(IERC20(yesToken), address(CONDITIONAL_ROUTER), amount);
        _forceApprove(IERC20(noToken), address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.mergePositions(activeProposal, collateralToken, amount);
    }

    function _tryMergeOutcomeAmount(bool companyAsset, uint256 amount)
        internal
        returns (bool merged)
    {
        (merged,) = address(this)
            .call(abi.encodeCall(this.mergeOutcomeSlice, (companyAsset, amount)));
    }

    function _sweepActiveOutcomeTokensTo(address recipient) internal {
        if (recipient == address(0)) return;
        if (activeYesCompanyToken != address(0)) {
            uint256 bal = IERC20(activeYesCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeYesCompanyToken).safeTransfer(recipient, bal);
        }
        if (activeNoCompanyToken != address(0)) {
            uint256 bal = IERC20(activeNoCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeNoCompanyToken).safeTransfer(recipient, bal);
        }
        if (activeYesCurrencyToken != address(0)) {
            uint256 bal = IERC20(activeYesCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeYesCurrencyToken).safeTransfer(recipient, bal);
        }
        if (activeNoCurrencyToken != address(0)) {
            uint256 bal = IERC20(activeNoCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(activeNoCurrencyToken).safeTransfer(recipient, bal);
        }
    }

    function _clearConditionalModeState() internal {
        conditionalYesLiquidity = 0;
        conditionalNoLiquidity = 0;
        inConditionalMode = false;
        activeProposalId = 0;
        activeProposal = address(0);
        activeYesCompanyToken = address(0);
        activeNoCompanyToken = address(0);
        activeYesCurrencyToken = address(0);
        activeNoCurrencyToken = address(0);
    }

    function _sortPair(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function _approvePairForAdapter(
        IFutarchyLiquidityAdapter adapter,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (amount0 > 0) {
            _forceApprove(IERC20(token0), address(adapter), amount0);
        }
        if (amount1 > 0) {
            _forceApprove(IERC20(token1), address(adapter), amount1);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _mulDivUp(uint256 value, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(value, numerator, denominator, Math.Rounding.Up);
    }

    function _shareOf(uint256 balance, uint256 shares, uint256 supply)
        internal
        pure
        returns (uint256)
    {
        return shares == supply ? balance : Math.mulDiv(balance, shares, supply);
    }

    function _conditionalLiquidityTotal() internal view returns (uint256) {
        return uint256(conditionalYesLiquidity) + uint256(conditionalNoLiquidity);
    }

    function _toTokenOrder(uint256 companyAmount, uint256 collateralAmount)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        if (COMPANY_IS_TOKEN0) {
            amount0 = companyAmount;
            amount1 = collateralAmount;
        } else {
            amount0 = collateralAmount;
            amount1 = companyAmount;
        }
    }

    function _fromTokenOrder(uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256 companyAmount, uint256 collateralAmount)
    {
        if (COMPANY_IS_TOKEN0) {
            companyAmount = amount0;
            collateralAmount = amount1;
        } else {
            companyAmount = amount1;
            collateralAmount = amount0;
        }
    }

    function _approveForAdapter(IFutarchyLiquidityAdapter adapter, uint256 amount0, uint256 amount1)
        internal
    {
        if (amount0 > 0) {
            _forceApprove(IERC20(TOKEN0), address(adapter), amount0);
        }
        if (amount1 > 0) {
            _forceApprove(IERC20(TOKEN1), address(adapter), amount1);
        }
    }

    function _payout(
        address recipient,
        uint256 companyOut,
        uint256 collateralOut,
        bool unwrapNative
    ) internal {
        if (companyOut > 0) {
            COMPANY_TOKEN.safeTransfer(recipient, companyOut);
        }
        if (collateralOut > 0) {
            if (unwrapNative) {
                WRAPPED_NATIVE.withdraw(collateralOut);
                payable(recipient).sendValue(collateralOut);
            } else {
                IERC20(address(WRAPPED_NATIVE)).safeTransfer(recipient, collateralOut);
            }
        }
    }

    function _sweepIdleToBootstrapRecipient(bool unwrapNative)
        internal
        returns (
            uint256 companySentToBootstrap,
            uint256 collateralSentToBootstrap,
            uint256 nativeSentToBootstrap
        )
    {
        _sweepActiveOutcomeTokensTo(BOOTSTRAP_RECIPIENT);

        companySentToBootstrap = COMPANY_TOKEN.balanceOf(address(this));
        if (companySentToBootstrap > 0) {
            COMPANY_TOKEN.safeTransfer(BOOTSTRAP_RECIPIENT, companySentToBootstrap);
        }

        uint256 collateralBalance = WRAPPED_NATIVE.balanceOf(address(this));
        if (collateralBalance > 0) {
            if (unwrapNative) {
                WRAPPED_NATIVE.withdraw(collateralBalance);
            } else {
                IERC20(address(WRAPPED_NATIVE)).safeTransfer(BOOTSTRAP_RECIPIENT, collateralBalance);
                collateralSentToBootstrap = collateralBalance;
            }
        }

        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            payable(BOOTSTRAP_RECIPIENT).sendValue(nativeBalance);
            nativeSentToBootstrap = nativeBalance;
        }
    }

    /// @dev Enforces that conditional->spot migration uses nearly all recovered inventory.
    ///      If spot and winning conditional prices are aligned, only small dust should remain.
    ///      Security rationale: forcing close ratio fit means a would-be attacker must move
    ///      conditional and spot together, then unwind both. That is primarily a round trip
    ///      where AMM fees dominate; the fit check prevents one-sided skew extraction.
    ///      Any allowed residual balances remain share-owned on the manager until redemption.
    function _assertSyncLeftoverWithinBounds(
        uint256 companyRecovered,
        uint256 collateralRecovered,
        uint256 companyUnused,
        uint256 collateralUnused
    ) internal pure {
        if (
            _exceedsLeftoverBps(companyRecovered, companyUnused)
                || _exceedsLeftoverBps(collateralRecovered, collateralUnused)
        ) {
            revert ExcessiveSyncLeftover(
                companyRecovered, collateralRecovered, companyUnused, collateralUnused
            );
        }
    }

    function _exceedsLeftoverBps(uint256 recovered, uint256 unused) internal pure returns (bool) {
        if (recovered == 0) return unused > 0;
        return unused > (recovered * MAX_SYNC_LEFTOVER_BPS) / BPS_DENOMINATOR;
    }

    function _assertOnlyBootstrap() internal view {
        if (msg.sender != BOOTSTRAP_RECIPIENT) revert OnlyBootstrapRecipient();
    }

    function _assertInitialized() internal view {
        if (!initializedFromBootstrap) revert NotInitialized();
    }

    function _assertNotEmergencyMode() internal view {
        if (emergencyExitArmedAt != 0) revert EmergencyModeActive();
    }
}
