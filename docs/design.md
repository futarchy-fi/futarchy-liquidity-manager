# Design

## Goal

`FutarchyLiquidityManager` is a generic liquidity vault for futarchy markets. LPs deposit a
company token and collateral once, receive FLM shares, and let the manager handle:

- spot liquidity while no official proposal is live;
- migration into YES/NO conditional pools while an official proposal is live;
- return to spot after proposal settlement;
- pro-rata LP redemption across active liquidity modes.

## Core Principle

Proposal curation must not imply custody over LP funds.

The owner or proposal manager can mark an official proposal only through
`FutarchyOfficialProposalSource`. When validation is enabled, `setOfficialProposal` accepts only
proposals whose on-chain properties match the configured safety policy.

## Bad Proposal Checks

The proposal source can reject:

- wrong company/collateral pair;
- missing or duplicate wrapped outcome tokens;
- missing YES/NO conditional pools;
- wrong CTF oracle or condition id;
- non-binary CTF conditions;
- missing Reality question;
- untrusted Reality arbitrator;
- opening time too far in the future;
- timeout below or above configured bounds;
- minimum bond above the configured maximum.

These checks are intended to prevent a weak proposal manager from freezing LP funds by selecting
an arbitrary or never-settling conditional market.

## Settlement Liveness

Validation alone cannot guarantee that a Reality question eventually resolves. For new
FLM-grade markets, use `DeadlineBoundedRealityProxy` as the CTF oracle. It supports normal
Reality resolution and a fallback `forceFailByDeadline` path that reports NO after:

```text
Reality opening timestamp + maxQuestionDuration
```

This cannot retrofit deadlines onto conditions created with a different oracle address.

## FAO Compatibility

FAO should use this package as an integration:

- deploy/configure generic FLM contracts;
- keep sale, arbitration, SnapshotX, and organization-specific deployment logic outside this
  core package;
- configure `COMPANY_TOKEN`, `BOOTSTRAP_RECIPIENT`, proposal source, adapters, and validation
  bounds for the FAO deployment.
