// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";

contract MockAlgebraFactoryLike is IAlgebraFactoryLike {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, address pool) external {
        pools[_pairKey(tokenA, tokenB)] = pool;
    }

    function poolByPair(address tokenA, address tokenB) external view returns (address) {
        return pools[_pairKey(tokenA, tokenB)];
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
    }
}
