# Futarchy Liquidity Manager

Audit-oriented smart contract package for generic futarchy liquidity management.

The core idea is that LPs deposit a company token and collateral once, receive FLM shares, and the
manager handles spot liquidity, source-atomic conditional YES/NO activation during an official
proposal, and CTF settlement back to share-owned base inventory.

Public deposits are accepted only in spot mode and in the vault's existing two-asset proportion.
Redemption is always available, including conditional and emergency modes. A redemption removes
only its proportional liquidity, principal, fee, and idle slices; it never redeploys survivor
assets. Callers supply no adapter ticks, slippage, deadlines, or initialization prices.

The current Swapr Algebra path is a no-funds prototype because permissionless pool precreation and
a mutable burn cooldown violate the production threat model. See
[`docs/readiness.md`](docs/readiness.md).

FAO production targets Ethereum mainnet. The selected successor uses the official Uniswap v4
PoolManager plus an initialization-only hook and a direct manager-bound conditional adapter. The
caller-bound CREATE2 factory now deploys and irreversibly binds that bundle atomically. The
repository remains unfundable until the [draft mainnet dependency manifest](docs/production-mainnet-dependency-manifest.md)
is completed and the exact production-config
rehearsal, plus external and legal review, are complete.

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

Adapter and deployment audit scope also includes `src/adapters/`, `src/routers/`, and
`src/factories/`. None of the current Algebra deployment artifacts are approved for funding.

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

Run the selected successor's initialization gate against the official Ethereum PoolManager:

```sh
RUN_MAINNET_FORK_TESTS=true \
  forge test --match-contract V4InitializationGateMainnetForkTest
```

Run its direct add, donation-fee collection, and proportional-removal lifecycle:

```sh
RUN_MAINNET_FORK_TESTS=true \
  forge test --match-contract V4ConditionalLiquidityAdapterMainnetForkTest
```

Run the factory-deployed source/CTF/two-pool activation and settlement lifecycle:

```sh
RUN_MAINNET_FORK_TESTS=true \
  forge test --match-contract V4FutarchyLiquidityManagerLifecycleMainnetForkTest
```

Generate a deployment from explicit JSON config:

```sh
FLM_ALGEBRA_FACTORY=0x... \
forge script script/DeployAlgebraPoolStabilityGuard.s.sol \
  --rpc-url gnosis \
  --broadcast

# Deploy the canonical permissionless factory once with the reviewed shared dependencies.
PRIVATE_KEY=... \
FLM_POSITION_MANAGER=0x... \
FLM_ALGEBRA_FACTORY=0x... \
FLM_CONDITIONAL_ROUTER=0x... \
FLM_POOL_STABILITY_GUARD=0x... \
FLM_WRAPPED_NATIVE=0x... \
forge script script/DeployFutarchyLiquidityManagerFactory.s.sol \
  --rpc-url gnosis \
  --broadcast

# Put the shared guard and factory addresses in the deploy config before validating.
tools/validate-configs.sh --deploy config/gnosis.production.json

FLM_DEPLOY_CONFIG=config/gnosis.production.json \
FLM_DEPLOY_OUTPUT=deployments/flm.gnosis.json \
forge script script/DeployFutarchyLiquidityManager.s.sol \
  --rpc-url gnosis \
  --broadcast
```

Generate a Safe transaction-builder batch:

```sh
tools/validate-configs.sh --batch config/batches/bootstrap.production.json

FLM_BATCH_CONFIG=config/batches/bootstrap.production.json \
FLM_BATCH_OUTPUT=out/flm-safe-batch.json \
forge script script/BuildLiquidityOperationBatch.s.sol
```
