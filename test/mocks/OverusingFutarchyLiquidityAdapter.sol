// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

contract OverusingFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
    function addFreshFullRangeLiquidity(address, address, uint256, uint256, uint160)
        external
        pure
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        return (address(1), 1, 0, 0);
    }

    function addFullRangeLiquidity(
        address,
        address,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata
    ) external pure returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used) {
        liquidityMinted = 1;
        amount0Used = amount0Desired + 1;
        amount1Used = amount1Desired;
    }

    function removeLiquidityDetailed(address, address, uint128)
        external
        pure
        returns (Removal memory removed)
    {
        return removed;
    }
}
