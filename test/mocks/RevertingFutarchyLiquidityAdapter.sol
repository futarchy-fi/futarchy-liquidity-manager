// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

contract RevertingFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
    function addFreshFullRangeLiquidity(address, address, uint256, uint256, uint160)
        external
        pure
        returns (address, uint128, uint256, uint256)
    {
        revert("LP add failed");
    }

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

    function removeLiquidityDetailed(address, address, uint128)
        external
        pure
        returns (Removal memory)
    {
        revert("not used");
    }
}
