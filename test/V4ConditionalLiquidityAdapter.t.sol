// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter,
    V4ModifyLiquidityParams
} from "../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {
    IV4BeforeInitializeHook,
    V4InitializationGate,
    V4PoolKey
} from "../src/adapters/V4InitializationGate.sol";
import {IFutarchyLiquidityAdapter} from "../src/interfaces/IFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";

interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract MockV4AdapterPoolManager is IV4PoolManagerMinimal {
    using SafeERC20 for IERC20;

    struct AdapterUnlockData {
        uint8 action;
        V4PoolKey key;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    mapping(bytes32 poolId => bool initialized) public initialized;
    mapping(bytes32 positionId => uint128 liquidity) public positionLiquidity;
    mapping(bytes32 positionId => uint256 amount0) public fees0;
    mapping(bytes32 positionId => uint256 amount1) public fees1;
    mapping(address currency => int256 delta) public openDelta;

    address private _syncedCurrency;
    uint256 private _syncedBalance;
    bool private _unlocked;

    bool public failNextModify;
    bool public corruptPokeFees;
    bool public injectSecondFees;

    function setFailNextModify(bool value) external {
        failNextModify = value;
    }

    function setCorruptPokeFees(bool value) external {
        corruptPokeFees = value;
    }

    function setInjectSecondFees(bool value) external {
        injectSecondFees = value;
    }

    function accrueFees(V4PoolKey calldata key, address owner, uint256 amount0, uint256 amount1)
        external
    {
        bytes32 position = _positionId(key, owner, -887_270, 887_270, 0);
        require(positionLiquidity[position] != 0);
        fees0[position] += amount0;
        fees1[position] += amount1;
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(!_unlocked);
        AdapterUnlockData memory decoded = abi.decode(data, (AdapterUnlockData));
        _unlocked = true;
        result = IV4UnlockCallback(msg.sender).unlockCallback(data);
        require(openDelta[decoded.key.currency0] == 0);
        require(openDelta[decoded.key.currency1] == 0);
        _unlocked = false;
    }

    function initialize(V4PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        bytes32 pool = keccak256(abi.encode(key));
        require(!initialized[pool]);
        bytes4 response =
            IV4BeforeInitializeHook(key.hooks).beforeInitialize(msg.sender, key, sqrtPriceX96);
        require(response == IV4BeforeInitializeHook.beforeInitialize.selector);
        initialized[pool] = true;
        return 0;
    }

    function modifyLiquidity(
        V4PoolKey memory key,
        V4ModifyLiquidityParams memory params,
        bytes calldata
    ) external returns (int256 callerDelta, int256 feesAccrued) {
        require(_unlocked);
        if (failNextModify) revert("modify failed");
        bytes32 position =
            _positionId(key, msg.sender, params.tickLower, params.tickUpper, params.salt);

        if (params.liquidityDelta > 0) {
            uint128 added = uint128(uint256(params.liquidityDelta));
            positionLiquidity[position] += added;
            callerDelta = _pack(-int128(added), -int128(added));
        } else if (params.liquidityDelta == 0) {
            uint256 accrued0 = fees0[position];
            uint256 accrued1 = fees1[position];
            fees0[position] = 0;
            fees1[position] = 0;
            callerDelta = _pack(int128(int256(accrued0)), int128(int256(accrued1)));
            feesAccrued = corruptPokeFees ? _pack(1, 0) : callerDelta;
        } else {
            uint128 removed = uint128(uint256(-params.liquidityDelta));
            require(positionLiquidity[position] >= removed);
            positionLiquidity[position] -= removed;
            callerDelta = _pack(int128(removed), int128(removed));
            if (injectSecondFees) {
                callerDelta = _pack(int128(removed + 1), int128(removed));
                feesAccrued = _pack(1, 0);
            }
        }

        openDelta[key.currency0] += int256(_amount0(callerDelta));
        openDelta[key.currency1] += int256(_amount1(callerDelta));
    }

    function sync(address currency) external {
        require(_unlocked);
        _syncedCurrency = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function take(address currency, address to, uint256 amount) external {
        require(_unlocked && openDelta[currency] >= int256(amount));
        openDelta[currency] -= int256(amount);
        IERC20(currency).safeTransfer(to, amount);
    }

    function settle() external payable returns (uint256 paid) {
        require(_unlocked && _syncedCurrency != address(0));
        paid = IERC20(_syncedCurrency).balanceOf(address(this)) - _syncedBalance;
        openDelta[_syncedCurrency] += int256(paid);
        _syncedCurrency = address(0);
        _syncedBalance = 0;
    }

    function _positionId(
        V4PoolKey memory key,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(key, owner, tickLower, tickUpper, salt));
    }

    function _pack(int128 amount0, int128 amount1) private pure returns (int256 delta) {
        assembly ("memory-safe") {
            delta := or(shl(128, amount0), and(sub(shl(128, 1), 1), amount1))
        }
    }

    function _amount0(int256 delta) private pure returns (int128 amount) {
        amount = int128(delta >> 128);
    }

    function _amount1(int256 delta) private pure returns (int128 amount) {
        amount = int128(delta);
    }
}

contract V4ConditionalLiquidityAdapterTest is Test {
    uint160 internal constant Q96 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant AMOUNT = 100 ether;
    address internal constant HOOK_ADDRESS = address(0xfa04400000000000000000000000000000002000);

    MockV4AdapterPoolManager internal poolManager;
    MockMintableERC20 internal token0;
    MockMintableERC20 internal token1;
    V4InitializationGate internal hook;
    V4ConditionalLiquidityAdapter internal adapter;

    function setUp() public {
        poolManager = new MockV4AdapterPoolManager();
        MockMintableERC20 assetA = new MockMintableERC20("Outcome A", "OA");
        MockMintableERC20 assetB = new MockMintableERC20("Outcome B", "OB");
        (token0, token1) = address(assetA) < address(assetB) ? (assetA, assetB) : (assetB, assetA);

        deployCodeTo(
            "src/adapters/V4InitializationGate.sol:V4InitializationGate",
            abi.encode(address(poolManager), address(this)),
            HOOK_ADDRESS
        );
        hook = V4InitializationGate(HOOK_ADDRESS);
        adapter =
            new V4ConditionalLiquidityAdapter(poolManager, address(poolManager).codehash, hook);
        hook.bindAdapter(address(adapter));
        adapter.bindManager(address(this));
    }

    function test_prefundedAddCollectsDonationAndRemovesProportionally() public {
        uint256 preexisting0 = 7 ether;
        uint256 preexisting1 = 11 ether;
        token0.mint(address(adapter), AMOUNT + preexisting0);
        token1.mint(address(adapter), AMOUNT + preexisting1);

        (address pool, uint128 liquidity, uint256 used0, uint256 used1) = adapter.addPrefundedFreshFullRangeLiquidity(
            address(token0), address(token1), AMOUNT, AMOUNT, Q96
        );
        assertEq(pool, address(poolManager));
        assertEq(adapter.poolByPair(address(token1), address(token0)), address(poolManager));
        assertEq(liquidity, AMOUNT);
        assertEq(used0, AMOUNT);
        assertEq(used1, AMOUNT);
        assertEq(token0.balanceOf(address(adapter)), preexisting0);
        assertEq(token1.balanceOf(address(adapter)), preexisting1);

        uint256 fee0 = 3 ether;
        uint256 fee1 = 5 ether;
        token0.mint(address(poolManager), fee0);
        token1.mint(address(poolManager), fee1);
        poolManager.accrueFees(_key(), address(adapter), fee0, fee1);

        IFutarchyLiquidityAdapter.Removal memory fees =
            adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        assertEq(fees.fees0, fee0);
        assertEq(fees.fees1, fee1);
        assertEq(token0.balanceOf(address(this)), fee0);
        assertEq(token1.balanceOf(address(this)), fee1);

        uint128 firstRemoval = liquidity / 3;
        IFutarchyLiquidityAdapter.Removal memory removed =
            adapter.removeLiquidityDetailed(address(token0), address(token1), firstRemoval);
        assertEq(removed.principal0, firstRemoval);
        assertEq(removed.principal1, firstRemoval);
        assertEq(_adapterLiquidity(), liquidity - firstRemoval);

        removed = adapter.removeLiquidityDetailed(
            address(token0), address(token1), liquidity - firstRemoval
        );
        assertEq(removed.principal0, liquidity - firstRemoval);
        assertEq(removed.principal1, liquidity - firstRemoval);
        assertEq(_adapterLiquidity(), 0);
        assertEq(adapter.poolByPair(address(token0), address(token1)), address(0));
        assertEq(token0.balanceOf(address(adapter)), preexisting0);
        assertEq(token1.balanceOf(address(adapter)), preexisting1);
    }

    function test_pullBasedFreshAddUsesExactManagerCustody() public {
        token0.mint(address(this), AMOUNT);
        token1.mint(address(this), AMOUNT);
        token0.approve(address(adapter), AMOUNT);
        token1.approve(address(adapter), AMOUNT);

        (address pool, uint128 liquidity, uint256 used0, uint256 used1) = adapter.addFreshFullRangeLiquidity(
            address(token0), address(token1), AMOUNT, AMOUNT, Q96
        );

        assertEq(pool, address(poolManager));
        assertEq(liquidity, AMOUNT);
        assertEq(used0, AMOUNT);
        assertEq(used1, AMOUNT);
        assertEq(token0.balanceOf(address(this)), 0);
        assertEq(token1.balanceOf(address(this)), 0);
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
    }

    function test_firstLiquidityFailureRollsBackInitializationAndCustody() public {
        token0.mint(address(adapter), AMOUNT);
        token1.mint(address(adapter), AMOUNT);
        poolManager.setFailNextModify(true);

        vm.expectRevert();
        adapter.addPrefundedFreshFullRangeLiquidity(
            address(token0), address(token1), AMOUNT, AMOUNT, Q96
        );

        assertFalse(poolManager.initialized(keccak256(abi.encode(_key()))));
        assertEq(token0.balanceOf(address(adapter)), AMOUNT);
        assertEq(token1.balanceOf(address(adapter)), AMOUNT);
        assertEq(_adapterLiquidity(), 0);
    }

    function test_mismatchedFeeReportRevertsWithoutConsumingFees() public {
        _addPosition();
        uint256 fee = 2 ether;
        token0.mint(address(poolManager), fee);
        token1.mint(address(poolManager), fee);
        poolManager.accrueFees(_key(), address(adapter), fee, fee);
        poolManager.setCorruptPokeFees(true);

        vm.expectRevert(V4ConditionalLiquidityAdapter.InvalidFeeDelta.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        assertEq(token0.balanceOf(address(this)), 0);
        assertEq(token1.balanceOf(address(this)), 0);

        poolManager.setCorruptPokeFees(false);
        IFutarchyLiquidityAdapter.Removal memory removal =
            adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
        assertEq(removal.fees0, fee);
        assertEq(removal.fees1, fee);
    }

    function test_secondFeeDeltaRevertsPrincipalRemovalAtomically() public {
        uint128 liquidity = _addPosition();
        poolManager.setInjectSecondFees(true);

        vm.expectRevert(V4ConditionalLiquidityAdapter.InvalidFeeDelta.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), liquidity / 2);
        assertEq(_adapterLiquidity(), liquidity);

        poolManager.setInjectSecondFees(false);
        adapter.removeLiquidityDetailed(address(token0), address(token1), liquidity / 2);
        assertEq(_adapterLiquidity(), liquidity - liquidity / 2);
    }

    function test_dependencyCodehashDriftFailsClosed() public {
        _addPosition();
        vm.etch(address(poolManager), hex"00");

        vm.expectRevert(V4ConditionalLiquidityAdapter.DependencyChanged.selector);
        adapter.removeLiquidityDetailed(address(token0), address(token1), 0);
    }

    function test_onlyManagerCanOperateAndBindingIsOneShot() public {
        vm.expectRevert(V4ConditionalLiquidityAdapter.UnauthorizedManager.selector);
        vm.prank(address(0xBEEF));
        adapter.removeLiquidityDetailed(address(token0), address(token1), 0);

        vm.expectRevert(V4ConditionalLiquidityAdapter.ManagerAlreadyBound.selector);
        adapter.bindManager(address(this));
    }

    function test_constructorPinsPoolManagerCodehash() public {
        vm.expectRevert(V4ConditionalLiquidityAdapter.InvalidPoolManager.selector);
        new V4ConditionalLiquidityAdapter(poolManager, bytes32(uint256(1)), hook);
    }

    function _addPosition() private returns (uint128 liquidity) {
        token0.mint(address(adapter), AMOUNT);
        token1.mint(address(adapter), AMOUNT);
        (, liquidity,,) = adapter.addPrefundedFreshFullRangeLiquidity(
            address(token0), address(token1), AMOUNT, AMOUNT, Q96
        );
    }

    function _adapterLiquidity() private view returns (uint128) {
        return adapter.positionLiquidity(keccak256(abi.encode(address(token0), address(token1))));
    }

    function _key() private view returns (V4PoolKey memory) {
        return V4PoolKey({
            currency0: address(token0),
            currency1: address(token1),
            fee: adapter.FEE(),
            tickSpacing: adapter.TICK_SPACING(),
            hooks: address(hook)
        });
    }
}
