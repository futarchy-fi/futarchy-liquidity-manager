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
tools/validate-configs.sh --batch config/batches/bootstrap.production.json
```

Strict mode rejects placeholder Safe/owner/target addresses, zero liquidity amounts for bootstrap
and deposit batches, missing deadlines, and zero slippage minimums on liquidity add/remove paths.
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
- `config/batches/emergency-exit.example.json` for the delayed full emergency exit.
- `config/batches/sweep-idle.example.json` for idle asset recovery to the bootstrap recipient.

All templates keep every slippage/deadline field visible even when the selected operation does not
use that leg. This makes reviews mechanical: fill the operation fields, run strict validation,
generate the batch, then audit the summary and calldata.

## Supported Operations

- `initializeFromBootstrap`
  - Transactions: company-token approval, then `manager.initializeFromBootstrap`.
  - Uses `companyAmount`, `nativeValue`, and `spotAdd`.
- `depositToSpot`
  - Transactions: company-token approval, then `manager.depositToSpot`.
  - Uses `companyAmount`, `nativeValue`, and `spotAdd`.
- `sync`
  - Transaction: `manager.sync`.
  - Uses `spotExit`, `spotAdd`, `yesAdd`, `noAdd`, `yesExit`, and `noExit`.
- `redeem`
  - Transaction: `manager.redeem`.
  - Uses `shares`, `recipient`, `unwrapNative`, `spotExit`, `yesExit`, and `noExit`.
- `setOfficialProposal`
  - Transaction: `proposalSource.setOfficialProposal`.
  - Uses `proposalId`, `proposal`, and `creator`.
- `setProposalValidationConfig`
  - Transaction: `proposalSource.setProposalValidationConfig`.
  - Uses `validation`.
- `armEmergencyExit`
- `disarmEmergencyExit`
- `emergencyExitAllToBootstrapRecipient`
  - Uses `unwrapNative`, `spotExit`, `yesExit`, and `noExit`.
- `sweepIdleToBootstrapRecipient`
  - Uses `unwrapNative`.

## Slippage And Deadlines

All adapter calldata is generated from explicit JSON fields:

- `amount0Min`
- `amount1Min`
- `deadline`
- `sqrtPriceX96` for add/mint paths
- `tickLower`
- `tickUpper`

For real execution, set nonzero `amount0Min`, `amount1Min`, and `deadline` values based on a fresh
quote. The examples use zeros only as placeholders.

## Audit Procedure

1. Review the JSON config.
2. Run `tools/validate-configs.sh --batch <final-config>`.
3. Generate the batch.
4. Decode each `data` field with `cast calldata-decode` or a Safe UI preview.
5. Confirm `to`, `value`, deadlines, slippage, and token approvals.
6. Sign only after calldata matches the reviewed config.
