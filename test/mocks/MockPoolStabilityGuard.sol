// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolStabilityGuard} from "../../src/interfaces/IPoolStabilityGuard.sol";

contract MockPoolStabilityGuard is IPoolStabilityGuard {
    mapping(address => bool) public poolFailure;
    mapping(bytes32 => bool) public pairFailure;

    error PoolRejected(address pool);
    error PairRejected(address tokenA, address tokenB);

    function setPoolFailure(address pool, bool fails) external {
        poolFailure[pool] = fails;
    }

    function setPairFailure(address tokenA, address tokenB, bool fails) external {
        pairFailure[_pairKey(tokenA, tokenB)] = fails;
    }

    function assertStable(address pool) external view {
        if (poolFailure[pool]) revert PoolRejected(pool);
    }

    function assertStablePair(address tokenA, address tokenB) external view {
        if (pairFailure[_pairKey(tokenA, tokenB)]) revert PairRejected(tokenA, tokenB);
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
    }
}
