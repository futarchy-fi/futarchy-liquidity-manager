# Constant-product FLM round-trip invariant

## Status and claim

This note states a mathematical design target for a futarchy liquidity manager. It is not a claim
about the current adapters. In particular, neither a raw Uniswap V2 `mint` with off-ratio assets
nor the current full-range V3-style adapters implement the unbalanced-join rule defined below.

Consider an FLM that burns some LP tokens in a spot company-token/collateral pool, splits the
withdrawn assets into YES and NO outcome tokens, supplies both conditional pools, and later returns
the winning outcome assets to the spot pool. In the continuous, zero-fee model below, the FLM can
recover at least as many LP tokens from the original spot pool as it burned, even when:

- both conditional pools already exist at arbitrary prices;
- either outcome wins;
- prices move arbitrarily while the proposal is active; and
- other accounts trade, add liquidity, or remove liquidity from the spot pool under the same
  invariant-preserving rules.

The result is about the **absolute number of original spot-pool LP tokens**, not an unchanged
percentage of the pool.

## Assumptions

The proof assumes:

1. Every pool uses the constant-product invariant and remains initialized with strictly positive
   reserves and LP-token supply. In particular, the original spot pool is not fully drained and
   reinitialized while the FLM is away.
2. Fees, protocol-fee minting, integer rounding, and fee-on-transfer or rebasing token behavior are
   ignored.
3. Ordinary liquidity additions and removals preserve the pool's invariant per LP token.
4. An **unbalanced join** means an atomic, zero-fee internal swap followed by a proportional
   liquidity addition. Equivalently, it mints LP tokens from the increase in the square root of the
   pool invariant. It is not a raw off-ratio Uniswap V2 `mint`.
5. Splitting one unit of an underlying token creates one YES unit and one NO unit. After binary
   settlement, each winning unit redeems one-for-one for its underlying and each losing unit is
   worthless.

The zero-fee assumption isolates the price- and reserve-ratio question. Real fees are economically
important but are a separate comparison: the FLM may earn less in the conditional pool than it
would have earned by remaining in the spot pool.

## Invariant units and LP tokens

For reserves `(A, B)`, define the pool's geometric liquidity as

$$
H(A,B)=\sqrt{AB}.
$$

If the pool has LP-token supply `L`, define geometric liquidity per LP token as

$$
g=\frac{\sqrt{AB}}{L}.
$$

In a fee-free constant-product pool, `g` is unchanged by the usual pool operations:

- a swap keeps `AB` and `L` unchanged;
- a proportional deposit scales both $\sqrt{AB}$ and `L` by the same factor; and
- a withdrawal scales both $\sqrt{AB}$ and `L` by the same factor.

Therefore arbitrary fee-free trades and invariant-preserving deposits or withdrawals can change
the reserves, price, and total LP supply without changing how much geometric liquidity one LP
token represents.

Suppose the FLM burns `n` LP tokens from the original spot pool and receives `x` company tokens
and `y` collateral tokens. A proportional LP burn gives

$$
\sqrt{xy}=ng. \tag{1}
$$

The right-hand side is the geometric liquidity represented by the `n` burned tokens.

## The unbalanced-join lemma

Let a pre-existing pool have arbitrary reserves `(A, B)`. An unbalanced join supplies `(x, y)` and
mints against the increase in geometric liquidity:

$$
J(A,B;x,y)
=\sqrt{(A+x)(B+y)}-\sqrt{AB}. \tag{2}
$$

The join always contributes at least the standalone geometric liquidity of its input:

$$
J(A,B;x,y)\geq\sqrt{xy}. \tag{3}
$$

To prove it, expand the following identity:

$$
(A+x)(B+y)
=\left(\sqrt{AB}+\sqrt{xy}\right)^2
+\left(\sqrt{Ay}-\sqrt{Bx}\right)^2. \tag{4}
$$

The final square is nonnegative, so

$$
\sqrt{(A+x)(B+y)}\geq\sqrt{AB}+\sqrt{xy},
$$

which is exactly (3). Equality holds when the supplied assets already match the pool ratio,
`x / y = A / B`. A price mismatch makes the inequality strict.

If the pool has LP supply `L` and invariant-per-token `g`, the corresponding fair LP mint is

$$
\Delta L
=L\left(\frac{\sqrt{(A+x)(B+y)}}{\sqrt{AB}}-1\right)
=\frac{J(A,B;x,y)}{g}. \tag{5}
$$

This is the LP-token result of an optimal zero-fee internal swap that makes the depositor's
remaining assets proportional to the post-swap reserves, followed by an ordinary balanced mint.
All supplied assets end in the pool, while the incumbent LP tokens retain the same `g`.

To construct that internal swap, choose intermediate reserves

$$
A_1=\sqrt{AB\frac{A+x}{B+y}}
\quad\text{and}\quad
B_1=\sqrt{AB\frac{B+y}{A+x}}. \tag{6}
$$

They satisfy $A_1B_1=AB$; unless the ratios already match, one reserve increases while the other
decreases, so moving from `(A, B)` to $(A_1,B_1)$ is a feasible zero-fee constant-product swap. If

$$
q=\sqrt{\frac{(A+x)(B+y)}{AB}},
$$

then $q>1$ and $(A+x,B+y)=q(A_1,B_1)$. After the swap, the depositor therefore holds exactly
$(q-1)(A_1,B_1)$, which is proportional to the intermediate reserves and can all be supplied by a
balanced mint. That mint creates $(q-1)L$, exactly equation (5).

## A tight bound for a fee-bearing balancing swap

Exact nondecrease does not survive a positive swap fee. There is nevertheless a tight continuous
bound for the same swap-then-mint construction.

Let $\gamma$ be the fraction of swap input that affects the constant-product price, with
$0<\gamma\leq1$. Thus a 5-basis-point fee has $\gamma=0.9995$. Suppose `(x, y)` is overweight in
the first asset relative to reserves `(A, B)`. The join swaps `s` units of the first asset for
`d` units of the second asset and then supplies the balanced remainder `(x-s, y+d)`. Define

$$
X=\frac{x}{s},\qquad z=1+\frac{y}{d},\qquad u=\frac{s}{A}.
$$

For a fee-on-input constant-product swap,

$$
\frac{d}{B-d}=\gamma u.
$$

The condition that the post-swap assets match the post-swap reserve ratio is equivalent to

$$
X=1+\gamma(1+u)z. \tag{6a}
$$

Set $h=\gamma(1+u)$, so $h\geq\gamma$. Let
$C=\sqrt{(x-s)(y+d)}$ be the minted position's immediate geometric claim—equivalently, its
pro-rata withdrawal claim immediately after the balanced mint. Then

$$
\frac{C^2}{xy}
=\frac{(x-s)(y+d)}{xy}
=\frac{h z^2}{(1+h z)(z-1)}. \tag{6b}
$$

For fixed `z`, the right-hand side increases with `h`, so its minimum has $h=\gamma$. For
$0<\gamma<1$, minimizing the remaining expression over $z>1$ gives $z=2/(1-\gamma)$ and therefore

$$
C\geq c(\gamma)\sqrt{xy},
\qquad
c(\gamma)=\frac{2\sqrt{\gamma}}{1+\gamma}. \tag{6c}
$$

For $\gamma=1$, direct substitution (or the limit as $\gamma\to1$) gives $c(1)=1$.

The opposite swap direction is symmetric. The bound is tight as the swap becomes small relative
to the incumbent pool. It equals one only when $\gamma=1$; for every positive fee there are joins
whose claim is strictly below $\sqrt{xy}$. Using $\gamma=0.9995$—the fee fraction configured by the
current Uniswap V3 adapter—gives the constant-product/full-range-limit factor
`0.9999999687`. This is not a guarantee of that adapter: it performs no balancing swap, uses finite
tick ranges and integer position-manager math, and its pools may contain concentrated positions.

The derivation models a fee retained in the input reserve. If a nonnegative fraction is extracted
as a protocol or community fee, the same lower bound survives in the constant-product model, but
the extracted amount reduces economic recovery and still requires implementation-specific
accounting.

If both conditional entry and the return to spot require a fee-bearing balancing swap, their
factors multiply. If fresh conditional pools are initialized at the supplied ratio, entry needs no
balancing swap and only the return factor applies.

## Conditional leg

Splitting the spot withdrawal produces `(x, y)` for the YES pool and another `(x, y)` for the NO
pool. Apply the unbalanced-join lemma independently to each pool. Their reserve ratios may differ
from the spot price and from each other, but each FLM position receives a geometric-liquidity claim
of at least

$$
\sqrt{xy}=ng. \tag{7}
$$

Fee-free swaps preserve each pool's invariant, and invariant-preserving LP deposits or withdrawals
preserve its geometric liquidity per LP token. Consequently, burning the FLM's LP position in
either conditional pool returns some outcome-token amounts `(u, v)` satisfying

$$
\sqrt{uv}\geq\sqrt{xy}=ng. \tag{8}
$$

Only one conditional pool ultimately matters. If YES wins, `u` YES-company tokens and `v`
YES-collateral tokens redeem one-for-one to `(u, v)` underlying tokens; if NO wins, the identical
argument applies to the NO pool. The losing pool can be worthless without weakening (8), because
the bound was established separately for both positions before the outcome was known.

## Return to the original spot pool

When the FLM returns, let the original spot pool have arbitrary reserves `(R, S)` and LP supply
`L'`. Other accounts may have traded, deposited, or withdrawn in the interim. Under the assumptions
above, the original pool still has the same invariant-per-token `g`.

The FLM redeems the winning outcome tokens and performs another unbalanced join with `(u, v)`. By
the lemma, the join adds at least

$$
J(R,S;u,v)\geq\sqrt{uv}\geq ng. \tag{9}
$$

Dividing by the unchanged geometric liquidity per original spot LP token gives the number `n'` of
new spot LP tokens:

$$
n'=\frac{J(R,S;u,v)}{g}\geq\frac{ng}{g}=n. \tag{10}
$$

Therefore the complete round trip cannot decrease the FLM's number of original spot-pool LP
tokens in this model.

### What changes when the original spot pool earns fees

Let $g_0$ be geometric liquidity per original spot LP token when the FLM leaves. Let $g_T$ be its
value immediately after the return balancing swap and proportional mint; the mint itself preserves
$g_T$. If $c_c$ and $c_s$ are the conditional-entry and spot-return factors from equation (6c), the
corresponding fee-aware comparison is only

$$
\frac{n'}{n}\geq c_c c_s\frac{g_0}{g_T}, \tag{10a}
$$

before counting fees earned by the winning conditional position or by any spot position the FLM
left behind. Spot trading fees can make $g_T>g_0$. Without a bound on that growth, this self-financed
comparison cannot promise recovery of the same absolute spot LP-token count merely from the assets
that were away. Conditional fees may offset the missed spot fees, but they do not do so universally.

### Integer rounding

Equation (6c) is a continuous bound. Swap-output rounding, token-unit granularity, and liquidity
minting rounded down can all reduce the on-chain result. There is no implementation-independent
relative rounding bound. For example, in Algebra at `sqrtPriceX96 = Q96` with ticks
`[-887220, 887220]`, minting one liquidity unit consumes one smallest unit of each token because
positive deltas round up, while immediately burning it returns zero of each token because negative
deltas round down. Relative loss is 100% even with zero fees. Near a finite-range boundary, one
token unit can also correspond to a very large liquidity-unit error, so there is no useful universal
absolute epsilon.

A real adapter must therefore impose minimum position sizes and check explicit swap output, token
usage, and liquidity minted against implementation-specific integer bounds. Failure must revert the
entire join rather than donate an unmatched remainder.

## Why raw Uniswap V2 minting is different

For an existing V2 pool, a raw off-ratio deposit does not mint equation (5). It mints

$$
\Delta L_{\min}
=L\min\left(\frac{x}{A},\frac{y}{B}\right). \tag{11}
$$

Only the limiting proportional amount receives LP-token credit. The excess changes reserves but is
effectively donated to incumbent LPs. To make the loss explicit, suppose without loss of generality
that

$$
\alpha=\frac{x}{A}\leq\beta=\frac{y}{B}.
$$

The new position owns the fraction $\alpha/(1+\alpha)$ of the post-mint pool, so its geometric
claim is

$$
C
=\frac{\alpha}{1+\alpha}\sqrt{(A+x)(B+y)}
=\sqrt{AB}\,\alpha\sqrt{\frac{1+\beta}{1+\alpha}}. \tag{12}
$$

For $\alpha<\beta$,

$$
\frac{C^2}{xy}
=\frac{\alpha(1+\beta)}{\beta(1+\alpha)}<1. \tag{13}
$$

Thus $C<\sqrt{xy}$ whenever the deposit ratio differs from the pool ratio, and
$C/\sqrt{xy}$ can approach zero. Equations (7) through (10) no longer follow.

The proved primitive therefore requires an invariant-growth join: for example, an atomic zap whose
internal balancing swap is fee-free, or AMM/hook accounting that implements equation (5) directly.
A fee-charging zap changes the exact result according to equation (6c), so an exact no-decrease
claim must subsidize that fee or use a genuinely fee-free join.

## What this proof does not establish

This proof deliberately does not establish:

- exact preservation after swap fees, protocol fees, or rounding;
- compensation for spot-pool fees the FLM forgoes while conditional;
- preservation after a donation or raw off-ratio mint changes the spot pool's invariant per LP
  token while the FLM is absent;
- safety of the proposal, oracle, wrapper, pool-identity, or settlement lifecycle;
- safe entry into arbitrary token contracts or arbitrary AMM implementations; or
- that the current FLM adapters implement the invariant-growth join.

Those are separate accounting and security requirements. The result here is narrower: arbitrary
reserve ratios alone do not reduce the recoverable number of original spot LP tokens when both
migrations use the specified zero-fee invariant-growth join.
