// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Fresh-liquidity entry point for an adapter already holding the exact activation assets.
interface IFutarchyPrefundedLiquidityAdapter {
    function poolByPair(address token0, address token1) external view returns (address pool);

    function addPrefundedFreshFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    )
        external
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);
}
