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
  state. An already-resolved condition is rejected before spot movement and rolls back the attempted
  official-registry write.
  The manager also requires each returned fresh-pool address to equal the adapter's canonical pair
  lookup. The real source-manager-router binding fixture proves that a direct first conditional-add
  revert or dishonest returned address restores the source registry, both CTF splits, spot
  position, pool creation, and wrapper custody; a failure on the second fresh position and an
  explicit external resolver-binding failure after activation restore the same envelope, including
  coordinator state. After successful activation, both an exact replay and a different proposal ID
  revert without changing the registry, captured binding, pools, or liquidity.
- The manager stores the CTF condition and wrapper binding used for settlement rather than rereading
  mutable proposal state.
- Settlement requires exact collateral and outcome-token balance deltas from complete-set merges,
  winner redemption, and losing-token consumption. A merge or winner redemption that pays exact
  collateral while consuming too few wrappers rolls back positions and binding, as do router
  failure and underpayment. A fault on the second underlying also rolls back the first underlying's
  completed merge and losing-wrapper consumption.
- Every spot and conditional adapter removal receipt must equal the manager's exact token balance
  deltas. The manager derives fee/principal classification from separate zero/nonzero removal
  phases rather than trusting returned labels. Misclassification cannot change payouts, and an
  overreport cannot consume survivor-owned idle balances; the complete operation reverts.
- Partial redemption removes proportional spot, YES, and NO liquidity; accounts for principal,
  fees, and six idle token balances; never restores liquidity; cannot reduce any survivor's
  per-share claim on those balances; handles divergent YES/NO liquidity and post-swap principal
  composition; falls back to exact in-kind outcomes when a merge approval fails, the router
  reverts, partially consumes wrappers, or underpays; assigns fees and six-token donations arriving
  after a conditional exit only to the remaining shares; and proves a failure for one underlying
  does not prevent the other underlying from merging. It settles after randomized one-to-four
  partial exits and gives final rounding residue to the last holder. The stateful manager invariant
  campaign also interleaves
  deposits, activation, fees, donations, redemptions, and settlement; every successful deposit and
  redemption checks survivor-favoring liquidity and six-token balance ratios, all six tokens remain
  in known custody, and zero share supply leaves no managed asset balance.
- Unit, fuzz, invariant, API-freeze, scope, configuration, batch-template, and fork fixtures are
  machine checked in CI. The real Algebra fork suite also captures the cooldown liveness failure
  and bounds a live-fee partial removal at 150,000 gas (116,245 measured). Both the public-vault and
  direct Algebra fixtures prove zero-liquidity collection materializes real fees without changing
  position liquidity and that an immediately following removal reports no residual fees. The
  real Uniswap V3 fixture exercises adapter-owned fresh pool creation, initialization, and first-NFT
  mint; proves the same zero-liquidity, fee-drain, and position-identity properties; and rejects
  reuse of the initialized pool after final removal. The deterministic V3 suite also rejects an
  uninitialized pool and initialized pools at guarded or manipulated prices before custody changes,
  injects distinct pool-creation and initialization failures, and proves each failure plus a failed
  first mint rolls back pool creation, initialization, balances, and approvals.
- Runtime-size checks retain an EIP-170 margin for the manager.

## Required before any funded deployment

- Replace the Algebra conditional adapter with an AMM integration satisfying every requirement in
  `production-amm-successor.md`, including immutable burn liveness and materially larger gas
  headroom.
- Re-run the complete unit and invariant suite, then run a deeper invariant pass:

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
