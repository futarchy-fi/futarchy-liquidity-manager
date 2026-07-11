# Design

## Goal

`FutarchyLiquidityManager` is a generic liquidity vault for futarchy markets. LPs deposit a
company token and collateral once, receive FLM shares, and let the manager handle:

- spot liquidity while no official proposal is live;
- migration into YES/NO conditional pools while an official proposal is live;
- return to spot after proposal settlement;
- pro-rata LP redemption across active liquidity modes.

## Core Principle

Proposal curation must not imply custody over LP funds.

The owner or proposal manager can mark an official proposal only through
`FutarchyOfficialProposalSource`. When validation is enabled, `setOfficialProposal` accepts only
proposals whose on-chain properties match the configured safety policy.

## Permissionless Deployment

The thin factory pins immutable hashes of the proposal source, adapter, and manager bare creation
code. Any account can supply those exact blobs and organization-specific parameters. The factory
appends constructor arguments itself, deploys the source, two adapters, and manager sequentially,
then irreversibly binds both adapters in the same transaction. Hash mismatches, oversized EIP-3860
initcode, failed creation, or failed binding revert the entire bundle.

The blobs stay in transaction calldata rather than factory runtime so the factory remains below the
EIP-170 limit. A child implementation change requires a new factory; there is no hash updater,
CREATE2 salt, clone implementation, or deployment owner.

The factory event's organization field is an unverified caller assertion. Organization registration
or a signed endorsement belongs in the consuming UI; event discovery alone is not canonical.

## Public Vault Accounting

Deposits are permissionless only while the manager is in spot mode. Before any deposit or
redemption, the manager removes every active position in full. Principal, accrued AMM fees, and
tracked idle balances then form one observable asset vector, avoiding a price oracle or per-holder
fee index.

A spot deposit supplies maximum amounts of both base assets. Shares are the smaller of the two
proportional contributions, rounded down; the accepted asset amounts are rounded up and all excess
is refunded or left unpulled. A redemption receives the same fraction of each consolidated asset,
with the final redeemer receiving all rounding dust.

In conditional mode, the vector also contains YES/NO company and collateral tokens. The manager
merges only the withdrawing slice's matched complete sets and transfers unmatched outcomes in kind.
If the merge call reverts, the complete sets are transferred in kind too, so router availability
cannot block withdrawal. Remaining assets are re-added with fixed adapter defaults. A failed re-add
does not revert redemption: assets stay in the manager and `restoreLiquidity()` is a permissionless
retry. Restoration first requires the exact spot or conditional pair to pass the shared stability
guard. Once stable, ratio-fit inventory is re-added and asymmetric fee inventory remains idle and
share-owned. A new conditional pool without 30 minutes of history therefore defers restoration but
never blocks the withdrawal that triggered it.

Emergency execution follows the same custody rule. It unwinds positions into the manager but never
transfers pooled assets or burns shares. Owner sweeping is disabled until total share supply is zero.

## Bad Proposal Checks

The proposal source can reject:

- wrong company/collateral pair;
- missing or duplicate wrapped outcome tokens;
- missing YES/NO conditional pools;
- wrong CTF oracle or condition id;
- non-binary CTF conditions;
- missing Reality question;
- untrusted Reality arbitrator;
- opening time too far in the future;
- timeout below or above configured bounds;
- minimum bond above the configured maximum.

These checks are intended to prevent a weak proposal manager from freezing LP funds by selecting
an arbitrary or never-settling conditional market.

## Migration Price Guard

Before either permissionless migration direction removes liquidity, the manager asks its immutable
shared `AlgebraPoolStabilityGuard` to compare the established spot pool's current tick with its
30-minute time-weighted average. More than 50 ticks of deviation, missing history, a missing pool,
or an uninitialized pool reverts before state changes.

The guard deliberately does not require history from newly created YES/NO pools. On entry, the
manager instead requires each conditional add to consume both sides of the inventory split from the
TWAP-anchored spot position within a symmetric 50-bps leftover bound. On return, the same spot guard
runs before the settled winner inventory is recovered and ratio-fit back into spot.

## Settlement Liveness

Validation alone cannot guarantee that a Reality question eventually resolves. For new
FLM-grade markets, use `DeadlineBoundedRealityProxy` as the CTF oracle. It supports normal
Reality resolution and a fallback `forceFailByDeadline` path that reports NO after:

```text
Reality opening timestamp + maxQuestionDuration
```

This cannot retrofit deadlines onto conditions created with a different oracle address.

## FAO Compatibility

FAO should use this package as an integration:

- deploy/configure generic FLM contracts;
- keep sale, arbitration, SnapshotX, and organization-specific deployment logic outside this
  core package;
- configure `COMPANY_TOKEN`, `BOOTSTRAP_RECIPIENT`, proposal source, adapters, and validation
  bounds for the FAO deployment.
