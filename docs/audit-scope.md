# Audit Scope

## Objective

Make futarchy liquidity provision operationally simple without giving a proposal curator the
power to freeze or redirect LP funds through arbitrary or never-settling conditional markets.

## Core Contracts

- `FutarchyLiquidityManager`: holds LP share accounting, spot liquidity, conditional migration,
  settlement return, redemption, compounding, and emergency exit state.
- `FutarchyOfficialProposalSource`: admits at most one official live proposal and can enforce
  on-chain proposal validation before the manager migrates liquidity.
- `DeadlineBoundedRealityProxy`: CTF oracle proxy for new FLM-grade proposals that can resolve
  normally through Reality or force a deterministic NO after a bounded deadline.

## External Dependencies

- ERC20 company token.
- Wrapped native collateral token.
- Futarchy proposal contract exposing collateral, wrapped outcomes, question id, and condition id.
- Conditional Tokens Framework.
- Reality.eth.
- Algebra/Swapr pool factory.
- Liquidity adapter contracts.
- Conditional split/merge/redeem router.

## Security Properties To Review

- LP shares remain proportional through deposits, withdrawals, migration, and settlement.
- Curator cannot select arbitrary unsafe proposals once validation is enabled.
- Validation rejects far-future opening times, excessive min bonds, bad timeout bounds, wrong
  arbitrators, wrong CTF oracle, non-binary conditions, wrong collateral, missing outcomes, and
  missing pools.
- Deadline proxy gives new FLM-grade proposals a bounded liveness path.
- Emergency exit does not create a hidden curator theft path.
- Adapters cannot over-pull tokens from the manager.

## FAO Compatibility

FAO should consume this package as an integration. If FAO needs sale bootstrap or SnapshotX
arbitration behavior, that code should stay outside the core package and call into the generic
interfaces.
