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
- `DeadlineBoundedRealityProxy`: CTF oracle proxy for new FLM-grade proposals that relays a
  finalized Reality result even on the deadline path, or forces deterministic NO after a bounded
  deadline only while Reality remains unresolved.
- `UniV3PoolStabilityGuard`: immutable 30-minute TWAP check for the selected Ethereum spot path. A
  pinned fork proves the configured fee/factory, required observation history, and 50-tick bound
  against the official v3 factory. `AlgebraPoolStabilityGuard` remains legacy prototype scope.
- `FutarchyLiquidityManagerFactory`: permissionless atomic bundle deployer pinned to immutable bare
  creation-code hashes and shared protocol dependencies.
- `V4InitializationGate`: partial Ethereum-mainnet successor seam. It reserves pool initialization
  for one irreversibly bound adapter and deliberately exposes no liquidity callbacks. The v4
  bundle factory deploys it at the mined address and binds it in the same transaction.
- `V4ConditionalLiquidityAdapter`: manager-bound direct v4 position owner. It atomically initializes
  and adds a fresh full-range position, settles exact PoolManager deltas, separates fee pokes from
  principal removal, and rejects dependency-codehash or fee-report drift. A pinned full-mainnet
  fixture covers the source, canonical CTF, deployed wrapper factory, both v4 positions, settlement,
  live v4 donations, a one-third unresolved redemption with pro-rata fee allocation, and
  final-holder conservation together with the real v3 spot position manager and production guard.
- `V4FutarchyLiquidityManagerFactory`: permissionless atomic v4 bundle deployer. It hash-pins all
  five child creation codes, deploys the initialization gate at a caller-bound mined CREATE2
  address, deploys the source/adapters/manager, wires the source's pool lookup directly to the v4
  conditional adapter, and completes all irreversible bindings before returning. Final-address
  deployment configuration and production dependency selection remain outside the implemented
  surface.

## External Dependencies

- ERC20 company token.
- Configured collateral token, either wrapped native through the payable overloads or ERC20
  collateral through explicit approval overloads.
- Futarchy proposal contract exposing collateral, wrapped outcomes, question id, and condition id.
- Conditional Tokens Framework.
- Reality.eth.
- Official Ethereum Uniswap v3 position manager/factory and a spot pool with at least 30 minutes of
  usable observations; a fresh pool needs observation cardinality raised before its first mint.
- Official Ethereum Uniswap v4 PoolManager and the exact-permission initialization gate.
- Canonical CTF Wrapped1155 factory.
- Algebra/Swapr dependencies only for historical prototype and regression coverage.
- Liquidity adapter contracts.
- Conditional split/merge/redeem router.

## Security Properties To Review

- LP shares remain proportional through deposits, withdrawals, migration, and settlement.
- Manager construction rejects an identical company/collateral token before either two-asset share
  accounting or bundle deployment can become live.
- Manager and factory construction reject code-less token, router, adapter, guard, and AMM
  dependencies before a permanently unusable direct deployment or bundle can persist.
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
- The manager persists the verified settlement winner with the last captured wrappers. Any later
  donation in that resolved snapshot is converted before a spot-mode sync, deposit, redemption, or
  activation, so it is priced for current shares and cannot be orphaned by pointer replacement.
- Proposal manager cannot select arbitrary unsafe proposals once validation is enabled.
- The proposal source completes an official write only if the activation target reports an exact
  capture of every source-validated proposal field; any mismatch rolls back both contracts.
- The source and manager independently require the two base assets and four outcome wrappers to be
  six distinct accounting tokens before the manager consults the spot guard or moves liquidity.
- Validation rejects far-future opening times, excessive min bonds, bad timeout bounds, wrong
  arbitrators, wrong CTF oracle, non-binary conditions, wrong collateral, missing outcomes, and
  non-pristine questions. The manager-bound adapter separately rejects pre-existing conditional
  pools during atomic activation.
- Deadline proxy gives new FLM-grade proposals a bounded liveness path.
- Emergency exit only unwinds positions into the manager. It neither burns shares nor transfers
  shareholder assets, redemption remains available while emergency mode is armed or executed, and
  anyone may execute the unwind after the owner-authorized delay. Arming or execution never blocks
  permissionless settlement of a captured CTF condition.
- Adapters cannot over-pull tokens from the manager.
- Source-atomic conditional activation fails closed before persistent state changes if the shared
  spot-pool guard cannot read valid history or detects more than 50 ticks of deviation.
- New YES/NO pools are not required to have 30 minutes of history before first seeding. Their adds
  remain bounded by the manager's symmetric 50-bps unused-inventory check against inventory
  removed from the TWAP-anchored spot position.
- Redemption performs no re-add and consults no stability guard. Settlement resolves the stored CTF
  assets before any optional spot action and currently leaves recovered base inventory idle and
  share-owned. Later donations to the still-current resolved wrapper snapshot follow the same
  recovery path before a subsequent spot sync, deposit, redemption, or activation.
- The factory accepts no caller-supplied constructor suffixes: it verifies bare creation-code
  hashes, appends all wiring itself, enforces the EIP-3860 limit, and rolls back partial bundles,
  including invalid identical-base-token and code-less-company-token manager deployments.

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
  interactions still require adapter review. NFT-adapter adds independently enforce exact input
  balance deltas, reconcile reported use to refunds, restore pre-call token custody, and clear
  downstream position-manager allowances.
- Deposits require exact ERC20 balance deltas; fee-on-transfer assets are rejected. Rebasing assets
  are not a supported company-token or collateral configuration.
- Native collateral is wrapped during payable deposits. The manager rejects direct native
  transfers and accepts unwrap proceeds only from its immutable wrapped-collateral contract.
  Unavoidable forced native currency is outside the six-token accounting model and remains
  unsweepable while shares exist.
- The immutable conditional router verifies canonical wrapper identity and exact split/settlement
  deltas. The manager independently requires exact merge, winner-redemption, and losing-consumption
  deltas during settlement; a failed redemption-time merge falls back to transferring that exact
  outcome-token slice.
- The immutable stability guard pins its v3 factory and fee. Its 30-minute window and 50-tick bound
  have no owner or runtime setters.
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
