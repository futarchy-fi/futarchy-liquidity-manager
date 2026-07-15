// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {IAlgebraFactoryLike} from "../interfaces/IAlgebraFactoryLike.sol";
import {ISwaprAlgebraPositionManager} from "../interfaces/ISwaprAlgebraPositionManager.sol";

/// @title SwaprAlgebraLiquidityAdapter
/// @notice Swapr Algebra V3 adapter for a single position per ordered token pair.
/// @dev The adapter custodies Algebra position NFTs and can only be operated by its bound manager.
/// It is intentionally generic and has no FAO-specific logic.
contract SwaprAlgebraLiquidityAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MIN_USAGE_BPS = 9950;

    /// @notice Adapter parameters for minting or increasing Algebra liquidity.
    /// @param tickLower Lower tick for a new position; zero falls back to `DEFAULT_TICK_LOWER`.
    /// @param tickUpper Upper tick for a new position; zero falls back to `DEFAULT_TICK_UPPER`.
    /// @param amount0Min Minimum token0 amount to use.
    /// @param amount1Min Minimum token1 amount to use.
    /// @param deadline Swapr Algebra transaction deadline; zero maps to `block.timestamp`.
    /// @param sqrtPriceX96 Optional pool initialization price for a missing pool.
    struct AddParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    /// @notice Legacy v1 add params kept for backward compatibility with existing encoded calldata.
    struct LegacyAddParams {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    ISwaprAlgebraPositionManager public immutable POSITION_MANAGER;
    IAlgebraFactoryLike public immutable FACTORY;
    int24 public immutable DEFAULT_TICK_LOWER;
    int24 public immutable DEFAULT_TICK_UPPER;
    address public MANAGER;

    address private immutable _bindingAuthority;

    mapping(bytes32 pairKey => uint256 tokenId) public positionTokenId;

    error InvalidTokenOrder();
    error InvalidTickRange();
    error InvalidAssetTransfer();
    error InvalidPool();
    error InvalidPosition();
    error InsufficientTokenUsage();
    error PositionNotFound();
    error PositionAlreadyExists();
    error PoolAlreadyExists(address pool);
    error InsufficientPositionLiquidity();
    error ManagerAlreadyBound();
    error UnauthorizedBindingAuthority();
    error UnauthorizedManager();
    error ZeroAddress();
    error ZeroAmount();

    event ManagerBound(address indexed manager);
    event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event LiquidityIncreased(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event LiquidityRemoved(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event PositionBurned(bytes32 indexed pairKey, uint256 indexed tokenId);

    /// @param positionManager Swapr Algebra non-fungible position manager.
    /// @param defaultTickLower Fallback lower tick when `AddParams.tickLower` is zero.
    /// @param defaultTickUpper Fallback upper tick when `AddParams.tickUpper` is zero.
    constructor(
        ISwaprAlgebraPositionManager positionManager,
        int24 defaultTickLower,
        int24 defaultTickUpper
    ) {
        if (address(positionManager) == address(0)) revert ZeroAddress();
        if (defaultTickLower >= defaultTickUpper) revert InvalidTickRange();
        address factory = positionManager.factory();
        if (factory == address(0)) revert ZeroAddress();

        POSITION_MANAGER = positionManager;
        FACTORY = IAlgebraFactoryLike(factory);
        DEFAULT_TICK_LOWER = defaultTickLower;
        DEFAULT_TICK_UPPER = defaultTickUpper;
        _bindingAuthority = msg.sender;
    }

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert UnauthorizedManager();
        _;
    }

    /// @notice Irreversibly binds the adapter to its liquidity manager.
    /// @dev Only the contract or account that deployed this adapter may bind it.
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
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        bytes32 key = _pairKey(token0, token1);
        if (positionTokenId[key] != 0) revert PositionAlreadyExists();

        address existingPool = FACTORY.poolByPair(token0, token1);
        if (existingPool != address(0)) revert PoolAlreadyExists(existingPool);

        pool = POSITION_MANAGER.createAndInitializePoolIfNecessary(token0, token1, sqrtPriceX96);
        if (pool == address(0) || FACTORY.poolByPair(token0, token1) != pool) revert InvalidPool();

        uint256 balance0Before = _pullExactAndApprove(token0, amount0);
        uint256 balance1Before = _pullExactAndApprove(token1, amount1);
        uint256 amount0Min = _minimumFreshAmount(amount0);
        uint256 amount1Min = _minimumFreshAmount(amount1);
        AddParams memory params = AddParams({
            tickLower: DEFAULT_TICK_LOWER,
            tickUpper: DEFAULT_TICK_UPPER,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: block.timestamp,
            sqrtPriceX96: 0
        });

        uint256 tokenId;
        (tokenId, liquidityMinted, amount0Used, amount1Used) =
            _mintPosition(token0, token1, amount0, amount1, params);
        if (
            tokenId == 0 || liquidityMinted == 0 || amount0Used < amount0Min
                || amount1Used < amount1Min || amount0Used > amount0 || amount1Used > amount1
        ) revert InsufficientTokenUsage();
        _validateFreshPosition(tokenId, token0, token1, liquidityMinted);
        if (FACTORY.poolByPair(token0, token1) != pool) revert InvalidPool();

        positionTokenId[key] = tokenId;
        emit PositionMinted(key, tokenId, liquidityMinted);
        _refundAndClear(token0, balance0Before, amount0, amount0Used);
        _refundAndClear(token1, balance1Before, amount1, amount1Used);
    }

    /// @notice Pulls tokens from the caller and adds liquidity to this adapter's pair position.
    /// @dev Mints a new NFT on first use for the pair, otherwise increases the stored position.
    /// Unused input amounts are refunded to the caller.
    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata data
    )
        external
        onlyManager
        returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        bytes32 key = _pairKey(token0, token1);
        AddParams memory params = _decodeAddParams(data);
        _pullAndApprove(token0, amount0Desired, msg.sender);
        _pullAndApprove(token1, amount1Desired, msg.sender);

        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) {
            uint256 newTokenId;
            (newTokenId, liquidityMinted, amount0Used, amount1Used) =
                _mintPosition(token0, token1, amount0Desired, amount1Desired, params);
            positionTokenId[key] = newTokenId;
            emit PositionMinted(key, newTokenId, liquidityMinted);
        } else {
            (liquidityMinted, amount0Used, amount1Used) = _increaseLiquidity(
                tokenId,
                amount0Desired,
                amount1Desired,
                params.amount0Min,
                params.amount1Min,
                _deadline(params.deadline)
            );
            emit LiquidityIncreased(key, tokenId, liquidityMinted);
        }

        _refundIfAny(token0, amount0Desired, amount0Used, msg.sender);
        _refundIfAny(token1, amount1Desired, amount1Used, msg.sender);
    }

    /// @notice Collects fees, then removes exactly the requested share of the stored position.
    /// @dev Algebra's `collect` performs the zero-liquidity pool burn needed to materialize fees.
    function removeLiquidityDetailed(address token0, address token1, uint128 liquidityToRemove)
        external
        onlyManager
        returns (Removal memory removal)
    {
        bytes32 key = _pairKey(token0, token1);
        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) revert PositionNotFound();

        uint128 currentLiquidity = _positionLiquidity(tokenId);
        if (liquidityToRemove > currentLiquidity) revert InsufficientPositionLiquidity();

        (removal.fees0, removal.fees1) = _collectChecked(token0, token1, tokenId);
        if (liquidityToRemove == 0) return removal;

        ISwaprAlgebraPositionManager.DecreaseLiquidityParams memory decreaseParams =
            ISwaprAlgebraPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

        (removal.principal0, removal.principal1) =
            POSITION_MANAGER.decreaseLiquidity(decreaseParams);
        (uint256 collected0, uint256 collected1) = _collectChecked(token0, token1, tokenId);
        if (
            collected0 != removal.principal0 || collected1 != removal.principal1
                || _positionLiquidity(tokenId) != currentLiquidity - liquidityToRemove
        ) revert InvalidAssetTransfer();

        emit LiquidityRemoved(key, tokenId, liquidityToRemove);
        if (liquidityToRemove == currentLiquidity) {
            POSITION_MANAGER.burn(tokenId);
            positionTokenId[key] = 0;
            emit PositionBurned(key, tokenId);
        }
    }

    /// @notice Returns the stored Algebra position NFT for an ordered token pair.
    function getPositionTokenId(address token0, address token1) external view returns (uint256) {
        return positionTokenId[_pairKey(token0, token1)];
    }

    function _pairKey(address token0, address token1) internal pure returns (bytes32) {
        if (token0 == address(0) || token1 == address(0) || token0 >= token1) {
            revert InvalidTokenOrder();
        }
        return keccak256(abi.encode(token0, token1));
    }

    function _deadline(uint256 provided) internal view returns (uint256) {
        return provided == 0 ? block.timestamp : provided;
    }

    function _minimumFreshAmount(uint256 desired) internal pure returns (uint256) {
        return Math.mulDiv(desired, MIN_USAGE_BPS, BPS_DENOMINATOR, Math.Rounding.Up);
    }

    function _decodeAddParams(bytes calldata data) internal pure returns (AddParams memory params) {
        if (data.length == 0) return params;
        if (data.length == 160) {
            LegacyAddParams memory legacy = abi.decode(data, (LegacyAddParams));
            params.tickLower = legacy.tickLower;
            params.tickUpper = legacy.tickUpper;
            params.amount0Min = legacy.amount0Min;
            params.amount1Min = legacy.amount1Min;
            params.deadline = legacy.deadline;
            return params;
        }
        params = abi.decode(data, (AddParams));
    }

    function _pullAndApprove(address token, uint256 amount, address from) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(from, address(this), amount);
        // OpenZeppelin v4 compatibility: no IERC20.forceApprove
        IERC20(token).safeApprove(address(POSITION_MANAGER), 0);
        IERC20(token).safeApprove(address(POSITION_MANAGER), amount);
    }

    function _pullExactAndApprove(address token, uint256 amount)
        internal
        returns (uint256 balanceBefore)
    {
        IERC20 asset = IERC20(token);
        balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - balanceBefore != amount) {
            revert InvalidAssetTransfer();
        }
        asset.safeApprove(address(POSITION_MANAGER), 0);
        asset.safeApprove(address(POSITION_MANAGER), amount);
    }

    function _mintPosition(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        AddParams memory params
    )
        internal
        returns (uint256 tokenId, uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used)
    {
        int24 tickLower = params.tickLower == 0 ? DEFAULT_TICK_LOWER : params.tickLower;
        int24 tickUpper = params.tickUpper == 0 ? DEFAULT_TICK_UPPER : params.tickUpper;
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (params.sqrtPriceX96 != 0) {
            POSITION_MANAGER.createAndInitializePoolIfNecessary(token0, token1, params.sqrtPriceX96);
        }

        ISwaprAlgebraPositionManager.MintParams memory mintParams =
            ISwaprAlgebraPositionManager.MintParams({
                token0: token0,
                token1: token1,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this),
                deadline: _deadline(params.deadline)
            });

        (tokenId, liquidityMinted, amount0Used, amount1Used) = POSITION_MANAGER.mint(mintParams);
    }

    function _collectChecked(address token0, address token1, uint256 tokenId)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 balance0Before = IERC20(token0).balanceOf(msg.sender);
        uint256 balance1Before = IERC20(token1).balanceOf(msg.sender);
        ISwaprAlgebraPositionManager.CollectParams memory collectParams =
            ISwaprAlgebraPositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = POSITION_MANAGER.collect(collectParams);
        uint256 balance0After = IERC20(token0).balanceOf(msg.sender);
        uint256 balance1After = IERC20(token1).balanceOf(msg.sender);
        if (
            balance0After < balance0Before || balance1After < balance1Before
                || balance0After - balance0Before != amount0
                || balance1After - balance1Before != amount1
        ) revert InvalidAssetTransfer();
    }

    function _increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal returns (uint128 liquidityAdded, uint256 amount0Used, uint256 amount1Used) {
        ISwaprAlgebraPositionManager.IncreaseLiquidityParams memory increaseParams =
            ISwaprAlgebraPositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });
        (liquidityAdded, amount0Used, amount1Used) =
            POSITION_MANAGER.increaseLiquidity(increaseParams);
    }

    function _refundIfAny(
        address token,
        uint256 amountCollected,
        uint256 amountUsed,
        address recipient
    ) internal {
        if (amountCollected <= amountUsed) return;
        IERC20(token).safeTransfer(recipient, amountCollected - amountUsed);
    }

    function _refundAndClear(
        address token,
        uint256 balanceBefore,
        uint256 amountDesired,
        uint256 amountReportedUsed
    ) internal {
        IERC20 asset = IERC20(token);
        uint256 balanceAfter = asset.balanceOf(address(this));
        if (balanceAfter < balanceBefore) revert InvalidAssetTransfer();
        uint256 refund = balanceAfter - balanceBefore;
        if (refund > amountDesired || amountDesired - refund != amountReportedUsed) {
            revert InvalidAssetTransfer();
        }
        if (asset.allowance(address(this), address(POSITION_MANAGER)) != 0) {
            asset.safeApprove(address(POSITION_MANAGER), 0);
        }
        if (refund > 0) asset.safeTransfer(msg.sender, refund);
        if (asset.balanceOf(address(this)) != balanceBefore) revert InvalidAssetTransfer();
    }

    function _validateFreshPosition(
        uint256 tokenId,
        address token0,
        address token1,
        uint128 expectedLiquidity
    ) internal view {
        address positionToken0;
        address positionToken1;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        (,, positionToken0, positionToken1, tickLower, tickUpper, liquidity,,,,) =
            POSITION_MANAGER.positions(tokenId);
        if (
            positionToken0 != token0 || positionToken1 != token1 || tickLower != DEFAULT_TICK_LOWER
                || tickUpper != DEFAULT_TICK_UPPER || liquidity != expectedLiquidity
        ) revert InvalidPosition();
    }

    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,, liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
    }
}
