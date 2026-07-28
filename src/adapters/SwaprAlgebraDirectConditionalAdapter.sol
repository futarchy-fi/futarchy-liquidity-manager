// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {IAlgebraFactoryLike} from "../interfaces/IAlgebraFactoryLike.sol";
import {ISwaprAlgebraPool} from "../interfaces/ISwaprAlgebraPool.sol";

interface IAlgebraPoolFactory is IAlgebraFactoryLike {
    function createPool(address tokenA, address tokenB) external returns (address pool);
}

/// @notice Conditional-only adapter that owns fixed full-range Algebra positions directly.
/// @dev Bypasses transferable NFTs and talks directly to the canonical Algebra factory and pools.
/// It supports fresh activation and proportional removal only.
contract SwaprAlgebraDirectConditionalAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant Q96 = uint256(1) << 96;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MIN_USAGE_BPS = 9950;
    int24 public constant TICK_LOWER = -887_220;
    int24 public constant TICK_UPPER = 887_220;
    uint160 private constant SQRT_LOWER_X96 = 4_306_310_044;
    uint160 private constant SQRT_UPPER_X96 =
        1_457_652_066_949_847_389_969_617_340_386_294_118_487_833_376_468;

    IAlgebraFactoryLike public immutable FACTORY;
    address public MANAGER;

    address private immutable _bindingAuthority;

    /// @notice Manager-owned logical liquidity units; unsolicited pool liquidity is share-donated.
    mapping(bytes32 pairKey => uint128 liquidity) public positionLiquidity;

    error InvalidAssetTransfer();
    error InvalidPool();
    error InvalidPosition();
    error InvalidTokenOrder();
    error InsufficientPositionLiquidity();
    error InsufficientTokenUsage();
    error LiquidityCooldownActive(address pool, uint32 liquidityCooldown);
    error ManagerAlreadyBound();
    error PoolAlreadyExists(address pool);
    error PositionAlreadyExists();
    error PositionNotFound();
    error UnauthorizedBindingAuthority();
    error UnauthorizedManager();
    error UnsupportedOperation();
    error ZeroAddress();
    error ZeroAmount();

    event ManagerBound(address indexed manager);
    event PositionMinted(bytes32 indexed pairKey, address indexed pool, uint128 liquidity);
    event LiquidityRemoved(bytes32 indexed pairKey, address indexed pool, uint128 liquidity);

    constructor(IAlgebraFactoryLike factory) {
        if (address(factory) == address(0)) revert ZeroAddress();
        FACTORY = factory;
        _bindingAuthority = msg.sender;
    }

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert UnauthorizedManager();
        _;
    }

    function bindManager(address manager) external {
        if (msg.sender != _bindingAuthority) revert UnauthorizedBindingAuthority();
        if (MANAGER != address(0)) revert ManagerAlreadyBound();
        if (manager == address(0)) revert ZeroAddress();
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

    /// @notice Creates a fresh position from exact activation assets delivered by the router.
    /// @dev Pre-existing balances are excluded from the position and preserved exactly.
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

    function poolByPair(address token0, address token1) external view returns (address pool) {
        pool = FACTORY.poolByPair(token0, token1);
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
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        bytes32 key = _pairKey(token0, token1);
        if (positionLiquidity[key] != 0) revert PositionAlreadyExists();
        address existingPool = FACTORY.poolByPair(token0, token1);
        if (existingPool != address(0)) revert PoolAlreadyExists(existingPool);

        pool = IAlgebraPoolFactory(address(FACTORY)).createPool(token0, token1);
        if (pool == address(0) || FACTORY.poolByPair(token0, token1) != pool) revert InvalidPool();
        uint32 liquidityCooldown = ISwaprAlgebraPool(pool).liquidityCooldown();
        if (liquidityCooldown != 0) revert LiquidityCooldownActive(pool, liquidityCooldown);
        ISwaprAlgebraPool(pool).initialize(sqrtPriceX96);

        (uint160 currentSqrtPriceX96,,,,,,) = ISwaprAlgebraPool(pool).globalState();
        uint128 requested = _liquidityForAmounts(currentSqrtPriceX96, amount0, amount1);
        if (requested == 0) revert ZeroAmount();

        (amount0Used, amount1Used, liquidityMinted) = ISwaprAlgebraPool(pool)
            .mint(
                address(this),
                address(this),
                TICK_LOWER,
                TICK_UPPER,
                requested,
                abi.encode(token0, token1, amount0, amount1)
            );
        uint256 amount0Min = Math.mulDiv(amount0, MIN_USAGE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
        uint256 amount1Min = Math.mulDiv(amount1, MIN_USAGE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
        if (
            liquidityMinted == 0 || liquidityMinted > requested || amount0Used < amount0Min
                || amount1Used < amount1Min || amount0Used > amount0 || amount1Used > amount1
        ) revert InsufficientTokenUsage();
        if (_poolLiquidity(pool) != liquidityMinted) revert InvalidPosition();
        if (FACTORY.poolByPair(token0, token1) != pool) revert InvalidPool();

        positionLiquidity[key] = liquidityMinted;
        emit PositionMinted(key, pool, liquidityMinted);
        _refundChecked(token0, balance0Before, amount0, amount0Used);
        _refundChecked(token1, balance1Before, amount1, amount1Used);
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
        bytes32 key = _pairKey(token0, token1);
        uint128 currentLiquidity = positionLiquidity[key];
        if (currentLiquidity == 0) revert PositionNotFound();
        if (liquidityToRemove > currentLiquidity) revert InsufficientPositionLiquidity();
        address pool = FACTORY.poolByPair(token0, token1);
        uint128 actualLiquidity = pool == address(0) ? 0 : _poolLiquidity(pool);
        if (actualLiquidity < currentLiquidity) {
            revert InvalidPosition();
        }

        (uint256 poked0, uint256 poked1) = ISwaprAlgebraPool(pool).burn(TICK_LOWER, TICK_UPPER, 0);
        if (poked0 != 0 || poked1 != 0) revert InvalidAssetTransfer();
        (removal.fees0, removal.fees1) = _collectChecked(pool, token0, token1);
        if (liquidityToRemove == 0) return removal;

        // A third party can mint into this unsalted owner/tick position. Distribute that donation
        // in the same proportion as logical manager liquidity, with final redemption taking all.
        uint128 actualToRemove = liquidityToRemove == currentLiquidity
            ? actualLiquidity
            : uint128(Math.mulDiv(actualLiquidity, liquidityToRemove, currentLiquidity));
        (removal.principal0, removal.principal1) =
            ISwaprAlgebraPool(pool).burn(TICK_LOWER, TICK_UPPER, actualToRemove);
        (uint256 collected0, uint256 collected1) = _collectChecked(pool, token0, token1);
        uint128 remaining = currentLiquidity - liquidityToRemove;
        uint128 actualRemaining = actualLiquidity - actualToRemove;
        if (
            collected0 != removal.principal0 || collected1 != removal.principal1
                || _poolLiquidity(pool) != actualRemaining || actualRemaining < remaining
        ) revert InvalidAssetTransfer();

        positionLiquidity[key] = remaining;
        emit LiquidityRemoved(key, pool, liquidityToRemove);
    }

    /// @dev Canonical Algebra pools call back only from a mint initiated above. The factory lookup
    /// authenticates the caller; the encoded maxima cap every transfer even under pool failure.
    function algebraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external
    {
        (address token0, address token1, uint256 amount0Max, uint256 amount1Max) =
            abi.decode(data, (address, address, uint256, uint256));
        if (msg.sender != FACTORY.poolByPair(token0, token1)) revert InvalidPool();
        if (amount0Owed > amount0Max || amount1Owed > amount1Max) {
            revert InvalidAssetTransfer();
        }
        if (amount0Owed != 0) IERC20(token0).safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed != 0) IERC20(token1).safeTransfer(msg.sender, amount1Owed);
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
            balanceAfter < balanceBefore
                || balanceAfter - balanceBefore != amountDesired - amountUsed
        ) {
            revert InvalidAssetTransfer();
        }
        uint256 refund = amountDesired - amountUsed;
        if (refund != 0) asset.safeTransfer(msg.sender, refund);
        if (asset.balanceOf(address(this)) != balanceBefore) revert InvalidAssetTransfer();
    }

    function _collectChecked(address pool, address token0, address token1)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 balance0Before = IERC20(token0).balanceOf(msg.sender);
        uint256 balance1Before = IERC20(token1).balanceOf(msg.sender);
        (amount0, amount1) = ISwaprAlgebraPool(pool)
            .collect(msg.sender, TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max);
        if (
            IERC20(token0).balanceOf(msg.sender) != balance0Before + amount0
                || IERC20(token1).balanceOf(msg.sender) != balance1Before + amount1
        ) revert InvalidAssetTransfer();
    }

    function _poolLiquidity(address pool) private view returns (uint128 liquidity) {
        bytes32 key = bytes32(
            (uint256(uint160(address(this))) << 48) | (uint256(uint24(TICK_LOWER)) << 24)
                | uint256(uint24(TICK_UPPER))
        );
        (liquidity,,,,,) = ISwaprAlgebraPool(pool).positions(key);
    }

    function _liquidityForAmounts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        uint256 intermediate = Math.mulDiv(sqrtPriceX96, SQRT_UPPER_X96, Q96);
        uint256 liquidity0 = Math.mulDiv(amount0, intermediate, SQRT_UPPER_X96 - sqrtPriceX96);
        uint256 liquidity1 = Math.mulDiv(amount1, Q96, sqrtPriceX96 - SQRT_LOWER_X96);
        uint256 value = Math.min(liquidity0, liquidity1);
        if (value > type(uint128).max) revert InvalidPosition();
        liquidity = uint128(value);
    }
}
