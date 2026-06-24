// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Algebra factory surface used to verify YES/NO liquidity pools exist.
interface IAlgebraFactoryLike {
    /// @notice Returns the pool address for an unordered token pair, or zero if none exists.
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}
