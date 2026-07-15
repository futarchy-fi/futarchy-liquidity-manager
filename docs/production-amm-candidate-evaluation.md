# Production AMM candidate evaluation — 2026-07-15

## Status

Uniswap v4 with an immutable initialization-only hook is the preferred technical architecture. It
is not yet a production successor: Gnosis is absent from the official deployment list, and no
production-use grant for a Futarchy deployment has been verified under the current v4 core
license. Do not add the dependency, sign a deployment batch, or fund this path until both blockers
are resolved.

## Candidate decision

| Candidate | Atomic fresh initialization | Removal liveness | New trusted core | Disposition |
| --- | --- | --- | --- | --- |
| Canonical Swapr Algebra | No; predictable pairs can be precreated | No; mutable cooldown can be refreshed by dust mints | No | Rejected |
| Canonical Uniswap v3 | No; its permissionless factory has the same precreation veto | Yes | No | Rejected |
| Private v3/Algebra factory | Possible | Depends on the fork | Yes | Rejected as the larger custom-core path |
| New constant-product AMM | Possible | Possible | Yes | Rejected; it invents different inventory/price and fee semantics |
| Uniswap v4 singleton plus initialization-only hook | Yes | Yes | No, if an official deployment exists | Preferred, release-blocked |

The v4 design is the smallest candidate that does not require inventing or forking an AMM. A pool
key includes its hook, and `beforeInitialize` receives the original caller. A non-proxy hook can
therefore bind initialization to one adapter while its address enables only the
`BEFORE_INITIALIZE` permission. There is no removal callback for that hook address, so neither the
hook nor third-party position activity can block the FLM position's removal.

## Minimal adapter shape

- Pin an audited, non-upgradeable PoolManager address and code hash. Pin a non-proxy hook whose
  runtime has no destruction path and whose address has only the before-initialize permission bit.
- The hook checks both `msg.sender == POOL_MANAGER` and the original initializer equals the bound
  adapter. The adapter fixes fee, tick spacing, hook, full-range ticks, salt, token ordering, and
  guarded initial price; callers supply none of them.
- During the source-owned activation transaction, the adapter initializes each conditional pool
  and immediately adds its first position in a PoolManager unlock callback. No transaction can be
  interleaved between initialization and first liquidity. Any failure reverts the proposal write,
  CTF split, spot migration, both initializations, and both first positions.
- The position owner is the adapter. Position identity also includes pool, ticks, and salt, so a
  third party can add liquidity only to its own position. Manager-only adapter entry points prevent
  a caller from modifying the FLM position.
- Removal first performs a zero-liquidity poke. With no add/remove hook permissions, its caller
  delta must equal the fee delta. The adapter then removes principal in the same callback and
  requires the second fee delta to be zero. It takes exactly the resulting currencies from the
  PoolManager; it never treats an informational fee report as an unbacked entitlement.
- Donations are shareholder assets, not deposits and not newly issued shares. The production tests
  must cover donations before the first external deposit, donations between partial redemptions,
  single-leg donations, and the upstream warning that `feesAccrued` can be artificially inflated.
- PoolManager ownership may control protocol-fee policy but must have no upgrade, pause, hook
  replacement, position seizure, or removal-lock authority. The production fork fixture must prove
  these exact powers for the pinned deployment.

This keeps the existing manager-facing fresh-add and detailed-removal interfaces. V4 pool keys,
unlock accounting, and hook permissions remain adapter-local.

## Upstream validation

The technical seam was checked against
[`Uniswap/v4-core` commit `46c6834`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75)
with its own Foundry configuration and Solidity 0.8.26:

- compiled PoolManager creation bytecode: 24,195 bytes;
- compiled PoolManager runtime bytecode: 24,010 bytes, 566 bytes below EIP-170;
- local PoolManager deployment: 4,870,672 gas;
- local authorized pool initialization through a before-initialize-only hook: 30,833 gas; and
- an adversarial test proved that an outsider initialization reverts, the bound caller then
  initializes the same key, and neither removal-hook bit is present.

The Gnosis block gas limit was 17,000,000 at block 47,217,750. These measurements validate the
singleton's architectural headroom only. They do not replace the required full outer-transaction
fork fixture with both positions, CTF work, transfers, calldata, and failure-path rollback.

The fee design follows the upstream
[`modifyLiquidity` contract](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/interfaces/IPoolManager.sol),
which separates the caller delta from `feesAccrued`, supports a zero-liquidity poke, and explicitly
warns that donation can inflate the reported fee value. The hook argument and permission-bit
behavior are fixed by upstream
[`PoolManager.initialize`](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol)
and
[`Hooks`](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol).

## Deployment and license evidence

The release blockers were rechecked against the current official and onchain sources at Ethereum
block 25,540,151 (`2026-07-15T19:29:23Z`):

- The [official v4 deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments)
  still has no Gnosis (chain ID 100) entry.
- The `v4deployments.uniswap.eth` resolver also returned an empty `text(node, "100")` value. This
  independently confirms that governance has not registered an official Gnosis deployment.
- `v4-core-license-date.uniswap.eth` had no ENS resolver, so it has not shortened the static
  2027-06-15 change date in the core license.
- The executed
  [v4 licensing-process proposal](https://vote.uniswapfoundation.org/proposals/85) grants the
  Uniswap Foundation deployment rights for DAO-selected chains. It does not grant Futarchy a
  general right to self-deploy or fork v4 core.

The shortest pre-change-date path is therefore to request a DAO-approved Gnosis deployment through
the established Uniswap process and consume the resulting official contracts. A Futarchy-operated
PoolManager deployment remains out of scope unless Futarchy receives its own applicable grant and
independent legal clearance.

## Release blockers

1. The [official v4 deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments)
   did not list Gnosis on 2026-07-15. Select an official Gnosis deployment with verified code and
   governance through the established Uniswap deployment process; an arbitrary or merely
   byte-identical fork is not an equivalent dependency.
2. V4 core is currently under its
   [Business Source License](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/licenses/BUSL_LICENSE),
   with an MIT change date no later than 2027-06-15. Production deployment before that date needs
   an applicable Additional Use Grant or other license clearance. This document is an engineering
   gate, not legal advice.
3. After those inputs are fixed, implement only the adapter and initialization hook, then run every
   adversarial, conservation, rollback, gas, bytecode, configuration, and batch gate in
   `production-amm-successor.md` on the real Gnosis deployment.
4. Independent review remains mandatory before funding.

Until then, the committed Algebra path remains a no-funds prototype.
