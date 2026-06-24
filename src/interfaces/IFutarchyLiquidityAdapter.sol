// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyLiquidityAdapter {
    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata data
    ) external returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);

    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0Out, uint256 amount1Out);

    function compoundPosition(address token0, address token1, bytes calldata data)
        external
        returns (uint128 liquidityAdded);
}
