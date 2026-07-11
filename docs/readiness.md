# Readiness Checklist

This file tracks the remaining gap between this repository and a limited-funds real deployment.
The machine-checkable evidence index is `audit/readiness-evidence.json`; CI validates it with
`tools/check-readiness-evidence.sh`.

## Limited Gnosis Canary

The reviewed ownerless stability guard and hash-pinned permissionless factory are deployed on
Gnosis. `config/gnosis.fao-canary.json` and `deployments/flm.gnosis.fao-canary.json` record the
exact configuration, runtime hashes, addresses, and transactions. A disposable GNO/sDAI bundle
was bootstrapped and partially redeemed successfully. When the live spot pool moved outside the
50-tick/30-minute guard, redemption still completed and restoration was safely deferred with all
remaining assets idle, share-owned, and redeemable. This proves the withdrawal failure boundary;
it is not approval to scale value before external review and a conditional lifecycle canary.

## Ready To Audit

- API and scope freeze: no FAO-specific imports, sale contracts, SnapshotX contracts, or
  deployment-specific custody paths in `src/`. CI enforces this with `tools/check-scope.sh`.
- API selector freeze: audited contract method identifiers are snapshotted in `audit/api-freeze`
  and checked by `tools/check-api-freeze.sh`.
- Unit and fuzz tests: core manager, proportional LP share mint/redeem behavior, proposal source
  validation, deadline proxy, accrued-fee/idle-balance accounting, conditional in-kind fallback,
  non-custodial emergency exit, and adapter safety checks, including exact TWAP-deviation
  boundaries and fail-closed history reads.
- Invariant tests: LP supply is backed by managed liquidity, conditional accounting is internally
  consistent, and adapter liquidity accounting matches manager state across deposit, redeem,
  migrate, and settle cycles.
- Fork tests: env-gated Gnosis checks for Swapr Algebra NFPM, real full-unwind spot and conditional
  share-operation gas, deployed proposal shape, CTF condition wiring, Reality question wiring, and
  futarchy router splitting.
- CI: `forge build`, `forge fmt --check`, `forge test`, and coverage summary.
- Config validation: CI checks deployment and batch example schemas, and strict mode rejects real
  configs with placeholder addresses, missing validation, or zero operation amounts.
- Operation templates: bootstrap, add-liquidity, redeem, sync migrate/settle, proposal setup, and
  emergency-control Safe batch configs are separated for independent calldata review and generated
  in CI.
- Docs: audit scope, dependency surface, deployment flow, FAO integration boundary, and operation
  batch flow.
- NatSpec: integration interfaces, proposal-source views, fixed manager execution policy, and the
  generic adapter boundary are documented for auditors and downstream integrators.

## Still Required Before Mainnet-Value Deployment

- Fill and independently review a concrete deployment config for the target organization.
- Deploy and verify one shared `AlgebraPoolStabilityGuard`, then put its address in each manager or
  factory deployment config using the same Algebra factory.
- Run `tools/preflight-limited-deploy.sh --deploy <final-config> --deployment-output
  <deploy-output> --batch <final-batch-config> ... --proposal <final-proposal> --run-fork-tests`
  for every real batch, then retain the generated summaries with the audit materials.
- Run `RUN_GNOSIS_FORK_TESTS=true forge test --match-path 'test/fork/*'` against the selected
  target proposal/token addresses.
- Generate Safe batches from final operation configs and audit the calldata before signing.
- Run a deeper invariant pass, for example:

  ```sh
  forge test --match-path 'test/invariant/*' --invariant-runs 256 --invariant-depth 500
  ```

- Complete an external review of `src/core`, `src/sources`, `src/oracles`, `src/interfaces`, and
  the selected adapter.
- Document the deployed owner Safe, proposal manager, bootstrap recipient, emergency signers, and
  monitoring process.
