# Dependencies

This package is generic, but it is not dependency-free. Dependencies are explicit and kept
behind narrow interfaces.

## Futarchy-Specific Interfaces

These are the dependencies that come from the futarchy stack rather than from Seer or unrelated
protocols:

- `IFutarchyProposalCore`
  - `collateralToken1()`
  - `collateralToken2()`
  - `wrappedOutcome(uint256)`
  - `questionId()`
  - `conditionId()`
- `IFutarchyConditionalRouter`
  - `splitPosition(proposal, collateralToken, amount)`
  - `mergePositions(proposal, collateralToken, amount)`
  - `redeemPositions(proposal, collateralToken, amount)`
- `IFutarchyOfficialProposalSource`
  - `officialProposal()`
  - `officialProposalExtended()`
- `IFutarchyLiquidityAdapter`
  - `addFullRangeLiquidity(...)`
  - `removeLiquidity(...)`
  - `compoundPosition(...)`

The package provides implementations for the proposal source and one liquidity adapter, but the
interfaces are the compatibility boundary for FAO or any other organization.

## External Protocol Interfaces

- ERC20 company token.
- Configured collateral token. Native-collateral flows require wrapped-native `deposit()` and
  `withdraw(uint256)` support; ERC20-collateral flows use approval and transfer.
- Conditional Tokens Framework.
- Reality.eth.
- Algebra/Swapr pool factory.
- Algebra/Swapr non-fungible position manager.
- OpenZeppelin contracts.

## Not Dependencies

The core package does not depend on:

- Seer;
- FAO sale contracts;
- FAO arbitration contracts;
- SnapshotX;
- futarchy.fi frontend or SDK code.

Those systems can integrate with this package, but they should not be imported by the audited
core.
