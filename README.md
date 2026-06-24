# Futarchy Liquidity Manager

Audit-oriented smart contract package for generic futarchy liquidity management.

The core idea is that LPs deposit a company token and collateral once, receive FLM shares,
and the manager handles spot liquidity, conditional YES/NO migration during an official
proposal, and return to spot after settlement.

## Layout

- `src/core/` - generic audited FLM state machine.
- `src/sources/` - official proposal source and on-chain proposal validation.
- `src/oracles/` - deadline-bounded Reality/CTF settlement helpers.
- `src/adapters/` - protocol-specific liquidity adapters.
- `src/interfaces/` - minimal external dependency interfaces.
- `test/` - focused unit tests and protocol mocks.
- `docs/` - design notes, threat model, and audit-scope material.

## Audit Boundary

Primary audit scope:

- `src/core/FutarchyLiquidityManager.sol`
- `src/sources/FutarchyOfficialProposalSource.sol`
- `src/oracles/DeadlineBoundedRealityProxy.sol`
- `src/interfaces/*.sol`

Adapter audit scope:

- `src/adapters/SwaprAlgebraLiquidityAdapter.sol`

Out of scope for this package:

- FAO sale contracts.
- SnapshotX arbitration/evaluator contracts.
- Frontend and SDK code.
- Deployment scripts for a specific organization.

FAO should integrate with this package by deploying/configuring these generic contracts. This
package should not import FAO-specific contracts.

## Test

```sh
git submodule update --init --recursive
forge test
```
