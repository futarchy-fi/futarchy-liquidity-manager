# Design

The source-atomic activation and proportional-redemption design is specified in
[`atomic-lifecycle-amendment.md`](atomic-lifecycle-amendment.md) and implemented at repository head.
The current Swapr Algebra adapter still fails its removal-liveness threat model, so this is a
no-funds prototype pending the replacement specified in `production-amm-successor.md`.

## Goal

`FutarchyLiquidityManager` is a generic liquidity vault for futarchy markets. LPs deposit a
company token and collateral once, receive FLM shares, and let the manager handle:

- spot liquidity while no official proposal is live;
- migration into YES/NO conditional pools while an official proposal is live;
- recovery to share-owned base inventory after proposal settlement;
- pro-rata LP redemption across active liquidity modes.

## Core Principle

Proposal curation must not imply custody over LP funds.

Only the source's immutable lifecycle coordinator can call `setOfficialProposal`. That call stores
one validated proposal snapshot and must activate the bound manager before returning, so either the
registry write and both first positions succeed together or every effect reverts. Source owners and
the mutable proposal manager may configure pre-binding policy and later metadata, but cannot bypass
the coordinator-only activation path.

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

Deposits are permissionless only while the manager is in spot mode. Before a deposit, the manager
fully consolidates the spot position so principal, accrued AMM fees, donations, and idle balances
form one observable two-asset vector. This prevents a new depositor from diluting earlier value
without a price oracle or per-holder fee index.

A spot deposit supplies maximum amounts of both base assets. Shares are the smaller of the two
proportional contributions, rounded down; the accepted asset amounts are rounded up and all excess
is refunded or left unpulled. A redemption receives the same fraction of each consolidated asset,
with the final redeemer receiving all rounding dust.

Redemption does not consolidate or restore survivor positions. It snapshots the six possible idle
balances, removes only the caller's floor-rounded share of each active position, adds proportional
fees, and leaves every remainder share-owned. Every adapter removal receipt must exactly match the
manager's two token balance deltas. The manager first makes a zero-liquidity call and treats its
entire exact delta as fees, then treats the following nonzero call's entire exact delta as
principal. Adapter field-label misclassification therefore cannot change payouts, and an
overreported output cannot spend survivor-owned idle inventory. In conditional mode it merges only
the withdrawing slice's matched complete sets and transfers unmatched outcomes in kind. If either
merge reverts, that underlying's complete sets are transferred in kind too, so router availability
cannot block withdrawal. The final holder receives all rounding residue.

Native collateral enters only through payable deposit functions and is wrapped immediately; the
manager's receive path accepts native currency only from its immutable wrapper during an unwrap.
Unavoidable forced native currency is outside the six-token accounting model and cannot be swept
until share supply is zero.

Emergency execution follows the same custody rule. It unwinds positions into the manager but never
transfers pooled assets or burns shares. The owner controls arm/disarm authorization; after the
delay, execution is permissionless. Settlement of an existing captured CTF condition remains
permissionless throughout. Owner sweeping is disabled until total share supply is zero.

## Bad Proposal Checks

The proposal source can reject:

- wrong company/collateral pair;
- missing or duplicate wrapped outcome tokens;
- wrong CTF oracle or condition id;
- non-binary CTF conditions;
- missing Reality question;
- untrusted Reality arbitrator;
- opening time too far in the future;
- timeout below or above configured bounds;
- minimum bond above the configured maximum.
- an answered, arbitrating, already-open, or too-short-lived Reality question.

These checks are intended to prevent a weak proposal manager from freezing LP funds by selecting
an arbitrary or never-settling conditional market. The manager independently repeats the nonzero
and pairwise-distinct wrapper check before consulting the spot guard or moving liquidity.

## Migration Price Guard

Before source-atomic conditional activation removes spot liquidity, the manager asks its immutable
shared `AlgebraPoolStabilityGuard` to compare the established spot pool's current tick with its
30-minute time-weighted average and return the guarded price. More than 50 ticks of deviation,
missing history, a missing pool, or an uninitialized pool reverts the complete source write.

The guard deliberately does not require history from newly created YES/NO pools. On entry, the
manager instead requires each conditional add to consume both sides of the inventory split from the
TWAP-anchored spot position within a symmetric 50-bps leftover bound. Settlement removes and
resolves the stored conditional assets without consulting the spot pool; recovered base inventory
stays idle and redeemable until a separately proven fair join exists.

The proposed zero-fee constant-product round-trip invariant is derived in
[`constant-product-roundtrip.md`](constant-product-roundtrip.md). It shows how an
invariant-growth unbalanced join can preserve the absolute number of original spot LP tokens across
arbitrarily priced conditional pools. This is a design result, not a property of the current
adapters or of a raw off-ratio Uniswap V2 mint.

## Settlement Liveness

Validation alone cannot guarantee that a Reality question eventually resolves. For new
FLM-grade markets, use `DeadlineBoundedRealityProxy` as the CTF oracle. It supports normal
Reality resolution and a fallback `forceFailByDeadline` path after:

```text
Reality opening timestamp + maxQuestionDuration
```

The fallback first relays any finalized Reality result, so a caller cannot race a finalized YES
answer with forced NO. It reports NO only if Reality is still unresolved at the deadline.

This cannot retrofit deadlines onto conditions created with a different oracle address.

## FAO Compatibility

FAO should use this package as an integration:

- deploy/configure generic FLM contracts;
- keep sale, arbitration, SnapshotX, and organization-specific deployment logic outside this
  core package;
- configure `COMPANY_TOKEN`, `BOOTSTRAP_RECIPIENT`, proposal source, adapters, and validation
  bounds for the FAO deployment.
