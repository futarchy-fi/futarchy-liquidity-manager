# Audit Scope

The current Swapr Algebra path is a no-funds prototype. A factory owner may enable mutable
`liquidityCooldown`, after which repeated third-party dust mints reset the shared position timestamp
and can indefinitely block spot and conditional burns. This unresolved trust boundary prevents the
bundle from satisfying always-redeemable custody.

## Objective

Make futarchy liquidity provision operationally simple without giving a proposal manager the
power to freeze or redirect LP funds through arbitrary or never-settling conditional markets.

## Core Contracts

- `FutarchyLiquidityManager`: holds LP share accounting, spot liquidity, conditional migration,
  settlement return, redemption, and emergency exit state. Adapter compounding remains
  intentionally unexposed.
- `FutarchyOfficialProposalSource`: admits at most one official live proposal and can enforce
  on-chain proposal validation before the manager migrates liquidity.
- `DeadlineBoundedRealityProxy`: CTF oracle proxy for new FLM-grade proposals that can resolve
  normally through Reality or force a deterministic NO after a bounded deadline.
- `AlgebraPoolStabilityGuard`: shared, immutable 30-minute TWAP check that rejects migration when
  the established spot pool's current tick differs from its average by more than 50 ticks.
- `FutarchyLiquidityManagerFactory`: permissionless atomic bundle deployer pinned to immutable bare
  creation-code hashes and shared protocol dependencies.

## External Dependencies

- ERC20 company token.
- Configured collateral token, either wrapped native through the payable overloads or ERC20
  collateral through explicit approval overloads.
- Futarchy proposal contract exposing collateral, wrapped outcomes, question id, and condition id.
- Conditional Tokens Framework.
- Reality.eth.
- Algebra/Swapr pool factory.
- Algebra pool observations with at least 30 minutes of usable spot-pool history.
- Liquidity adapter contracts.
- Conditional split/merge/redeem router.

## Security Properties To Review

- LP shares remain proportional through deposits, withdrawals, migration, and settlement.
- Every share change fully unwinds active positions first, so accrued AMM fees and tracked idle
  balances enter the same pro-rata balance vector. Later deposits cannot dilute existing value and
  a partial redeemer cannot collect fees or outcome balances belonging to remaining holders.
- Deposits are accepted only in spot mode and only in the vault's existing two-asset proportion.
- Conditional redemption touches only the withdrawing fraction. Matched complete sets are merged
  when possible; router failure and unmatched balances fall back to in-kind outcome tokens.
- Proposal manager cannot select arbitrary unsafe proposals once validation is enabled.
- Validation rejects far-future opening times, excessive min bonds, bad timeout bounds, wrong
  arbitrators, wrong CTF oracle, non-binary conditions, wrong collateral, missing outcomes, and
  missing pools.
- Deadline proxy gives new FLM-grade proposals a bounded liveness path.
- Emergency exit only unwinds positions into the manager. It neither burns shares nor transfers
  shareholder assets, and redemption remains available while emergency mode is armed or executed.
- Adapters cannot over-pull tokens from the manager.
- Both migration directions fail closed before removing liquidity if the shared spot-pool guard
  cannot read valid history or detects more than 50 ticks of current-to-TWAP deviation.
- New YES/NO pools are not required to have 30 minutes of history before first seeding. Their adds
  remain bounded by the manager's symmetric 50-bps unused-inventory check against inventory
  removed from the TWAP-anchored spot position.
- Every post-deposit or post-redemption re-add first requires the exact pair to pass the immutable
  stability guard. Ratio-fit inventory is deployed while asymmetric fee inventory stays idle and
  share-owned. Redemption catches missing history or an unstable pair and leaves all surviving
  holder assets idle for a permissionless retry.
- The factory accepts no caller-supplied constructor suffixes: it verifies bare creation-code
  hashes, appends all wiring itself, enforces the EIP-3860 limit, and rolls back partial bundles.

## Permissions

- `FutarchyLiquidityManager.owner`
  - can arm/disarm emergency exit;
  - can unwind all positions only after `EMERGENCY_EXIT_DELAY`;
  - can sweep residual assets to `BOOTSTRAP_RECIPIENT` only when total share supply is zero.
- `BOOTSTRAP_RECIPIENT`
  - is the only account allowed to call `initializeFromBootstrap`;
  - receives only zero-supply residual sweeps, not emergency-exit assets.
- `FutarchyOfficialProposalSource.owner`
  - can set the proposal manager;
  - can perform every proposal-source operation available to the proposal manager.
- `FutarchyOfficialProposalSource.proposalManager`
  - can set the official proposer;
  - can configure validation;
  - can set/clear the official proposal;
  - can mark manual settlement if no settlement oracle is configured.
- Any account
  - can deposit to spot;
  - can redeem its own FLM shares;
  - can call `sync` when conditions are met;
  - can retry restoration of share-owned idle balances.

## Trust Assumptions

- The selected liquidity adapter is in audit scope. The manager checks that add-liquidity calls do
  not report more input used than provided, but adapter custody and protocol interactions still
  require adapter review.
- Deposits require exact ERC20 balance deltas; fee-on-transfer assets are rejected. Rebasing assets
  are not a supported company-token or collateral configuration.
- The conditional router is trusted to split and settle the expected proposal positions. A failed
  redemption-time complete-set merge falls back to transferring that exact outcome-token slice.
- The immutable stability guard is shared by deployments using the same Algebra factory. Its
  factory, 30-minute window, and 50-tick bound have no owner or runtime setters.
- The official proposal source owner or proposal manager is trusted to configure validation
  correctly before setting a production official proposal.
- If manual settlement is used, the owner or proposal manager is trusted for settlement timing. For
  bounded liveness, prefer a settlement oracle or `DeadlineBoundedRealityProxy` path.
- `BOOTSTRAP_RECIPIENT` should be controlled by the organization integration, normally a Safe or
  reviewed bootstrap contract.

## FAO Compatibility

FAO should consume this package as an integration. If FAO needs sale bootstrap or SnapshotX
arbitration behavior, that code should stay outside the core package and call into the generic
interfaces.
