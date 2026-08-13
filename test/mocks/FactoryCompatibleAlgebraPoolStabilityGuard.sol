// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {IPoolStabilityGuard} from "../../src/interfaces/IPoolStabilityGuard.sol";
import {AlgebraPoolStabilityGuard} from "../../src/oracles/AlgebraPoolStabilityGuard.sol";

/// @dev Test-only bridge for the frozen bundle factory's legacy FACTORY() wiring check.
contract FactoryCompatibleAlgebraPoolStabilityGuard is IPoolStabilityGuard {
    IAlgebraFactoryLike public immutable FACTORY;
    AlgebraPoolStabilityGuard public immutable GUARD;

    constructor(IAlgebraFactoryLike factory) {
        FACTORY = factory;
        GUARD = new AlgebraPoolStabilityGuard(factory);
    }

    function assertStable(address pool) external view {
        GUARD.assertStable(pool);
    }

    function assertStablePair(address tokenA, address tokenB) external view {
        GUARD.assertStablePair(tokenA, tokenB);
    }

    function assertStablePairAndGetSqrtPrice(address tokenA, address tokenB)
        external
        view
        returns (uint160)
    {
        return GUARD.assertStablePairAndGetSqrtPrice(tokenA, tokenB);
    }
}
