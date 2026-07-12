// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV3PoolLike} from "../../src/interfaces/IUniswapV3PoolLike.sol";

contract MockUniswapV3PoolLike is IUniswapV3PoolLike {
    uint160 public sqrtPriceX96 = 1;
    int24 public tick;
    int56 internal older;
    int56 internal newer;
    uint256 internal historyLength = 2;
    bool public shouldRevert;

    function setSlot0(uint160 newSqrtPriceX96, int24 newTick) external {
        sqrtPriceX96 = newSqrtPriceX96;
        tick = newTick;
    }

    function setTickCumulatives(int56 newOlder, int56 newNewer) external {
        older = newOlder;
        newer = newNewer;
        historyLength = 2;
    }

    function setHistoryLength(uint256 length) external {
        require(length <= 2);
        historyLength = length;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 2, 2, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidity)
    {
        require(!shouldRevert, "missing history");
        require(
            secondsAgos.length == 2 && secondsAgos[0] == 30 minutes && secondsAgos[1] == 0,
            "wrong window"
        );

        tickCumulatives = new int56[](historyLength);
        secondsPerLiquidity = new uint160[](historyLength);
        if (historyLength > 0) tickCumulatives[0] = older;
        if (historyLength > 1) tickCumulatives[1] = newer;
    }
}
