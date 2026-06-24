// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

contract RevertingFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
    function addFullRangeLiquidity(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        liquidityMinted = 0;
        amount0Used = 0;
        amount1Used = 0;
        revert("LP add failed");
    }

    function removeLiquidity(address, address, uint128, bytes calldata)
        external
        pure
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        amount0Out = 0;
        amount1Out = 0;
        revert("not used");
    }

    function compoundPosition(address, address, bytes calldata)
        external
        pure
        returns (uint128 liquidityAdded)
    {
        liquidityAdded = 0;
    }
}
