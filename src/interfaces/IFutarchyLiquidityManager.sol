// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal FLM surface expected by bootstrap integrations.
interface IFutarchyLiquidityManager {
    /// @notice Initializes first spot liquidity from the configured bootstrap recipient.
    /// @dev The concrete manager restricts this call to `BOOTSTRAP_RECIPIENT` and allows it once.
    function initializeFromBootstrap(uint256 companyAmount)
        external
        payable
        returns (uint128 liquidityMinted);

    /// @notice Initializes first spot liquidity with ERC20 collateral from the configured
    /// bootstrap recipient.
    /// @dev The caller must approve both the company token and collateral token.
    function initializeFromBootstrap(uint256 companyAmount, uint256 collateralAmount)
        external
        returns (uint128 liquidityMinted);
}
