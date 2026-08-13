# FLMMarketLauncher + operator-mode — internal adversarial pre-review

> **Status: internal adversarial review, NOT the independent sign-off.** This is
> the grounding package for a named independent reviewer to validate. Four
> independent lenses each tried to *break* one security invariant against the
> committed code (launcher, manager, source, adapter, router). Verdicts and the
> exact residuals are below.

## Scope

`src/factories/FLMMarketLauncher.sol`, `src/core/FutarchyLiquidityManager.sol`,
`src/sources/FutarchyOfficialProposalSource.sol`,
`src/adapters/SwaprAlgebraDirectConditionalAdapter.sol`,
`src/routers/FutarchyConditionalRouter.sol`, plus the deploy gate
`tools/validate-configs.sh`. Threat actor: a fully compromised launcher owner
(`0xEB`, single-sig) that holds **no** fLP shares (all shares are the operator
Safe's).

## Verdicts

| Lens | Verdict |
|---|---|
| Fund theft (can 0xEB move manager funds / hold shares?) | **UPHELD — no theft path** |
| Griefing blast-radius (worst damage without theft) | **UPHELD — bounded + recoverable** |
| Deadline/validation bypass (unbounded/resolved market activatable?) | **Contract footgun, closed by the deploy gate** |
| Redemption availability (can a holder always exit pro-rata?) | **UPHELD — with sub-unit caveats** |

## 1. No theft path

The launcher has exactly two owner entrypoints: one-shot `bind()` and
`launchMarket()`. `launchMarket` passes only a *proposal address* to
`source.setOfficialProposal(id, proposal, address(this))` — it cannot inject
activation data. The source **reads and validates** the outcome tokens and
`conditionId` from the proposal itself, cryptographically pins
`conditionId == getConditionId(trustedOracle, questionId, 2)`, and builds the
activation struct. The manager's activation sends funds only into itself, the
immutable `CONDITIONAL_ADAPTER`, and the immutable `CONDITIONAL_ROUTER`; every
`_mint` targets `BOOTSTRAP_RECIPIENT`; withdrawal (`redeem`) burns
`msg.sender`'s own shares. The launcher holds no tokens and no share-minting or
transfer path. **Residual (not launcher-controllable):** a proposal returning a
genuine `conditionId` but forged wrapper-token addresses relies on the canonical
`CONDITIONAL_ROUTER` refusing non-canonical wrappers — the standard Futarchy
trust assumption; worst case is a revert (grief), not theft.

## 2. Griefing is bounded and recoverable

A compromised 0xEB can activate a valid-but-junk market. Bounds:
- Only `MIGRATION_BPS = 8000` (80%) migrates; 20% always stays share-owned in spot.
- Pools seed at the TWAP-guarded spot price (`POOL_STABILITY_GUARD`), not an
  attacker price — no free arbitrage subsidy.
- One market at a time (`ProposalAlreadyActive`); re-activation needs settlement,
  which 0xEB does not control (trusted oracle + arbitrator).
- Realized loss ceiling = impermanent-loss/arb on the 80% slice of one market;
  extraction needs third-party capital and yields 0xEB nothing.

**Recovery is immediate.** The Safe holds all shares, so `redeem(all)` unwinds
100% of the vault (spot + both conditional pools + in-kind outcomes) in one tx,
mid-market, no delay. Owner-only `armEmergencyExit()` instantly locks 0xEB out of
new activations; after the 2-day delay `executeEmergencyExit()` consolidates
everything, bypassing settlement. 0xEB cannot force emergency mode, wedge `sync()`,
DoS redemption, or permanently brick funds.

## 3. Deadline footgun — closed by the deploy gate

The source has a **condition-only** validation mode (`validation.realitio == 0`)
that skips every deadline/timeout/pristine/arbitrator check and is
freezable-enabled — a real footgun in the contract's general design. It is closed
for any funded deployment by two independent layers:
1. `tools/validate-configs.sh` strict `--deploy` mode requires
   `validation.realitio` and `trustedArbitrator` non-zero, `maxOpeningDelay > 0`,
   `minTimeout > 0`, `maxTimeout >= minTimeout`, `minConditionalLifetime >= 1 day`
   (lines 185-201). A condition-only or unbounded-timing config cannot pass.
2. The canonical operator config (`config/gnosis.operator.json`) uses full-Reality
   mode with all bounds set. Under it, `_validateRealityQuestion` enforces future
   opening within `maxOpeningDelay`, timeout in `[min,max]`,
   `openingTs+timeout >= now + minConditionalLifetime`, pristine question, and
   trusted arbitrator — no overflow or question/condition-split gap found.

**Reviewer action:** confirm the deployed config is full-Reality (realitio set);
never deploy a `realitio == 0` config to funds.

## 4. Redemption always available (sub-unit caveats)

`redeem()` is gated only by initialization — not by mode or the emergency delay —
and works in spot, conditional, resolved-but-unsynced, emergency-armed, and
emergency-executed states. Conditional-slice removal is attacker-safe: only the
adapter can burn its position; third-party dust-mints are swept pro-rata on final
redemption and never strand funds; the removal-invariant reverts are
mathematically unreachable; there is no cooldown check on the burn path.
Unresolved value comes out in-kind as outcome tokens. **Honest caveats:**
- **Sub-unit dust holders** (stake worth < 1 liquidity unit per pool) can hit
  `ZeroRedeemLiquidity` on a non-final redeem — a "combine shares or be the final
  redeemer" nuisance, not a trap on any material position. The Safe (sole/majority
  holder) is never affected.
- **External Swapr-governance cooldown:** the Algebra factory owner could arm a
  nonzero `liquidityCooldown` on a live pool, and dust-mints could then re-arm it,
  reverting `burn` and forcing a bounded wait on the conditional slice. Requires
  trusted-DAO misbehavior, self-heals when cooldown lapses, and is monitored by
  `tools/cooldown-watcher.sh`.
- **Fee-on-transfer/rebasing tokens** would brick the exact-balance checks —
  irrelevant for GNO/sDAI (safe-fail if ever configured).

## Trust roots (for the reviewer to confirm)

Every residual reduces to trust roots that are **not** launcher-controllable and
are set at deploy from the validated config: `POOL_STABILITY_GUARD`, the Reality
oracle (`realitio`), `trustedArbitrator`, and the canonical `CONDITIONAL_ROUTER`
(wrapper enforcement). The dependency manifest pins these to the real, verified
Gnosis canonical addresses (all confirmed to have code on-chain).

## Recommendation

No code change required before funding. The security model — single-sig migrator
cannot steal, markets are deadline-bounded, fLP holders exit pro-rata — holds
under the intended (validated, full-Reality) deployment. An independent reviewer
should validate this package, focusing on the trust-root addresses and the
canonical-router wrapper enforcement.
