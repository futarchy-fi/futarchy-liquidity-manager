// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../interfaces/ISwaprAlgebraPositionManager.sol";

/// @title SwaprAlgebraLiquidityAdapter
/// @notice Swapr Algebra V3 adapter for a single position per ordered token pair.
/// @dev The adapter custodies Algebra position NFTs and can only be operated by its bound manager.
/// It is intentionally generic and has no FAO-specific logic.
contract SwaprAlgebraLiquidityAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

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

    /// @notice Adapter parameters for removing or compounding Algebra liquidity.
    /// @param amount0Min Minimum token0 amount accepted.
    /// @param amount1Min Minimum token1 amount accepted.
    /// @param deadline Swapr Algebra transaction deadline; zero maps to `block.timestamp`.
    struct ExitParams {
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    ISwaprAlgebraPositionManager public immutable POSITION_MANAGER;
    int24 public immutable DEFAULT_TICK_LOWER;
    int24 public immutable DEFAULT_TICK_UPPER;
    address public MANAGER;

    address private immutable _bindingAuthority;

    mapping(bytes32 pairKey => uint256 tokenId) public positionTokenId;

    error InvalidTokenOrder();
    error InvalidTickRange();
    error PositionNotFound();
    error InsufficientPositionLiquidity();
    error ManagerAlreadyBound();
    error UnauthorizedBindingAuthority();
    error UnauthorizedManager();
    error ZeroAddress();

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

        POSITION_MANAGER = positionManager;
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

    /// @notice Removes liquidity from this adapter's stored pair position.
    /// @dev Collects all owed token balances to the caller and burns the NFT when all liquidity is
    /// removed.
    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata data)
        external
        onlyManager
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        bytes32 key = _pairKey(token0, token1);
        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) revert PositionNotFound();

        ExitParams memory params = _decodeExitParams(data);
        uint128 currentLiquidity = _positionLiquidity(tokenId);
        if (liquidity == 0 || liquidity > currentLiquidity) revert InsufficientPositionLiquidity();

        ISwaprAlgebraPositionManager.DecreaseLiquidityParams memory decreaseParams =
            ISwaprAlgebraPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                deadline: _deadline(params.deadline)
            });

        POSITION_MANAGER.decreaseLiquidity(decreaseParams);

        ISwaprAlgebraPositionManager.CollectParams memory collectParams =
            ISwaprAlgebraPositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0Out, amount1Out) = POSITION_MANAGER.collect(collectParams);
        emit LiquidityRemoved(key, tokenId, liquidity);

        if (liquidity == currentLiquidity) {
            POSITION_MANAGER.burn(tokenId);
            positionTokenId[key] = 0;
            emit PositionBurned(key, tokenId);
        }
    }

    /// @notice Collects fees to this adapter and reinvests them into the existing pair position.
    /// @dev Returns zero when no position exists or no fees are collectable.
    function compoundPosition(address token0, address token1, bytes calldata data)
        external
        onlyManager
        returns (uint128 liquidityAdded)
    {
        bytes32 key = _pairKey(token0, token1);
        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) return 0;

        ExitParams memory params = _decodeExitParams(data);
        (uint256 amount0Collected, uint256 amount1Collected) = _collectToSelf(tokenId);
        if (amount0Collected == 0 && amount1Collected == 0) return 0;

        uint256 amount0Used;
        uint256 amount1Used;
        _approveIfAny(token0, amount0Collected);
        _approveIfAny(token1, amount1Collected);
        (liquidityAdded, amount0Used, amount1Used) = _increaseLiquidity(
            tokenId,
            amount0Collected,
            amount1Collected,
            params.amount0Min,
            params.amount1Min,
            _deadline(params.deadline)
        );
        emit LiquidityIncreased(key, tokenId, liquidityAdded);

        _refundIfAny(token0, amount0Collected, amount0Used, msg.sender);
        _refundIfAny(token1, amount1Collected, amount1Used, msg.sender);
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

    function _decodeExitParams(bytes calldata data)
        internal
        pure
        returns (ExitParams memory params)
    {
        if (data.length == 0) return params;
        params = abi.decode(data, (ExitParams));
    }

    function _pullAndApprove(address token, uint256 amount, address from) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(from, address(this), amount);
        // OpenZeppelin v4 compatibility: no IERC20.forceApprove
        IERC20(token).safeApprove(address(POSITION_MANAGER), 0);
        IERC20(token).safeApprove(address(POSITION_MANAGER), amount);
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

    function _collectToSelf(uint256 tokenId) internal returns (uint256 amount0, uint256 amount1) {
        ISwaprAlgebraPositionManager.CollectParams memory collectParams =
            ISwaprAlgebraPositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
        (amount0, amount1) = POSITION_MANAGER.collect(collectParams);
    }

    function _approveIfAny(address token, uint256 amount) internal {
        if (amount == 0) return;
        // OpenZeppelin v4 compatibility: no IERC20.forceApprove
        IERC20(token).safeApprove(address(POSITION_MANAGER), 0);
        IERC20(token).safeApprove(address(POSITION_MANAGER), amount);
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

    function _positionLiquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,, liquidity,,,,) = POSITION_MANAGER.positions(tokenId);
    }
}
