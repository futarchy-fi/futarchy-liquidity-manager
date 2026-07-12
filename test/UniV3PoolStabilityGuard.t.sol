// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {UniV3PoolStabilityGuard} from "../src/oracles/UniV3PoolStabilityGuard.sol";
import {MockUniswapV3FactoryLike} from "./mocks/MockUniswapV3FactoryLike.sol";
import {MockUniswapV3PoolLike} from "./mocks/MockUniswapV3PoolLike.sol";

contract UniV3PoolStabilityGuardTest is Test {
    address internal constant TOKEN_A = address(0xA);
    address internal constant TOKEN_B = address(0xB);
    uint24 internal constant FEE = 500;

    MockUniswapV3FactoryLike internal factory;
    MockUniswapV3PoolLike internal pool;
    UniV3PoolStabilityGuard internal guard;

    function setUp() public {
        factory = new MockUniswapV3FactoryLike();
        pool = new MockUniswapV3PoolLike();
        guard = new UniV3PoolStabilityGuard(IUniswapV3FactoryLike(address(factory)), FEE);
        factory.setPool(TOKEN_A, TOKEN_B, FEE, address(pool));
    }

    function test_configuration_is_fixed() public view {
        assertEq(address(guard.FACTORY()), address(factory));
        assertEq(guard.FEE(), FEE);
        assertEq(guard.TWAP_WINDOW(), 30 minutes);
        assertEq(guard.MAX_TICK_DEVIATION(), 50);
    }

    function test_resolves_unordered_configured_fee_pool_only() public {
        address fee3000Pool = address(0x3000);
        factory.setPool(TOKEN_A, TOKEN_B, 3000, fee3000Pool);

        guard.assertStablePair(TOKEN_B, TOKEN_A);
    }

    function test_accepts_50_tick_boundary_and_rejects_51() public {
        pool.setSlot0(1, 50);
        guard.assertStable(address(pool));

        pool.setSlot0(1, 51);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV3PoolStabilityGuard.UnstablePool.selector, address(pool), int24(51), int24(0)
            )
        );
        guard.assertStable(address(pool));
    }

    function test_rounds_negative_mean_tick_down() public {
        pool.setTickCumulatives(0, -1801);
        pool.setSlot0(1, -52);

        guard.assertStable(address(pool));
    }

    function test_rejects_missing_pool() public {
        address missingToken = address(0xC);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV3PoolStabilityGuard.PoolNotFound.selector, TOKEN_A, missingToken
            )
        );
        guard.assertStablePair(TOKEN_A, missingToken);
    }

    function test_rejects_uninitialized_pool() public {
        pool.setSlot0(0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(UniV3PoolStabilityGuard.InvalidPoolState.selector, address(pool))
        );
        guard.assertStable(address(pool));
    }

    function test_rejects_insufficient_history() public {
        pool.setHistoryLength(1);
        vm.expectRevert(
            abi.encodeWithSelector(UniV3PoolStabilityGuard.InvalidHistory.selector, address(pool))
        );
        guard.assertStable(address(pool));
    }

    function test_fails_closed_when_history_query_reverts() public {
        pool.setShouldRevert(true);
        vm.expectRevert(bytes("missing history"));
        guard.assertStable(address(pool));
    }

    function test_rejects_out_of_range_mean_tick() public {
        int56 meanTick = int56(int256(type(int24).max) + 1);
        pool.setTickCumulatives(0, meanTick * int56(uint56(30 minutes)));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniV3PoolStabilityGuard.MeanTickOutOfRange.selector, address(pool), meanTick
            )
        );
        guard.assertStable(address(pool));
    }

    function test_rejects_zero_addresses() public {
        vm.expectRevert(UniV3PoolStabilityGuard.ZeroAddress.selector);
        new UniV3PoolStabilityGuard(IUniswapV3FactoryLike(address(0)), FEE);

        vm.expectRevert(UniV3PoolStabilityGuard.ZeroAddress.selector);
        guard.assertStable(address(0));
    }
}
