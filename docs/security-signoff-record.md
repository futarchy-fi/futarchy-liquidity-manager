# Independent sign-off record — FLM operator mode + FLMMarketLauncher

**Reviewer:** independent agent (separate from the implementing agent), commissioned
per Kelvin's direction 2026-07-29 that a separate agent serves as the independent
reviewer of record. Full internal adversarial pre-review: `security-review-launcher.md`.

**Verdict: APPROVED-WITH-CONDITIONS.**

The security model holds, verified from the code: the single-sig launcher owner (0xEB)
cannot steal or withdraw funds (withdrawal strictly share-gated; launcher holds no
shares/no fund path); worst-case is bounded, recoverable griefing (≤80% slice of one
market, Safe redeems instantly, owner-only emergency kill-switch); every activatable
market is deadline-bounded by the source validation; fLP holders redeem pro-rata at any
moment including from conditional pools. `forge test --no-match-path "test/fork/*"` =
240 passed. Conclusions matched the internal review; no additional theft vector found.

## Conditions (deploy-time gates before deposit)

1. **Fill + re-validate the deploy config.** `config/gnosis.operator.json` fails strict
   `--deploy` with placeholder-zero `factory`/`poolStabilityGuard`. Substitute the real
   deployed addresses and re-run `tools/validate-configs.sh --deploy <final>` (exit 0) as
   the final go/no-go. A filled copy was proven to pass; a `realitio=0` copy fails (footgun
   closed).
2. **Wiring.** `proposalManager` and `officialProposer` must be the **launcher address**
   (template shows the Safe as placeholder). Source `owner` and manager `owner` must remain
   the **Safe** — the launcher must never receive ownership of either. (Launcher-as-
   proposalManager is benign: its bytecode has no setManualSettled/setOfficialProposer path.)
3. **Trusted-oracle deadline bound — RESOLVED as accepted residual.** On-chain check
   (2026-07-29): `trustedOracle 0xb5786fA17cc3E262d855240a074978C133438e7b` does NOT expose
   `maxQuestionDuration()` (reverts) → it is NOT a DeadlineBoundedRealityProxy. It is the
   oracle the Gnosis futarchy factory uses (matches every factory-created conditionId), so
   it cannot be swapped without breaking conditionId validation. Effect: per-market
   opening+timeout bounds still hold and fLP redemption is always available, but there is no
   forced-resolution auto-return backstop if a Reality question stalls — the Safe redeems
   pro-rata or emergency-exits (2-day) instead. **No fund loss; accepted operational
   residual.**

## Residual risks the operator accepts

Bounded griefing (compromised 0xEB locks 80% of one market until resolution — recoverable,
nets 0xEB nothing); question text not validated on-chain (structure/timing/arbitrator are);
external Swapr-DAO cooldown could delay a burn (self-heals, monitored); fee-on-transfer
collateral would brick invariants (N/A for GNO/sDAI); canonical router wrapper enforcement
is a trust root (forged wrappers revert, not steal). Plus condition-3's no-auto-return.

**Fund only after conditions 1-2 are met with the final `validate-configs.sh --deploy`
passing, and condition-3's residual accepted.**
