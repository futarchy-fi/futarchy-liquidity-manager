# FAO Integration Boundary

FAO should consume this package as a generic liquidity module. This repository should not import
FAO sale, arbitration, SnapshotX, frontend, or SDK contracts.

## Integration Responsibilities

FAO-side code or operations should:

- deploy/configure the generic FLM contracts;
- hold the organization-specific sale, arbitration, SnapshotX, and governance logic outside this
  repository;
- call `initializeFromBootstrap` from the configured `bootstrapRecipient`;
- configure `FutarchyOfficialProposalSource` validation before setting a real official proposal;
- assign a proposal manager for proposal-source operations when ownership should remain separate
  from day-to-day metadata updates;
- set only proposals whose creator equals the configured `officialProposer`;
- generate operation batches from explicit JSON and audit calldata before execution.

## Minimal Bootstrap Flow

1. Deploy one `AlgebraPoolStabilityGuard` for the target Algebra factory, or reuse its reviewed
   deployment across every FAO/FLM manager on that chain.
2. Deploy `FutarchyOfficialProposalSource`.
3. Optionally deploy `DeadlineBoundedRealityProxy` for new FLM-grade proposal factories.
4. Deploy one `SwaprAlgebraLiquidityAdapter` for spot and one for conditional pools.
5. Deploy `FutarchyLiquidityManager` with the shared guard address.
6. Irreversibly bind both adapters to the manager from their deployment authority.
7. Approve company tokens from `bootstrapRecipient` to the manager.
8. For native collateral, call `initializeFromBootstrap(companyAmount)` with native value. For
   ERC20 collateral, approve the collateral token and call
   `initializeFromBootstrap(companyAmount, collateralAmount)`. No caller supplies adapter data.
9. Public LPs may call `depositToSpot` only outside conditional and emergency modes. Deposits are
   accepted in the existing two-asset vault proportion and excess input is refunded or unpulled.
10. LPs may call `redeem(shares, recipient, unwrapNative)` in every lifecycle and emergency state.

## Proposal Flow

1. Create or identify the futarchy proposal.
2. Ensure YES/NO outcome pools exist if validation requires pools.
3. Configure proposal validation bounds for the token pair, CTF oracle, Reality contract,
   arbitrator, opening delay, timeout, and min bond.
4. Call `setOfficialProposal`.
5. Call `sync` to migrate 80% of spot liquidity into conditional pools. The call fails closed if
   the established spot pool lacks 30 minutes of history or its current tick is more than 50 ticks
   from that TWAP. Newly seeded YES/NO pools do not need pre-existing 30-minute history.
6. After settlement, call `sync` again to return conditional liquidity to spot. The same spot-pool
   guard runs before conditional positions are removed.

## Out Of Scope

The following should remain in FAO or another integration repository:

- sale accounting and redemption policy;
- SnapshotX proposal creation/execution;
- arbitration/evaluator policy;
- frontend proposal linking;
- organization-specific deployment addresses.
