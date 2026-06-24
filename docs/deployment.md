# Deployment

Deployments are configured from JSON so addresses and bounds are reviewable before broadcasting.
Do not edit addresses directly inside scripts for a real deployment.

## Config

Start from `config/gnosis.example.json` and create a deployment-specific copy outside the example,
for example:

```sh
cp config/gnosis.example.json config/gnosis.fao.json
```

Required organization-specific fields:

- `owner`: owner of the proposal source and liquidity manager emergency controls, ideally a Safe.
- `bootstrapRecipient`: account allowed to call `initializeFromBootstrap`; for FAO this should be
  the integration contract or Safe that initially funds liquidity.
- `companyToken`: the token paired against wrapped native collateral.
- `officialProposer`: the only proposal creator whose official proposal can trigger migration.
- `lpTokenName` and `lpTokenSymbol`: ERC20 metadata for FLM shares.

Gnosis defaults included in the example:

- `wrappedNative`: WXDAI.
- `positionManager`: Swapr Algebra non-fungible position manager.
- `algebraFactory`: Swapr Algebra factory.
- `futarchyRouter`: futarchy conditional split/merge/redeem router.
- `deadlineProxy.conditionalTokens`: canonical Conditional Tokens Framework address.

Validation fields are explicit even when disabled. For production, prefer enabling validation before
setting an official proposal. If `deployDeadlineProxy` is true and `validation.trustedOracle` is
zero, the deployment script uses the newly deployed `DeadlineBoundedRealityProxy`.

## Broadcast

```sh
PRIVATE_KEY=... \
FLM_DEPLOY_CONFIG=config/gnosis.fao.json \
FLM_DEPLOY_OUTPUT=deployments/flm.gnosis.json \
forge script script/DeployFutarchyLiquidityManager.s.sol \
  --rpc-url gnosis \
  --broadcast \
  --verify
```

The script writes deployed addresses to `FLM_DEPLOY_OUTPUT`. Review that output before generating
liquidity or proposal batches.

## Limited-Funds Deployment Order

1. Deploy the FLM stack from a reviewed JSON config.
2. Verify deployed bytecode and constructor arguments.
3. Configure proposal validation if it was not configured during deployment.
4. Generate and audit the bootstrap liquidity Safe batch.
5. Execute with limited funds first.
6. Confirm spot position token id and balances.
7. Only then set an official proposal and generate sync batches.

## No Docker Requirement

The repository uses Foundry directly. The deployment and batch scripts do not require Docker.
