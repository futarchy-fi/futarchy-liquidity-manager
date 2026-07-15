# Fable architecture review — 2026-07-15

## Provenance

- Route: `/Users/kas/bin/claude-azsantos -p --model fable --no-session-persistence --tools ''`
- Health response: `FABLE_OK`
- Model reported by `modelUsage`: `claude-fable-5` only; no fallback model
- Session: `56bfc49b-5401-4262-ba89-e16801f36dc6`
- Result UUID: `44534eed-bec3-4e55-a8a2-fa6dbcd01f1a`
- No tools, web access, persistent session, permission grants, or file edits

## Decision

Fable approved the current Algebra implementation for a draft PR and bounded testnet/canary work,
not production funding. Two independent production blockers remain:

1. Canonical Algebra pool creation is permissionless. Because proposal, condition, and wrapper
   creation cannot fit with activation under Gnosis's 17,000,000 block gas limit, predictable pair
   addresses are exposed before activation and a third party can precreate a pool to veto the
   proposal.
2. Even the staged activation consumes most of a Gnosis block. Passing the present minimum margin
   is evidence for bounded testing, not sufficient production headroom.

The recommended production successor is a Uniswap v4 pool whose hook restricts initialization and
first liquidity to an authenticated FLM activation. A permissioned Algebra factory is the second
choice. Private transaction delivery is not a protocol-level fix.

Admission must fail closed within the same atomic transition and bind the canonical condition,
wrappers, and pool key. It must reject a resolved CTF condition, a finalized or
arbitration-pending Reality question, and any condition whose earliest forceable finality is inside
the protocol minimum conditional lifetime. Rejecting every already-answered question is preferred.

The current strict-Reality source implements the conservative form of that rule: the question must
be pristine and non-arbitrating, and its opening must remain at least the configured `minTimeout`
in the future. Condition-only integrations still need an equivalent immutable lifecycle guarantee.

## Required follow-up

- keep the Algebra path explicitly non-production;
- design and threat-model the v4 hook-gated adapter before moving funds;
- preserve atomic rollback and proposal-key reuse after failed activation;
- test donation absorption against first-deposit share inflation and single-leg donation; and
- give the v4 path materially more block-gas headroom.

## Subsequent Algebra finding

Review after the Fable call found a third independent blocker in canonical Algebra V1.9. The
factory owner can enable a mutable pool `liquidityCooldown`; every positive mint to the public
`(owner, lowerTick, upperTick)` position resets its last-add timestamp, while every burn is gated by
that timestamp. A third party can therefore repeat a dust mint and indefinitely block both the
direct conditional position and the position-manager-owned spot range. The real-Gnosis fork suite
now preserves this attack as an explicit regression.

There is no adapter-local repair because the recipient need not consent and rotation requires the
already blocked burn. This tightens the earlier disposition: the Swapr Algebra branch is a
no-funds prototype, not a funded canary. An ownerless factory with immutable zero cooldown, a
permissioned custom pool, or the recommended v4 hook-gated successor is required.
