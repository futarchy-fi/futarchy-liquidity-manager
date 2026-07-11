// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal router surface for splitting, merging, and redeeming futarchy outcome tokens.
/// @dev The manager trusts the configured router to map proposal/collateral pairs to the expected
/// YES/NO wrapped outcome tokens.
interface IFutarchyConditionalRouter {
    /// @notice Splits base collateral into YES and NO wrapped outcome tokens for `proposal`.
    function splitPosition(address proposal, address collateralToken, uint256 amount) external;

    /// @notice Merges equal YES and NO wrapped outcome balances back into base collateral.
    function mergePositions(address proposal, address collateralToken, uint256 amount) external;

    /// @notice Redeems winning outcome tokens for base collateral after proposal settlement.
    function redeemPositions(address proposal, address collateralToken, uint256 amount) external;

    /// @notice Returns which binary proposal outcomes have a nonzero payout.
    function getWinningOutcomes(bytes32 conditionId) external view returns (bool[] memory);
}
