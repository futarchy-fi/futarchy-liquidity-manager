# Audit Scope

## Objective

Make futarchy liquidity provision operationally simple without giving a proposal manager the
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
- Configured collateral token, either wrapped native through the payable overloads or ERC20
  collateral through explicit approval overloads.
- Futarchy proposal contract exposing collateral, wrapped outcomes, question id, and condition id.
- Conditional Tokens Framework.
- Reality.eth.
- Algebra/Swapr pool factory.
- Liquidity adapter contracts.
- Conditional split/merge/redeem router.

## Security Properties To Review

- LP shares remain proportional through deposits, withdrawals, migration, and settlement.
- Proposal manager cannot select arbitrary unsafe proposals once validation is enabled.
- Validation rejects far-future opening times, excessive min bonds, bad timeout bounds, wrong
  arbitrators, wrong CTF oracle, non-binary conditions, wrong collateral, missing outcomes, and
  missing pools.
- Deadline proxy gives new FLM-grade proposals a bounded liveness path.
- Emergency exit does not create a hidden proposal-manager theft path.
- Adapters cannot over-pull tokens from the manager.

## Permissions

- `FutarchyLiquidityManager.owner`
  - can arm/disarm emergency exit;
  - can execute emergency exit only after `EMERGENCY_EXIT_DELAY`;
  - can sweep idle assets to `BOOTSTRAP_RECIPIENT`.
- `BOOTSTRAP_RECIPIENT`
  - is the only account allowed to call `initializeFromBootstrap`;
  - receives idle sweeps and emergency-exit assets.
- `FutarchyOfficialProposalSource.owner`
  - can set the proposal manager;
  - can perform every proposal-source operation available to the proposal manager.
- `FutarchyOfficialProposalSource.proposalManager`
  - can set the official proposer;
  - can configure validation;
  - can set/clear the official proposal;
  - can mark manual settlement if no settlement oracle is configured.
- Any account
  - can deposit to spot;
  - can redeem its own FLM shares;
  - can call `sync` when conditions are met.

## Trust Assumptions

- The selected liquidity adapter is in audit scope. The manager checks that add-liquidity calls do
  not report more input used than provided, but adapter custody and protocol interactions still
  require adapter review.
- The conditional router is trusted to split, merge, and redeem the expected proposal positions.
- The official proposal source owner or proposal manager is trusted to configure validation
  correctly before setting a production official proposal.
- If manual settlement is used, the owner or proposal manager is trusted for settlement timing. For
  bounded liveness, prefer a settlement oracle or `DeadlineBoundedRealityProxy` path.
- `BOOTSTRAP_RECIPIENT` should be controlled by the organization integration, normally a Safe or
  reviewed bootstrap contract.

## FAO Compatibility

FAO should consume this package as an integration. If FAO needs sale bootstrap or SnapshotX
arbitration behavior, that code should stay outside the core package and call into the generic
interfaces.
