// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev ABI-compatible with the MIT-licensed Uniswap v4 PoolKey type.
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IV4BeforeInitializeHook {
    function beforeInitialize(address sender, V4PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        returns (bytes4);
}

/// @notice One-time-bound Uniswap v4 hook that reserves pool initialization for one adapter.
/// @dev The deployment address must enable only BEFORE_INITIALIZE. No liquidity callback exists,
/// so this hook cannot block later position removal.
contract V4InitializationGate is IV4BeforeInitializeHook {
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;

    address public immutable POOL_MANAGER;
    address public immutable BINDING_AUTHORITY;
    address public ADAPTER;

    error AdapterAlreadyBound();
    error InvalidAdapter();
    error InvalidHookAddress();
    error InvalidHookKey();
    error InvalidPoolManager();
    error UnauthorizedBindingAuthority();
    error UnauthorizedInitializer();
    error ZeroAddress();

    event AdapterBound(address indexed adapter);

    constructor(address poolManager, address bindingAuthority) {
        if (poolManager == address(0) || bindingAuthority == address(0)) revert ZeroAddress();
        if (poolManager.code.length == 0) revert InvalidPoolManager();
        if (uint160(address(this)) & ALL_HOOK_MASK != BEFORE_INITIALIZE_FLAG) {
            revert InvalidHookAddress();
        }

        POOL_MANAGER = poolManager;
        BINDING_AUTHORITY = bindingAuthority;
    }

    /// @notice Irreversibly binds the only caller allowed to initialize this hook's pools.
    function bindAdapter(address adapter) external {
        if (msg.sender != BINDING_AUTHORITY) revert UnauthorizedBindingAuthority();
        if (ADAPTER != address(0)) revert AdapterAlreadyBound();
        if (adapter.code.length == 0 || adapter == address(this) || adapter == POOL_MANAGER) {
            revert InvalidAdapter();
        }

        ADAPTER = adapter;
        emit AdapterBound(adapter);
    }

    function beforeInitialize(address sender, V4PoolKey calldata key, uint160)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != POOL_MANAGER) revert InvalidPoolManager();
        if (sender != ADAPTER || ADAPTER == address(0)) revert UnauthorizedInitializer();
        if (key.hooks != address(this)) revert InvalidHookKey();
        return IV4BeforeInitializeHook.beforeInitialize.selector;
    }
}
