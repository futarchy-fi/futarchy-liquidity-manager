# Readiness checklist

This repository is ready for continued review and adversarial testing, not for funding. The
current Swapr Algebra implementation is a no-funds prototype because the factory owner can enable
a mutable liquidity cooldown and third-party dust mints can then block position burns indefinitely.
See `atomic-lifecycle-amendment.md`, `production-amm-successor.md`,
`production-amm-candidate-evaluation.md`, and `operations.md`.

## Evidence available now

- The proposal source validates one proposal snapshot and atomically activates the manager. A
  failure in source storage, CTF splitting, pool creation, initialization, or first mint reverts the
  complete transition. The real source-manager-router binding fixture proves that a failure on the
  second fresh position restores the source registry, both CTF splits, the spot position, and both
  pool creations; an explicit post-activation coordinator revert restores the same envelope.
- The manager stores the CTF condition and wrapper binding used for settlement rather than rereading
  mutable proposal state.
- Settlement requires exact collateral and outcome-token balance deltas from complete-set merges,
  winner redemption, and losing-token consumption; router failure, partial consumption, or
  underpayment rolls back positions and binding.
- Partial redemption removes proportional spot, YES, and NO liquidity; accounts for principal,
  fees, and six idle token balances; never restores liquidity; cannot reduce any survivor's
  per-share claim on those balances; handles divergent YES/NO liquidity and post-swap principal
  composition; assigns fees and six-token donations arriving after a conditional exit only to the
  remaining shares; settles after randomized one-to-four partial exits; and gives final rounding
  residue to the last holder.
- Unit, fuzz, invariant, API-freeze, scope, configuration, batch-template, and fork fixtures are
  machine checked in CI. The real Algebra fork suite also captures the cooldown liveness failure
  and bounds a live-fee partial removal at 150,000 gas (116,245 measured). The real Uniswap V3
  fixture exercises adapter-owned fresh pool creation, initialization, and first-NFT mint; proves
  that a zero-liquidity pre-collection materializes current fees without changing the position's
  liquidity or NFT identity; and rejects reuse of the initialized pool after final removal. The
  deterministic V3 suite also rejects an uninitialized pre-existing pool before custody changes
  and proves a failed first mint rolls back pool creation, initialization, balances, and approvals.
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
