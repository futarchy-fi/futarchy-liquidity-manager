// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Swapr Algebra pool surface needed for a current-tick/TWAP check.
interface IAlgebraPoolLike {
    function liquidityCooldown() external view returns (uint32);

    function globalState()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 fee,
            uint16 timepointIndex,
            uint8 communityFeeToken0,
            uint8 communityFeeToken1,
            bool unlocked
        );

    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulatives,
            uint112[] memory volatilityCumulatives,
            uint256[] memory volumePerAvgLiquiditys
        );
}
