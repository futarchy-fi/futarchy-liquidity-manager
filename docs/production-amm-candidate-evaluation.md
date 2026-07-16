# Production AMM candidate evaluation — 2026-07-16

## Status

FAO production now targets Ethereum mainnet, not Gnosis Chain. Ethereum has an official Uniswap v4
deployment, so the prior missing-deployment blocker is superseded. Uniswap v4 with an immutable
initialization-only hook is selected for implementation. The repository now contains the gate and
manager-bound direct conditional adapter, but not atomic bundle wiring, a full-lifecycle mainnet
fork proof, or external review. Do not sign a deployment batch or fund this path until those gates
pass.

## Candidate decision

| Candidate | Atomic fresh initialization | Removal liveness | New trusted core | Disposition |
| --- | --- | --- | --- | --- |
| Canonical Swapr Algebra | No; predictable pairs can be precreated | No; mutable cooldown can be refreshed by dust mints | No | Rejected |
| Canonical Uniswap v3 | No; its permissionless factory has the same precreation veto | Yes | No | Rejected |
| Private v3/Algebra factory | Possible | Depends on the fork | Yes | Rejected as the larger custom-core path |
| New constant-product AMM | Possible | Possible | Yes | Rejected; it invents different inventory/price and fee semantics |
| Official Ethereum Uniswap v4 plus initialization-only hook | Yes | Yes | No | Selected, implementation incomplete |

The v4 design is the smallest candidate that does not require inventing or forking an AMM. A pool
key includes its hook, and `beforeInitialize` receives the original caller. The committed
`V4InitializationGate` binds once to one code-bearing adapter, accepts calls only from the official
PoolManager on behalf of that adapter, and requires the pool key to name itself. Its deployment
address enables exactly `BEFORE_INITIALIZE`; there is no add/remove callback, proxy, owner setter,
or removal lock. Focused adversarial tests prove an outsider cannot preinitialize the predictable
key and the bound adapter can still initialize it afterward.

## Minimal adapter shape

- Pin the official Ethereum PoolManager address and reviewed runtime code hash. Deploy the
  non-proxy hook by CREATE2 at an address whose low permission bits contain only
  `BEFORE_INITIALIZE`; atomically deploy the adapter and irreversibly bind it through the bundle
  factory before returning.
- The hook checks both `msg.sender == POOL_MANAGER`, the original initializer equals the bound
  adapter, and the pool key names that hook. The adapter fixes fee, tick spacing, hook, full-range
  ticks, salt, token ordering, and guarded initial price; callers supply none of them.
- During the source-owned activation transaction, the adapter initializes each conditional pool
  and immediately adds its first position in a PoolManager unlock callback. No transaction can be
  interleaved between initialization and first liquidity. Any failure reverts the proposal write,
  CTF split, spot migration, both initializations, and both first positions.
- The position owner is the adapter. Position identity includes pool, ticks, and salt, so a third
  party can add liquidity only to its own position. Manager-only adapter entry points prevent a
  caller from modifying the FLM position.
- Removal first performs a zero-liquidity poke. With no add/remove hook permissions, its caller
  delta must equal the fee delta. The adapter then removes principal in the same callback and
  requires the second fee delta to be zero. It takes exactly the resulting currencies from the
  PoolManager; it never treats an informational fee report as an unbacked entitlement.
- Donations are shareholder assets, not deposits and not newly issued shares. Production tests
  must cover donations before the first external deposit, donations between partial redemptions,
  single-leg donations, and the upstream warning that `feesAccrued` can be artificially inflated.
- PoolManager ownership may control protocol-fee policy but must have no upgrade, pause, hook
  replacement, position seizure, or removal-lock authority. The production fork fixture must prove
  these exact powers for the pinned deployment.

This keeps the existing manager-facing fresh-add and detailed-removal interfaces. V4 pool keys,
unlock accounting, and hook permissions remain adapter-local.

The committed direct adapter implements that boundary without a v4 periphery dependency. It pins
the PoolManager runtime hash, fixes fee 500, tick spacing 10, full-range ticks, hook, and zero salt,
and derives a conservative liquidity request from the guarded price. Exact returned deltas are
capped by the prefunded assets and must consume at least 99.5% of both legs. Its removal unlock
pokes and takes real fee deltas before removing principal, requires the second fee report to be
zero, and sends both phases directly to the bound manager.

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
- a pinned Ethereum fork at block 25,542,490 verifies the official PoolManager runtime code hash
  and proves the exact committed gate ABI rejects an outsider before accepting the bound adapter on
  the same pool key.
- the same pinned fork proves the committed adapter initializes and adds through the official
  PoolManager, realizes a third-party pool donation as shareholder fees, removes one third, then
  removes the exact remainder without adapter residue.

These measurements validate the singleton's architectural shape only. They do not replace the
required full outer-transaction Ethereum-mainnet fork fixture with both positions, CTF work,
transfers, calldata, and failure-path rollback.

The fee design follows the upstream
[`modifyLiquidity` contract](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/interfaces/IPoolManager.sol),
which separates the caller delta from `feesAccrued`, supports a zero-liquidity poke, and explicitly
warns that donation can inflate the reported fee value. The hook argument and permission-bit
behavior are fixed by upstream
[`PoolManager.initialize`](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol)
and
[`Hooks`](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/libraries/Hooks.sol).

## Deployment and license evidence

The [official v4 deployment list](https://developers.uniswap.org/docs/protocols/v4/deployments)
lists Ethereum chain ID 1 PoolManager
`0x000000000004444c5dc75cB358380D2e3dE08A90`. FAO must consume that reviewed deployment rather
than deploy or fork v4 core.

Upstream `PoolManager.sol` is BUSL-1.1, while the integration-facing
[`IPoolManager.sol`](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol)
and hook-dispatch
[`Hooks.sol`](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol) are MIT-licensed.
The committed gate is original MIT-licensed code with a minimal ABI-compatible pool-key type; it
does not deploy or copy PoolManager. The production adapter should likewise depend only on the
minimum MIT-licensed interfaces and types needed to call the official deployment. Independent
legal review remains a real-funds gate; this document is an engineering analysis, not legal advice.

## Release blockers

1. Implement atomic factory wiring for mined hook deployment, adapter deployment, both irreversible
   bindings, and manager/source creation in one transaction.
2. Pin and independently verify the official Ethereum PoolManager runtime hash and every imported
   upstream file/license; complete legal review before real funds.
3. Run every adversarial, conservation, rollback, gas, bytecode, configuration, and batch gate in
   `production-amm-successor.md`, including the full source/CTF/two-pool manager lifecycle, on a
   pinned Ethereum-mainnet fork and the final deployment config.
4. Complete independent contract and role review before funding.

Until then, both the committed Algebra path and the partial v4 path remain no-funds prototypes.
