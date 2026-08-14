// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Read-only price-stability gate used before automated liquidity migrations.
interface IPoolStabilityGuard {
    /// @notice Reverts unless `pool` satisfies the implementation's fixed stability policy.
    function assertStable(address pool) external view;

    /// @notice Resolves a pool for `tokenA`/`tokenB` and reverts unless it is stable.
    function assertStablePair(address tokenA, address tokenB) external view;

    function assertStablePairAndGetSqrtPrice(address tokenA, address tokenB)
        external
        view
        returns (uint160 sqrtPriceX96);
}
