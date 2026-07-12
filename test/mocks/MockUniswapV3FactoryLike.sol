// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";

contract MockUniswapV3FactoryLike is IUniswapV3FactoryLike {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_poolKey(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_poolKey(tokenA, tokenB, fee)];
    }

    function _poolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB, fee))
            : keccak256(abi.encode(tokenB, tokenA, fee));
    }
}
