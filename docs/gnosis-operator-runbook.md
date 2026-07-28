# FLM Gnosis Operator-Mode Runbook

Operational procedures for running FLM in operator-custody mode on Gnosis (Swapr
Algebra). Deposits are gated to the operator Safe; the failure modes and their
recoveries are below. Concrete addresses, salts, and Safe batches live **outside
this repo** in the private operator manifest — this file is procedure only.

## Roles

All four authority roles are the GIP-145 Safe (2-of-3): owner, coordinator
(proposalManager), bootstrapRecipient, officialProposer. The deployer is a
throwaway EOA. The compromised `0x693E…` key holds **no** role and is denylisted
in `tools/validate-configs.sh`.

## 1. Deploy (one-shot)

Deploy is broadcast by the throwaway deployer EOA (not the Safe); the Gnosis
factory uses nonce-based CREATE, so the manager address is only known after the
factory + bundle land. Order:

1. **Guard first** (its address feeds the config):
   ```
   PRIVATE_KEY=<deployer> FLM_ALGEBRA_FACTORY=<algebra factory> \
     forge script script/DeployAlgebraPoolStabilityGuard.s.sol \
     --fork-url <gnosis rpc> --broadcast
   ```
2. Write the deployed guard address into the operator config's
   `poolStabilityGuard`. Then `tools/validate-configs.sh --deploy <config>` must
   pass — it refuses zero/placeholder guard and any compromised key.
3. **Stack**:
   ```
   PRIVATE_KEY=<deployer> FLM_DEPLOY_CONFIG=<config> \
     FLM_DEPLOY_OUTPUT=<private path> \
     forge script script/DeployFutarchyLiquidityManager.s.sol \
     --fork-url <gnosis rpc> --broadcast
   ```
   The output JSON has the deployed `manager` + `proposalSource`.
4. Copy `manager` into the private bootstrap batch (replace the placeholder in
   every tx target + approve spender) before signing §2.
5. Deploy the cooldown watcher (§5) before funding.

The full deploy wiring is rehearsed against real Gnosis dependencies by
`test/fork/FlmOperatorLifecycleFork.t.sol` (deploys guard + factory + bundle with
the Safe as coordinator, runs bootstrap→activation→settlement→redeem).

## 2. Bootstrap (once, per manager)

Seed the spot pool, let it observe ~30 min for a stable TWAP, then bootstrap
from the Safe at the pilot size (2–5k). Only the bootstrap recipient can deposit
— this is enforced at the `_depositToSpot` choke point. Scale to 10–15k only
after one clean full cycle.

## 3. Activation (per proposal)

Submit **bundled**: proposal-create → pool-create → `setOfficialProposal` in one
transaction, so no third party can front-create the YES/NO pool at a bad price
in between (the deferred precreation-veto risk — griefing costs the attacker,
never you, and the bundle closes the window). Activation is atomic: any failure
(CTF split, pool create, first mint) reverts the whole transition with no state
change, so a griefed attempt is simply retried with a fresh proposal.

**Before signing `setOfficialProposal`:** derive conditionId and the four
wrapped-outcome tokens from the canonical Seer factory for this proposal and
confirm they match what the batch encodes. The stored `creator` is
coordinator-supplied attribution, not a second on-chain auth factor — this check
is what makes it trustworthy.

## 4. Settlement

When Reality resolves, run `sync()` (keeper or manual) to fold the resolved
outcome back into share-owned base inventory. A keeper cron that dust-deposits
to trigger re-entry keeps the recovered ~80% slice from sitting idle between
markets.

**Guard:** confirm the Reality answer is a strict YES/NO payout vector before
relying on `sync()`. A non-strict answer bricks `sync()` — see §6.

## 5. Cooldown watch (continuous)

`tools/cooldown-watcher.sh` polls each managed pool's `liquidityCooldown()` and
alerts on any nonzero value. Arm it on cron (every ~15 min) with `POOLS` set to
the live YES/NO pools and `ALERT_CMD`/`WEBHOOK` for delivery. An armed cooldown
means a hostile Swapr factory owner could delay your withdrawals ≤24h — never
observed, capped, recoverable by waiting out a lapse. The activation-time gate
(`liquidityCooldown()==0` in the adapter and stability guard) already refuses to
*open* a position into an armed pool; the watcher covers arming *after* entry.

## 6. Emergency exit

Triggers: `sync()` bricked by a non-strict Reality answer, or any accounting
loss beyond survivor-favoring dust (canary stop condition from
`atomic-lifecycle-amendment.md`).

1. Arm emergency mode (owner / Safe). This starts the fixed 2-day delay.
2. After the delay, holders redeem in-kind (proportional liquidity + principal +
   fee + idle slices). The vault is then terminally dead.
3. Redeploy a fresh manager from the manifest and re-bootstrap.

Emergency mode keeps redemption enabled throughout; only deposits and normal
activation stop. Deposits are also frozen during conditional mode
(`minConditionalLifetime` ≥ 1 day) — top-ups queue behind the live market, which
is fine for a single operator.

## Stop conditions (halt scale-up)

Any cycle where FLM does not hold both first conditional positions, or shows an
accounting loss beyond dust, halts scaling and triggers investigation before the
next market.
