// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    IV4BeforeInitializeHook,
    V4InitializationGate,
    V4PoolKey
} from "../src/adapters/V4InitializationGate.sol";

contract MockV4PoolManager {
    mapping(bytes32 poolId => bool initialized) public initialized;

    function initialize(V4PoolKey calldata key, uint160 sqrtPriceX96) external {
        bytes4 response =
            IV4BeforeInitializeHook(key.hooks).beforeInitialize(msg.sender, key, sqrtPriceX96);
        require(response == IV4BeforeInitializeHook.beforeInitialize.selector);
        initialized[keccak256(abi.encode(key))] = true;
    }
}

contract MockV4InitializationAdapter {
    function initialize(MockV4PoolManager poolManager, V4PoolKey calldata key, uint160 sqrtPriceX96)
        external
    {
        poolManager.initialize(key, sqrtPriceX96);
    }
}

contract V4InitializationGateTest is Test {
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    address internal constant HOOK_ADDRESS = address(0xF00D2000);

    MockV4PoolManager internal poolManager;
    MockV4InitializationAdapter internal adapter;
    V4InitializationGate internal hook;
    V4PoolKey internal key;

    function setUp() public {
        poolManager = new MockV4PoolManager();
        adapter = new MockV4InitializationAdapter();
        deployCodeTo(
            "src/adapters/V4InitializationGate.sol:V4InitializationGate",
            abi.encode(address(poolManager), address(this)),
            HOOK_ADDRESS
        );
        hook = V4InitializationGate(HOOK_ADDRESS);
        hook.bindAdapter(address(adapter));
        key = V4PoolKey({
            currency0: address(0x1000),
            currency1: address(0x2000),
            fee: 500,
            tickSpacing: 10,
            hooks: address(hook)
        });
    }

    function test_outsiderCannotPreinitializeButBoundAdapterCan() public {
        vm.expectRevert(V4InitializationGate.UnauthorizedInitializer.selector);
        poolManager.initialize(key, 1 << 96);
        assertFalse(poolManager.initialized(keccak256(abi.encode(key))));

        adapter.initialize(poolManager, key, 1 << 96);

        assertTrue(poolManager.initialized(keccak256(abi.encode(key))));
    }

    function test_hookEnablesOnlyBeforeInitialize() public view {
        assertEq(uint160(address(hook)) & ALL_HOOK_MASK, BEFORE_INITIALIZE_FLAG);
    }

    function test_onlyPoolManagerCanInvokeHook() public {
        vm.expectRevert(V4InitializationGate.InvalidPoolManager.selector);
        vm.prank(address(adapter));
        hook.beforeInitialize(address(adapter), key, 1 << 96);
    }

    function test_hookRejectsDifferentHookKey() public {
        key.hooks = address(0x2000);
        vm.expectRevert(V4InitializationGate.InvalidHookKey.selector);
        vm.prank(address(poolManager));
        hook.beforeInitialize(address(adapter), key, 1 << 96);
    }

    function test_bindingIsAuthorityOnlyCodeBearingAndOneShot() public {
        address secondHookAddress = address(0xF00D6000);
        deployCodeTo(
            "src/adapters/V4InitializationGate.sol:V4InitializationGate",
            abi.encode(address(poolManager), address(this)),
            secondHookAddress
        );
        V4InitializationGate secondHook = V4InitializationGate(secondHookAddress);

        vm.expectRevert(V4InitializationGate.UnauthorizedBindingAuthority.selector);
        vm.prank(address(0xBEEF));
        secondHook.bindAdapter(address(adapter));

        vm.expectRevert(V4InitializationGate.InvalidAdapter.selector);
        secondHook.bindAdapter(address(0xCAFE));

        secondHook.bindAdapter(address(adapter));
        MockV4InitializationAdapter replacement = new MockV4InitializationAdapter();
        vm.expectRevert(V4InitializationGate.AdapterAlreadyBound.selector);
        secondHook.bindAdapter(address(replacement));
    }
}
