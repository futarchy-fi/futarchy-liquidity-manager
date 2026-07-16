# Readiness checklist

This repository is ready for continued review and adversarial testing, not for funding. The
current Swapr Algebra implementation is a no-funds prototype because the factory owner can enable
a mutable liquidity cooldown and third-party dust mints can then block position burns indefinitely.
See `atomic-lifecycle-amendment.md`, `production-amm-successor.md`,
`production-amm-candidate-evaluation.md`, and `operations.md`.

## Evidence available now

- The proposal source validates one proposal snapshot and atomically activates the manager. A
  failure in source storage, either CTF split, pool creation, initialization, or first mint reverts
  the complete transition. Before completing the official write, the source hash-attests the
  target's entire captured activation snapshot; a corrupt capture rolls back both source and target
  state. Both the source and manager independently require the two base assets and four outcome
  wrappers to be six distinct accounting tokens; exhaustive tests reject every outcome-to-outcome
  and outcome-to-base alias before spot movement. An already-resolved
  condition is rejected before spot movement and rolls back the attempted official-registry write.
  The manager also requires each returned fresh-pool address to equal the adapter's canonical pair
  lookup. The real source-manager-router binding fixture proves that a direct first conditional-add
  revert or dishonest returned address restores the source registry, both CTF splits, spot
  position, pool creation, and wrapper custody; a failure on the second fresh position and an
  explicit external resolver-binding failure after activation restore the same envelope, including
  coordinator state, CTF collateral, wrapper total supply and custody, base custody, and manager
  router allowances. After successful activation, both an exact replay and a different proposal ID
  revert without changing the registry, captured binding, pools, or liquidity.
- Manager construction rejects an identical company/collateral ERC-20; direct and permissionless
  factory tests prove the invalid two-bucket configuration cannot persist.
- Manager and factory construction reject code-less token, router, adapter, guard, and AMM
  dependencies; direct tests and a failed permissionless bundle prove the invalid wiring cannot
  persist. The v4 factory rejects a code-less PoolManager even when its supplied expected hash
  matches the empty account's code hash.
- The v4 factory enforces the spot adapter's exact Uniswap v3 tick bounds and 10-tick alignment at
  construction, so an immutable out-of-range or misaligned policy cannot leave a permanently
  unusable factory deployed.
- Strict deployment preflight independently rejects that identical pair and requires the frozen
  validation policy's proposal/collateral tokens to equal the manager pair. The deployment script
  also requires code at every configured token, AMM, router, and guard address before broadcast.
- The manager stores the CTF condition and wrapper binding used for settlement rather than rereading
  mutable proposal state.
- The deadline proxy relays a finalized Reality result even when its fallback path is called after
  the deadline; it forces NO only while Reality remains unresolved, so delayed CTF relay cannot
  overturn a finalized YES answer. If Reality metadata says a normal answer is already final but
  the result read fails, the fallback now fails closed instead of misclassifying the read failure
  as an unresolved question. Explicit tests also prove that a normal answer still inside its
  challenge window and an arbitration-pending answer take the bounded NO path, as does the
  canonical unresolved-answer sentinel.
- Settlement requires exact collateral and outcome-token balance deltas from complete-set merges,
  winner redemption, and losing-token consumption. A merge or winner redemption that pays exact
  collateral while consuming too few wrappers rolls back positions and binding, as do router
  failure and underpayment. A fault on the second underlying also rolls back the first underlying's
  completed merge and losing-wrapper consumption.
- Settlement remains permissionless after the final unresolved redemption reduces share supply and
  all liquidity to zero; any subsequently donated losing wrappers are consumed before binding is
  cleared.
- Settlement stores the verified winner with its durable wrapper snapshot. Tests donate all four
  resolved wrappers after settlement and prove recovery before spot redemption, deposit pricing,
  and a later proposal activation replaces the snapshot.
- Once the owner arms the delayed emergency path, any account can execute its non-custodial unwind;
  active positions move into the manager while every share remains redeemable, and arming or
  execution does not disable settlement of the captured CTF condition.
- Every spot and conditional adapter removal receipt must equal the manager's exact token balance
  deltas. The manager derives fee/principal classification from separate zero/nonzero removal
  phases rather than trusting returned labels. Misclassification cannot change payouts, and an
  overreport cannot consume survivor-owned idle balances; the complete operation reverts.
- The native receive boundary rejects direct transfers and accepts only immutable-wrapper unwrap
  proceeds, preventing ordinary native transfers from bypassing the six-token redemption model.
- Partial redemption removes proportional spot, YES, and NO liquidity; accounts for principal,
  fees, and six idle token balances; never restores liquidity; cannot reduce any survivor's
  per-share claim on those balances; handles divergent YES/NO liquidity and post-swap principal
  composition; falls back to exact in-kind outcomes when a merge approval fails, the router
  reverts, partially consumes wrappers, or underpays; assigns fees and six-token donations arriving
  after a conditional exit only to the remaining shares; and proves a failure for one underlying
  does not prevent the other underlying from merging. It settles after randomized one-to-four
  partial exits and gives final rounding residue to the last holder. The stateful manager invariant
  campaign also interleaves deposits, activation, fees, donations, redemptions, settlement, and
  emergency arm, disarm, and permissionless execution. Settlement remains in the action set while
  emergency mode is armed or executed; every successful deposit and redemption checks
  survivor-favoring liquidity and six-token balance ratios, all six tokens remain in known custody,
  zero share supply leaves no managed asset balance, and executed emergency mode leaves no
  position liquidity.
- Independent executable rounding properties prove that floor-rounded share minting plus
  ceil-rounded accepted deposits cannot dilute either base asset, while floor-rounded liquidity,
  idle, and fee payouts cannot reduce the corresponding survivor claim per share.
- Unit, fuzz, invariant, API-freeze, scope, configuration, batch-template, and fork fixtures are
  machine checked in CI. The real Algebra fork suite also captures the cooldown liveness failure
  and bounds a live-fee partial removal at 150,000 gas (116,245 measured). Both the public-vault and
  direct Algebra fixtures prove zero-liquidity collection materializes real fees without changing
  position liquidity and that an immediately following removal reports no residual fees. The real
  Swapr NFT add also proves exact caller balance deltas, zero adapter residue, and zero residual
  position-manager allowances. The public-vault manager path preserves its spot NFT identity
  through a depositor's partial exit and clears the ID only when the final bootstrap holder redeems. The
  real Uniswap V3 fixture exercises adapter-owned fresh pool creation, initialization, and first-NFT
  mint; proves the same zero-liquidity, fee-drain, and position-identity properties; and rejects
  reuse of the initialized pool after final removal. The deterministic V3 suite also rejects an
  uninitialized pool and initialized pools at guarded or manipulated prices before custody changes,
  injects distinct pool-creation and initialization failures, and proves each failure plus a failed
  first mint rolls back pool creation, initialization, balances, and approvals.
- Runtime-size checks retain an EIP-170 margin for the manager.
- The v4 successor now has a selector-frozen initialization gate. Its exact-permission hook address,
  one-time code-bearing adapter binding, PoolManager-only callback, original-sender check, and
  self-referential pool key are unit tested. A pinned Ethereum-mainnet fork verifies the official
  PoolManager code hash and exact hook ABI.
- The selector-frozen v4 conditional adapter pins that runtime hash, binds irreversibly to one
  manager, owns one unsalted full-range position per pair, and uses no add/remove hook callbacks.
  Unit tests cover atomic first-liquidity rollback, dependency drift, donation fees, dishonest fee
  reports, second-phase fee leakage, and sequential partial/final removal. A pinned mainnet fork
  proves the same direct add, donation-fee collection, and proportional removal against the
  official PoolManager. The fork also installs a protocol-fee controller through the pinned owner,
  sets the maximum valid fee in both directions, and leaves a third party's same-key, same-ticks,
  same-salt position active while the FLM removes its own position completely; the independent
  position remains removable afterward.
- The selector-frozen v4 bundle factory now hash-pins the source, spot adapter, initialization gate,
  conditional adapter, and manager. Its effective CREATE2 salt commits to `msg.sender`; every child
  uses a domain-separated derivative, preventing another wallet from consuming or a permissionless
  intervening deployment from shifting any advertised address. The proposal source uses the
  deployed v4 adapter as its immutable singleton-pool lookup rather than retaining an unrelated
  Algebra dependency. Tests prove exact five-child prediction across interleaving, permission-bit
  enforcement, all four irreversible bindings, mutated-code rejection, and rollback of every child
  when the final manager deployment fails. A pinned fork then drives the factory-deployed
  source, canonical Ethereum CTF, router, manager, and both conditional positions through atomic
  activation and settlement against the official PoolManager and deployed Ethereum Wrapped1155
  factory. That live factory exposed a semantic-order lookup failure when deterministic wrapper
  addresses sort opposite the proposal pair; the adapter's read-only lookup now canonicalizes
  either order while mutation entry points remain strictly ordered. The candidate spot position
  manager is now codehash-pinned and exercised through spot pool creation, bootstrap mint, and
  activation removal in that same fork. The production v3 guard also enforces its real 30-minute
  history and price checks there; the fixture proves observation cardinality must be raised before
  the first mint so the initialization observation survives. Pinned dependency evidence is
  recorded in `production-mainnet-dependency-manifest.md`; final tokens, roles, exact config, salt,
  batch, and independent review remain unresolved.
  Three additional full-stack fault runs inject a revert at the canonical CTF split, the first
  official-PoolManager initialization, and the exact second official-PoolManager initialization.
  Each failed outer proposal write restores the empty registry, original spot NFT and liquidity,
  base balances, wrapper supplies and custody, and both absent conditional positions. Clearing the
  injected fault then lets the identical proposal activate, proving the failed attempt left no
  live-pool precreation veto.
- The same real-stack fork donates one complete set across both live v4 pools, then gives one holder
  one third of the shares and redeems them while the CTF condition is unresolved. The fee phase pays
  that holder its exact pro-rata original inventory plus donation within four wei. The spot NFT
  identity survives; spot, YES, and NO liquidity decrease by their exact floor-rounded shares;
  canonical CTF merges complete sets and the redeemer receives no outcome residue. A second
  complete-set donation plus a YES-company-only donation after that exit leave the exited balances
  fixed and belong entirely to the survivor. Both settlement outcomes pass. A winning donated leg
  yields LP recovery of 103 company versus 102 collateral within five wei; a losing donated leg
  leaves LP recovery at 102 versus 102 and its untouched NO-company counterpart outside the
  manager, so no losing fee is converted into base value. A third run places the single-leg fee
  before the unresolved exit: the redeemer receives its floor-rounded YES-company share in kind
  within four wei, retains the same base balance through settlement, and can redeem the winning
  wrapper independently afterward.
- The pinned block's actual gas limit is 60,000,000. Charging 21,000 base gas plus the worst-case
  16 gas for every calldata byte yields 12,125,922 gas for the atomic bundle transaction,
  2,343,088 gas for source/CTF/two-pool activation, 1,460,745 gas for symmetric donated-fee partial
  redemption, and 1,487,553 gas for asymmetric in-kind redemption. The fork asserts each remains
  below half a block, leaving more than 30,000,000 gas of explicit headroom.
- The expanded prescribed deep invariant command passes with zero reverts: each of five manager
  accounting, custody, and emergency invariants runs 256 times at depth 500 (128,000 calls each)
  across nine randomized actions, while the two UniV3 invariants retain their stricter inline
  256-by-512 configuration (131,072 calls each). The final candidate must re-run this gate after
  its exact configuration is fixed.
- The current 242-test instrumented suite also passes Foundry's coverage profile with `--ir-minimum`
  after excluding the production-profile-only artifact-hash assertion (coverage deliberately
  recompiles different bytecode). This flag is required because unoptimized instrumentation
  exceeds Solidity's stack limit. The manager reports 93.06%
  line, 91.20% statement, 67.65% branch, and 98.61% function coverage. Production compilation
  independently confirms a 24,171-byte manager runtime, 405 bytes below EIP-170.
- The current 243-test normal suite includes direct emergency-handler reachability, three
  pinned-mainnet activation rollback cases, and a fifth invariant that requires executed emergency
  mode to leave every manager position at zero liquidity. Artifact drift, permissionless bundle
  interleaving, code-less PoolManager, and immutable spot-tick-policy checks remain green.
- The current compiler profile and bare creation-code hashes for the v4 factory and all five
  children are pinned in `production-mainnet-dependency-manifest.md`; an executable drift test
  requires an explicit manifest update whenever any artifact changes.
- The mainnet-only factory deployment handoff reads a reviewable config, refuses any dependency
  runtime-codehash drift or router dependency mismatch, hard-pins the official v3 position manager
  and v4 PoolManager, and emits a config-linked factory artifact. It deliberately cannot create a
  bundle or select unresolved roles, tokens, validation, salt, or funding.

## Atomic rollback evidence map

| Failure boundary | Direct adversarial evidence |
| --- | --- |
| Source write or activation target | `test_activation_revert_rolls_back_source_write`; every corrupt captured field is also faulted independently. |
| Resolved condition or spot guard | `test_activation_rejects_resolved_condition_before_removing_spot`; `test_activation_guard_failure_rolls_back_every_side_effect`. |
| Either CTF split leg | `test_atomic_activation_uses_captured_source_snapshot` injects a receipt shortfall for company and collateral separately and checks source, spot, CTF, router, allowance, wrapper, and adapter state. |
| Canonical mainnet CTF split | `testFork_realCtfSplitFailureRollsBackAndRetrySucceeds` faults the deployed CTF call after real v3 spot removal, checks the outer registry/spot/wrapper/adapter envelope, then retries successfully. |
| First conditional pool/add | The same full binding test injects first-add and post-add accounting failures and proves the created pool, split wrappers, and spot removal all roll back. |
| Second conditional pool | `test_activation_rolls_back_first_pool_when_second_pool_is_precreated` proves the newly created first pool disappears while the adversarial second pool remains. |
| First or second official mainnet v4 initialization | `testFork_firstRealV4InitializeFailureRollsBackAndRetrySucceeds` and `testFork_secondRealV4InitializeFailureRollsBackAndRetrySucceeds` fault each deployed PoolManager boundary, prove prior live-stack effects disappear, and retry the identical activation. |
| AMM create, initialize, or first mint | `test_freshAddPoolCreateAndInitializeFailuresRollBack`, `test_freshAddFirstMintFailureRollsBackPoolAndCustody`, and `test_firstLiquidityFailureRollsBackInitializationAndCustody`. |
| Outer lifecycle step after successful activation | `test_atomic_activation_uses_captured_source_snapshot` forces its resolver step to revert and compares the complete source, manager, spot, CTF, router, wrapper, pool, balance, and allowance envelope. |
| Atomic bundle deployment/wiring | `test_lateManagerFailureRollsBackHookAndEveryCreate`, `test_sameTokenManagerFailureAlsoRollsBackMinedHook`, and the empty-runtime/initcode/hash fault cases. |

## Required before any funded deployment

- Promote the implemented v4 successor only after its final spot dependency and exact
  deployment configuration satisfy every requirement in `production-amm-successor.md`, including
  immutable burn liveness and materially larger gas headroom.
- Re-run the complete unit and invariant suite on the final candidate, then repeat the deeper pass:

  ```sh
  FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=500 \
    forge test --match-path 'test/invariant/*'
  ```

- Add fork tests for the selected production AMM, final proposal registry, CTF/router, token pair,
  and deployment configuration.
- Complete external review of the source, manager, router, stability guard, factory, and selected
  adapter.
- Independently review the owner, lifecycle coordinator, bootstrap recipient, emergency process,
  and every generated Safe batch before signing.

Do not sign or fund the committed Algebra production/example batches. They remain schema and
historical canary evidence only.
