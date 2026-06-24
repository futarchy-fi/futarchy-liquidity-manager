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
- set only proposals whose creator equals the configured `officialProposer`;
- generate operation batches from explicit JSON and audit calldata before execution.

## Minimal Bootstrap Flow

1. Deploy `FutarchyOfficialProposalSource`.
2. Optionally deploy `DeadlineBoundedRealityProxy` for new FLM-grade proposal factories.
3. Deploy one `SwaprAlgebraLiquidityAdapter` for spot and one for conditional pools.
4. Deploy `FutarchyLiquidityManager`.
5. Approve company tokens from `bootstrapRecipient` to the manager.
6. Call `initializeFromBootstrap(companyAmount, spotAddData)` with native collateral value.

## Proposal Flow

1. Create or identify the futarchy proposal.
2. Ensure YES/NO outcome pools exist if validation requires pools.
3. Configure proposal validation bounds for the token pair, CTF oracle, Reality contract,
   arbitrator, opening delay, timeout, and min bond.
4. Call `setOfficialProposal`.
5. Call `sync` to migrate 80% of spot liquidity into conditional pools.
6. After settlement, call `sync` again to return conditional liquidity to spot.

## Out Of Scope

The following should remain in FAO or another integration repository:

- sale accounting and redemption policy;
- SnapshotX proposal creation/execution;
- arbitration/evaluator policy;
- frontend proposal linking;
- organization-specific deployment addresses.
