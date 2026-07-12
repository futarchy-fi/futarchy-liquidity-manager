// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolStabilityGuard} from "../interfaces/IPoolStabilityGuard.sol";
import {IUniswapV3FactoryLike} from "../interfaces/IUniswapV3FactoryLike.sol";
import {IUniswapV3PoolLike} from "../interfaces/IUniswapV3PoolLike.sol";

/// @notice Rejects a UniV3 pool whose current tick is more than 50 ticks from its 30m TWAP.
contract UniV3PoolStabilityGuard is IPoolStabilityGuard {
    uint32 public constant TWAP_WINDOW = 30 minutes;
    int24 public constant MAX_TICK_DEVIATION = 50;

    IUniswapV3FactoryLike public immutable FACTORY;
    uint24 public immutable FEE;

    error ZeroAddress();
    error PoolNotFound(address tokenA, address tokenB);
    error InvalidPoolState(address pool);
    error InvalidHistory(address pool);
    error MeanTickOutOfRange(address pool, int56 meanTick);
    error UnstablePool(address pool, int24 currentTick, int24 meanTick);

    constructor(IUniswapV3FactoryLike factory, uint24 fee) {
        if (address(factory) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        FEE = fee;
    }

    function assertStable(address pool) external view {
        _assertStable(pool);
    }

    function assertStablePair(address tokenA, address tokenB) external view {
        address pool = FACTORY.getPool(tokenA, tokenB, FEE);
        if (pool == address(0)) revert PoolNotFound(tokenA, tokenB);
        _assertStable(pool);
    }

    function _assertStable(address pool) internal view {
        if (pool == address(0)) revert ZeroAddress();

        int24 currentTick = _currentTick(pool);
        int24 twapTick = _twapTick(pool);
        int256 deviation = int256(currentTick) - int256(twapTick);
        if (deviation < 0) deviation = -deviation;
        if (deviation > int256(int24(MAX_TICK_DEVIATION))) {
            revert UnstablePool(pool, currentTick, twapTick);
        }
    }

    function _currentTick(address pool) internal view returns (int24 tick) {
        uint160 sqrtPriceX96;
        (sqrtPriceX96, tick,,,,,) = IUniswapV3PoolLike(pool).slot0();
        if (sqrtPriceX96 == 0) revert InvalidPoolState(pool);
    }

    function _twapTick(address pool) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        (int56[] memory tickCumulatives,) = IUniswapV3PoolLike(pool).observe(secondsAgos);
        if (tickCumulatives.length != 2) revert InvalidHistory(pool);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int56 divisor = int56(uint56(TWAP_WINDOW));
        int56 meanTick = tickDelta / divisor;
        if (tickDelta < 0 && tickDelta % divisor != 0) meanTick--;
        if (meanTick < type(int24).min || meanTick > type(int24).max) {
            revert MeanTickOutOfRange(pool, meanTick);
        }
        // Range checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(meanTick);
    }
}
