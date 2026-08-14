# FLM Gnosis Operator-Mode Runbook

Operational procedures for running FLM in operator-custody mode on Gnosis (Swapr
Algebra). Deposits are gated to the operator Safe; the failure modes and their
recoveries are below. Concrete addresses, salts, and Safe batches live **outside
this repo** in the private operator manifest — this file is procedure only.

## Roles

The GIP-145 Safe (2-of-3) owns the manager and proposal source, is the bootstrap
recipient, and holds all funded shares. The launcher is owned by the `0xEB…`
operator and is configured as both the source's immutable lifecycle coordinator
(`proposalManager` at construction) and `officialProposer`. The `0x645A…`
deployer holds no contract role after deployment. The compromised `0x693E…` key
holds **no** role and is denylisted in `tools/validate-configs.sh`.

## 1. Deploy (one-shot)

Deploy is broadcast by the deployer EOA (not the Safe); the Gnosis factory uses
nonce-based CREATE, so the manager address is only known after the factory and
bundle land. Order:

1. **Launcher first.** Deploy it with the `0xEB…` operator as owner and record
   its address. Do not grant it Organization editor permission.
   ```
   PRIVATE_KEY=<deployer> FLM_LAUNCHER_OWNER=<0xEB operator> \
     FLM_LAUNCHER_DEPLOY_OUTPUT=<private path> \
     forge script script/DeployFLMMarketLauncher.s.sol \
     --fork-url <gnosis rpc> --broadcast
   ```
2. **Guard** (its address feeds the config):
   ```
   PRIVATE_KEY=<deployer> FLM_ALGEBRA_FACTORY=<algebra factory> \
     forge script script/DeployAlgebraPoolStabilityGuard.s.sol \
     --fork-url <gnosis rpc> --broadcast
   ```
3. Deploy the hash-pinned factory for the reviewed creation code. Write the
   launcher into `proposalManager` and `officialProposer`, the Safe into `owner`
   and `bootstrapRecipient`, and the deployed factory/guard into the operator
   config. Then `tools/validate-configs.sh --deploy <config>` must pass.
4. **Stack**:
   ```
   PRIVATE_KEY=<deployer> FLM_DEPLOY_CONFIG=<config> \
     FLM_DEPLOY_OUTPUT=<private path> \
     forge script script/DeployFutarchyLiquidityManager.s.sol \
     --fork-url <gnosis rpc> --broadcast
   ```
   The output JSON has the deployed `manager` + `proposalSource`.
5. The `0xEB…` owner calls
   `launcher.bind(source, manager, factory, organization, GNO, sDAI, category,
   language)` once. This is launcher wiring only; it does not create or link a
   market and requires no Organization editor role.
6. Copy `manager` into the private bootstrap batch (replace the placeholder in
   every tx target + approve spender) before signing §2.
7. Deploy the cooldown watcher (§5) before funding.

`test/fork/FlmOperatorLifecycleFork.t.sol` covers the manager/source lifecycle
against real Gnosis dependencies. `test/fork/FlmLauncherOneSigFork.t.sol`
covers launcher wiring and the existing-market lifecycle without an
Organization editor grant.

## 2. Bootstrap (once, per manager)

Seed the spot pool, let it observe ~30 min for a stable TWAP, then bootstrap
from the Safe at the pilot size (2–5k). Only the bootstrap recipient can deposit
— this is enforced at the `_depositToSpot` choke point. Scale to 10–15k only
after one clean full cycle.

## 3. Activation (per proposal)

The launcher calls `activateExistingMarket(proposalId, proposal)` for an
already-created proposal. This path does not create a proposal, write
Organization metadata, or require the launcher to be an Organization editor.
The source validates the proposal and atomically starts the manager migration;
then anyone calls `migrateSide(true)` and `migrateSide(false)` to create the two
fresh conditional positions.

**Before activation:** derive the condition id and four wrapped-outcome tokens
from the canonical proposal and confirm the source's `validateProposal` result.
Both YES/NO Algebra pools must be absent: the fresh-only conditional adapter
cannot adopt an existing pool, and manager activation reverts before moving
spot funds if either pool already exists. The stored `creator` is
coordinator-supplied attribution, not a second on-chain authentication factor.

Activation and the two permissionless `migrateSide` calls are separate to stay
within the Gnosis gas budget. A third party can therefore create a pool after a
successful activation but before its side migrates. If that happens,
`migrateSide` reverts and redemptions remain disabled while migration is active;
the owner Safe must call `abortMigration()` to merge the outcome tokens and
restore spot liquidity. Do not retry that proposal with this fresh-only adapter.

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
