// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    SwaprAlgebraDirectConditionalAdapter
} from "../src/adapters/SwaprAlgebraDirectConditionalAdapter.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {MockDirectAlgebraFactory, MockDirectAlgebraPool} from "./mocks/MockDirectAlgebraPool.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";

contract SwaprAlgebraDirectConditionalAdapterTest is Test {
    uint160 internal constant Q96 = uint160(1) << 96;

    MockMintableERC20 internal tokenA;
    MockMintableERC20 internal tokenB;
    MockDirectAlgebraFactory internal factory;
    MockDirectAlgebraPool internal pool;
    SwaprAlgebraDirectConditionalAdapter internal adapter;

    function setUp() public {
        tokenA = new MockMintableERC20("A", "A");
        tokenB = new MockMintableERC20("B", "B");
        factory = new MockDirectAlgebraFactory();
        pool = new MockDirectAlgebraPool();
        factory.setNextPool(pool);
        adapter = new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(address(factory)));
        adapter.bindManager(address(this));

        tokenA.mint(address(this), 1 ether);
        tokenB.mint(address(this), 1 ether);
        tokenA.approve(address(adapter), type(uint256).max);
        tokenB.approve(address(adapter), type(uint256).max);
    }

    function test_addFresh_reverts_when_liquidity_cooldown_is_armed() public {
        pool.setLiquidityCooldown(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                SwaprAlgebraDirectConditionalAdapter.LiquidityCooldownActive.selector,
                address(pool),
                uint32(1)
            )
        );
        _addFresh();
    }

    function test_addFresh_succeeds_when_liquidity_cooldown_is_zero() public {
        (address createdPool, uint128 liquidity,,) = _addFresh();

        assertEq(createdPool, address(pool));
        assertGt(liquidity, 0);
    }

    function _addFresh()
        internal
        returns (address createdPool, uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        (address token0, address token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        return adapter.addFreshFullRangeLiquidity(token0, token1, 1 ether, 1 ether, Q96);
    }
}
