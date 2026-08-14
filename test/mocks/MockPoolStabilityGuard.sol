// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolStabilityGuard} from "../../src/interfaces/IPoolStabilityGuard.sol";

contract MockPoolStabilityGuard is IPoolStabilityGuard {
    address public FACTORY;
    mapping(address => bool) public poolFailure;
    mapping(bytes32 => bool) public pairFailure;
    uint160 public sqrtPriceX96 = uint160(1 << 96);

    error PoolRejected(address pool);
    error PairRejected(address tokenA, address tokenB);

    function setFactory(address factory) external {
        FACTORY = factory;
    }

    function setPoolFailure(address pool, bool fails) external {
        poolFailure[pool] = fails;
    }

    function setPairFailure(address tokenA, address tokenB, bool fails) external {
        pairFailure[_pairKey(tokenA, tokenB)] = fails;
    }

    function setSqrtPriceX96(uint160 newSqrtPriceX96) external {
        sqrtPriceX96 = newSqrtPriceX96;
    }

    function assertStable(address pool) external view {
        if (poolFailure[pool]) revert PoolRejected(pool);
    }

    function assertStablePair(address tokenA, address tokenB) external view {
        if (pairFailure[_pairKey(tokenA, tokenB)]) revert PairRejected(tokenA, tokenB);
    }

    function assertStablePairAndGetSqrtPrice(address tokenA, address tokenB)
        external
        view
        returns (uint160)
    {
        if (pairFailure[_pairKey(tokenA, tokenB)]) revert PairRejected(tokenA, tokenB);
        return sqrtPriceX96;
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
    }
}
