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
2. Generate the batch.
3. Decode each `data` field with `cast calldata-decode` or a Safe UI preview.
4. Confirm `to`, `value`, deadlines, slippage, and token approvals.
5. Sign only after calldata matches the reviewed config.
