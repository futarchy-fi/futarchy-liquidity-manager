# Draft Ethereum mainnet dependency manifest

This is evidence for the selected mainnet architecture, not deployment authorization. All on-chain
observations below are pinned to Ethereum block `25,542,490` and reproduced by the fork tests or
with `cast` against an archival mainnet RPC. Final token, role, configuration, salt, and deployed
bundle fields remain intentionally unresolved.

## Pinned external deployments

| Dependency | Address | Runtime code hash | Evidence and disposition |
| --- | --- | --- | --- |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293` | Official Ethereum deployment; exercised by all three mainnet fork suites. |
| Conditional Tokens Framework | `0xC59b0e4De5F1248C1140964E0fF287B192407E0C` | `0x710326c6e1e66bc95ad81734a3c08448d7aa9fd0636c4477003fdababc3d1c1c` | Canonical Ethereum deployment; exercised by the full activation and settlement fork. |
| Wrapped1155Factory | `0xD194319D1804C1051DD21Ba1Dc931cA72410B79f` | `0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6` | Ethereum artifact in `seer-pm/demo` commit `cb0eff50b301ff715a7e41b7e164f2478670e0bc`; exercised by the full fork. External review still required. |
| Uniswap v3 NonfungiblePositionManager | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` | `0x692e658b31cbe3407682854806658d315d61a58c7e4933a2f91d383dc00736c6` | Candidate final spot manager. At the pinned block `factory()` and `WETH9()` return the entries below. The full fork creates a test-token pool, mints its spot NFT, and removes the migration slice through this deployment; final-token behavior is not yet exercised. |
| Uniswap v3 factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | `0x4d7b8525cd5d14343fa67a732fba5b24cddba11620ca88392f4ec6c52f91fd69` | Returned by the candidate spot position manager. |
| WETH9 | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | `0xd0a06b12ac47863b5c7be4185c2deaad1c61557033f56c7d4ea74429cbb25e23` | Returned by the candidate spot position manager; this does not select WETH as FAO collateral. |

The wrapper source file declares `LGPL-3.0-or-later`, while the containing repository has an MIT
root license and the source header lists no auditors. Legal provenance and independent contract
review are therefore unresolved real-funds gates even though the deployed integration works in the
pinned lifecycle fixture.

## Local bundle dependencies

The production bundle is intended to deploy the selector-frozen
`V4FutarchyLiquidityManagerFactory` children atomically: initialization gate, proposal source,
Uniswap v3 spot adapter, v4 conditional adapter, and manager. The factory must pin the reviewed
creation-code hashes and the PoolManager runtime hash above. Its creator-bound CREATE2 bundle salt
must be mined and reproduced for the final Safe sender; no relay may substitute for that sender.
All five addresses are available from `predictBundleAddresses` and remain unchanged if unrelated
callers deploy intervening bundles.

The current candidate is compiled with Solidity `0.8.36`, optimizer enabled at one run, and
`via_ir = true`. It targets Shanghai EVM with stripped revert strings and no CBOR/bytecode metadata
hash. Under that exact profile, the bare creation-code hashes are:

| Candidate artifact | Bare creation-code hash |
| --- | --- |
| `FutarchyOfficialProposalSource` | `0xeec528405c315ae9de9317487b7ddaf26bf3748af830bb4dd95538ca09c2afbf` |
| `UniswapV3LiquidityAdapter` | `0xc2f01cca15a3dc38280b20c05dcce401b71abd0f017fa04abe32550dc18e9a2b` |
| `V4InitializationGate` | `0x56052e89d8d3305ab4d3c35922882faee512c39fe45102cc0dec86bf7e57f75f` |
| `V4ConditionalLiquidityAdapter` | `0xba940a9f090ff9120797bb258c48717d0c508bbbc23d9379eb8c10bebcc4fc53` |
| `FutarchyLiquidityManager` | `0x7accf3e36923467479f9a697e2ae81b5e2da0a8ab31031d61901f04cc253550c` |
| `V4FutarchyLiquidityManagerFactory` | `0xe6df50aabe5258cd3d084046eb8b3573cad874c50e7aa721257e033374497440` |

`test_candidateCreationCodeHashesMatchMainnetManifest` fails on any artifact drift. These are
candidate build identities, not deployed-address or audit approval claims; any reviewed source or
compiler change must deliberately update both the test and this table.

`DeployV4MainnetFactory.s.sol` is the executable factory-only handoff for this manifest. It accepts
a reviewed `mainnet-v4-factory` config, requires Ethereum chain ID 1, rechecks the official v3 and
v4 addresses and runtime hashes above, verifies every selected router/CTF/wrapper/guard/collateral
runtime hash plus the router's immutable dependency binding, and records the config hash, deployed
factory creation/runtime hashes, and all five child creation-code hashes. It cannot create a child
bundle, choose a raw salt, or move funds.

The full fork also deploys the production `UniV3PoolStabilityGuard` against the official v3 factory.
It raises the fresh spot pool's observation cardinality to two before the first mint, preserves the
initial observation, waits the full 30-minute window, and proves both bootstrap and activation
checks. Without that second observation slot, the first mint overwrites the only observation and
the later TWAP correctly reverts `OLD`.

The same fixture donates complete sets across both live v4 pools before a one-third exit, then adds
another complete set and a YES-company-only donation after it. The exited balances remain fixed;
both resolutions run against the live stack. A winning donated leg produces LP recovery of 103
company versus 102 collateral within five wei; a losing donated leg leaves LP recovery at 102
versus 102 and its untouched NO-company counterpart outside the manager. Asymmetric live fees are
therefore credited only to then-current shares and only at their realized payout.

A separate run moves the YES-company-only donation before the unresolved one-third exit. The
redeemer receives its floor-rounded fee share as an unmatched wrapper within four wei, keeps the
same base balance through settlement, and redeems the winning wrapper independently afterward.

Another run first faults the second proportional adapter removal after the first official-v4
unwind. LP shares, both positions, spot identity, and all six holder/manager/PoolManager balances
restore exactly. Its identical retry faults the canonical company-side CTF merge: collateral still
merges normally and the company slice is paid as exact YES/NO wrappers. After resolution the holder
redeems the winner and consumes the loser independently, the survivor settles and exits, and
aggregate recovery of both base assets remains within five wei.

A settlement rollback run faults the canonical collateral-side CTF merge only after the company
merge and winner redemption have executed. The failed permissionless sync restores both v4
positions, captured manager binding/accounting, PoolManager balances, CTF collateral/underlying
custody, wrapper supply/custody, and allowances. Clearing the fault lets the identical sync and
final exit complete.

An emergency run accrues donations in both official-v4 positions, arms the delayed exit, and lets
an unrelated account begin the unwind. A fault at the second adapter removal restores the already
removed first official-v4 position, PoolManager/manager custody, accounting, shares, and the
unexecuted emergency flag. The identical outsider retry receives no assets, reaches zero position
liquidity, and lets a one-third holder redeem against unresolved canonical CTF for proportional
base value within five wei and no outcome residue. The survivor settles after source-registry
clearing, and aggregate final recovery remains within five wei per base asset.

Nine rollback variants fault official-v3 spot principal removal, each canonical CTF split, wrapper
conversion on each underlying, and each official-PoolManager initialization and first-liquidity
call. Each failed outer proposal write restores the empty source registry, actual spot NFT and
liquidity, base custody and allowances, CTF underlying custody, wrapper supplies and custody,
PoolManager balances, and absent YES/NO adapter positions. Clearing the fault lets the identical
proposal activate, so no failed initialization or later first-liquidity call leaves a latent
pool-precreation veto.

At this block the actual gas limit is `60,000,000`. Conservative transaction estimates add `21,000`
base gas and charge all calldata bytes at the nonzero rate of 16 gas: the atomic bundle is
`12,125,922` gas, source/CTF/two-pool activation is `2,343,088` gas, and partial real-stack
redemption after symmetric live v4 donations is `1,460,745` gas; the asymmetric in-kind case is
`1,487,553` gas and the canonical-merge-failure fallback is `1,417,015` gas. The fork asserts each
stays below half the block limit. These are fixture bounds, not estimates for still-unknown final
token or coordinator calldata.

The expanded required deep invariant command passes: five manager invariants each execute 256 runs
at depth 500 (128,000 calls) across nine actions, including emergency arm, disarm, execution, and
settlement during emergency mode. Two UniV3 invariants retain their stricter inline 256-by-512
setting (131,072 calls). All finish with zero reverts. Re-run it after fixing every deployment field
below.

## Unresolved deployment fields

Do not render or sign a production batch until one reviewed manifest revision fixes and verifies:

- company token and collateral token addresses, decimals, code hashes, and issuer/upgrade powers;
- the exact v3 spot tick range, initial price, existing-pool rejection behavior, and token ordering;
- owner Safe, lifecycle coordinator, bootstrap recipient, official proposer, and emergency process;
- proposal validation stack, Reality/CTF identifiers and bounds, and final router configuration;
- raw bundle salt, effective creator-bound salt, and predicted addresses for all five children;
- factory address and runtime hash, final confirmation of the candidate creation hashes above,
  deployed child runtime hashes, constructor arguments, and verified-source/license records;
- exact deployment calldata, Safe batch hash, simulation block, gas bounds, and independent
  reproduction sign-off.

Until those fields are fixed, the v3 spot position manager remains a pinned candidate rather than
a production selection. The full fixture correctly uses deterministic spot tokens while using the
production spot guard implementation, real v3 position manager, v4 PoolManager, CTF, and
Wrapped1155Factory.
