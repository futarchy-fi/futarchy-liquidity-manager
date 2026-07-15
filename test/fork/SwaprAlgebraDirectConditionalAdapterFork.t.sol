// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    SwaprAlgebraDirectConditionalAdapter
} from "../../src/adapters/SwaprAlgebraDirectConditionalAdapter.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {ISwaprAlgebraPool} from "../../src/interfaces/ISwaprAlgebraPool.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";

interface IDirectAlgebraSwapPool {
    function swap(
        address recipient,
        bool zeroToOne,
        int256 amountRequired,
        uint160 limitSqrtPrice,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IAlgebraFactoryOwner {
    function owner() external view returns (address);
}

interface IAlgebraCooldownPool {
    function setLiquidityCooldown(uint32 newLiquidityCooldown) external;
}

contract SwaprAlgebraDirectConditionalAdapterForkTest is Test {
    uint256 internal constant GNOSIS_FORK_BLOCK = 47_207_759;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    uint160 internal constant SQRT_PRICE_ONE = uint160(1) << 96;
    uint160 internal constant MIN_SQRT_PRICE = 4_295_128_740;
    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    struct Pair {
        address token0;
        address token1;
        address pool;
        uint128 liquidity;
    }

    function testFork_prefundedActivationPreservesDonationsAndRejectsNonManager() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"), GNOSIS_FORK_BLOCK);

        SwaprAlgebraDirectConditionalAdapter adapter =
            new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        adapter.bindManager(address(this));

        MockMintableERC20 first = new MockMintableERC20("Prefunded 0", "P0");
        MockMintableERC20 second = new MockMintableERC20("Prefunded 1", "P1");
        address token0 = address(first) < address(second) ? address(first) : address(second);
        address token1 = address(first) < address(second) ? address(second) : address(first);
        uint256 amount0 = 1 ether;
        uint256 amount1 = 1 ether;
        uint256 donation0 = 0.123 ether;
        uint256 donation1 = 0;
        MockMintableERC20(token0).mint(address(adapter), amount0 + donation0);
        MockMintableERC20(token1).mint(address(adapter), amount1 + donation1);

        address outsider = address(0xBAD);
        vm.prank(outsider);
        vm.expectRevert(SwaprAlgebraDirectConditionalAdapter.UnauthorizedManager.selector);
        adapter.addPrefundedFreshFullRangeLiquidity(
            token0, token1, amount0, amount1, SQRT_PRICE_ONE
        );

        (address pool, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = adapter.addPrefundedFreshFullRangeLiquidity(
            token0, token1, amount0, amount1, SQRT_PRICE_ONE
        );

        assertGt(liquidity, 0);
        assertEq(IERC20(token0).balanceOf(address(adapter)), donation0);
        assertEq(IERC20(token1).balanceOf(address(adapter)), donation1);
        assertEq(IERC20(token0).balanceOf(address(this)), amount0 - amount0Used);
        assertEq(IERC20(token1).balanceOf(address(this)), amount1 - amount1Used);
        assertEq(_poolLiquidity(pool, address(adapter)), liquidity);

        vm.prank(outsider);
        vm.expectRevert(SwaprAlgebraDirectConditionalAdapter.UnauthorizedManager.selector);
        adapter.removeLiquidityDetailed(token0, token1, liquidity);

        assertEq(IERC20(token0).balanceOf(address(adapter)), donation0);
        assertEq(IERC20(token1).balanceOf(address(adapter)), donation1);
        assertEq(_poolLiquidity(pool, address(adapter)), liquidity);
    }

    function testFork_realFeesPartialFinalRemovalAndTwoPairIsolation() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraDirectConditionalAdapter adapter =
            new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        adapter.bindManager(address(this));

        Pair memory pairA = _createPair(adapter, "Direct A0", "DA0", "Direct A1", "DA1");
        Pair memory pairB = _createPair(adapter, "Direct B0", "DB0", "Direct B1", "DB1");

        assertEq(_poolLiquidity(pairA.pool, address(adapter)), pairA.liquidity);
        assertEq(_poolLiquidity(pairB.pool, address(adapter)), pairB.liquidity);
        assertEq(_keccakPositionLiquidity(pairA.pool, address(adapter)), 0);
        assertEq(_keccakPositionLiquidity(pairB.pool, address(adapter)), 0);

        _swap(pairA);
        _swap(pairB);

        IFutarchyLiquidityAdapter.Removal memory feesA = _remove(adapter, pairA, 0);
        assertGt(feesA.fees0 + feesA.fees1, 0, "pair A must accrue real swap fees");
        assertEq(_tracked(adapter, pairA), pairA.liquidity);
        _assertPairUnchanged(adapter, pairB, pairB.liquidity);

        uint128 partialA = pairA.liquidity / 3;
        IFutarchyLiquidityAdapter.Removal memory principalA = _remove(adapter, pairA, partialA);
        assertGt(principalA.principal0 + principalA.principal1, 0);
        uint128 remainingA = pairA.liquidity - partialA;
        _assertPairUnchanged(adapter, pairA, remainingA);
        _assertPairUnchanged(adapter, pairB, pairB.liquidity);

        _swap(pairA);
        IFutarchyLiquidityAdapter.Removal memory finalA = _remove(adapter, pairA, remainingA);
        assertGt(finalA.fees0 + finalA.fees1, 0, "pair A must accrue fees after partial exit");
        assertGt(finalA.principal0 + finalA.principal1, 0);
        _assertPairUnchanged(adapter, pairA, 0);
        _assertPairUnchanged(adapter, pairB, pairB.liquidity);

        IFutarchyLiquidityAdapter.Removal memory feesB = _remove(adapter, pairB, 0);
        assertGt(feesB.fees0 + feesB.fees1, 0, "pair B must retain its own fees");
        uint128 partialB = pairB.liquidity / 2;
        IFutarchyLiquidityAdapter.Removal memory principalB = _remove(adapter, pairB, partialB);
        assertGt(principalB.principal0 + principalB.principal1, 0);
        uint128 remainingB = pairB.liquidity - partialB;
        _assertPairUnchanged(adapter, pairB, remainingB);

        IFutarchyLiquidityAdapter.Removal memory finalB = _remove(adapter, pairB, remainingB);
        assertGt(finalB.principal0 + finalB.principal1, 0);
        _assertPairUnchanged(adapter, pairB, 0);

        assertEq(IERC20(pairA.token0).balanceOf(address(adapter)), 0);
        assertEq(IERC20(pairA.token1).balanceOf(address(adapter)), 0);
        assertEq(IERC20(pairB.token0).balanceOf(address(adapter)), 0);
        assertEq(IERC20(pairB.token1).balanceOf(address(adapter)), 0);
    }

    function testFork_thirdPartyMintDonationIsRemovedProRataAndCannotBrick() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraDirectConditionalAdapter adapter =
            new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        adapter.bindManager(address(this));
        Pair memory pair = _createPair(adapter, "Grief A0", "GA0", "Grief A1", "GA1");

        uint128 donatedLiquidity = pair.liquidity / 1000;
        (,, uint128 donatedActual) = ISwaprAlgebraPool(pair.pool)
            .mint(
                address(this),
                address(adapter),
                TICK_LOWER,
                TICK_UPPER,
                donatedLiquidity,
                abi.encode(pair.token0, pair.token1)
            );
        assertEq(donatedActual, donatedLiquidity);
        uint128 actualBefore = pair.liquidity + donatedLiquidity;
        assertEq(_poolLiquidity(pair.pool, address(adapter)), actualBefore);
        assertEq(_tracked(adapter, pair), pair.liquidity);

        uint128 logicalPartial = pair.liquidity / 3;
        uint128 expectedActualPartial =
            uint128((uint256(actualBefore) * logicalPartial) / pair.liquidity);
        IFutarchyLiquidityAdapter.Removal memory partialRemoval =
            _remove(adapter, pair, logicalPartial);
        assertGt(partialRemoval.principal0 + partialRemoval.principal1, 0);
        assertEq(_tracked(adapter, pair), pair.liquidity - logicalPartial);
        assertEq(_poolLiquidity(pair.pool, address(adapter)), actualBefore - expectedActualPartial);

        IFutarchyLiquidityAdapter.Removal memory finalRemoval =
            _remove(adapter, pair, pair.liquidity - logicalPartial);
        assertGt(finalRemoval.principal0 + finalRemoval.principal1, 0);
        assertEq(_tracked(adapter, pair), 0);
        assertEq(_poolLiquidity(pair.pool, address(adapter)), 0);
        assertEq(IERC20(pair.token0).balanceOf(address(adapter)), 0);
        assertEq(IERC20(pair.token1).balanceOf(address(adapter)), 0);
    }

    function testFork_mutableCooldownLetsThirdPartyMintRepeatedlyBlockBurn() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraDirectConditionalAdapter adapter =
            new SwaprAlgebraDirectConditionalAdapter(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        adapter.bindManager(address(this));
        Pair memory pair = _createPair(adapter, "Cooldown A0", "CA0", "Cooldown A1", "CA1");

        vm.prank(IAlgebraFactoryOwner(ALGEBRA_FACTORY).owner());
        IAlgebraCooldownPool(pair.pool).setLiquidityCooldown(uint32(1 days));
        assertEq(ISwaprAlgebraPool(pair.pool).liquidityCooldown(), 1 days);

        uint128 dustLiquidity = pair.liquidity / 1000;
        vm.warp(block.timestamp + 1 days + 1);
        _donateLiquidity(pair, address(adapter), dustLiquidity);
        vm.expectRevert();
        adapter.removeLiquidityDetailed(pair.token0, pair.token1, 1);

        vm.warp(block.timestamp + 1 days + 1);
        _donateLiquidity(pair, address(adapter), dustLiquidity);
        vm.expectRevert();
        adapter.removeLiquidityDetailed(pair.token0, pair.token1, 1);
    }

    function _createPair(
        SwaprAlgebraDirectConditionalAdapter adapter,
        string memory name0,
        string memory symbol0,
        string memory name1,
        string memory symbol1
    ) private returns (Pair memory pair) {
        MockMintableERC20 first = new MockMintableERC20(name0, symbol0);
        MockMintableERC20 second = new MockMintableERC20(name1, symbol1);
        pair.token0 = address(first) < address(second) ? address(first) : address(second);
        pair.token1 = address(first) < address(second) ? address(second) : address(first);

        MockMintableERC20(pair.token0).mint(address(this), 3 ether);
        MockMintableERC20(pair.token1).mint(address(this), 3 ether);
        IERC20(pair.token0).approve(address(adapter), type(uint256).max);
        IERC20(pair.token1).approve(address(adapter), type(uint256).max);
        (pair.pool, pair.liquidity,,) = adapter.addFreshFullRangeLiquidity(
            pair.token0, pair.token1, 1 ether, 1 ether, SQRT_PRICE_ONE
        );

        assertEq(
            IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(pair.token0, pair.token1), pair.pool
        );
        assertGt(pair.liquidity, 0);
        assertEq(IERC20(pair.token0).balanceOf(address(adapter)), 0);
        assertEq(IERC20(pair.token1).balanceOf(address(adapter)), 0);
    }

    function _swap(Pair memory pair) private {
        IDirectAlgebraSwapPool(pair.pool)
            .swap(
                address(this),
                true,
                int256(0.1 ether),
                MIN_SQRT_PRICE,
                abi.encode(pair.token0, pair.token1)
            );
    }

    function _remove(
        SwaprAlgebraDirectConditionalAdapter adapter,
        Pair memory pair,
        uint128 liquidity
    ) private returns (IFutarchyLiquidityAdapter.Removal memory removal) {
        uint256 balance0Before = IERC20(pair.token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(pair.token1).balanceOf(address(this));
        removal = adapter.removeLiquidityDetailed(pair.token0, pair.token1, liquidity);
        assertEq(
            IERC20(pair.token0).balanceOf(address(this)) - balance0Before,
            removal.fees0 + removal.principal0
        );
        assertEq(
            IERC20(pair.token1).balanceOf(address(this)) - balance1Before,
            removal.fees1 + removal.principal1
        );
    }

    function _donateLiquidity(Pair memory pair, address recipient, uint128 liquidity) private {
        (,, uint128 donated) = ISwaprAlgebraPool(pair.pool)
            .mint(
                address(this),
                recipient,
                TICK_LOWER,
                TICK_UPPER,
                liquidity,
                abi.encode(pair.token0, pair.token1)
            );
        assertEq(donated, liquidity);
    }

    function _assertPairUnchanged(
        SwaprAlgebraDirectConditionalAdapter adapter,
        Pair memory pair,
        uint128 expected
    ) private view {
        assertEq(_tracked(adapter, pair), expected);
        assertEq(_poolLiquidity(pair.pool, address(adapter)), expected);
    }

    function _tracked(SwaprAlgebraDirectConditionalAdapter adapter, Pair memory pair)
        private
        view
        returns (uint128)
    {
        return adapter.positionLiquidity(keccak256(abi.encode(pair.token0, pair.token1)));
    }

    function _poolLiquidity(address pool, address owner) private view returns (uint128 liquidity) {
        bytes32 key = bytes32(
            (uint256(uint160(owner)) << 48) | (uint256(uint24(TICK_LOWER)) << 24)
                | uint256(uint24(TICK_UPPER))
        );
        (liquidity,,,,,) = ISwaprAlgebraPool(pool).positions(key);
    }

    function _keccakPositionLiquidity(address pool, address owner)
        private
        view
        returns (uint128 liquidity)
    {
        bytes32 key = keccak256(abi.encodePacked(owner, TICK_LOWER, TICK_UPPER));
        (liquidity,,,,,) = ISwaprAlgebraPool(pool).positions(key);
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
    {
        (address token0, address token1) = abi.decode(data, (address, address));
        require(
            msg.sender == IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(token0, token1), "pool"
        );
        if (amount0Delta > 0) {
            require(IERC20(token0).transfer(msg.sender, uint256(amount0Delta)), "token0");
        }
        if (amount1Delta > 0) {
            require(IERC20(token1).transfer(msg.sender, uint256(amount1Delta)), "token1");
        }
    }

    function algebraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external
    {
        (address token0, address token1) = abi.decode(data, (address, address));
        require(
            msg.sender == IAlgebraFactoryLike(ALGEBRA_FACTORY).poolByPair(token0, token1), "pool"
        );
        if (amount0Owed > 0) {
            require(IERC20(token0).transfer(msg.sender, amount0Owed), "token0");
        }
        if (amount1Owed > 0) {
            require(IERC20(token1).transfer(msg.sender, amount1Owed), "token1");
        }
    }
}
