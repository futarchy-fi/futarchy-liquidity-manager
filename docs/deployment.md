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
zero, the deployment script uses the newly deployed `DeadlineBoundedRealityProxy`. Enabled
validation is constructor-initialized on the proposal source, so the owner can be a Safe from the
first deployed state.

## Production Preflight

Example configs intentionally contain zero placeholders. Before broadcasting a real deployment, run
the limited-funds preflight on the reviewed deploy config:

```sh
tools/preflight-limited-deploy.sh \
  --deploy config/gnosis.fao.json
```

After the deployment output exists and before signing any operation batch, run preflight on the
reviewed deploy config, deployment output, and every batch intended for signing:

```sh
tools/preflight-limited-deploy.sh \
  --deploy config/gnosis.fao.json \
  --deployment-output deployments/flm.gnosis.json \
  --batch config/batches/bootstrap.production.json \
  --batch config/batches/set-proposal-validation.production.json \
  --proposal <final-futarchy-proposal> \
  --run-fork-tests
```

The preflight runs strict config validation, renders every batch to Safe transaction-builder JSON
plus a Markdown summary, checks that batch targets match the deployment output when
`--deployment-output` is supplied, and optionally runs the Gnosis fork tests against the selected
proposal, company token, and collateral token. When `--run-fork-tests` is supplied, the proposal
must be provided with `--proposal` or by a `setOfficialProposal` batch; the company and collateral
token addresses come from the deploy config unless `TEST_COMPANY_TOKEN` or
`TEST_COLLATERAL_TOKEN` are set explicitly. Strict validation rejects zero deployment addresses and
requires proposal validation to be enabled with real Reality/CTF/arbitrator bounds. CI validates
placeholder examples separately in `--allow-placeholders` mode.

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

The script writes deployed addresses, the reviewed config hash, and deployed code hashes to
`FLM_DEPLOY_OUTPUT`. Review that output before generating liquidity or proposal batches.

Before signing any operation batch, link it back to the reviewed deploy config and deployment
output:

```sh
tools/check-deployment-artifacts.sh \
  --deploy config/gnosis.fao.json \
  --deployment-output deployments/flm.gnosis.json \
  --batch config/batches/bootstrap.production.json
```

This recomputes the deploy config hash and catches copied-address mistakes such as a batch
targeting the wrong manager, proposal source, company token, owner Safe, bootstrap recipient, or
official proposer.

## Limited-Funds Deployment Order

1. Deploy the FLM stack from a reviewed JSON config.
2. Run `tools/preflight-limited-deploy.sh --deploy <reviewed-config> --deployment-output
   <deploy-output> --batch <batch-config> ... --proposal <final-proposal> --run-fork-tests` and
   keep the output with the audit materials.
3. Verify deployed bytecode and constructor arguments.
4. Configure proposal validation if it was not configured during deployment.
5. Generate and audit the bootstrap liquidity Safe batch.
6. Execute with limited funds first.
7. Confirm spot position token id and balances.
8. Only then set an official proposal and generate sync batches.

## No Docker Requirement

The repository uses Foundry directly. The deployment and batch scripts do not require Docker.
