# Readiness Checklist

This file tracks the remaining gap between this repository and a limited-funds real deployment.

## Ready To Audit

- API and scope freeze: no FAO-specific imports, sale contracts, SnapshotX contracts, or
  deployment-specific custody paths in `src/`. CI enforces this with `tools/check-scope.sh`.
- API selector freeze: audited contract method identifiers are snapshotted in `audit/api-freeze`
  and checked by `tools/check-api-freeze.sh`.
- Unit and fuzz tests: core manager, proportional LP share mint/redeem behavior, proposal source
  validation, deadline proxy, bad-proposal exit safety, emergency exit destination safety, and
  adapter safety checks.
- Invariant tests: LP supply is backed by managed liquidity, conditional accounting is internally
  consistent, and adapter liquidity accounting matches manager state across deposit, redeem,
  migrate, and settle cycles.
- Fork tests: env-gated Gnosis checks for Swapr Algebra NFPM, deployed proposal shape, CTF
  condition wiring, Reality question wiring, and futarchy router splitting.
- CI: `forge build`, `forge fmt --check`, `forge test`, and coverage summary.
- Config validation: CI checks deployment and batch example schemas, and strict mode rejects real
  configs with placeholder addresses, missing validation, missing deadlines, or zero slippage
  minimums.
- Operation templates: bootstrap, add-liquidity, redeem, sync migrate/settle, proposal setup, and
  emergency-control Safe batch configs are separated for independent calldata review and generated
  in CI.
- Docs: audit scope, dependency surface, deployment flow, FAO integration boundary, and operation
  batch flow.
- NatSpec: integration interfaces, proposal-source views, and adapter slippage/deadline parameters
  are documented at the code boundary used by auditors and downstream integrators.

## Still Required Before Mainnet-Value Deployment

- Fill and independently review a concrete deployment config for the target organization.
- Run `tools/validate-configs.sh --deploy <final-config>` and
  `tools/validate-configs.sh --batch <final-batch-config>` for every real batch.
- Run `RUN_GNOSIS_FORK_TESTS=true forge test --match-path 'test/fork/*'` against the selected
  target proposal/token addresses.
- Generate Safe batches from final operation configs and audit the calldata before signing.
- Run a deeper invariant pass, for example:

  ```sh
  forge test --match-path 'test/invariant/*' --invariant-runs 256 --invariant-depth 500
  ```

- Complete an external review of `src/core`, `src/sources`, `src/oracles`, `src/interfaces`, and
  the selected adapter.
- Document the deployed owner Safe, bootstrap recipient, emergency signers, and monitoring process.
