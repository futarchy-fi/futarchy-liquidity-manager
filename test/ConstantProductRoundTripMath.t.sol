// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Continuous constant-product check for docs/constant-product-roundtrip.md equation (6c).
contract ConstantProductRoundTripMathTest is Test {
    function testFuzz_feeBearingJoinRespectsTightContinuousBound(
        uint32 pRaw,
        uint32 qRaw,
        uint32 aRaw,
        uint32 bRaw,
        uint32 mRaw,
        uint32 nRaw
    ) public pure {
        // gamma = p/q, u = a/b, and z = m/n > 1.
        uint256 q = bound(qRaw, 1, 1_000_000);
        uint256 p = bound(pRaw, 1, q);
        uint256 a = bound(aRaw, 0, 1_000_000);
        uint256 b = bound(bRaw, 1, 1_000_000);
        uint256 n = bound(nRaw, 1, 999_999);
        uint256 m = bound(mRaw, n + 1, 1_000_000);

        // h*z^2 / ((1+h*z)(z-1)) >= 4*gamma/(1+gamma)^2,
        // with h = gamma*(1+u), after clearing every positive denominator.
        uint256 left = (a + b) * m * m * (p + q) * (p + q);
        uint256 right = 4 * q * (q * b * n + p * (a + b) * m) * (m - n);

        assertGe(left, right);
    }

    function test_feeBoundIsTight() public pure {
        // gamma = 997/1000, u = 0, z = 2/(1-gamma) = 2000/3.
        uint256 p = 997;
        uint256 q = 1000;
        uint256 a = 0;
        uint256 b = 1;
        uint256 m = 2000;
        uint256 n = 3;

        uint256 left = (a + b) * m * m * (p + q) * (p + q);
        uint256 right = 4 * q * (q * b * n + p * (a + b) * m) * (m - n);

        assertEq(left, right);
    }
}
