# FLM on Gnosis — path to funded

## 1. Verdict

**Fundable: FLM Operator Mode on Swapr Algebra — operator-only deposits (GIP-145 Safe as sole shareholder), full clean-key redeploy, small adapter fix for the precreation veto. First funded market in ~4–6 weeks (aggressive: 2–3 weeks at reduced size).**

The repo's blanket "no-funds prototype" verdict on Gnosis/Algebra was written for a public-LP vault, where administrator-independent exit is non-negotiable. On-chain verification shows two of the three Algebra blockers are overstated for that case and irrelevant for ours. Gate `depositToSpot` to the operator Safe — a one-line reuse of the existing `_assertOnlyBootstrap()` — and the public-LP obligation vanishes: the only funds at risk are yours, held by the same Safe that already owns emergency powers. Every documented blocker then re-derives as either latent-and-monitorable, verified-benign, or a small code fix.

What this buys: today's ~10–15k of hand-built 10-tx Safe batches become bootstrap-once, then one Safe tx per proposal activation, keeper-cron'd `sync()` at settlement, one-tx top-ups — on the lifecycle engine that already carries a 5-invariant 128k-call campaign and full rollback proofs.

What this is not: a public LP product. That remains Uniswap v4 on Ethereum (unchanged), with ownerless-v4-on-Gnosis as the documented successor once BUSL-1.1 resolves (Additional Use Grant, or MIT change date 2027-06-15).

## 2. What's actually true about the blockers

Verified against Gnosis mainnet (rpc.gnosischain.com, verified sources), 2026-07-28.

| Doc claim | On-chain reality | Disposition |
|---|---|---|
| Mutable `liquidityCooldown` lets third parties block burns indefinitely — fatal | **Theoretical-only.** Cooldown is 0 on every pool ever created by factory `0xa086...da766`; zero `LiquidityCooldown` events chain-wide, ever. Arming it requires Swapr's 2-of-3 operational Safe (`0x4d0a...4bbe`) acting hostilely, per-pool, capped at 1 day by `Constants.MAX_LIQUIDITY_COOLDOWN`. Worst case: renewable ≤24h delay of the operator's own withdrawal. | Downgrade to monitored risk. On-chain entry gates + watcher (M2, M6). |
| Dust mints into FLM's NFPM position block burns / lock funds | **Verified benign.** `increaseLiquidity` is indeed permissionless on FLM's own tokenId, and the `burn()` in `removeLiquidityDetailed` is skipped forever once dusted — but nothing reverts, tracked principal exits fully each cycle, all balance-delta checks pass. Only the attacker's dust strands. The docs called this a burn-block; it's a cosmetic NFT-cleanup skip. | Dropped. No remediation. |
| Permissionless pool precreation breaks activation | **Confirmed, but mischaracterized.** `createPool` is permissionless (simulated from a dead EOA, no revert) and `_addFresh` hard-reverts `PoolAlreadyExists` with no adopt path — so activation of that conditionId is dead forever; retry requires a fresh proposal, re-griefable for dollars of gas. But the atomic revert means **no theft is possible**: FLM never touches the attacker's pool. This is DoS/toil, not fund risk. | Real blocker. Fixed by adapter adopt-path (M3) + bundled submission hygiene. |
| Uniswap v4 unavailable on Gnosis | **Confirmed.** No code at any official PoolManager address on chain 100; Gnosis absent from the canonical deployments list. | Algebra stands for this deployment class; v4 stays the horizon. |
| 12.1M gas bundle vs half-block rule | Physics is fine — 12.1M fits Gnosis's 17M once, and deployment is one-shot. Activation-class txs (~2.3M) fit comfortably. "Below half a block" is public-vault policy, not a constraint. | Replace with measured Gnosis gas fixtures + margins (M4). |

Independent of all of the above, **the live canary and every checked-in Gnosis config are unsalvageable**: compromised key `0x693E...b43d` is constructor-immutable as `BOOTSTRAP_RECIPIENT` / sole proposal authority, and HEAD bytecode no longer matches factory `0x1814...7f54`'s pinned creation-code hashes. Full redeploy — new factory included — is required in every conceivable path.

## 3. The plan

Milestones ordered; each unblocks the next. Deployer = clean `0x645A` EOA. Owner, coordinator, bootstrap recipient, sole depositor = GIP-145 Safe `0x63f539CA` (has code, so it satisfies HEAD's contract-coordinator requirement; closes the OFFICIAL_PROPOSER attribution medium by identity — the operator attests its own proposals, backed by a written proposal-identity runbook deriving conditionId/wrapped outcomes from the canonical Seer factory before every `setOfficialProposal`).

**M1 — Threat-model amendment + config purge (days).**
Docs amendment scoping the no-funds prohibition: lifted only for configs whose depositor gate is verified on-chain as operator-only; Ethereum v4 doctrine untouched. Rewrite `config/gnosis.*.json` purging every `0x693E` occurrence; add a compromised-key denylist to `validate-configs.sh` (today it would happily pass the poisoned configs). Quarantine canary artifacts so no tooling validates batches against the dead stack. *Unblocks: everything — no signing until this exists.*

**M2 — Deposit gate + cooldown entry gates (days).**
Add `_assertOnlyBootstrap()` to both `_depositToSpot` variants. Add `liquidityCooldown()==0` checks in `_addFresh` and `AlgebraPoolStabilityGuard._assertStable` so FLM can never open a position into an armed pool. Deliberate api-freeze manifest updates. *Unblocks: the entire scope reduction in section 2.*

**M3 — Precreation-veto fix (week).**
Extend `_addFresh`: adopt a pre-existing pool when the adapter holds zero position — initialize price if uninitialized, else assert sqrtPrice within stability-guard bounds of captured spot; revert only on hostile capital at a deviant price (operator arbs and retries — activation is atomically retryable). Acceptance = six-case adversarial fork matrix: precreated-uninitialized, precreated-at-price, empty-mispriced, hostile-capital revert + retry-after-arb, cooldown-armed refusal, pre-mint dust. This diff is the one genuinely new attack surface — review effort concentrates here. Fallback if it slips: ship without it, eat re-proposal toil, and use bundled proposal-create → pool-create → `setOfficialProposal` submission to close the front-run window operationally. *Unblocks: griefer-proof activation.*

**M4 — Real-dependency Gnosis fork suite (weeks — the long pole).**
Promote `RUN_GNOSIS_FORK_TESTS` into CI at a pinned block with real GNO/sDAI, Seer proposal, Reality/CTF, Swapr addresses (retire `MockMintableERC20`). Full lifecycle spot→conditional→settlement→redeem, rollback at every boundary, Gnosis-pinned gas fixtures with explicit margins vs 17M and a submit-at-max-gas rule. Verify settlement strictness up front: confirm the Reality/CTF path delivers only strict YES/NO payout vectors, or constrain question templates and document the `sync()`-brick → emergency-exit recovery. *Unblocks: the only evidence the Algebra path works against real dependencies at all — today's readiness evidence is Ethereum-pinned or mocked.*

**M5 — Review + gate re-run (days + review calendar).**
Diff-scoped **independent second reviewer** (not just Fable+Codex cross-review) over the M2/M3 diffs and role/config wiring — days of calendar, not an audit; the base at `bee832c` already carries the deep review. Then invariant campaign (`FOUNDRY_INVARIANT_RUNS=256 DEPTH=500`) on the exact final config, api-freeze updates, preflight strict mode, per-field Safe-batch calldata decode per `docs/operations.md`. In parallel, non-gating: Swapr Safe outreach for a public cooldown-stays-0 commitment. *Unblocks: signing.*

**M6 — Redeploy (week).**
Gnosis dependency manifest (Swapr factory/NFPM, Reality/CTF/arbitrator, roles, salt, predicted addresses; second-machine reproduction). Fresh hash-pinned factory from `0x645A` at HEAD hashes; atomic 4-contract bundle from the reviewed config; `bindActivationTarget` freezes validation — every Reality/CTF/arbitrator/timing field is final before this tx. Deploy the cooldown watcher (cron on `liquidityCooldown()` + events → Telegram) alongside. *Unblocks: live stack.*

**M7 — Bootstrap + first funded market (days).**
Seed spot pool, 30-min TWAP observation, bootstrap from the Safe at ~2–5k, one full proposal cycle end-to-end (one-tx activation, keeper `sync()` at settlement), then scale to 10–15k. Canary stop conditions from `atomic-lifecycle-amendment.md` apply: any phase without both FLM-owned first positions, or accounting loss beyond survivor-favoring dust, halts scale-up. Write the invalid-settlement/emergency-redeploy runbook.

## 4. Residual risks accepted

- **Swapr Safe turns hostile + sustained daily dusting**: your funds locked in-pool for the duration (1-day cooldown cap, renewable). Never observed; watcher gives same-day detection; recovery is social or waiting out a lapse. Accepted because only operator funds are exposed.
- **Non-strict Reality answer bricks `sync()`**: only exit is emergency arm → 2-day delay → in-kind redemption, then the vault is terminally dead — scripted redeploy per occurrence. Reduced by M4's strictness verification and template hygiene, not eliminated.
- **The adopt-path diff (M3)** is the most plausible way to lose money rather than time — hence the graft: independent reviewer + six-case fork matrix as hard acceptance.
- **Deposits close during conditional mode** (`minConditionalLifetime` ≥ 1 day, frozen): top-ups queue behind live markets. Fine for one operator.
- **Gas margin real but not luxurious**: a costlier future proposal shape could push staged activation near 17M; fixtures bound only the measured config.
- **Doctrine fork**: two live dispositions (Ethereum v4 public; Gnosis Algebra operator). Shared-core changes must flow through api-freeze and both fork suites or one path rots.
- **No defense-in-depth behind the GIP-145 Safe**: its compromise = coordinator + owner + depositor + all shares at once. No third party harmed — that is the point of the scope — but it's total.

## 5. Open questions for Kelvin

1. **Sign the threat-model amendment?** This plan deliberately overrides the repo's written prohibition (`readiness.md`, `operations.md`, `production-amm-successor.md`) for operator-custody configs only. Needs your explicit sign-off — it's the load-bearing scope cut.
2. **Does this supersede or run parallel to the 2026-07-16 Ethereum-mainnet decision?** Recommendation: parallel — Gnosis operator mode now, Ethereum v4 public vault unchanged, ownerless-v4-on-Gnosis tracked against the 2027-06-15 BUSL date.
3. **Aggressive timeline?** 2–3 weeks by deferring M3 (eat re-proposal toil per grief, use bundled submission) and funding at reduced size on fork-lite evidence. Defensible only because every at-risk dollar is yours. Say which.
4. **Who is the independent second reviewer** for the M2/M3 diffs?
5. **Old canary**: formally wind down and write off residual balances/LP shares held by `0x693E`, or leave abandoned-and-quarantined? (Recommendation: write off + annotate; never reuse.)
6. **Frozen constants acceptable?** 80% migration ratio, 0.5% leftover bound, 2-day emergency delay are compile-time and untunable post-deploy.
7. **Keeper for post-settlement re-entry**: `sync()` leaves recovered assets idle until the next deposit — approve a keeper dust-deposit cron so the 80% slice doesn't sit out of the pool after each settlement?