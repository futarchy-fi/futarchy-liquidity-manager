// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";

interface IAlgebraMintCallback {
    function algebraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external;
}

contract MockDirectAlgebraPool {
    uint32 public liquidityCooldown;
    uint160 public sqrtPriceX96;
    uint128 internal _liquidity;

    function setLiquidityCooldown(uint32 value) external {
        liquidityCooldown = value;
    }

    function initialize(uint160 value) external {
        sqrtPriceX96 = value;
    }

    function globalState()
        external
        view
        returns (uint160, int24, uint16, uint16, uint8, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function mint(
        address sender,
        address,
        int24,
        int24,
        uint128 liquidityDesired,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1, uint128 liquidityActual) {
        IAlgebraMintCallback(sender).algebraMintCallback(liquidityDesired, liquidityDesired, data);
        _liquidity += liquidityDesired;
        return (liquidityDesired, liquidityDesired, liquidityDesired);
    }

    function burn(int24, int24, uint128) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function collect(address, int24, int24, uint128, uint128)
        external
        pure
        returns (uint128, uint128)
    {
        return (0, 0);
    }

    function positions(bytes32)
        external
        view
        returns (uint128, uint32, uint256, uint256, uint128, uint128)
    {
        return (_liquidity, 0, 0, 0, 0, 0);
    }
}

contract MockDirectAlgebraFactory is IAlgebraFactoryLike {
    MockDirectAlgebraPool public nextPool;
    mapping(bytes32 => address) internal _pools;

    function setNextPool(MockDirectAlgebraPool pool) external {
        nextPool = pool;
    }

    function createPool(address tokenA, address tokenB) external returns (address pool) {
        pool = address(nextPool);
        _pools[_pairKey(tokenA, tokenB)] = pool;
    }

    function poolByPair(address tokenA, address tokenB) external view returns (address) {
        return _pools[_pairKey(tokenA, tokenB)];
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
    }
}
