// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {AlgebraPoolStabilityGuard} from "../../src/oracles/AlgebraPoolStabilityGuard.sol";

contract AlgebraPoolStabilityGuardForkTest is Test {
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
    address internal constant SWAPR_ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;

    function testFork_gno_sdai_spot_pool_passes_thirtyMinuteGuard() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        AlgebraPoolStabilityGuard guard =
            new AlgebraPoolStabilityGuard(IAlgebraFactoryLike(SWAPR_ALGEBRA_FACTORY));
        guard.assertStablePair(GNO, SDAI);
    }
}
