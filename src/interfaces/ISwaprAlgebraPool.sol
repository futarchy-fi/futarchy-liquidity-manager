// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Swapr Algebra V1 pool surface used by the direct conditional adapter.
interface ISwaprAlgebraPool {
    function initialize(uint160 sqrtPriceX96) external;

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

    function mint(
        address sender,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityDesired,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1, uint128 liquidityActual);

    function burn(int24 tickLower, int24 tickUpper, uint128 liquidity)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    function positions(bytes32 key)
        external
        view
        returns (
            uint128 liquidity,
            uint32 lastLiquidityAddTimestamp,
            uint256 innerFeeGrowth0,
            uint256 innerFeeGrowth1,
            uint128 fees0,
            uint128 fees1
        );
}
