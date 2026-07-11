# Operation Batches

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
- `config/batches/sync.example.json` for both spot-to-conditional migration and settlement
  return-to-spot.
- `config/batches/redeem.example.json` for LP share redemption.
- `config/batches/set-proposal-validation.example.json` before admitting a real proposal.
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
  - Takes no execution parameters. Slippage bounds, deadlines, and full-range ticks are enforced by
    the manager and its bound adapters. Before either migration direction removes liquidity, the
    immutable shared guard requires the established spot pool's current tick to be within 50 ticks
    of its 30-minute TWAP; missing history fails closed.
- `redeem`
  - Transaction: `manager.redeem`.
  - Uses `shares`, `recipient`, and `unwrapNative`.
  - Removes all active positions to account for principal, fees, and idle balances, pays the
    withdrawing fraction, then tries to restore the remaining positions. In conditional mode it
    merges only the withdrawing slice's matched complete sets; if the router rejects a merge, that
    slice is transferred in kind. Unmatched outcome tokens are always transferred in kind.
- `setOfficialProposal`
  - Transaction: `proposalSource.setOfficialProposal`.
  - Must be submitted by the owner or proposal manager.
  - Uses `proposalId`, `proposal`, and `creator`.
- `setProposalValidationConfig`
  - Transaction: `proposalSource.setProposalValidationConfig`.
  - Must be submitted by the owner or proposal manager.
  - Uses `validation`.
- `armEmergencyExit`
- `disarmEmergencyExit`
- `executeEmergencyExit`
  - After the delay, removes active positions into the manager without transferring shareholder
    assets. Redemption remains open.
- `sweepIdleToBootstrapRecipient`
  - Uses `unwrapNative` and reverts while any FLM share exists.

## Fixed Execution Policy

The manager passes empty adapter calldata for bootstrap, deposits, redemptions, restoration,
emergency unwind, and `sync`. The bound adapter therefore uses immutable ticks, the current block as
deadline, existing pools, and no caller-selected initialization price. Lifecycle `sync` additionally
enforces the manager's TWAP guard and symmetric 50-bps inventory-use bound. Restoration requires
each exact spot/YES/NO pair to pass the shared stability guard, then permits asymmetric fee inventory
to remain idle and share-owned. A failed best-effort post-redemption restore leaves all remaining
assets idle and emits `LiquidityRestoreDeferred`; anyone may retry `restoreLiquidity()` after the
pool has sufficient stable history.

For ERC20 collateral such as sDAI, set `collateralToken` to the deployed collateral token,
`collateralAmount` to the amount being supplied, `nativeValue` to zero, and `unwrapNative` to false.

## Audit Procedure

1. Review the JSON config.
2. Run `tools/preflight-limited-deploy.sh --deployment-output <deploy-output> --batch <final-config>`.
3. Review the generated Markdown summary and Safe transaction-builder JSON.
4. Decode each `data` field with `cast calldata-decode` or a Safe UI preview.
5. Confirm `to`, `value`, share amount, recipient, and token approvals.
6. Sign only after calldata matches the reviewed config.
