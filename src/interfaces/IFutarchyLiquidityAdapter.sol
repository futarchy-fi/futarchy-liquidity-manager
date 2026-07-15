// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Generic full-range liquidity adapter interface used by the manager.
interface IFutarchyLiquidityAdapter {
    struct Removal {
        uint256 principal0;
        uint256 principal1;
        uint256 fees0;
        uint256 fees1;
    }

    function addFreshFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    )
        external
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);

    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata data
    ) external returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);

    function removeLiquidityDetailed(address token0, address token1, uint128 liquidity)
        external
        returns (Removal memory removed);
}
