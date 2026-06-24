# Futarchy Liquidity Manager

Audit-oriented smart contract package for generic futarchy liquidity management.

The core idea is that LPs deposit a company token and collateral once, receive FLM shares,
and the manager handles spot liquidity, conditional YES/NO migration during an official
proposal, and return to spot after settlement.

## Layout

- `src/core/` - generic audited FLM state machine.
- `src/sources/` - official proposal source and on-chain proposal validation.
- `src/oracles/` - deadline-bounded Reality/CTF settlement helpers.
- `src/adapters/` - protocol-specific liquidity adapters.
- `src/interfaces/` - minimal external dependency interfaces.
- `script/` - JSON-configured deployment and Safe batch helpers.
- `test/` - focused unit tests and protocol mocks.
- `docs/` - design notes, threat model, and audit-scope material.

## Audit Boundary

Primary audit scope:

- `src/core/FutarchyLiquidityManager.sol`
- `src/sources/FutarchyOfficialProposalSource.sol`
- `src/oracles/DeadlineBoundedRealityProxy.sol`
- `src/interfaces/*.sol`

Adapter audit scope:

- `src/adapters/SwaprAlgebraLiquidityAdapter.sol`

Out of scope for this package:

- FAO sale contracts.
- SnapshotX arbitration/evaluator contracts.
- Frontend and SDK code.
- Deployment scripts for a specific organization.

FAO should integrate with this package by deploying/configuring these generic contracts. This
package should not import FAO-specific contracts.

## Test

```sh
git submodule update --init --recursive
forge test
```

Run Gnosis fork checks explicitly:

```sh
RUN_GNOSIS_FORK_TESTS=true forge test --match-path 'test/fork/*'
```

Generate a deployment from explicit JSON config:

```sh
FLM_DEPLOY_CONFIG=config/gnosis.example.json \
FLM_DEPLOY_OUTPUT=deployments/flm.gnosis.json \
forge script script/DeployFutarchyLiquidityManager.s.sol \
  --rpc-url gnosis \
  --broadcast
```

Generate a Safe transaction-builder batch:

```sh
FLM_BATCH_CONFIG=config/safe-batch.example.json \
FLM_BATCH_OUTPUT=out/flm-safe-batch.json \
forge script script/BuildLiquidityOperationBatch.s.sol
```
