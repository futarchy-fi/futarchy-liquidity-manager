// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {V4InitializationGate, V4PoolKey} from "../../src/adapters/V4InitializationGate.sol";

interface IV4PoolManagerFork {
    function initialize(V4PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
}

contract MainnetV4InitializationAdapter {
    function initialize(
        IV4PoolManagerFork poolManager,
        V4PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external returns (int24 tick) {
        return poolManager.initialize(key, sqrtPriceX96);
    }
}

contract V4InitializationGateMainnetForkTest is Test {
    uint256 internal constant FORK_BLOCK = 25_542_490;
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    address internal constant HOOK_ADDRESS = address(0xfa04400000000000000000000000000000002000);

    function testFork_officialPoolManagerEnforcesInitializationGate() public {
        if (!vm.envOr("RUN_MAINNET_FORK_TESTS", false)) return;
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://rpc.mevblocker.io"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);

        MainnetV4InitializationAdapter adapter = new MainnetV4InitializationAdapter();
        deployCodeTo(
            "src/adapters/V4InitializationGate.sol:V4InitializationGate",
            abi.encode(POOL_MANAGER, address(this)),
            HOOK_ADDRESS
        );
        V4InitializationGate hook = V4InitializationGate(HOOK_ADDRESS);
        hook.bindAdapter(address(adapter));
        V4PoolKey memory key = V4PoolKey({
            currency0: address(0x1111),
            currency1: address(0x2222),
            fee: 500,
            tickSpacing: 10,
            hooks: address(hook)
        });

        vm.expectRevert();
        IV4PoolManagerFork(POOL_MANAGER).initialize(key, Q96);

        int24 tick = adapter.initialize(IV4PoolManagerFork(POOL_MANAGER), key, Q96);
        assertEq(tick, 0);
    }
}
