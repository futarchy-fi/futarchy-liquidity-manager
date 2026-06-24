// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Generic full-range liquidity adapter interface used by the manager.
/// @dev Adapters are in audit scope. The manager verifies reported input usage does not exceed the
/// requested amounts, but adapter custody and external AMM interactions must still be reviewed.
interface IFutarchyLiquidityAdapter {
    /// @notice Adds liquidity for an ordered token pair.
    /// @param token0 Lower-address token in the pair.
    /// @param token1 Higher-address token in the pair.
    /// @param amount0Desired Maximum token0 amount the adapter may use.
    /// @param amount1Desired Maximum token1 amount the adapter may use.
    /// @param data Adapter-specific slippage, deadline, tick, or pool-initialization calldata.
    /// @return liquidityMinted Adapter liquidity units minted.
    /// @return amount0Used Actual token0 amount consumed.
    /// @return amount1Used Actual token1 amount consumed.
    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata data
    ) external returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used);

    /// @notice Removes liquidity from an ordered token pair.
    /// @param data Adapter-specific slippage/deadline calldata.
    /// @return amount0Out Token0 amount returned to the caller.
    /// @return amount1Out Token1 amount returned to the caller.
    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0Out, uint256 amount1Out);

    /// @notice Reinvests collectable fees or idle adapter balances into the active position.
    /// @param data Adapter-specific slippage/deadline calldata.
    /// @return liquidityAdded Additional adapter liquidity units minted.
    function compoundPosition(address token0, address token1, bytes calldata data)
        external
        returns (uint128 liquidityAdded);
}
