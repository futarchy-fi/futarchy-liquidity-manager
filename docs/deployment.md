# Deployment

> **No-funds prototype:** do not broadcast or fund the current Swapr Algebra bundle. Permissionless
> pool precreation, mutable Algebra liquidity cooldown, and near-block-limit activation remain
> unresolved. The commands below are retained for deterministic simulation and artifact review.

## Ethereum-mainnet v4 factory

The reviewed successor has a separate, mainnet-only factory deployment script. It deliberately
deploys no child bundle and selects no FAO token, Safe, lifecycle role, validation policy, or salt.
Start from the placeholder config and fill only independently reviewed values:

```sh
cp config/mainnet-v4-factory.example.json config/mainnet-v4-factory.production.json
tools/validate-configs.sh --v4-factory config/mainnet-v4-factory.production.json
```

The config pins the conditional router and its CTF/Wrapped1155 dependencies, the v3 stability
guard, the collateral token, their runtime code hashes, and the immutable spot ticks. The script
also hard-pins the official Ethereum v3 NonfungiblePositionManager and v4 PoolManager addresses and
runtime code hashes recorded in `production-mainnet-dependency-manifest.md`. It rejects any runtime
drift and verifies that the router's immutable dependencies match the reviewed config before
broadcast:

```sh
PRIVATE_KEY=... \
FLM_V4_FACTORY_CONFIG=config/mainnet-v4-factory.production.json \
FLM_V4_FACTORY_DEPLOY_OUTPUT=deployments/flm.v4.factory.mainnet.json \
forge script script/DeployV4MainnetFactory.s.sol:DeployV4MainnetFactory \
  --rpc-url "$MAINNET_RPC_URL" \
  --broadcast \
  --verify
```

The output records the input-file hash, factory creation/runtime hashes, every external dependency
and runtime hash, both ticks, and all five child creation-code hashes. Treat it as factory evidence,
not authorization to create or fund a bundle. Bundle prediction/deployment remains intentionally
unimplemented until the unresolved fields in the mainnet dependency manifest are fixed.

## Historical Gnosis/Algebra prototype

Deployments are configured from JSON so addresses and bounds are reviewable before broadcasting.
Do not edit addresses directly inside scripts for a real deployment.

## Config

Start from `config/gnosis.example.json` and create a deployment-specific copy outside the example,
for example:

```sh
cp config/gnosis.example.json config/gnosis.fao.json
```

Required organization-specific fields:

- `organization`: organization address indexed by the permissionless factory event. The event is
  an unverified caller claim, not proof that the organization endorsed the deployment.
- `factory`: reviewed canonical `FutarchyLiquidityManagerFactory` for this dependency set and
  contract version.
- `owner`: owner of the proposal source and liquidity manager emergency controls, ideally a Safe.
- `proposalManager`: deployed lifecycle-coordinator contract and initial mutable proposal manager.
  It is the immutable sole caller of `setOfficialProposal`; later changing the mutable proposal
  manager does not change that coordinator.
- `bootstrapRecipient`: account allowed to call `initializeFromBootstrap`; for FAO this should be
  the integration contract or Safe that initially funds liquidity.
- `companyToken`: the token paired against the configured collateral token. It must differ from
  `wrappedNative`; validation's expected proposal/collateral tokens must equal this pair exactly.
- `officialProposer`: creator attribution that the immutable lifecycle coordinator must supply for
  an official proposal. The proposal ABI has no creator getter, so this field is not an independent
  source-side authentication factor; review the coordinator's canonical factory/pipeline lookup.
- `lpTokenName` and `lpTokenSymbol`: ERC20 metadata for FLM shares.

Every configured token and protocol dependency used by the manager or factory must already contain
deployed contract code on the target chain. Manager and factory constructors enforce this for
direct callers, and the deployment script checks the configured token, AMM, router, and guard
addresses before starting a broadcast.

Gnosis defaults included in the example:

- `wrappedNative`: collateral token used by the manager. Use WXDAI for native-collateral flows, or
  the ERC20 collateral itself, such as sDAI, for ERC20-collateral markets.
- `positionManager`: Swapr Algebra non-fungible position manager.
- `algebraFactory`: Swapr Algebra factory.
- `futarchyRouter`: futarchy conditional split/merge/redeem router.
- `poolStabilityGuard`: a reviewed shared `AlgebraPoolStabilityGuard` deployment for the configured
  `algebraFactory`.
- `deadlineProxy.conditionalTokens`: canonical Conditional Tokens Framework address.

Validation fields are explicit even when disabled. For production, prefer enabling validation before
setting an official proposal. If `deployDeadlineProxy` is true and `validation.trustedOracle` is
zero, the deployment script uses the newly deployed `DeadlineBoundedRealityProxy`. Enabled
validation is constructor-initialized on the proposal source, so the owner and proposal manager are
fixed from the first deployed state.

For ERC20-collateral deployments, bootstrap and deposit batches must use `collateralToken` and
`collateralAmount` with `nativeValue` set to zero. Native-collateral deployments use `nativeValue`
and leave `collateralAmount` at zero.

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

Deploy the stateless guard once per Algebra factory, then copy the emitted address into each
reviewed deploy config as `poolStabilityGuard`:

```sh
PRIVATE_KEY=... \
FLM_ALGEBRA_FACTORY=0x... \
FLM_GUARD_DEPLOY_OUTPUT=deployments/flm.guard.gnosis.json \
forge script script/DeployAlgebraPoolStabilityGuard.s.sol \
  --rpc-url gnosis \
  --broadcast \
  --verify
```

The guard has no owner or setters. Its factory, 30-minute TWAP window, and 50-tick maximum
current-to-average deviation are fixed in deployed code. A missing pool, uninitialized pool, or
unavailable observation history reverts the check.

Deploy the permissionless factory once. It pins the bare creation-code hashes and shared protocol
dependencies without storing the large child bytecode in its runtime:

```sh
PRIVATE_KEY=... \
FLM_POSITION_MANAGER=0x... \
FLM_ALGEBRA_FACTORY=0x... \
FLM_CONDITIONAL_ROUTER=0x... \
FLM_POOL_STABILITY_GUARD=0x... \
FLM_WRAPPED_NATIVE=0x... \
FLM_FACTORY_DEPLOY_OUTPUT=deployments/flm.factory.gnosis.json \
forge script script/DeployFutarchyLiquidityManagerFactory.s.sol \
  --rpc-url gnosis \
  --broadcast \
  --verify
```

Copy the emitted factory address into the reviewed deploy config. The bundle script checks every
factory dependency and creation-code hash before broadcasting. For local simulation only, a zero
factory address makes the script deploy an ephemeral matching factory first.

```sh
PRIVATE_KEY=... \
FLM_DEPLOY_CONFIG=config/gnosis.fao.json \
FLM_DEPLOY_OUTPUT=deployments/flm.gnosis.json \
forge script script/DeployFutarchyLiquidityManager.s.sol \
  --rpc-url gnosis \
  --broadcast \
  --verify
```

The script sends the three pinned bare creation-code blobs to the factory, which appends all
constructor arguments and atomically deploys the source, two adapters, manager, and irreversible
adapter bindings. It writes the factory, deployed addresses, reviewed config hash, pinned creation
code hashes, and deployed code hashes to `FLM_DEPLOY_OUTPUT`.

Because creation is permissionless, `LiquidityManagerCreated.organization` is not a canonical
registry. A UI must show new bundles as unverified until the named organization registers the
manager or signs an endorsement; it must never infer endorsement from the event alone.

Before signing any operation batch, link it back to the reviewed deploy config and deployment
output:

```sh
tools/check-deployment-artifacts.sh \
  --deploy config/gnosis.fao.json \
  --deployment-output deployments/flm.gnosis.json \
  --batch config/batches/bootstrap.production.json
```

This recomputes the deploy config hash and catches copied-address mistakes such as a batch
targeting the wrong manager, proposal source, company token, owner Safe, proposal manager,
bootstrap recipient, or official proposer.

## Limited-Funds Deployment Order

1. Deploy or verify the shared stability guard.
2. Deploy or verify the hash-pinned permissionless factory and record both addresses in the
   reviewed JSON config.
3. Create the FLM stack through that factory from the reviewed config.
4. Run `tools/preflight-limited-deploy.sh --deploy <reviewed-config> --deployment-output
   <deploy-output> --batch <batch-config> ... --proposal <final-proposal> --run-fork-tests` and
   keep the output with the audit materials.
5. Verify deployed bytecode and constructor arguments.
6. Confirm the constructor-set proposal validation is frozen and matches the reviewed config.
7. Generate and audit the bootstrap liquidity Safe batch.
8. Execute only in disposable simulation; the current Algebra path is not fundable.
9. Confirm spot position token id and balances and wait until the spot pool has usable 30-minute
   observation history.
10. Only then have the lifecycle coordinator atomically set and activate an official proposal.

## No Docker Requirement

The repository uses Foundry directly. The deployment and batch scripts do not require Docker.
