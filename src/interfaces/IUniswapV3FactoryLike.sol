// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Uniswap V3 factory surface needed for fixed-fee pool lookup.
interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);
}
