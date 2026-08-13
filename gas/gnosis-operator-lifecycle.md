# Gnosis operator lifecycle gas fixture

Fork block: `47,439,000` on Gnosis. Measured with Foundry `0.8.36`, optimizer enabled, after
including 21,000 intrinsic gas and 16 gas per calldata byte.

| Operation | Conservative gas | Enforced margin |
| --- | ---: | ---: |
| Factory four-contract bundle | 11,966,674 | 3,000,000 below 17,000,000 |
| Safe-driven activation | 15,737,719 | 1,000,000 below 17,000,000 |

The activation fixture creates two fresh Algebra pools. Its margin is deliberately recorded as
observed, not rounded up: the test fails if it falls below 1,000,000 gas of Gnosis block headroom.

The condition is prepared and resolved through the live Gnosis CTF. The test deploys this repo's
router against that CTF and the live canonical Wrapped1155 factory because the supplied live
router does not implement the frozen proposal source's `CONDITIONAL_TOKENS()` dependency getter.
