// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockAlgebraPoolLike {
    bytes4 internal constant GET_TIMEPOINTS_SELECTOR = bytes4(keccak256("getTimepoints(uint32[])"));

    uint160 public sqrtPriceX96 = 1;
    int24 public tick;
    int256 internal _older;
    int256 internal _newer;
    uint256 internal _historyLength = 2;
    bool public shouldRevert;

    function setGlobalState(uint160 newSqrtPriceX96, int24 newTick) external {
        sqrtPriceX96 = newSqrtPriceX96;
        tick = newTick;
    }

    function setTickCumulatives(int56 older, int56 newer) external {
        _older = older;
        _newer = newer;
        _historyLength = 2;
    }

    function setHistoryLength(uint256 length) external {
        require(length <= 2);
        _historyLength = length;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function globalState()
        external
        view
        returns (uint160, int24, uint16, uint16, uint8, uint8, bool)
    {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }

    /// @dev Hand-encodes Algebra's four dynamic return arrays to avoid a solc 0.8.20
    /// stack-too-deep bug in test mocks. Only tick cumulatives are populated.
    fallback() external {
        require(msg.sig == GET_TIMEPOINTS_SELECTOR);
        require(!shouldRevert, "missing history");

        uint256 headOffset;
        uint256 historyLength;
        uint256 firstAgo;
        uint256 secondAgo;
        assembly {
            headOffset := calldataload(4)
            historyLength := calldataload(36)
            firstAgo := calldataload(68)
            secondAgo := calldataload(100)
        }
        require(
            msg.data.length == 132 && headOffset == 32 && historyLength == 2
                && firstAgo == 30 minutes && secondAgo == 0
        );

        uint256 tickCount = _historyLength;
        int256 older = _older;
        int256 newer = _newer;
        bytes memory result = new bytes(256 + 32 * tickCount);
        assembly {
            let data := add(result, 32)
            let secondOffset := add(160, mul(32, tickCount))
            mstore(data, 128)
            mstore(add(data, 32), secondOffset)
            mstore(add(data, 64), add(secondOffset, 32))
            mstore(add(data, 96), add(secondOffset, 64))
            mstore(add(data, 128), tickCount)
            if gt(tickCount, 0) { mstore(add(data, 160), older) }
            if gt(tickCount, 1) { mstore(add(data, 192), newer) }
            return(data, mload(result))
        }
    }
}
