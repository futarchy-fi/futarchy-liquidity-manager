// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

contract OverusingFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
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

    function removeLiquidity(address, address, uint128, bytes calldata)
        external
        pure
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        amount0Out = 0;
        amount1Out = 0;
    }

    function compoundPosition(address, address, bytes calldata)
        external
        pure
        returns (uint128 liquidityAdded)
    {
        liquidityAdded = 0;
    }
}
