# Production AMM successor requirements

The Swapr Algebra implementation is a no-funds prototype. A production successor must preserve the
atomic proposal and proportional-redemption model without inheriting its pool-precreation veto,
mutable burn cooldown, or narrow gas margin.

## Operator-custody Gnosis configs

The no-funds rule remains for public-LP configs. It is lifted only for Gnosis configs whose
depositor gate has been verified on-chain as operator-only, with the operator Safe as sole
depositor. That limited operator-custody exception leaves the public-LP production-successor and
Ethereum v4 conclusions unchanged.

The current candidate disposition and release blockers are recorded in
`production-amm-candidate-evaluation.md`.

## Required properties

- Only the authenticated FLM activation may initialize a conditional pool and create its first
  liquidity. Predictable token pairs must not let a third party veto activation beforehand.
- The hook's CREATE2 address must not introduce a new public-salt precreation veto. Address mining
  and factory deployment must commit the effective salt to the actual creating wallet.
- No administrator or third-party liquidity action may impose or refresh a lock on FLM removal.
  Share redemption, settlement, and emergency unwind must remain permissionless. The only
  share-size liveness exception is a nonfinal redemption whose every active-liquidity slice floors
  to zero; it must revert without burning shares rather than donate the holder's principal claim.
- The manager passes one source-validated proposal snapshot through activation. The AMM integration
  must not reread a mutable proposal or accept caller-selected wrappers, pool keys, prices, ticks,
  deadlines, or slippage policy.
- The guarded spot price determines conditional initialization, with checked orientation for every
  token ordering. Failure at creation, initialization, first liquidity, or verification must revert
  the complete source write and spot migration.
- Partial redemption removes the caller's proportional position and accrued fees without
  redeploying survivor assets. The final holder receives deterministic rounding residue.
- Pool and hook administration must be immutable or incapable of blocking initialization, removal,
  collection, and settlement. A privileged promise not to change configuration is insufficient.
- Staged activation must retain materially more Ethereum-mainnet block-gas headroom than the
  Algebra prototype; the bound is measured from a pinned mainnet fork fixture, includes calldata
  overhead, and is compared with that fork block's actual gas limit.

## Integration boundary

Keep the manager-facing fresh-add and detailed-removal interfaces AMM-neutral. AMM-specific pool
keys, hook permissions, position identifiers, and fee accounting belong inside the replacement
adapter. Do not add a compatibility mode that keeps the Algebra conditional path fundable.

## Release evidence

- adversarial tests for precreation, unauthorized initialization, unauthorized first liquidity,
  third-party donations, administration changes, and every removal-blocking hook path;
- unit, fuzz, and invariant conservation tests across sequential partial redemptions;
- real-fork atomic rollback tests at each external call boundary;
- committed activation and full-outer gas fixtures with explicit margin; and
- bytecode, selector-freeze, configuration, and batch gates all green.

Funding remains prohibited until these properties are implemented and independently reviewed.
