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
  revert without changing the registry, captured binding, pools, or liquidity. The same real
  source-manager-router fixture then performs a proportional unresolved exit and settlement,
  injects a first-add failure into a second policy-valid proposal, proves the empty registry,
  surviving spot slice, idle base custody, and fresh pool lookups all restore, and completes the
  identical second activation.
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
- Settlement stores the verified winner with its durable wrapper snapshot. Tests first perform a
  proportional unresolved redemption, settle without redeploying recovered inventory, donate
  resolved wrappers, and prove recovery before spot redemption, deposit pricing, and a later
  proposal activation replaces the snapshot.
- Once the owner arms the delayed emergency path, any account can execute its non-custodial unwind;
  active positions move into the manager, the redemption entry point remains enabled, and arming
  or execution does not disable settlement of the captured CTF condition. A nonfinal redemption
  whose share of every active position floors to zero liquidity reverts without burning shares;
  the holder must combine or transfer shares until at least one unit is withdrawable.
- Every spot and conditional adapter removal receipt must equal the manager's exact token balance
  deltas. The manager derives fee/principal classification from separate zero/nonzero removal
  phases rather than trusting returned labels. Misclassification cannot change payouts, and an
  overreport cannot consume survivor-owned idle balances; the complete operation reverts.
- Every ERC20 payout and zero-supply sweep requires the recipient's balance to increase by exactly
  the reported amount. A regression enables a company-token recipient fee only after bootstrap,
  proves redemption restores shares and liquidity instead of silently underpaying, then disables
  the fee and completes the identical exit. After a final unresolved redemption burns all shares,
  a separate regression faults the fourth captured-wrapper sweep, proves the preceding three
  wrapper payments roll back, and then transfers all four exact balances to the bootstrap recipient
  on the identical retry.
- CTF split collateral and every spot or conditional adapter refund also require exact recipient
  deltas. Late-fee regressions prove an underpaid CTF split restores collateral and wrapper state,
  and an underpaid refund restores the complete v3 NFT or v4 position change before exact retry.
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
- Independent company-token, wrapped-collateral, and post-unwrap native-delivery faults after all
  three proportional removals and both complete-set merges roll back the share burn, manager and
  adapter liquidity, removal counters, and six-token manager/adapter/router/recipient custody. The
  later faults also roll back the recipient's preceding company-token transfer, while rejected
  native delivery restores the burned WETH and native balances. Clearing the faults lets the
  identical native redemption succeed. A gas-forwarded native callback that attempts a nested
  redemption is rejected by the guard while the outer exit completes with exact shares and payout.
- When both complete-set merges fall back to in-kind outcomes, independent faults on each of the
  four wrapper transfers restore every earlier wrapper payment plus the complete redemption state.
  Clearing the fault lets the identical exit pay the exact base and four-wrapper slice.
- Independent executable rounding properties prove that floor-rounded share minting plus
  ceil-rounded accepted deposits cannot dilute either base asset, while floor-rounded liquidity,
  idle, and fee payouts cannot reduce the corresponding survivor claim per share. A direct unit
  test proves an all-zero nonfinal liquidity plan reverts without burning the dust holder's shares,
  then succeeds after that holder combines enough shares.
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
  Ten full-stack fault runs inject a revert at official-v3 spot principal removal, each canonical
  CTF split, wrapper conversion on each underlying, each official-PoolManager initialization and
  first-liquidity call, and source capture verification after activation completes. Each failed
  outer proposal write restores the empty registry, actual
  spot NFT and liquidity, base custody and allowances, CTF underlying custody, wrapper supplies
  and custody, PoolManager balances, and both absent conditional positions. Clearing the injected
  fault then lets the identical proposal activate, proving the failed attempt left no live-pool
  precreation veto.
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
  wrapper independently afterward. A fourth run first faults the second proportional adapter
  removal after the first official-v4 unwind and proves shares, both positions, the spot identity,
  and all six holder/manager/PoolManager balances roll back. Its identical retry then faults the
  canonical company-side CTF merge: collateral still merges, the company slice is paid as exact
  YES/NO wrappers, and the holder later redeems the winner and consumes the loser. Survivor
  settlement plus final exit conserves both base assets within five wei. A fifth run faults the
  canonical collateral-side CTF merge after
  both v4 removals and company merge/winner recovery. The failed sync restores the captured
  binding/accounting, adapter positions, PoolManager balances, CTF collateral/underlying custody,
  wrapper supply/custody, and allowances; the identical retry and final exit then succeed.
  A sixth run arms emergency mode with donated fees live and lets an unrelated account begin the
  delayed unwind. A fault at the second adapter removal restores the first official-v4 position,
  both custody envelopes, manager accounting, and the unexecuted emergency flag. The identical
  outsider retry unwinds both positions without receiving shares or assets. A one-third holder
  then redeems against the still-unresolved canonical CTF and receives its proportional base value
  within five wei with no outcome residue. The captured proposal remains intact,
  source-independent settlement succeeds for the survivor, and aggregate final recovery remains
  within five wei per base asset.
  Seventh and eighth runs stop before proposal activation and arm emergency mode while the
  official-v3 spot NFT is live. One faults principal removal after fee collection; the other faults
  NFT burn after fee collection, full principal removal, and principal collection. Each restores
  the NFT/liquidity, manager/adapter/v3-pool/NPM balances, share supply, and the unexecuted emergency
  flag. The identical outsider retry receives no shares or tokens, and final shareholder redemption
  recovers both bootstrap assets within two wei.
- The pinned block's actual gas limit is 60,000,000. Charging 21,000 base gas plus the worst-case
  16 gas for every calldata byte yields 12,125,922 gas for the atomic bundle transaction,
  2,343,088 gas for source/CTF/two-pool activation, 1,460,745 gas for symmetric donated-fee partial
  redemption, 1,487,553 gas for asymmetric in-kind redemption, and 1,417,015 gas for the
  canonical-merge-failure fallback. The fork asserts each remains below half a block, leaving more
  than 30,000,000 gas of explicit headroom.
- The expanded prescribed deep invariant command passes with zero reverts: each of five manager
  accounting, custody, and emergency invariants runs 256 times at depth 500 (128,000 calls each)
  across nine randomized actions, while the two UniV3 invariants retain their stricter inline
  256-by-512 configuration (131,072 calls each). The final candidate must re-run this gate after
  its exact configuration is fixed.
- The current 262-test instrumented suite also passes Foundry's coverage profile with `--ir-minimum`
  after excluding the production-profile-only artifact-hash assertion (coverage deliberately
  recompiles different bytecode). This flag is required because unoptimized instrumentation
  exceeds Solidity's stack limit. The manager reports 93.12%
  line, 91.29% statement, 67.96% branch, and 98.63% function coverage. Production compilation
  independently confirms a 24,399-byte manager runtime, 177 bytes below EIP-170 and 49 bytes below
  the repository's stricter ceiling.
- The current 263-test normal suite includes direct emergency-handler reachability, ten
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
| Official mainnet v3 spot removal | `testFork_spotRemovalFailureRollsBackAndRetrySucceeds` faults principal removal after the real fee-collection phase, restores actual NFT liquidity and the outer envelope, then retries successfully. |
| Both canonical mainnet CTF splits | `testFork_firstRealCtfSplitFailureRollsBackAndRetrySucceeds` and `testFork_secondRealCtfSplitFailureRollsBackAndRetrySucceeds` fault each deployed CTF call, including after the first underlying completed, compare base/CTF custody and allowances, then retry successfully. |
| CTF receives less collateral than the wrappers minted | `test_split_rejects_late_ctf_transfer_fee_without_minting_wrappers` enables a fee only for the CTF recipient, proves user collateral plus wrapper/underlying state restore, then retries the identical split fee-free. |
| Deployed wrapper conversion for either underlying | `testFork_firstRealWrapperMintFailureRollsBackAndRetrySucceeds` and `testFork_secondAssetRealWrapperMintFailureRollsBackAndRetrySucceeds` fault the canonical ERC1155-to-ERC20 conversion before the first and after the complete first underlying, restore CTF/wrapper custody and supply, then retry successfully. |
| First conditional pool/add | The same full binding test injects first-add and post-add accounting failures and proves the created pool, split wrappers, and spot removal all roll back. It repeats the first-add fault after a proportional exit and settlement, proves the reduced spot slice and idle survivor custody restore with no registry or fresh pools, then activates the identical second proposal. |
| Second conditional pool | `test_activation_rolls_back_first_pool_when_second_pool_is_precreated` proves the newly created first pool disappears while the adversarial second pool remains. |
| First or second official mainnet v4 initialization/liquidity | `testFork_firstRealV4InitializeFailureRollsBackAndRetrySucceeds`, `testFork_firstRealV4LiquidityFailureRollsBackAndRetrySucceeds`, `testFork_secondRealV4InitializeFailureRollsBackAndRetrySucceeds`, and `testFork_secondRealV4LiquidityFailureRollsBackAndRetrySucceeds` fault each deployed PoolManager boundary, prove prior live-stack effects and any pool initialization disappear, and retry the identical activation. |
| Spot or conditional adapter refund underpays the manager | `test_refundRejectsLateTransferFeeAndRollsBackPosition` and `test_prefundedRefundRejectsLateTransferFeeAndRollsBackPosition` enable fees only on the manager refund, restore the v3 NFT or fresh v4 position and all custody, then complete the identical add fee-free. |
| Second conditional removal during proportional redemption | `testFork_lateRemovalRollbackThenCompanyMergeFailureRemainsRedeemable` completes the proportional YES removal before faulting the NO adapter boundary, then proves LP shares, both positions, spot identity, and all six holder/manager/PoolManager balances roll back. |
| Canonical mainnet CTF merge during redemption | The identical retry in `testFork_lateRemovalRollbackThenCompanyMergeFailureRemainsRedeemable` faults the company merge, proves collateral still merges and exact YES/NO company wrappers are paid in kind, then redeems/consumes those wrappers after resolution and conserves both assets through survivor settlement and final exit. |
| Successful ERC20 call underpays its recipient | `test_redemption_rejects_late_transfer_fee_without_burning_shares` enables a company-token recipient fee only after bootstrap. The exact recipient-delta check restores shares and liquidity, and the identical redemption succeeds after the fee is disabled. |
| Router merge underpays its direct caller | `test_merge_rejects_late_transfer_fee_without_consuming_wrappers` enables a fee only for the caller, restores both complete-set wrappers and collateral custody, then completes the identical merge fee-free. |
| Any in-kind outcome transfer during proportional redemption | `test_each_in_kind_outcome_transfer_failure_rolls_back_complete_redemption` forces both merges into fallback, then independently faults each of the four exact wrapper transfers. Every case restores shares, spot/YES/NO liquidity, removal counters, managed/router custody, and any preceding wrapper payments before the identical retry pays the exact base and four-wrapper slice. |
| Fourth captured-wrapper transfer during a zero-supply sweep | `test_zero_supply_outcome_sweep_rolls_back_and_retries_atomically` donates all four active outcomes after the final unresolved share burn, faults the fourth transfer, proves the prior three payments restore, then sweeps every exact balance to the bootstrap recipient on retry. |
| Each final recipient payout path during proportional redemption | `test_each_final_payout_failure_rolls_back_complete_conditional_redemption` independently faults the exact company-token transfer, wrapped-collateral transfer, and native delivery after unwrap. Each occurs after spot/YES/NO removal, share burn, and both complete-set merges; the later faults occur after company payment, and native delivery also occurs after WETH withdrawal. Every case restores shares, liquidity, removal counters, and token/native custody before the identical native retry succeeds. |
| Native recipient reenters redemption during payout | `test_native_payout_blocks_reentrant_redemption_without_blocking_outer_exit` gives the recipient remaining shares and forwards native payout gas to its callback. The nested redemption is rejected while the outer proportional burn, liquidity reduction, and exact company/native payment complete. |
| Late canonical mainnet CTF merge during settlement | `testFork_lateRealSettlementMergeFailureRollsBackAndRetrySucceeds` proves both v4 removals and company merge/winner redemption execute before the collateral fault, compares captured binding/accounting plus actual protocol custody and positions, then completes the identical settlement after clearing the fault. |
| Second conditional removal during emergency unwind | `testFork_outsiderEmergencyRollbackKeepsUnresolvedRedemptionLive` executes the first official-v4 removal before faulting the second adapter boundary, proves both positions, PoolManager/manager custody, accounting, shares, and the emergency flag roll back, then completes the identical outsider retry, unresolved shareholder redemption, and source-independent survivor settlement. |
| Official-v3 spot emergency unwind | `testFork_outsiderSpotEmergencyRollbackPreservesSharesAndAssets` faults principal removal after fee collection; `testFork_outsiderSpotEmergencyBurnRollbackPreservesSharesAndAssets` faults NFT burn after fee collection, full principal removal, and principal collection. Both prove the NFT/liquidity, manager/adapter/v3-pool/NPM balances, shares, and emergency flag restore, then let the same outsider retry with zero gain and recover both bootstrap assets within two wei. |
| AMM create, initialize, or first mint | `test_freshAddPoolCreateAndInitializeFailuresRollBack`, `test_freshAddFirstMintFailureRollsBackPoolAndCustody`, and `test_firstLiquidityFailureRollsBackInitializationAndCustody`. |
| Outer lifecycle step after successful activation | `test_atomic_activation_uses_captured_source_snapshot` covers the complete mock envelope. `testFork_postActivationVerificationFailureRollsBackAndRetrySucceeds` faults the source capture read only after the real manager activation completes, restores the source, spot NFT, CTF/wrapper custody, and both official-v4 positions, then retries the identical proposal. |
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
