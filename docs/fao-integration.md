# FAO Integration Boundary

The current Swapr Algebra implementation is a no-funds prototype. FAO must not route treasury or LP
assets into it: permissionless pool precreation, mutable liquidity-cooldown griefing, and activation
gas fragility remain unresolved. The Ethereum-mainnet v4 successor has a gate and direct adapter,
plus atomic caller-bound factory wiring, but lacks a full source/CTF/two-pool manager fork proof and
final deployment manifest. The integration flow below specifies interfaces, not deployment
approval.

FAO should consume this package as a generic liquidity module. This repository should not import
FAO sale, arbitration, SnapshotX, frontend, or SDK contracts.

## Integration Responsibilities

FAO-side code or operations should:

- deploy/configure the generic FLM contracts;
- hold the organization-specific sale, arbitration, SnapshotX, and governance logic outside this
  repository;
- call `initializeFromBootstrap` from the configured `bootstrapRecipient`;
- constructor-configure `FutarchyOfficialProposalSource` validation before its activation target is
  bound;
- assign a proposal manager for proposal-source operations when ownership should remain separate
  from day-to-day metadata updates;
- set only proposals whose creator equals the configured `officialProposer`;
- generate operation batches from explicit JSON and audit calldata before execution.

## Minimal Bootstrap Flow

1. For prototype simulation only, deploy one `AlgebraPoolStabilityGuard` for the target Algebra
   factory, or reuse its reviewed deployment across every FAO/FLM manager on that chain.
2. Deploy `FutarchyOfficialProposalSource`.
3. Optionally deploy `DeadlineBoundedRealityProxy` for new FLM-grade proposal factories.
4. Deploy one `SwaprAlgebraLiquidityAdapter` for spot and one
   `SwaprAlgebraDirectConditionalAdapter` for fresh conditional pools.
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

1. Create the futarchy proposal, CTF condition, and canonical wrappers. The two conditional pools
   must still be fresh; precreating them makes activation revert.
2. Before bundle binding, configure proposal validation bounds for the token pair, CTF oracle,
   Reality contract, arbitrator, opening delay, timeout, min bond, and conditional lifetime.
3. Through the immutable lifecycle coordinator, call `setOfficialProposal`. The source write,
   manager activation, guarded spot removal, CTF split, both fresh pool initializations, and both
   first positions either succeed together or all revert. There is no later activation `sync`.
4. After CTF reports an exact binary payout, anyone may call `manager.sync`. It resolves only the
   captured condition, ignores later source mutation, and leaves recovered base inventory idle and
   share-owned; no unproven off-ratio spot join runs.

## Out Of Scope

The following should remain in FAO or another integration repository:

- sale accounting and redemption policy;
- SnapshotX proposal creation/execution;
- arbitration/evaluator policy;
- frontend proposal linking;
- organization-specific deployment addresses.
