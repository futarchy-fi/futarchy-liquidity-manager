// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {AlgebraPoolStabilityGuard} from "../src/oracles/AlgebraPoolStabilityGuard.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockAlgebraPoolLike} from "./mocks/MockAlgebraPoolLike.sol";

contract AlgebraPoolStabilityGuardTest is Test {
    address internal constant TOKEN_A = address(0xA);
    address internal constant TOKEN_B = address(0xB);

    MockAlgebraFactoryLike internal factory;
    MockAlgebraPoolLike internal pool;
    AlgebraPoolStabilityGuard internal guard;

    function setUp() public {
        factory = new MockAlgebraFactoryLike();
        pool = new MockAlgebraPoolLike();
        guard = new AlgebraPoolStabilityGuard(IAlgebraFactoryLike(address(factory)));
        factory.setPool(TOKEN_A, TOKEN_B, address(pool));
    }

    function test_constants_and_factory_are_fixed() public view {
        assertEq(address(guard.ALGEBRA_FACTORY()), address(factory));
        assertEq(guard.TWAP_WINDOW(), 30 minutes);
        assertEq(guard.MAX_TICK_DEVIATION(), 50);
    }

    function test_assertStable_accepts_deviation_at_boundary() public {
        pool.setGlobalState(1, 50);
        guard.assertStable(address(pool));
    }

    function test_assertStable_reverts_when_liquidity_cooldown_is_armed() public {
        pool.setLiquidityCooldown(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlgebraPoolStabilityGuard.LiquidityCooldownActive.selector, address(pool), uint32(1)
            )
        );
        guard.assertStable(address(pool));
    }

    function test_assertStablePair_resolves_unordered_pair() public view {
        guard.assertStablePair(TOKEN_B, TOKEN_A);
    }

    function test_assertStable_reverts_above_deviation() public {
        pool.setGlobalState(1, 51);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlgebraPoolStabilityGuard.UnstablePool.selector, address(pool), int24(51), int24(0)
            )
        );
        guard.assertStable(address(pool));
    }

    function test_assertStable_rounds_negative_mean_tick_down() public {
        pool.setTickCumulatives(0, -1801);
        pool.setGlobalState(1, -52);

        guard.assertStable(address(pool));
    }

    function test_assertStable_does_not_round_positive_mean_tick_up() public {
        pool.setTickCumulatives(0, 1801);
        pool.setGlobalState(1, 51);

        guard.assertStable(address(pool));
    }

    function test_assertStable_reverts_for_invalid_history_length() public {
        pool.setHistoryLength(1);

        vm.expectRevert(
            abi.encodeWithSelector(AlgebraPoolStabilityGuard.InvalidHistory.selector, address(pool))
        );
        guard.assertStable(address(pool));
    }

    function test_assertStable_fails_closed_when_history_query_reverts() public {
        pool.setShouldRevert(true);

        vm.expectRevert();
        guard.assertStable(address(pool));
    }

    function test_assertStable_reverts_for_uninitialized_pool() public {
        pool.setGlobalState(0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlgebraPoolStabilityGuard.InvalidPoolState.selector, address(pool)
            )
        );
        guard.assertStable(address(pool));
    }

    function test_assertStable_reverts_for_out_of_range_mean_tick() public {
        pool.setTickCumulatives(0, int56(int256(type(int24).max) + 1) * 1800);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlgebraPoolStabilityGuard.MeanTickOutOfRange.selector,
                address(pool),
                int56(int256(type(int24).max) + 1)
            )
        );
        guard.assertStable(address(pool));
    }

    function test_assertStablePair_reverts_when_pool_is_missing() public {
        address missingToken = address(0xC);

        vm.expectRevert(
            abi.encodeWithSelector(
                AlgebraPoolStabilityGuard.PoolNotFound.selector, TOKEN_A, missingToken
            )
        );
        guard.assertStablePair(TOKEN_A, missingToken);
    }

    function test_constructor_and_direct_check_reject_zero_addresses() public {
        vm.expectRevert(AlgebraPoolStabilityGuard.ZeroAddress.selector);
        new AlgebraPoolStabilityGuard(IAlgebraFactoryLike(address(0)));

        vm.expectRevert(AlgebraPoolStabilityGuard.ZeroAddress.selector);
        guard.assertStable(address(0));
    }
}
