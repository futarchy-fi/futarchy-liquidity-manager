# Atomic lifecycle and proportional redemption amendment

The current Swapr Algebra implementation does not meet this threat model when a nonzero mutable
pool cooldown is enabled: repeated third-party dust mints can reset the public position timestamp
and block every burn indefinitely. Donation accounting is safe only while burns remain available;
this adapter must not be funded.

## Status

The proposal-source, manager, router, and accounting portions of this document describe the
contracts at repository head. The immutable Uniswap v4 conditional successor is implemented and
mainnet-fork validated; the Swapr Algebra adapter still cannot satisfy immutable removal liveness
and must not be funded. The repository remains a no-funds prototype until the final mainnet tokens,
configuration, deployment artifacts, and independent review satisfy
`production-amm-successor.md` and `production-amm-candidate-evaluation.md`.

The amendment has two independent safety goals:

1. A successful conditional activation always creates and funds fresh conditional pools in the
   same transaction that records the official proposal.
2. Redeeming one holder's FLM shares never removes or redeploys liquidity belonging to surviving
   holders.

The proposal source remains the only official-proposal registry. CTF remains the source of the
binary payout. The FLM does not create a second registry and does not react to event logs.

## Trust boundaries

The responsibilities are deliberately separate:

- **Proposal source:** selects one official proposal and enforces proposal-admission policy.
- **CTF and canonical wrapper system:** define the condition, outcome positions, wrappers, and
  payout.
- **FLM manager:** validates the selected market's structural relationship to its immutable base
  pair and guarantees safe liquidity transitions.
- **Manager-bound adapters:** are part of the FLM execution boundary. They may create positions and
  move only assets supplied by their manager. They never choose a proposal, recipient, or price.
- **Keeper:** has liveness responsibility only. It may submit permissionless settlement or retry
  transactions but has no authority to select assets or redirect funds.

An official-proposal source or its governance can still refuse to propose a market. It cannot make
the FLM enter an old, pre-funded, or attacker-initialized conditional pool.

## State machine

```text
Uninitialized --bootstrap--> Spot
Spot --source callback in official transition--> Conditional(bound proposal + condition)
Conditional --CTF payout reported; anyone settles--> Spot
Spot or Conditional --delayed owner action--> Emergency/idle
```

Emergency mode remains an overlay that blocks deposits and activation but never blocks settlement
or share redemption.

### Spot to conditional

The current sequence

```text
setOfficialProposal()  ... later ...  permissionless sync()
```

is removed. The replacement sequence is:

1. The lifecycle integration creates or finalizes the proposal, CTF condition, and canonical
   wrappers.
2. The production lifecycle coordinator calls `FutarchyOfficialProposalSource`; direct owner or EOA
   use of the activation setter is disabled.
3. The source validates and stores the official proposal. Pool-existence validation is deliberately
   absent: both conditional pools must still be nonexistent.
4. Before the setter may return, the source passes its single validated proposal snapshot to the
   bound FLM manager's `activateOfficialProposal(snapshot)` hook.
5. The manager accepts that callback only from its immutable source and validates the snapshot's
   base pair, condition, wrappers, and active phase. It requires the two base assets and four
   outcome wrappers to be pairwise distinct and requires
   `CTF.payoutDenominator(conditionId) == 0`, and obtains the established spot pool's guarded
   current price. It does not reread mutable proposal metadata. The current manager checks that
   require nonzero YES/NO pools are removed.
6. The manager removes the configured spot-liquidity fraction and splits the recovered base assets
   into complete YES and NO sets.
7. For each conditional pair, the manager-bound adapter requires that no pool address exists,
   creates and initializes the pool at the correctly oriented guarded spot price, and mints the
   first position to itself from the FLM's split inventory.
8. Each adapter call must return a fresh code-bearing pool and nonzero liquidity. The manager stores
   the validated proposal snapshot and position liquidity as one active binding; pool getters are
   derived from the immutable adapter using those stored wrapper pairs.
9. The lifecycle coordinator completes resolver binding and observation-cardinality setup before
   outer lifecycle transaction returns.

Any failure reverts the whole call stack, including the source's official-proposal write, pool
creation, token split, position mint, resolver binding, and any enclosing lifecycle state change.
This full envelope is guaranteed only when the source's activation setter is callable exclusively
through the reviewed coordinator path; an owner bypass would invalidate the guarantee.

The old spot-to-conditional branch of permissionless `sync()` must be deleted, not retained as a
fallback. `sync()` or a renamed `settle()` remains permissionless only for the bound proposal's CTF
settlement.

### Conditional to spot

The manager settles only the condition id stored during activation. It does not require the
mutable proposal source still to expose the same proposal, and it does not accept a caller-supplied
replacement.

After CTF reports denominator `D > 0` and exactly `[D, 0]` or `[0, D]`, settlement:

1. removes the surviving FLM positions;
2. merges complete sets and redeems the winning residue;
3. accounts for all idle outcome and base balances; and
4. optionally returns to the established spot pool if the separately reviewed join primitive and
   its guard are available; otherwise it completes with recovered base assets idle and share-owned.

Every router call uses the stored proposal and verifies its condition id and canonical wrappers
still equal the activation snapshot. A proposal-based router lookup may not silently substitute a
different condition or wrapper address.

Settlement measures the exact collateral received and outcome wrappers consumed by every complete-
set merge and winning-position redemption. A router revert, partial consumption, or underpayment
reverts the whole settlement, preserving the active binding and both positions.

After matched sets are merged and winning residue is redeemed, any remaining losing wrappers are
explicitly unwrapped and redeemed for their immutable zero payout, or equivalently burned through
a reviewed router primitive. The manager must prove their exact consumption before clearing active
token addresses. Losing wrappers may not be stranded in an address the share-accounting code can no
longer reach.

The manager retains the verified winner and durable wrapper snapshot after settlement. Before a
later spot-mode sync, deposit, redemption, or activation, it applies the same exact recovery to
balances donated in that resolved snapshot. Deposits price the recovered base assets, redemptions
pay their proportional share, and a later activation drains them before replacing the snapshot.
Transfers of older wrappers after a later snapshot has replaced them are unsupported
arbitrary-token transfers rather than vault donations.

The manager first removes and resolves the bound conditional assets without consulting the spot
pool. A spot manipulation guard may gate only the subsequent spot join; if it fails, recovered base
assets remain idle, share-owned, and redeemable. A broken or manipulated spot pool must never strand
resolved CTF assets. A 30-minute self-TWAP is never an authorization mechanism for entering or
re-entering a conditional pool.

## Required contract seams

The exact names may change to fit bytecode limits, but the semantics must not.

### Proposal source

```solidity
interface IOfficialProposalActivationTarget {
    function activateOfficialProposal(uint256 proposalId, address proposal) external;

    function PROPOSAL_SOURCE() external view returns (address);

    function canActivateOfficialProposal() external view returns (bool);
}

function bindActivationTarget(address target) external;
```

Binding is one-time and is completed by the bundle factory in the same transaction that binds the
adapters. Only the factory's pinned binding authority may call it. Binding rejects zero and
non-contract targets, a second binding, and any target whose reciprocal `PROPOSAL_SOURCE()` is not
this source. Setting an official proposal reverts while the target is unbound.

In a bound FLM source, the activation setter is callable only by the reviewed lifecycle
coordinator, never directly by the owner, proposal manager EOA, or keeper. The setter passes the
single validated snapshot to the manager. The manager accepts it only from that immutable source
and does not reread mutable proposal metadata. Admission of a later proposal follows
`canActivateOfficialProposal()` and the manager's stored/CTF phase, not a stale manual source
settlement flag.

The new source removes the `requirePools` admission flag and `MissingPool` result. Every deployment
config, batch template, script, and test must remove that field. The manager likewise removes its
current requirement that source-reported YES/NO pool addresses be nonzero before activation.

The manager should trust the bound source as the registry instead of duplicating a mutable creator
attestation in a second immutable manager field. Structural market validation remains in the
manager.

### Pool guard

The spot guard must expose the price it already reads:

```solidity
function assertStablePairAndGetSqrtPrice(address tokenA, address tokenB)
    external
    view
    returns (uint160 nativeOrderSqrtPriceX96);
```

No lifecycle caller supplies the initialization price. The manager maps the guarded spot price to
each conditional pair's token ordering, including checked inversion.

### Liquidity adapter

```solidity
function addFreshFullRangeLiquidity(
    address token0,
    address token1,
    uint256 amount0,
    uint256 amount1,
    uint160 sqrtPriceX96
) external returns (
    address pool,
    uint128 liquidity,
    uint256 amount0Used,
    uint256 amount1Used
);
```

This manager-only call must:

- reject any existing pool, including an uninitialized one;
- create and initialize the pool at `sqrtPriceX96`;
- mint the first position with each unused amount no greater than 50 basis points of that supplied
  amount, using the same two-sided rule currently enforced by `MAX_SYNC_LEFTOVER_BPS`;
- require the exact supplied-token balance delta, reconcile reported use plus refund to that input,
  and clear any downstream token allowance before returning;
- refund unused assets only to the manager; and
- return and verify that the created position and pool match the requested pair and fixed range.

Freshness is enforced inside the manager-bound adapter because that adapter owns the AMM-specific
factory and position-manager knowledge. An external orchestrator may invoke the source and perform
post-mint resolver work in the same outer transaction, but it may not create the pools on the
FLM's behalf. Bundle wiring verifies that the adapter's immutable pool factory and position manager
belong to the same AMM deployment before binding it to the manager.

For proportional redemption, the adapter also needs one detailed removal primitive:

```solidity
struct Removal {
    uint256 principal0;
    uint256 principal1;
    uint256 fees0;
    uint256 fees1;
}

function removeLiquidityDetailed(
    address token0,
    address token1,
    uint128 liquidity
) external returns (Removal memory removed);
```

The manager first invokes it with zero liquidity, classifies that call's entire exact balance delta
as fees, then invokes it with the requested liquidity and classifies the second call's entire exact
delta as principal. Returned field labels are deliberately summed and ignored. The adapter's first
phase must execute the AMM-specific fee-growth realization sequence, collect all accrued fees, and
leave no pre-existing owed amount. The second collection must equal the position manager's reported
principal. This order separates fees from principal without a persistent fee index and does not
assume that a bare `collect` call realizes fees on every supported AMM.

For `liquidity == 0`, the adapter performs only the fee collection: it does not decrease or burn
the position and reports zero principal. A real fork test must prove that each supported position
manager actually materializes current fees on that pre-collection path.

## Spot deposit rounding contract

Let `S` be the existing share supply, `B[T] > 0` each consolidated base-asset balance, and `x[T]`
the caller's offered amounts. The manager mints

$$
m=\min_T\left\lfloor\frac{x[T]S}{B[T]}\right\rfloor
$$

and accepts `a[T] = ceil(m B[T] / S)` of each asset. Therefore `a[T]S >= mB[T]`, which is exactly

$$
\frac{B[T]+a[T]}{S+m}\geq\frac{B[T]}{S}.
$$

The floor chooses a mint amount supported by both offered assets; the ceiling charges enough of
each asset to prevent dilution. Exact transfer-delta checks reject taxed input, and excess input is
never pulled or is refunded. `VaultShareRoundingMath.t.sol` checks both assets independently over
the integer implementation.

## Proportional redemption contract

Let `S` be total FLM share supply before redemption and `s` the shares being burned. For each
active NFT with liquidity `L`, remove

$$
r=\begin{cases}
L, & s=S,\\
\left\lfloor Ls/S\right\rfloor, & s<S.
\end{cases}
$$

Before any adapter call, the manager snapshots the idle balance `I[T]` of each of the six possible
assets—company, collateral, YES-company, NO-company, YES-collateral, and NO-collateral. If detailed
removal reports principal `P[T]` and fees `F[T]`, the exact per-token payout is

```text
P[T] + share(I[T], s, S) + share(F[T], s, S)
```

where `share(x, s, S)` is `x` for the final redeemer and `floor(x*s/S)` otherwise. Principal and
fee deposits from the adapter are never retroactively counted as pre-existing idle balance. The
remainder of each idle and fee bucket stays manager-idle and share-owned; the final redeemer
receives it. Rounding the removed liquidity down favors survivors:

$$
\frac{L-\lfloor Ls/S\rfloor}{S-s}\geq\frac{L}{S}.
$$

During an unresolved proposal, the manager handles each underlying independently. It attempts to
merge exactly `min(YES, NO)` of that underlying in a failure-isolated self-call. Success requires
exact base-token output and exact wrapper consumption. A revert, approval failure, partial
consumption, or underpayment rolls back that underlying's merge and returns its complete sets in
kind. Any unmatched outcomes are also transferred in kind. Redemption never calls an adapter add,
a pool guard, or a liquidity-restoration function.

If active NFT liquidity exists and a non-final redemption rounds every planned NFT removal to zero,
the redemption reverts without burning shares. The holder may combine or transfer shares until at
least one liquidity unit is withdrawable. This avoids silently donating the entire principal claim
in exchange for fees or idle dust.

### Why unresolved base-only redemption is not promised

For either underlying asset `U`, define

$$
D_U=\text{YES}_U-\text{NO}_U.
$$

Splitting and merging complete sets do not change $D_U$. A base-only payout has $D_U=0$, while a
proportional removal from independently traded YES and NO pools can have $D_U\neq0$. Eliminating
that residue requires a market trade, an external balance sheet, another shareholder's opposite
claim, or waiting for resolution.

The safe vault contract is therefore base assets for matched sets plus unmatched outcomes in kind.
A caller may use a separate, opt-in zap to trade those outcomes after receipt. That trade is not
part of FLM share accounting and cannot expose survivor liquidity.

## Spot return and the fair-join gate

Fresh conditional activation needs no balancing swap because both pools are initialized at the
split inventory's price. Returning the winning assets to the established spot pool may be
off-ratio.

The constant-product target and fee bound are derived in
[`constant-product-roundtrip.md`](constant-product-roundtrip.md). The current V3 and Algebra
adapters do not implement that join. A production return path must not use a raw off-ratio mint or
donate excess assets.

V3 remains the implementation target for this amendment, but a rebalance-and-mint primitive is not
accepted until an implementation-specific model covers its finite range, tick crossings, dynamic
or fixed swap fee, community/protocol fee, and integer rounding. Until that gate is met, settlement
may keep unmatched base inventory idle and share-owned; it may not claim the LP-token
nondecrease theorem.

Algebra's dynamic fee can change on the first swap in a block. A fair-join check therefore uses
realized balance deltas and liquidity minted, not a hard-coded live fee or a pre-read fee value.

## Threat model and required behavior

| Threat | Required behavior |
| --- | --- |
| Arbitrary CTF event or proposal log | Ignored; only the bound source callback can activate. |
| Activation target captures any field differently from the source-validated snapshot | The entire source write and target activation revert. |
| Existing or attacker-created conditional pool | Activation reverts with no persistent spot-liquidity movement. |
| First conditional adapter add reverts after both CTF splits | Activation reverts and restores the source write, both splits, spot position, pool lookup, and wrapper custody. |
| Adapter returns a pool other than its canonical pair lookup | Activation reverts and restores the source write, CTF splits, spot position, and created pool. |
| Failure after only one conditional pool is created | Entire official transition rolls back. |
| Post-activation resolver binding reverts | The enclosing lifecycle transaction restores resolver/coordinator state, source write, CTF splits, positions, pools, and manager binding. |
| Source cleared or replaced after activation | Stored proposal and condition still settle normally. |
| Replayed activation or second live proposal | Reverts without changing positions or binding. |
| Company token and collateral are the same ERC-20 | Manager construction reverts, including through the permissionless bundle factory, before any contract bundle can persist. |
| A token, router, adapter, guard, or AMM dependency is an EOA or other code-less address | Manager or factory construction reverts before an unusable direct deployment or bundle can persist; the deployment script rejects configured code-less dependencies before broadcast. |
| An outcome wrapper aliases either base asset | Source admission and manager activation independently reject before spot movement, preserving six distinct accounting buckets. |
| Adapter reports removal assets it did not transfer | The entire operation reverts before survivor-owned idle balances can fund the discrepancy. |
| Adapter preserves receipt totals but swaps principal/fee field labels | The manager ignores labels and classifies exact deltas by the zero-liquidity and nonzero phases. |
| Adapter's zero-liquidity call removes principal or leaves realized fees owed | The adapter violates the audited phase contract; deterministic and real-fork fixtures must prove unchanged liquidity and an immediately fee-free principal phase for the pinned bytecode. |
| A caller initializes a predictable v4 conditional pool before activation | The initialization-only hook rejects every origin except its irreversibly bound adapter; a failed first position reverts that initialization in the same transaction. |
| Another wallet front-runs the published hook salt | The bundle factory hashes the creating wallet with its raw salt before CREATE2, so the other caller derives a different address and cannot consume the intended hook. |
| A third party uses the same v4 pool, ticks, and salt | PoolManager position identity also includes `msg.sender`; the third party creates a separate position and cannot change the adapter-owned liquidity. |
| A v4 fee report is inflated or disagrees with realizable value | A zero-liquidity poke must return identical caller and fee deltas, and only the caller delta is taken. Principal removal follows an internal poke and requires its own fee report to be zero. Any mismatch reverts the unlock. |
| The selected PoolManager runtime or hook binding changes | The adapter pins and rechecks the PoolManager code hash and the hook's PoolManager/adapter binding before every operation. The hook has no proxy, owner setter, or add/remove-liquidity permission. |
| An arbitrary contract calls the adapter unlock callback | Only the pinned PoolManager is accepted; manager-facing add/remove entry points remain restricted to the irreversible manager binding. |
| The first spot mint overwrites a fresh v3 pool's only oracle observation | Production setup raises observation cardinality before minting and waits the complete 30-minute window. Otherwise the immutable guard fails closed with `OLD`; activation cannot proceed on fabricated history. |
| One redeemer manipulates or removes TWAP history | Redemption still succeeds; no guard is consulted. |
| First partial redeemer attempts to take all NFT fees | Pre-collect/decrease/post-collect separation limits payout to its share. |
| v4 donations accrue before a partial manager redemption | The zero-liquidity phase realizes the live fees, only the redeemer's floor-rounded share is paid, and the remainder stays share-owned for survivors. |
| A single-leg v4 donation accrues after a holder exits | The exited balances stay fixed. If that outcome wins, surviving shares receive its base value; if it loses, they receive zero for that leg and its untouched complete-set counterpart remains outside the manager. Settlement does not invent base value. |
| Fees or donations arrive after a partial redemption | Only the then-current share supply owns the new value; exited holders gain no retroactive claim. The live v4/CTF fixture donates again after exit and proves the exited base balances stay fixed through final settlement. |
| Resolved wrappers are donated after settlement but before the next activation | The stored winner and durable wrapper snapshot convert them before a later spot sync, deposit, redemption, or activation; pricing and payout include the value, and activation cannot orphan it by replacing pointers. |
| Fees, donations, deposits, redemptions, and settlement are repeatedly interleaved | Every successful deposit and redemption preserves existing-holder value per share; issued assets stay in known custody and zero supply leaves no managed residue. |
| Merge router is unavailable or maliciously reverts | Withdrawing outcome slice is paid in kind. |
| Settlement router reverts, partially consumes, or underpays | The whole settlement reverts; active positions and the captured binding remain intact. |
| Rounding across sequential redemptions | No overpayment; survivor ratio never falls; final holder receives dust. |
| Bundle, activation, or conditional redemption approaches the Ethereum block limit | The pinned mainnet fork charges base gas plus worst-case nonzero calldata, compares each transaction to the block's actual 60,000,000 gas limit, and requires more than half a block of headroom. |
| Direct native transfer bypasses the six-token accounting model | Reverts; native currency is accepted only from the immutable wrapped-collateral contract during an unwrap. Unavoidable forced native currency is not a supported deposit or donation and remains sweepable only after share supply reaches zero. |
| Owner becomes unavailable after arming emergency exit | After the fixed delay, any account can unwind positions into the manager; settlement of the captured CTF condition and share redemption remain permissionless, and no caller receives shareholder assets. |
| Deadline caller races an already-finalized YES result before it reaches CTF | The deadline path relays the finalized Reality result; it reports forced NO only while Reality remains unresolved. |
| A normal answer remains inside its challenge window at the hard deadline | The answer is still unresolved; the bounded policy reports NO. Deployments must choose `maxQuestionDuration` with this terminal rule in mind. |
| Arbitration remains pending at the hard deadline | The bounded policy reports NO rather than giving arbitration an unbounded veto. |
| Finalized Reality metadata exists but the normal result read fails | The deadline path fails closed without reporting payouts; only pending or canonically unresolved state may use forced NO. |
| Bad fair-join quote or changed spot state | Entire join reverts or leaves inventory idle; no donation. |
| Legacy Algebra conditional pool precreation used only for griefing | Funds remain in spot and custody is safe, but liveness fails; this is why that path remains unfundable. The selected v4 gate rejects outsider initialization instead. |

## Verification gates

### Atomic activation

- force a revert at every source, split, pool-create, initialize, first-mint, resolver, and outer
  lifecycle phase and compare the complete pre/post state envelope;
- reject existing uninitialized, initialized, correctly priced, manipulated, YES-only, and NO-only
  pools;
- reject an already-resolved condition before persistent spot movement and prove full rollback;
- exhaust every outcome-to-outcome and outcome-to-base alias before persistent spot movement;
- test every company/collateral and wrapper address ordering;
- prove only the source can activate and `sync()` cannot perform first activation;
- prove the source setter is reachable only through the lifecycle coordinator and that direct owner,
  EOA, and unbound calls revert;
- prove production configs and scripts contain no pre-existing-pool admission mode;
- prove the first pool liquidity belongs only to the FLM; and
- cover fresh create-initialize-mint against real Algebra and Uniswap V3 deployments; and
- on the pinned official Ethereum v4 PoolManager, prove outsider initialization rejection,
  adapter-only initialization plus first liquidity, donation-fee realization, partial removal, and
  final removal.

### Proportional redemption

- separate fee and principal balance deltas for partial, zero-liquidity, and final removals;
- keep NFT ids unchanged for partial redemption and clear them only for the final holder;
- fuzz share supply, share amount, all three liquidity amounts, six idle balances, and asymmetric
  fees;
- prove per-token conservation across arbitrary sequential redemptions;
- prove adapter-add and guard call counts remain zero during redemption;
- test divergent YES/NO prices and liquidity, merge failure, and unmatched in-kind payout;
- settle correctly after one or many partial redemptions;
- consume explicitly any losing-token residue when the losing balance exceeds the winner, including
  settlement after the final unresolved redemption has reduced FLM supply to zero; and
- repeat partial fee-bearing removal on a real Algebra fork with a gas bound.

### Math and bytecode

- keep the fee-bound executable property test aligned with the proof document;
- keep the executable deposit and redemption floor/ceiling properties aligned with the vault
  equations;
- add exact AMM-specific quote/execution tests before enabling a fair join;
- retain the manager runtime-size gate below EIP-170; and
- remove superseded entry and restoration code instead of carrying two safety models.

## Implementation order

1. **Lifecycle seam:** source binding, source-only activation, stored CTF binding, fresh adapter add,
   and atomic rollback tests.
2. **Redemption seam:** detailed adapter removal, proportional manager accounting, removal of
   redemption-triggered restoration, and sequential-redemption invariants.
3. **Settlement accounting:** recover all remaining position and idle outcomes, then leave safe
   unmatched base inventory idle until the fair-join gate passes.
4. **Fair join:** implement and enable only after the exact V3/Algebra range, fee, and rounding model
   agrees with unit, fuzz, invariant, and fork execution.

A canary must stop before funding if any phase can leave an official proposal recorded without both
FLM-owned first positions, if any partial redemption changes a survivor NFT, if accounting loses a
token unit other than documented survivor-favoring dust, if runtime bytecode crosses EIP-170, or if
the implementation-specific fair-join bound is weaker than its configured on-chain check.
