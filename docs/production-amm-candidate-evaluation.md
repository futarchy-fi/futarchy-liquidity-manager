# Production AMM candidate evaluation — 2026-07-16

## Status

FAO production now targets Ethereum mainnet, not Gnosis Chain. Ethereum has an official Uniswap v4
deployment, so the prior missing-deployment blocker is superseded. Uniswap v4 with an immutable
initialization-only hook is selected for implementation. The repository now contains the gate and
manager-bound direct conditional adapter plus an atomic caller-bound CREATE2 bundle factory, but
not the final production dependency manifest, exact-config rehearsal, or external review. Do not
sign a deployment batch or fund this path until those gates pass.

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
  factory before returning. Bind the effective salt to the creating wallet so a different caller
  cannot front-run and consume the mined address.
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

The committed v4 bundle factory validates the five bare creation-code hashes supplied in calldata,
derives the hook CREATE2 salt from the creating wallet and its mined raw salt, validates the exact
permission bits before any child deployment, and then deploys the hook, proposal source, v3 spot
adapter, v4 conditional adapter, and manager. The hook→adapter, both adapter→manager, and
source→manager bindings all complete in the same reverting transaction. Deterministic tests prove a
late manager failure removes the already-created hook and every preceding child.
The source's immutable pool lookup is the deployed v4 conditional adapter itself, so registry views
resolve both singleton pool keys without retaining a legacy Algebra-factory dependency.

The production batch must call this factory directly from the Safe or creator address used while
mining the hook salt. It must not use a public relay or intermediary proxy: `msg.sender` is the salt
domain, so an intermediary would derive a different address and a shared public sender would lose
the intended caller-separation property.

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
- a full pinned-mainnet fixture deploys the caller-bound factory bundle, uses canonical Ethereum
  Conditional Tokens to split both base assets through the real router, atomically activates the
  real source and manager into two official-PoolManager positions, resolves through CTF, and removes
  and redeems both positions. It also creates a spot pool, mints its NFT, and removes the migration
  slice through the deployed mainnet Uniswap v3 position manager, while using the deployed Ethereum
  Wrapped1155 factory. Combined v3/v4 rounding leaves at most two wei per base asset; only the spot
  tokens remain deterministic stand-ins. The production v3 guard passes after the fixture raises
  observation cardinality before the first mint and waits its full 30-minute history window.

These fixtures validate the singleton and full outer-transaction architecture, but not the final
spot manager, deployment addresses, calldata, or Safe batch. The pinned dependency evidence and
unresolved fields are recorded in `production-mainnet-dependency-manifest.md`. Deterministic
tests remain the exhaustive failure-path rollback evidence until the exact production dependency
fixture is selected.

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

1. Produce the final Ethereum dependency manifest, mine and independently reproduce the
   creator-bound hook salt, and exercise the exact factory bytecode against those addresses.
2. Pin and independently verify the official Ethereum PoolManager runtime hash and every imported
   upstream file/license; complete legal review before real funds.
3. Run every adversarial, conservation, rollback, gas, bytecode, configuration, and batch gate in
   `production-amm-successor.md` against the final spot dependency and deployment config;
   repeat the now-passing source/CTF/two-pool manager lifecycle with those exact addresses.
4. Complete independent contract and role review before funding.

Until then, both the committed Algebra path and the partial v4 path remain no-funds prototypes.
