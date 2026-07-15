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
- A spot deposit fully consolidates the spot position before pricing new shares, so accrued fees,
  donations, and idle balances cannot be diluted. Redemption snapshots idle assets and removes only
  proportional liquidity and fees; a partial redeemer cannot collect value belonging to survivors.
- Deposits are accepted only in spot mode and only in the vault's existing two-asset proportion.
- Conditional redemption touches only the withdrawing fraction. Matched complete sets are merged
  when possible; router failure and unmatched balances fall back to in-kind outcome tokens.
- Stateful fee and donation sequences cannot dilute an existing holder: every successful deposit
  and redemption must preserve or increase each remaining liquidity and six-token balance claim
  per share. All issued test assets remain in modeled manager, adapter, router, or holder custody,
  and zero share supply leaves no balance under manager or adapter control.
- Proposal manager cannot select arbitrary unsafe proposals once validation is enabled.
- The proposal source completes an official write only if the activation target reports an exact
  capture of every source-validated proposal field; any mismatch rolls back both contracts.
- Validation rejects far-future opening times, excessive min bonds, bad timeout bounds, wrong
  arbitrators, wrong CTF oracle, non-binary conditions, wrong collateral, missing outcomes, and
  non-pristine questions. The manager-bound adapter separately rejects pre-existing conditional
  pools during atomic activation.
- Deadline proxy gives new FLM-grade proposals a bounded liveness path.
- Emergency exit only unwinds positions into the manager. It neither burns shares nor transfers
  shareholder assets, redemption remains available while emergency mode is armed or executed, and
  anyone may execute the unwind after the owner-authorized delay.
- Adapters cannot over-pull tokens from the manager.
- Source-atomic conditional activation fails closed before persistent state changes if the shared
  spot-pool guard cannot read valid history or detects more than 50 ticks of deviation.
- New YES/NO pools are not required to have 30 minutes of history before first seeding. Their adds
  remain bounded by the manager's symmetric 50-bps unused-inventory check against inventory
  removed from the TWAP-anchored spot position.
- Redemption performs no re-add and consults no stability guard. Settlement resolves the stored CTF
  assets before any optional spot action and currently leaves recovered base inventory idle and
  share-owned.
- The factory accepts no caller-supplied constructor suffixes: it verifies bare creation-code
  hashes, appends all wiring itself, enforces the EIP-3860 limit, and rolls back partial bundles.

## Permissions

- `FutarchyLiquidityManager.owner`
  - can arm/disarm emergency exit;
  - can sweep residual assets to `BOOTSTRAP_RECIPIENT` only when total share supply is zero.
- `BOOTSTRAP_RECIPIENT`
  - is the only account allowed to call `initializeFromBootstrap`;
  - receives only zero-supply residual sweeps, not emergency-exit assets.
- `FutarchyOfficialProposalSource.owner`
  - can set the proposal manager;
  - can perform every proposal-source operation available to the proposal manager.
- `FutarchyOfficialProposalSource.proposalManager`
  - can set the official proposer;
  - can configure validation only before activation-target binding;
  - can clear the official proposal but cannot set one;
  - can mark manual settlement if no settlement oracle is configured.
- `FutarchyOfficialProposalSource.LIFECYCLE_COORDINATOR`
  - is immutable and is the only caller allowed to atomically set and activate an official
    proposal.
- Any account
  - can deposit to spot;
  - can redeem its own FLM shares;
  - can call `sync` to settle a captured condition when CTF reports an exact binary payout;
  - can execute an owner-armed emergency unwind after `EMERGENCY_EXIT_DELAY`.

## Trust Assumptions

- The selected liquidity adapter is in audit scope. The manager checks that add-liquidity calls do
  not report more input used than provided and that every removal receipt equals the exact assets
  received. It classifies the entire exact delta from a zero-liquidity call as fees and the exact
  delta from the immediately following nonzero call as principal, so it does not trust the
  adapter's returned field labels. Adapter zero-liquidity semantics, custody, and protocol
  interactions still require adapter review.
- Deposits require exact ERC20 balance deltas; fee-on-transfer assets are rejected. Rebasing assets
  are not a supported company-token or collateral configuration.
- The immutable conditional router verifies canonical wrapper identity and exact split/settlement
  deltas. The manager independently requires exact merge, winner-redemption, and losing-consumption
  deltas during settlement; a failed redemption-time merge falls back to transferring that exact
  outcome-token slice.
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
