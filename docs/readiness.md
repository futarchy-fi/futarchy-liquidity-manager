# Readiness checklist

This repository is ready for continued review and adversarial testing, not for funding. The
current Swapr Algebra implementation is a no-funds prototype because the factory owner can enable
a mutable liquidity cooldown and third-party dust mints can then block position burns indefinitely.
See `atomic-lifecycle-amendment.md`, `production-amm-successor.md`, and `operations.md`.

## Evidence available now

- The proposal source validates one proposal snapshot and atomically activates the manager. A
  failure in source storage, CTF splitting, pool creation, initialization, or first mint reverts the
  complete transition.
- The manager stores the CTF condition and wrapper binding used for settlement rather than rereading
  mutable proposal state.
- Partial redemption removes proportional spot, YES, and NO liquidity; accounts for principal,
  fees, and six idle token balances; never restores liquidity; and gives final rounding residue to
  the last holder.
- Unit, fuzz, invariant, API-freeze, scope, configuration, batch-template, and fork fixtures are
  machine checked in CI. The real Algebra fork suite also captures the cooldown liveness failure.
- Runtime-size checks retain an EIP-170 margin for the manager.

## Required before any funded deployment

- Replace the Algebra conditional adapter with an AMM integration satisfying every requirement in
  `production-amm-successor.md`, including immutable burn liveness and materially larger gas
  headroom.
- Re-run the complete unit and invariant suite, then run a deeper invariant pass:

  ```sh
  forge test --match-path 'test/invariant/*' --invariant-runs 256 --invariant-depth 500
  ```

- Add fork tests for the selected production AMM, final proposal registry, CTF/router, token pair,
  and deployment configuration.
- Complete external review of the source, manager, router, stability guard, factory, and selected
  adapter.
- Independently review the owner, lifecycle coordinator, bootstrap recipient, emergency process,
  and every generated Safe batch before signing.

Do not sign or fund the committed Algebra production/example batches. They remain schema and
historical canary evidence only.
