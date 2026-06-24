// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Swapr Algebra non-fungible position manager surface used by the adapter.
interface ISwaprAlgebraPositionManager {
    /// @notice Parameters for minting a new concentrated liquidity position.
    struct MintParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Parameters for adding liquidity to an existing NFT position.
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for removing liquidity from an existing NFT position.
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters for collecting owed token balances from an NFT position.
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Mints a new Algebra liquidity position NFT.
    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Creates and initializes the pool if needed, returning the pool address.
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint160 sqrtPriceX96
    ) external returns (address pool);

    /// @notice Adds liquidity to an existing position NFT.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Removes liquidity from an existing position NFT.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collects owed token balances from an existing position NFT.
    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Burns an empty position NFT.
    function burn(uint256 tokenId) external;

    /// @notice Returns position metadata and liquidity for an NFT id.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}
