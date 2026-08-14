// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {
    IFutarchyPrefundedLiquidityAdapter
} from "../interfaces/IFutarchyPrefundedLiquidityAdapter.sol";
import {V4InitializationGate, V4PoolKey} from "./V4InitializationGate.sol";

struct V4ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

/// @dev Minimal ABI-compatible surface from the MIT-licensed Uniswap v4 IPoolManager interface.
interface IV4PoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory result);
    function initialize(V4PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(
        V4PoolKey memory key,
        V4ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function take(address currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
}

/// @notice Manager-bound conditional-liquidity adapter for the official Uniswap v4 PoolManager.
/// @dev Owns one unsalted full-range position per ordered pair. The paired hook controls only
/// initialization; it has no callback capable of blocking liquidity removal.
contract V4ConditionalLiquidityAdapter is
    IFutarchyLiquidityAdapter,
    IFutarchyPrefundedLiquidityAdapter
{
    using SafeERC20 for IERC20;

    uint24 public constant FEE = 500;
    int24 public constant TICK_SPACING = 10;
    int24 public constant TICK_LOWER = -887_270;
    int24 public constant TICK_UPPER = 887_270;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_USAGE_BPS = 9950;
    uint256 private constant Q96 = uint256(1) << 96;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 private constant BEFORE_INITIALIZE_FLAG = 1 << 13;

    IV4PoolManagerMinimal public immutable POOL_MANAGER;
    bytes32 public immutable POOL_MANAGER_CODEHASH;
    V4InitializationGate public immutable INITIALIZATION_GATE;
    address public MANAGER;

    address private immutable _bindingAuthority;

    mapping(bytes32 pairKey => uint128 liquidity) public positionLiquidity;

    enum Action {
        Add,
        Poke,
        Remove
    }

    struct UnlockData {
        Action action;
        V4PoolKey key;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    error DependencyChanged();
    error InvalidAssetTransfer();
    error InvalidDelta();
    error InvalidFeeDelta();
    error InvalidHook();
    error InvalidPoolManager();
    error InvalidTokenOrder();
    error InsufficientPositionLiquidity();
    error InsufficientTokenUsage();
    error ManagerAlreadyBound();
    error PositionAlreadyExists();
    error PositionNotFound();
    error UnauthorizedBindingAuthority();
    error UnauthorizedManager();
    error UnauthorizedPoolManager();
    error UnsupportedOperation();
    error ZeroAddress();
    error ZeroAmount();

    event ManagerBound(address indexed manager);
    event PositionMinted(bytes32 indexed pairKey, uint128 liquidity);
    event LiquidityRemoved(bytes32 indexed pairKey, uint128 liquidity);

    constructor(
        IV4PoolManagerMinimal poolManager,
        bytes32 poolManagerCodehash,
        V4InitializationGate initializationGate
    ) {
        if (address(poolManager) == address(0) || address(initializationGate) == address(0)) {
            revert ZeroAddress();
        }
        if (
            poolManagerCodehash == bytes32(0)
                || address(poolManager).codehash != poolManagerCodehash
        ) {
            revert InvalidPoolManager();
        }
        if (
            initializationGate.POOL_MANAGER() != address(poolManager)
                || uint160(address(initializationGate)) & ALL_HOOK_MASK != BEFORE_INITIALIZE_FLAG
        ) revert InvalidHook();

        POOL_MANAGER = poolManager;
        POOL_MANAGER_CODEHASH = poolManagerCodehash;
        INITIALIZATION_GATE = initializationGate;
        _bindingAuthority = msg.sender;
    }

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert UnauthorizedManager();
        _;
    }

    function bindManager(address manager) external {
        if (msg.sender != _bindingAuthority) revert UnauthorizedBindingAuthority();
        if (MANAGER != address(0)) revert ManagerAlreadyBound();
        if (manager.code.length == 0) revert ZeroAddress();
        MANAGER = manager;
        emit ManagerBound(manager);
    }

    function addFreshFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    )
        external
        onlyManager
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        uint256 balance0Before = _pullExact(token0, amount0);
        uint256 balance1Before = _pullExact(token1, amount1);
        return
            _addFresh(
                token0, token1, amount0, amount1, sqrtPriceX96, balance0Before, balance1Before
            );
    }

    function addPrefundedFreshFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96
    )
        external
        onlyManager
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        if (balance0 < amount0 || balance1 < amount1) revert InvalidAssetTransfer();
        return _addFresh(
            token0, token1, amount0, amount1, sqrtPriceX96, balance0 - amount0, balance1 - amount1
        );
    }

    function poolByPair(address tokenA, address tokenB) external view returns (address pool) {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) {
            revert InvalidTokenOrder();
        }
        bytes32 key = tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
        if (positionLiquidity[key] != 0) pool = address(POOL_MANAGER);
    }

    function addFullRangeLiquidity(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (uint128, uint256, uint256)
    {
        revert UnsupportedOperation();
    }

    function removeLiquidityDetailed(address token0, address token1, uint128 liquidityToRemove)
        external
        onlyManager
        returns (Removal memory removal)
    {
        bytes32 pair = _pairKey(token0, token1);
        uint128 currentLiquidity = positionLiquidity[pair];
        if (currentLiquidity == 0) revert PositionNotFound();
        if (liquidityToRemove > currentLiquidity) revert InsufficientPositionLiquidity();
        _assertDependencies();

        Action action = liquidityToRemove == 0 ? Action.Poke : Action.Remove;
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                UnlockData({
                    action: action,
                    key: _poolKey(token0, token1),
                    liquidity: liquidityToRemove,
                    amount0Max: 0,
                    amount1Max: 0
                })
            )
        );
        removal = abi.decode(result, (Removal));

        if (liquidityToRemove != 0) {
            positionLiquidity[pair] = currentLiquidity - liquidityToRemove;
            emit LiquidityRemoved(pair, liquidityToRemove);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory result) {
        if (msg.sender != address(POOL_MANAGER)) revert UnauthorizedPoolManager();
        UnlockData memory data = abi.decode(rawData, (UnlockData));

        if (data.action == Action.Add) {
            (int256 delta, int256 feesAccrued) = POOL_MANAGER.modifyLiquidity(
                data.key,
                V4ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(uint256(data.liquidity)), 0),
                ""
            );
            if (feesAccrued != 0) revert InvalidFeeDelta();
            (uint256 amount0, uint256 amount1) =
                _settleNegativeDelta(data.key, delta, data.amount0Max, data.amount1Max);
            return abi.encode(amount0, amount1);
        }

        Removal memory removal;
        (int256 feeDelta, int256 reportedFees) = POOL_MANAGER.modifyLiquidity(
            data.key, V4ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, 0, 0), ""
        );
        if (feeDelta != reportedFees) revert InvalidFeeDelta();
        (removal.fees0, removal.fees1) = _takePositiveDelta(data.key, feeDelta);

        if (data.action == Action.Remove) {
            (int256 principalDelta, int256 secondFees) = POOL_MANAGER.modifyLiquidity(
                data.key,
                V4ModifyLiquidityParams(
                    TICK_LOWER, TICK_UPPER, -int256(uint256(data.liquidity)), 0
                ),
                ""
            );
            if (secondFees != 0) revert InvalidFeeDelta();
            (removal.principal0, removal.principal1) = _takePositiveDelta(data.key, principalDelta);
        }
        return abi.encode(removal);
    }

    function _addFresh(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 balance0Before,
        uint256 balance1Before
    )
        private
        returns (address pool, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        if (amount0 == 0 || amount1 == 0 || sqrtPriceX96 == 0) revert ZeroAmount();
        bytes32 pair = _pairKey(token0, token1);
        if (positionLiquidity[pair] != 0) revert PositionAlreadyExists();
        _assertDependencies();

        V4PoolKey memory key = _poolKey(token0, token1);
        POOL_MANAGER.initialize(key, sqrtPriceX96);

        uint256 requested = Math.min(
            Math.mulDiv(amount0, sqrtPriceX96, Q96), Math.mulDiv(amount1, Q96, sqrtPriceX96)
        );
        if (requested == 0 || requested > type(uint128).max) revert ZeroAmount();
        liquidityMinted = uint128(requested);

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                UnlockData({
                    action: Action.Add,
                    key: key,
                    liquidity: liquidityMinted,
                    amount0Max: amount0,
                    amount1Max: amount1
                })
            )
        );
        (amount0Used, amount1Used) = abi.decode(result, (uint256, uint256));
        uint256 amount0Min = Math.mulDiv(amount0, MIN_USAGE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
        uint256 amount1Min = Math.mulDiv(amount1, MIN_USAGE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
        if (amount0Used < amount0Min || amount1Used < amount1Min) {
            revert InsufficientTokenUsage();
        }

        positionLiquidity[pair] = liquidityMinted;
        emit PositionMinted(pair, liquidityMinted);
        _refundChecked(token0, balance0Before, amount0, amount0Used);
        _refundChecked(token1, balance1Before, amount1, amount1Used);
        pool = address(POOL_MANAGER);
    }

    function _assertDependencies() private view {
        if (address(POOL_MANAGER).codehash != POOL_MANAGER_CODEHASH) revert DependencyChanged();
        if (
            INITIALIZATION_GATE.POOL_MANAGER() != address(POOL_MANAGER)
                || INITIALIZATION_GATE.ADAPTER() != address(this)
        ) revert InvalidHook();
    }

    function _poolKey(address token0, address token1) private view returns (V4PoolKey memory key) {
        key = V4PoolKey({
            currency0: token0,
            currency1: token1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(INITIALIZATION_GATE)
        });
    }

    function _pairKey(address token0, address token1) private pure returns (bytes32) {
        if (token0 == address(0) || token1 == address(0) || token0 >= token1) {
            revert InvalidTokenOrder();
        }
        return keccak256(abi.encode(token0, token1));
    }

    function _pullExact(address token, uint256 amount) private returns (uint256 balanceBefore) {
        IERC20 asset = IERC20(token);
        balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) != balanceBefore + amount) {
            revert InvalidAssetTransfer();
        }
    }

    function _refundChecked(
        address token,
        uint256 balanceBefore,
        uint256 amountDesired,
        uint256 amountUsed
    ) private {
        IERC20 asset = IERC20(token);
        uint256 balanceAfter = asset.balanceOf(address(this));
        if (
            amountUsed > amountDesired || balanceAfter < balanceBefore
                || balanceAfter - balanceBefore != amountDesired - amountUsed
        ) revert InvalidAssetTransfer();
        uint256 refund = amountDesired - amountUsed;
        if (refund != 0) {
            uint256 recipientBefore = asset.balanceOf(MANAGER);
            asset.safeTransfer(MANAGER, refund);
            if (asset.balanceOf(MANAGER) != recipientBefore + refund) {
                revert InvalidAssetTransfer();
            }
        }
        if (asset.balanceOf(address(this)) != balanceBefore) revert InvalidAssetTransfer();
    }

    function _settleNegativeDelta(
        V4PoolKey memory key,
        int256 delta,
        uint256 amount0Max,
        uint256 amount1Max
    ) private returns (uint256 amount0, uint256 amount1) {
        int128 delta0 = _amount0(delta);
        int128 delta1 = _amount1(delta);
        if (delta0 >= 0 || delta1 >= 0) revert InvalidDelta();
        amount0 = uint256(-int256(delta0));
        amount1 = uint256(-int256(delta1));
        if (amount0 > amount0Max || amount1 > amount1Max) revert InvalidAssetTransfer();
        _settle(key.currency0, amount0);
        _settle(key.currency1, amount1);
    }

    function _settle(address currency, uint256 amount) private {
        POOL_MANAGER.sync(currency);
        IERC20(currency).safeTransfer(address(POOL_MANAGER), amount);
        if (POOL_MANAGER.settle() != amount) revert InvalidAssetTransfer();
    }

    function _takePositiveDelta(V4PoolKey memory key, int256 delta)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        int128 delta0 = _amount0(delta);
        int128 delta1 = _amount1(delta);
        if (delta0 < 0 || delta1 < 0) revert InvalidDelta();
        amount0 = uint128(delta0);
        amount1 = uint128(delta1);
        if (amount0 != 0) POOL_MANAGER.take(key.currency0, MANAGER, amount0);
        if (amount1 != 0) POOL_MANAGER.take(key.currency1, MANAGER, amount1);
    }

    function _amount0(int256 delta) private pure returns (int128 amount) {
        amount = int128(delta >> 128);
    }

    function _amount1(int256 delta) private pure returns (int128 amount) {
        amount = int128(delta);
    }
}
