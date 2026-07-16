# Operation Batches

Do not sign or fund batches for the current Swapr Algebra prototype. Its mutable pool cooldown lets
third-party position mints block burns, so the AMM cannot yet support the administrator-independent
position-removal path required by redemption.

`script/BuildLiquidityOperationBatch.s.sol` generates Safe transaction-builder JSON from
`config/safe-batch.example.json` style files. The script emits exactly one logical operation per
batch so reviewers can audit calldata and values independently.

## Command

```sh
FLM_BATCH_CONFIG=config/batches/bootstrap.json \
FLM_BATCH_OUTPUT=out/bootstrap.safe.json \
FLM_BATCH_SUMMARY=out/bootstrap.summary.md \
forge script script/BuildLiquidityOperationBatch.s.sol
```

The script writes both the Safe transaction-builder JSON and a Markdown sidecar summary. Review the
summary first, then decode the calldata in the JSON before signing.

For real operation batches, run strict validation on the finalized config before generating or
signing:

```sh
tools/preflight-limited-deploy.sh \
  --deployment-output deployments/flm.gnosis.json \
  --batch config/batches/bootstrap.production.json
```

Strict mode rejects placeholder Safe/owner/target addresses, zero liquidity amounts for bootstrap
and deposit batches, and mixed native/ERC20 collateral funding. When `--deployment-output` is
supplied, preflight also
verifies the deployment output hash schema, recomputes the reviewed deploy config hash when
`--deploy` is supplied, and checks that the batch references the deployed manager, proposal source,
tokens, owner Safe or proposal-manager Safe, bootstrap recipient, and official proposer expected
for the selected operation.
The example config is validated in CI with `--allow-placeholders` because it is only a schema
template.

CI also runs:

```sh
tools/check-batch-templates.sh
```

That command renders every example template into Safe transaction-builder JSON and a Markdown
summary, then checks both outputs are parseable.

## Operation Templates

Start from the closest operation-specific template instead of editing the generic example:

- `config/batches/bootstrap.example.json` for `initializeFromBootstrap`.
- `config/batches/deposit-to-spot.example.json` for later spot liquidity additions.
- `config/batches/sync.example.json` for permissionless settlement of an already active condition.
- `config/batches/redeem.example.json` for LP share redemption.
- `config/batches/set-proposal-validation.example.json` only for a separately deployed, still
  unbound source. Factory-created bundles freeze constructor validation immediately and cannot use
  this post-deployment operation.
- `config/batches/set-official-proposal.example.json` after proposal validation is configured.
- `config/batches/arm-emergency-exit.example.json` to start the emergency delay.
- `config/batches/disarm-emergency-exit.example.json` to cancel an armed emergency exit.
- `config/batches/emergency-exit.example.json` for the delayed non-custodial emergency unwind.
- `config/batches/sweep-idle.example.json` for residual recovery after share supply reaches zero.

Share-changing calls accept no adapter calldata. Ticks, pool initialization, deadlines, and
slippage parameters therefore cannot be selected by a depositor, redeemer, or emergency operator.

## Supported Operations

- `initializeFromBootstrap`
  - Transactions: company-token approval, optional collateral-token approval, then
    `manager.initializeFromBootstrap`.
  - Uses `companyAmount` and either `nativeValue` or `collateralAmount`.
- `depositToSpot`
  - Transactions: company-token approval, optional collateral-token approval, then
    `manager.depositToSpot`.
  - The amounts are maxima. The manager accepts the existing vault proportion and refunds or does
    not pull the excess.
- `sync`
  - Transaction: `manager.sync`.
  - Takes no execution parameters and can only settle the condition captured during activation.
    It cannot activate a proposal. Settlement does not consult the mutable source or spot guard and
    leaves recovered base assets idle and share-owned. It remains callable while emergency mode is
    armed or executed.
- `redeem`
  - Transaction: `manager.redeem`.
  - Uses `shares`, `recipient`, and `unwrapNative`.
  - Snapshots idle balances, removes only the withdrawing fraction of active liquidity, pays its
    proportional principal and fees, and never redeploys survivor assets. In conditional mode it
    merges only the withdrawing slice's matched complete sets; if the router rejects a merge, that
    slice is transferred in kind. Unmatched outcome tokens are always transferred in kind.
  - A nonfinal call reverts without burning shares if its share of every active position floors to
    zero liquidity. Combine or transfer shares until at least one liquidity unit is withdrawable.
- `setOfficialProposal`
  - Transaction: `proposalSource.setOfficialProposal`.
  - Must be submitted by the immutable lifecycle coordinator. The source write, manager
    activation, CTF split, both fresh pool initializations, and both first positions are atomic.
  - Uses `proposalId`, `proposal`, and `creator`.
- `setProposalValidationConfig`
  - Transaction: `proposalSource.setProposalValidationConfig`.
  - Must be submitted by the owner or proposal manager.
  - Uses `validation`.
- `armEmergencyExit`
  - Owner-only authorization control.
- `disarmEmergencyExit`
  - Owner-only authorization control.
- `executeEmergencyExit`
  - Permissionless after the owner arms the exit and the delay elapses. Removes active positions
    into the manager without transferring shareholder assets. Redemption remains open.
- `sweepIdleToBootstrapRecipient`
  - Uses `unwrapNative` and reverts while any FLM share exists.

## Fixed Execution Policy

The manager passes no caller-selected adapter execution policy. Bootstrap and spot deposits use the
bound spot adapter's immutable ticks and deadline policy. Source-only activation derives each fresh
conditional price from the guarded spot price and enforces the symmetric 50-bps inventory-use bound.
Redemption only calls detailed removal; there is no post-redemption add or restoration path.

For ERC20 collateral such as sDAI, set `collateralToken` to the deployed collateral token,
`collateralAmount` to the amount being supplied, `nativeValue` to zero, and `unwrapNative` to false.

## Audit Procedure

1. Review the JSON config.
2. Run `tools/preflight-limited-deploy.sh --deployment-output <deploy-output> --batch <final-config>`.
3. Review the generated Markdown summary and Safe transaction-builder JSON.
4. Decode each `data` field with `cast calldata-decode` or a Safe UI preview.
5. Confirm `to`, `value`, share amount, recipient, and token approvals.
6. Sign only after calldata matches the reviewed config.
