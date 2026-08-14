// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Executable rounding proofs for the vault equations in the atomic lifecycle amendment.
contract VaultShareRoundingMathTest is Test {
    function testFuzz_depositRoundingCannotDiluteEitherAsset(
        uint96 supplyRaw,
        uint96 balance0Raw,
        uint96 balance1Raw,
        uint96 offered0Raw,
        uint96 offered1Raw
    ) public pure {
        uint256 supply = bound(supplyRaw, 1, type(uint96).max);
        uint256 balance0 = bound(balance0Raw, 1, type(uint96).max);
        uint256 balance1 = bound(balance1Raw, 1, type(uint96).max);
        uint256 offered0 = bound(offered0Raw, 1, type(uint96).max);
        uint256 offered1 = bound(offered1Raw, 1, type(uint96).max);

        uint256 shares0 = Math.mulDiv(offered0, supply, balance0);
        uint256 shares1 = Math.mulDiv(offered1, supply, balance1);
        uint256 minted = shares0 < shares1 ? shares0 : shares1;
        if (minted == 0) return;

        uint256 accepted0 = Math.mulDiv(minted, balance0, supply, Math.Rounding.Up);
        uint256 accepted1 = Math.mulDiv(minted, balance1, supply, Math.Rounding.Up);

        assertLe(accepted0, offered0);
        assertLe(accepted1, offered1);
        assertGe((balance0 + accepted0) * supply, balance0 * (supply + minted));
        assertGe((balance1 + accepted1) * supply, balance1 * (supply + minted));
    }

    function testFuzz_partialRedemptionRoundingFavorsSurvivors(
        uint96 supplyRaw,
        uint96 sharesRaw,
        uint96 liquidityRaw,
        uint96 idleRaw,
        uint96 feesRaw
    ) public pure {
        uint256 supply = bound(supplyRaw, 2, type(uint96).max);
        uint256 shares = bound(sharesRaw, 1, supply - 1);
        uint256 liquidity = uint256(liquidityRaw);
        uint256 idle = uint256(idleRaw);
        uint256 fees = uint256(feesRaw);

        uint256 removed = Math.mulDiv(liquidity, shares, supply);
        uint256 idlePaid = Math.mulDiv(idle, shares, supply);
        uint256 feesPaid = Math.mulDiv(fees, shares, supply);
        uint256 survivingShares = supply - shares;

        assertGe((liquidity - removed) * supply, liquidity * survivingShares);
        assertGe((idle - idlePaid) * supply, idle * survivingShares);
        assertGe((fees - feesPaid) * supply, fees * survivingShares);
    }
}
