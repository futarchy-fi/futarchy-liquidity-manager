// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter
} from "../../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {V4InitializationGate, V4PoolKey} from "../../src/adapters/V4InitializationGate.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";

interface IV4PoolManagerDonate is IV4PoolManagerMinimal {
    function donate(V4PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (int256 delta);
}

contract MainnetV4Donor {
    using SafeERC20 for IERC20;

    IV4PoolManagerDonate private immutable _poolManager;

    constructor(IV4PoolManagerDonate poolManager) {
        _poolManager = poolManager;
    }

    function donate(V4PoolKey calldata key, uint256 amount0, uint256 amount1) external {
        _poolManager.unlock(abi.encode(key, amount0, amount1));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(_poolManager));
        (V4PoolKey memory key, uint256 amount0, uint256 amount1) =
            abi.decode(rawData, (V4PoolKey, uint256, uint256));
        int256 delta = _poolManager.donate(key, amount0, amount1, "");
        _settle(key.currency0, uint256(-int256(int128(delta >> 128))));
        _settle(key.currency1, uint256(-int256(int128(delta))));
        return "";
    }

    function _settle(address token, uint256 amount) private {
        _poolManager.sync(token);
        IERC20(token).safeTransfer(address(_poolManager), amount);
        require(_poolManager.settle() == amount);
    }
}

contract V4ConditionalLiquidityAdapterMainnetForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_542_490;
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant AMOUNT = 100 ether;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    address internal constant HOOK_ADDRESS = address(0xfa04400000000000000000000000000000002000);

    function testFork_realPoolManagerAddsCollectsAndProportionallyRemoves() public {
        if (!vm.envOr("RUN_MAINNET_FORK_TESTS", false)) return;
        string memory rpcUrl =
            vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);

        MockMintableERC20 assetA = new MockMintableERC20("Outcome A", "OA");
        MockMintableERC20 assetB = new MockMintableERC20("Outcome B", "OB");
        (MockMintableERC20 token0, MockMintableERC20 token1) =
            address(assetA) < address(assetB) ? (assetA, assetB) : (assetB, assetA);

        deployCodeTo(
            "src/adapters/V4InitializationGate.sol:V4InitializationGate",
            abi.encode(POOL_MANAGER, address(this)),
            HOOK_ADDRESS
        );
        V4InitializationGate hook = V4InitializationGate(HOOK_ADDRESS);
        V4ConditionalLiquidityAdapter adapter = new V4ConditionalLiquidityAdapter(
            IV4PoolManagerMinimal(POOL_MANAGER), POOL_MANAGER_CODEHASH, hook
        );
        hook.bindAdapter(address(adapter));
        adapter.bindManager(address(this));

        token0.mint(address(adapter), AMOUNT);
        token1.mint(address(adapter), AMOUNT);
        (address pool, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = adapter.addPrefundedFreshFullRangeLiquidity(
            address(token0), address(token1), AMOUNT, AMOUNT, Q96
        );
        assertEq(pool, POOL_MANAGER);
        assertGt(liquidity, 0);
        assertGe(amount0Used, AMOUNT * 9950 / 10_000);
        assertGe(amount1Used, AMOUNT * 9950 / 10_000);
        assertEq(adapter.poolByPair(address(token0), address(token1)), POOL_MANAGER);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);

        MainnetV4Donor donor = new MainnetV4Donor(IV4PoolManagerDonate(POOL_MANAGER));
        uint256 donation = 1 ether;
        token0.mint(address(donor), donation);
        token1.mint(address(donor), donation);
        donor.donate(
            V4PoolKey({
                currency0: address(token0),
                currency1: address(token1),
                fee: adapter.FEE(),
                tickSpacing: adapter.TICK_SPACING(),
                hooks: address(hook)
            }),
            donation,
            donation
        );

        uint256 manager0Before = token0.balanceOf(address(this));
        uint256 manager1Before = token1.balanceOf(address(this));
        IFutarchyLiquidityAdapter.Removal memory fees =
            adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        assertGt(fees.fees0, 0);
        assertGt(fees.fees1, 0);
        assertEq(token0.balanceOf(address(this)) - manager0Before, fees.fees0);
        assertEq(token1.balanceOf(address(this)) - manager1Before, fees.fees1);

        uint128 firstRemoval = liquidity / 3;
        IFutarchyLiquidityAdapter.Removal memory partialRemoval =
            adapter.removeLiquidityDetailed(address(token0), address(token1), firstRemoval);
        assertGt(partialRemoval.principal0, 0);
        assertGt(partialRemoval.principal1, 0);
        assertEq(
            adapter.positionLiquidity(keccak256(abi.encode(address(token0), address(token1)))),
            liquidity - firstRemoval
        );

        adapter.removeLiquidityDetailed(address(token0), address(token1), liquidity - firstRemoval);
        assertEq(
            adapter.positionLiquidity(keccak256(abi.encode(address(token0), address(token1)))), 0
        );
        assertEq(adapter.poolByPair(address(token0), address(token1)), address(0));
    }
}
