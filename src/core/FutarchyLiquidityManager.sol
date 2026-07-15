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
import {
    IFutarchyPrefundedLiquidityAdapter
} from "../interfaces/IFutarchyPrefundedLiquidityAdapter.sol";
import {IPoolStabilityGuard} from "../interfaces/IPoolStabilityGuard.sol";

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
    uint96 private _capturedProposalId;
    uint128 public conditionalNoLiquidity;
    uint256 public emergencyExitArmedAt;
    uint128 public spotLiquidity;
    uint128 public conditionalYesLiquidity;
    address private _capturedProposal;
    bytes32 private _capturedConditionId;
    address private _capturedYesCompanyToken;
    address private _capturedNoCompanyToken;
    address private _capturedYesCurrencyToken;
    address private _capturedNoCurrencyToken;

    enum SyncAction {
        None,
        MigratedToConditional,
        MigratedBackToSpot
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

    struct RedeemPlan {
        uint128 spot;
        uint128 yes;
        uint128 no;
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
    error ZeroRedeemLiquidity();
    error ZeroRecipient();
    error SharesOutstanding();
    error InvalidDepositRatio();
    error InvalidAssetTransfer();
    error InvalidSettlementOutcome();
    error IncompleteOutcomeRecovery();
    error OnlySelf();
    error OnlyProposalSource();
    error ProposalAlreadyActive();
    error ConditionAlreadyResolved();
    error InvalidSqrtPrice();

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
                || address(wrappedNative) == address(0) || address(proposalSource) == address(0)
                || address(spotAdapter) == address(0) || address(conditionalAdapter) == address(0)
                || address(conditionalRouter) == address(0)
                || address(poolStabilityGuard) == address(0) || initialOwner == address(0)
        ) {
            revert ZeroAddress();
        }

        BOOTSTRAP_RECIPIENT = bootstrapRecipient;
        COMPANY_TOKEN = companyToken;
        WRAPPED_NATIVE = wrappedNative;
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

    function activeProposalId() external view returns (uint256) {
        return inConditionalMode ? uint256(_capturedProposalId) : 0;
    }

    function activeProposal() external view returns (address) {
        return inConditionalMode ? _capturedProposal : address(0);
    }

    function activeConditionId() external view returns (bytes32) {
        return inConditionalMode ? _capturedConditionId : bytes32(0);
    }

    function activeYesPool() public view returns (address) {
        return inConditionalMode
            ? _conditionalPool(_capturedYesCompanyToken, _capturedYesCurrencyToken)
            : address(0);
    }

    function activeNoPool() public view returns (address) {
        return inConditionalMode
            ? _conditionalPool(_capturedNoCompanyToken, _capturedNoCurrencyToken)
            : address(0);
    }

    function activeYesCompanyToken() external view returns (address) {
        return inConditionalMode ? _capturedYesCompanyToken : address(0);
    }

    function activeNoCompanyToken() external view returns (address) {
        return inConditionalMode ? _capturedNoCompanyToken : address(0);
    }

    function activeYesCurrencyToken() external view returns (address) {
        return inConditionalMode ? _capturedYesCurrencyToken : address(0);
    }

    function activeNoCurrencyToken() external view returns (address) {
        return inConditionalMode ? _capturedNoCurrencyToken : address(0);
    }

    /// @notice Returns the last atomically captured proposal, including after settlement.
    /// @dev The source uses this durable snapshot for its registry view; active getters still
    /// return zero whenever no conditional position is live.
    function capturedOfficialProposal()
        external
        view
        returns (IFutarchyOfficialProposalSource.ProposalActivationData memory proposal)
    {
        proposal.proposalId = uint256(_capturedProposalId);
        proposal.proposal = _capturedProposal;
        proposal.conditionId = _capturedConditionId;
        proposal.proposalToken = address(COMPANY_TOKEN);
        proposal.collateralToken = address(WRAPPED_NATIVE);
        proposal.yesCompanyToken = _capturedYesCompanyToken;
        proposal.noCompanyToken = _capturedNoCompanyToken;
        proposal.yesCurrencyToken = _capturedYesCurrencyToken;
        proposal.noCurrencyToken = _capturedNoCurrencyToken;
    }

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
        _assertSpotPoolStable();
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
        _restoreSpotLiquidity();
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
        RedeemPlan memory plan = _redeemPlan(shares, supply);
        VaultAmounts memory amounts = _redeemAmounts(shares, supply);
        _removeRedeemLiquidity(plan, shares, supply, amounts);
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
        emit SharesRedeemed(msg.sender, recipient, shares, companyOut, collateralOut);
    }

    /// @dev Failure-isolated merge primitive. Only a self-call from redemption may invoke it.
    function mergeOutcomeSlice(bool companyAsset, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        IERC20 collateralToken = companyAsset ? COMPANY_TOKEN : IERC20(address(WRAPPED_NATIVE));
        IERC20 yesToken =
            IERC20(companyAsset ? _capturedYesCompanyToken : _capturedYesCurrencyToken);
        IERC20 noToken = IERC20(companyAsset ? _capturedNoCompanyToken : _capturedNoCurrencyToken);
        uint256 beforeBalance = collateralToken.balanceOf(address(this));
        uint256 yesBefore = yesToken.balanceOf(address(this));
        uint256 noBefore = noToken.balanceOf(address(this));
        _forceApprove(yesToken, address(CONDITIONAL_ROUTER), amount);
        _forceApprove(noToken, address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.mergePositions(
            address(collateralToken),
            _capturedConditionId,
            address(yesToken),
            address(noToken),
            amount
        );
        _forceApprove(yesToken, address(CONDITIONAL_ROUTER), 0);
        _forceApprove(noToken, address(CONDITIONAL_ROUTER), 0);
        if (
            collateralToken.balanceOf(address(this)) - beforeBalance != amount
                || yesBefore - yesToken.balanceOf(address(this)) != amount
                || noBefore - noToken.balanceOf(address(this)) != amount
        ) {
            revert IncompleteOutcomeRecovery();
        }
    }

    /// @notice Whether the bound proposal source may atomically activate a fresh market now.
    function canActivateOfficialProposal() public view returns (bool) {
        return initializedFromBootstrap && totalSupply() != 0 && spotLiquidity != 0
            && !inConditionalMode && emergencyExitArmedAt == 0;
    }

    /// @notice Atomically moves the configured spot slice into two fresh conditional pools.
    /// @dev Only the immutable proposal source may call this hook, from inside its official
    /// proposal write. Any failure rolls that write and every AMM side effect back together.
    function activateOfficialProposal(
        IFutarchyOfficialProposalSource.ProposalActivationData calldata proposal
    ) external nonReentrant {
        if (msg.sender != address(PROPOSAL_SOURCE)) revert OnlyProposalSource();
        _assertNotEmergencyMode();
        _assertInitialized();
        if (inConditionalMode) revert ProposalAlreadyActive();

        _validateProposal(proposal);
        if (proposal.proposalId > type(uint96).max) revert InvalidProposalConfig();
        bytes32 conditionId = proposal.conditionId;
        (uint256 denominator,,) = CONDITIONAL_ROUTER.getPayouts(conditionId);
        if (denominator != 0) revert ConditionAlreadyResolved();

        uint160 spotSqrtPriceX96 =
            POOL_STABILITY_GUARD.assertStablePairAndGetSqrtPrice(TOKEN0, TOKEN1);
        if (spotSqrtPriceX96 == 0) revert InvalidSqrtPrice();

        uint128 liquidityToMove =
            uint128((uint256(spotLiquidity) * MIGRATION_BPS) / BPS_DENOMINATOR);
        if (liquidityToMove == 0) revert ZeroLiquidityMinted();

        (uint256 companyOut, uint256 collateralOut) = _removeFromSpot(liquidityToMove);
        COMPANY_TOKEN.safeApprove(address(CONDITIONAL_ROUTER), companyOut);
        IERC20(address(WRAPPED_NATIVE)).safeApprove(address(CONDITIONAL_ROUTER), collateralOut);
        CONDITIONAL_ROUTER.splitPositionPairTo(
            conditionId,
            address(COMPANY_TOKEN),
            proposal.yesCompanyToken,
            proposal.noCompanyToken,
            companyOut,
            address(WRAPPED_NATIVE),
            proposal.yesCurrencyToken,
            proposal.noCurrencyToken,
            collateralOut,
            address(CONDITIONAL_ADAPTER)
        );

        (, uint128 yesAdded) = _addFreshConditionalPair(
            proposal.yesCompanyToken,
            proposal.yesCurrencyToken,
            companyOut,
            collateralOut,
            spotSqrtPriceX96
        );
        (, uint128 noAdded) = _addFreshConditionalPair(
            proposal.noCompanyToken,
            proposal.noCurrencyToken,
            companyOut,
            collateralOut,
            spotSqrtPriceX96
        );

        inConditionalMode = true;
        _capturedProposal = proposal.proposal;
        _capturedProposalId = uint96(proposal.proposalId);
        _capturedConditionId = conditionId;
        _capturedYesCompanyToken = proposal.yesCompanyToken;
        _capturedNoCompanyToken = proposal.noCompanyToken;
        _capturedYesCurrencyToken = proposal.yesCurrencyToken;
        _capturedNoCurrencyToken = proposal.noCurrencyToken;
        conditionalYesLiquidity = yesAdded;
        conditionalNoLiquidity = noAdded;
        emit LiquidityMigratedToConditional(
            proposal.proposalId, liquidityToMove, uint256(yesAdded) + uint256(noAdded)
        );
    }

    /// @notice Permissionlessly settles the stored active CTF condition.
    /// @dev Spot-to-conditional activation is source-only and cannot be reached through this call.
    function sync() external nonReentrant returns (SyncAction action) {
        _assertNotEmergencyMode();
        _assertInitialized();
        if (!inConditionalMode) {
            return SyncAction.None;
        }
        return _syncFromConditional();
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
        IFutarchyOfficialProposalSource.ProposalActivationData calldata proposal
    ) internal view {
        if (
            proposal.proposal.code.length == 0 || proposal.proposalToken != address(COMPANY_TOKEN)
                || proposal.collateralToken != address(WRAPPED_NATIVE)
                || proposal.yesCompanyToken == address(0) || proposal.noCompanyToken == address(0)
                || proposal.yesCurrencyToken == address(0) || proposal.noCurrencyToken == address(0)
                || proposal.yesCompanyToken == proposal.noCompanyToken
                || proposal.yesCurrencyToken == proposal.noCurrencyToken
                || proposal.conditionId == bytes32(0)
        ) {
            revert InvalidProposalConfig();
        }
    }

    function _settlementWinner() internal view returns (bool settled, bool yesWins) {
        (uint256 denominator, uint256 yesNumerator, uint256 noNumerator) =
            CONDITIONAL_ROUTER.getPayouts(_capturedConditionId);
        if (denominator == 0) {
            if (yesNumerator != 0 || noNumerator != 0) revert InvalidSettlementOutcome();
            return (false, false);
        }
        if (yesNumerator == denominator && noNumerator == 0) return (true, true);
        if (noNumerator == denominator && yesNumerator == 0) return (true, false);
        revert InvalidSettlementOutcome();
    }

    function _syncFromConditional() internal returns (SyncAction) {
        (bool settled, bool yesWins) = _settlementWinner();
        if (!settled) return SyncAction.None;

        uint256 condLiq = _conditionalLiquidityTotal();
        if (conditionalYesLiquidity > 0) {
            _removeFromConditionalPair(
                _capturedYesCompanyToken, _capturedYesCurrencyToken, conditionalYesLiquidity
            );
            conditionalYesLiquidity = 0;
        }
        if (conditionalNoLiquidity > 0) {
            _removeFromConditionalPair(
                _capturedNoCompanyToken, _capturedNoCurrencyToken, conditionalNoLiquidity
            );
            conditionalNoLiquidity = 0;
        }

        // Resolution and custody recovery never depend on the spot pool. The recovered base
        // assets remain idle and share-owned until a separately safe spot join is available.
        _recoverIdleOutcomeBalances(yesWins);
        if (
            IERC20(_capturedYesCompanyToken).balanceOf(address(this)) != 0
                || IERC20(_capturedNoCompanyToken).balanceOf(address(this)) != 0
                || IERC20(_capturedYesCurrencyToken).balanceOf(address(this)) != 0
                || IERC20(_capturedNoCurrencyToken).balanceOf(address(this)) != 0
        ) revert IncompleteOutcomeRecovery();

        emit LiquidityMigratedBackToSpot(uint256(_capturedProposalId), condLiq, 0);
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

    function _addFreshConditionalPair(
        address companyOutcome,
        address currencyOutcome,
        uint256 companyAmount,
        uint256 currencyAmount,
        uint160 spotSqrtPriceX96
    ) internal returns (address pool, uint128 liquidityMinted) {
        if (companyAmount == 0 || currencyAmount == 0) {
            revert ZeroLiquidityMinted();
        }

        bool companyOutcomeIsToken0 = companyOutcome < currencyOutcome;
        uint160 sqrtPriceX96 = companyOutcomeIsToken0 == COMPANY_IS_TOKEN0
            ? spotSqrtPriceX96
            : _invertSqrtPrice(spotSqrtPriceX96);
        address token0 = companyOutcomeIsToken0 ? companyOutcome : currencyOutcome;
        address token1 = companyOutcomeIsToken0 ? currencyOutcome : companyOutcome;
        uint256 amount0Desired = companyOutcomeIsToken0 ? companyAmount : currencyAmount;
        uint256 amount1Desired = companyOutcomeIsToken0 ? currencyAmount : companyAmount;

        uint256 amount0Used;
        uint256 amount1Used;
        (pool, liquidityMinted, amount0Used, amount1Used) = IFutarchyPrefundedLiquidityAdapter(
                address(CONDITIONAL_ADAPTER)
            )
            .addPrefundedFreshFullRangeLiquidity(
                token0, token1, amount0Desired, amount1Desired, sqrtPriceX96
            );
        if (pool.code.length == 0 || liquidityMinted == 0) revert ZeroLiquidityMinted();
        if (amount0Used > amount0Desired || amount1Used > amount1Desired) {
            revert AdapterOverusedInput();
        }

        uint256 companyUnused =
            companyOutcomeIsToken0 ? amount0Desired - amount0Used : amount1Desired - amount1Used;
        uint256 currencyUnused =
            companyOutcomeIsToken0 ? amount1Desired - amount1Used : amount0Desired - amount0Used;
        _assertSyncLeftoverWithinBounds(
            companyAmount, currencyAmount, companyUnused, currencyUnused
        );
    }

    function _invertSqrtPrice(uint160 sqrtPriceX96) internal pure returns (uint160 inverted) {
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        uint256 value = Math.ceilDiv(uint256(1) << 192, uint256(sqrtPriceX96));
        if (value == 0 || value > type(uint160).max) revert InvalidSqrtPrice();
        inverted = uint160(value);
    }

    function _removeFromSpot(uint128 liquidity)
        internal
        returns (uint256 companyOut, uint256 collateralOut)
    {
        IFutarchyLiquidityAdapter.Removal memory removed =
            SPOT_ADAPTER.removeLiquidityDetailed(TOKEN0, TOKEN1, liquidity);
        spotLiquidity -= liquidity;
        (companyOut, collateralOut) = _fromTokenOrder(removed.principal0, removed.principal1);
    }

    function _removeFromConditionalPair(address tokenA, address tokenB, uint128 liquidity)
        internal
    {
        if (liquidity == 0) return;
        (address token0, address token1) = _sortPair(tokenA, tokenB);
        CONDITIONAL_ADAPTER.removeLiquidityDetailed(token0, token1, liquidity);
    }

    /// @dev Full consolidation makes every fee and idle balance part of one observable vault
    /// balance before shares change. This avoids fee indices and price oracles.
    function _consolidateVault() internal {
        if (spotLiquidity > 0) _removeFromSpot(spotLiquidity);
        if (conditionalYesLiquidity > 0) {
            _removeFromConditionalPair(
                _capturedYesCompanyToken, _capturedYesCurrencyToken, conditionalYesLiquidity
            );
            conditionalYesLiquidity = 0;
        }
        if (conditionalNoLiquidity > 0) {
            _removeFromConditionalPair(
                _capturedNoCompanyToken, _capturedNoCurrencyToken, conditionalNoLiquidity
            );
            conditionalNoLiquidity = 0;
        }
    }

    function _restoreSpotLiquidity() internal {
        uint256 companyAmount = COMPANY_TOKEN.balanceOf(address(this));
        uint256 collateralAmount = WRAPPED_NATIVE.balanceOf(address(this));
        if (companyAmount > 0 && collateralAmount > 0) {
            _assertSpotPoolStable();
            _addToSpot(companyAmount, collateralAmount, "");
        }
    }

    function _redeemPlan(uint256 shares, uint256 supply)
        internal
        view
        returns (RedeemPlan memory plan)
    {
        plan.spot = _liquidityShare(spotLiquidity, shares, supply);
        plan.yes = _liquidityShare(conditionalYesLiquidity, shares, supply);
        plan.no = _liquidityShare(conditionalNoLiquidity, shares, supply);
        if (
            shares != supply && _conditionalLiquidityTotal() + uint256(spotLiquidity) != 0
                && plan.spot == 0 && plan.yes == 0 && plan.no == 0
        ) revert ZeroRedeemLiquidity();
    }

    function _liquidityShare(uint128 liquidity, uint256 shares, uint256 supply)
        internal
        pure
        returns (uint128)
    {
        if (shares == supply) return liquidity;
        return uint128(Math.mulDiv(uint256(liquidity), shares, supply));
    }

    function _removeRedeemLiquidity(
        RedeemPlan memory plan,
        uint256 shares,
        uint256 supply,
        VaultAmounts memory amounts
    ) internal {
        if (spotLiquidity > 0) {
            IFutarchyLiquidityAdapter.Removal memory removed =
                SPOT_ADAPTER.removeLiquidityDetailed(TOKEN0, TOKEN1, plan.spot);
            spotLiquidity -= plan.spot;
            (uint256 companyPrincipal, uint256 collateralPrincipal) =
                _fromTokenOrder(removed.principal0, removed.principal1);
            (uint256 companyFees, uint256 collateralFees) =
                _fromTokenOrder(removed.fees0, removed.fees1);
            amounts.company += companyPrincipal + _shareOf(companyFees, shares, supply);
            amounts.collateral += collateralPrincipal + _shareOf(collateralFees, shares, supply);
        }

        if (conditionalYesLiquidity > 0) {
            (uint256 companyOut, uint256 currencyOut) = _redeemConditionalPair(
                _capturedYesCompanyToken, _capturedYesCurrencyToken, plan.yes, shares, supply
            );
            conditionalYesLiquidity -= plan.yes;
            amounts.outcomes.yesCompany += companyOut;
            amounts.outcomes.yesCurrency += currencyOut;
        }
        if (conditionalNoLiquidity > 0) {
            (uint256 companyOut, uint256 currencyOut) = _redeemConditionalPair(
                _capturedNoCompanyToken, _capturedNoCurrencyToken, plan.no, shares, supply
            );
            conditionalNoLiquidity -= plan.no;
            amounts.outcomes.noCompany += companyOut;
            amounts.outcomes.noCurrency += currencyOut;
        }
    }

    function _redeemConditionalPair(
        address companyOutcome,
        address currencyOutcome,
        uint128 liquidity,
        uint256 shares,
        uint256 supply
    ) internal returns (uint256 companyOut, uint256 currencyOut) {
        (address token0, address token1) = _sortPair(companyOutcome, currencyOutcome);
        IFutarchyLiquidityAdapter.Removal memory removed =
            CONDITIONAL_ADAPTER.removeLiquidityDetailed(token0, token1, liquidity);
        uint256 amount0 = removed.principal0 + _shareOf(removed.fees0, shares, supply);
        uint256 amount1 = removed.principal1 + _shareOf(removed.fees1, shares, supply);
        return companyOutcome < currencyOutcome ? (amount0, amount1) : (amount1, amount0);
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
            _shareOf(IERC20(_capturedYesCompanyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.noCompany =
            _shareOf(IERC20(_capturedNoCompanyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.yesCurrency =
            _shareOf(IERC20(_capturedYesCurrencyToken).balanceOf(address(this)), shares, supply);
        amounts.outcomes.noCurrency =
            _shareOf(IERC20(_capturedNoCurrencyToken).balanceOf(address(this)), shares, supply);
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
            IERC20(_capturedYesCompanyToken).safeTransfer(recipient, amounts.yesCompany);
        }
        if (amounts.noCompany > 0) {
            IERC20(_capturedNoCompanyToken).safeTransfer(recipient, amounts.noCompany);
        }
        if (amounts.yesCurrency > 0) {
            IERC20(_capturedYesCurrencyToken).safeTransfer(recipient, amounts.yesCurrency);
        }
        if (amounts.noCurrency > 0) {
            IERC20(_capturedNoCurrencyToken).safeTransfer(recipient, amounts.noCurrency);
        }
    }

    function _recoverIdleOutcomeBalances(bool yesWins) internal {
        _recoverOutcomeAmounts(
            address(COMPANY_TOKEN),
            _capturedYesCompanyToken,
            _capturedNoCompanyToken,
            IERC20(_capturedYesCompanyToken).balanceOf(address(this)),
            IERC20(_capturedNoCompanyToken).balanceOf(address(this)),
            yesWins
        );
        _recoverOutcomeAmounts(
            address(WRAPPED_NATIVE),
            _capturedYesCurrencyToken,
            _capturedNoCurrencyToken,
            IERC20(_capturedYesCurrencyToken).balanceOf(address(this)),
            IERC20(_capturedNoCurrencyToken).balanceOf(address(this)),
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

        uint256 yesRemainder = yesAmount - mergeAmount;
        uint256 noRemainder = noAmount - mergeAmount;
        uint256 redeemAmount = yesWins ? yesRemainder : noRemainder;
        address winningToken = yesWins ? yesToken : noToken;
        if (redeemAmount > 0) {
            _forceApprove(IERC20(winningToken), address(CONDITIONAL_ROUTER), redeemAmount);
            CONDITIONAL_ROUTER.redeemPositions(
                collateralToken, _capturedConditionId, yesToken, noToken, redeemAmount
            );
            _forceApprove(IERC20(winningToken), address(CONDITIONAL_ROUTER), 0);
        }

        uint256 losingAmount = yesWins ? noRemainder : yesRemainder;
        address losingToken = yesWins ? noToken : yesToken;
        if (losingAmount > 0) {
            _forceApprove(IERC20(losingToken), address(CONDITIONAL_ROUTER), losingAmount);
            CONDITIONAL_ROUTER.consumeLosingPositions(
                collateralToken, _capturedConditionId, yesToken, noToken, losingAmount
            );
            _forceApprove(IERC20(losingToken), address(CONDITIONAL_ROUTER), 0);
        }
    }

    function _mergeOutcomeAmount(
        address collateralToken,
        address yesToken,
        address noToken,
        uint256 amount
    ) internal {
        _forceApprove(IERC20(yesToken), address(CONDITIONAL_ROUTER), amount);
        _forceApprove(IERC20(noToken), address(CONDITIONAL_ROUTER), amount);
        CONDITIONAL_ROUTER.mergePositions(
            collateralToken, _capturedConditionId, yesToken, noToken, amount
        );
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
        if (_capturedYesCompanyToken != address(0)) {
            uint256 bal = IERC20(_capturedYesCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(_capturedYesCompanyToken).safeTransfer(recipient, bal);
        }
        if (_capturedNoCompanyToken != address(0)) {
            uint256 bal = IERC20(_capturedNoCompanyToken).balanceOf(address(this));
            if (bal > 0) IERC20(_capturedNoCompanyToken).safeTransfer(recipient, bal);
        }
        if (_capturedYesCurrencyToken != address(0)) {
            uint256 bal = IERC20(_capturedYesCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(_capturedYesCurrencyToken).safeTransfer(recipient, bal);
        }
        if (_capturedNoCurrencyToken != address(0)) {
            uint256 bal = IERC20(_capturedNoCurrencyToken).balanceOf(address(this));
            if (bal > 0) IERC20(_capturedNoCurrencyToken).safeTransfer(recipient, bal);
        }
    }

    function _clearConditionalModeState() internal {
        conditionalYesLiquidity = 0;
        conditionalNoLiquidity = 0;
        inConditionalMode = false;
    }

    function _conditionalPool(address tokenA, address tokenB) internal view returns (address pool) {
        (address token0, address token1) = _sortPair(tokenA, tokenB);
        pool = IFutarchyPrefundedLiquidityAdapter(address(CONDITIONAL_ADAPTER))
            .poolByPair(token0, token1);
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
