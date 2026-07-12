// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFutarchyLiquidityAdapter} from "../interfaces/IFutarchyLiquidityAdapter.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../interfaces/IUniswapV3NonfungiblePositionManager.sol";

/// @notice Manager-bound Uniswap V3 fee-500 adapter with one fixed-range NFT per ordered pair.
contract UniswapV3LiquidityAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

    uint24 public constant FEE = 500;
    int24 public constant TICK_SPACING = 10;
    int24 public constant MIN_TICK = -887_272;
    int24 public constant MAX_TICK = 887_272;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_USAGE_BPS = 9950;

    IUniswapV3NonfungiblePositionManager public immutable POSITION_MANAGER;
    int24 public immutable DEFAULT_TICK_LOWER;
    int24 public immutable DEFAULT_TICK_UPPER;
    address public MANAGER;

    address private immutable _bindingAuthority;

    mapping(bytes32 pairKey => uint256 tokenId) public positionTokenId;

    error InvalidAssetTransfer();
    error InvalidPosition();
    error InvalidTokenOrder();
    error InvalidTickRange();
    error ManagerAlreadyBound();
    error PositionNotFound();
    error InsufficientPositionLiquidity();
    error UnauthorizedBindingAuthority();
    error UnauthorizedManager();
    error UnsupportedData();
    error ZeroAddress();

    event ManagerBound(address indexed manager);
    event PositionMinted(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event LiquidityIncreased(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event LiquidityRemoved(bytes32 indexed pairKey, uint256 indexed tokenId, uint128 liquidity);
    event PositionBurned(bytes32 indexed pairKey, uint256 indexed tokenId);

    constructor(
        IUniswapV3NonfungiblePositionManager positionManager,
        int24 defaultTickLower,
        int24 defaultTickUpper
    ) {
        if (address(positionManager) == address(0)) revert ZeroAddress();
        if (
            defaultTickLower < MIN_TICK || defaultTickUpper > MAX_TICK
                || defaultTickLower >= defaultTickUpper || defaultTickLower % TICK_SPACING != 0
                || defaultTickUpper % TICK_SPACING != 0
        ) revert InvalidTickRange();

        POSITION_MANAGER = positionManager;
        DEFAULT_TICK_LOWER = defaultTickLower;
        DEFAULT_TICK_UPPER = defaultTickUpper;
        _bindingAuthority = msg.sender;
    }

    modifier onlyManager() {
        if (msg.sender != MANAGER) revert UnauthorizedManager();
        _;
    }

    /// @notice Irreversibly binds the adapter to the manager selected by its deployer.
    function bindManager(address manager) external {
        if (msg.sender != _bindingAuthority) revert UnauthorizedBindingAuthority();
        if (MANAGER != address(0)) revert ManagerAlreadyBound();
        if (manager == address(0)) revert ZeroAddress();
        MANAGER = manager;
        emit ManagerBound(manager);
    }

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
        _requireEmptyData(data);
        bytes32 key = _pairKey(token0, token1);
        uint256 balance0Before = _pullExactAndApprove(token0, amount0Desired);
        uint256 balance1Before = _pullExactAndApprove(token1, amount1Desired);

        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) {
            (tokenId, liquidityMinted, amount0Used, amount1Used) = POSITION_MANAGER.mint(
                IUniswapV3NonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    fee: FEE,
                    tickLower: DEFAULT_TICK_LOWER,
                    tickUpper: DEFAULT_TICK_UPPER,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: _minimumAmount(amount0Desired),
                    amount1Min: _minimumAmount(amount1Desired),
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            if (tokenId == 0) revert InvalidPosition();
            positionTokenId[key] = tokenId;
            emit PositionMinted(key, tokenId, liquidityMinted);
        } else {
            (liquidityMinted, amount0Used, amount1Used) = POSITION_MANAGER.increaseLiquidity(
                IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: _minimumAmount(amount0Desired),
                    amount1Min: _minimumAmount(amount1Desired),
                    deadline: block.timestamp
                })
            );
            emit LiquidityIncreased(key, tokenId, liquidityMinted);
        }

        _refundAndClear(token0, balance0Before, amount0Desired, amount0Used);
        _refundAndClear(token1, balance1Before, amount1Desired, amount1Used);
    }

    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata data)
        external
        onlyManager
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        _requireEmptyData(data);
        bytes32 key = _pairKey(token0, token1);
        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) revert PositionNotFound();

        uint128 currentLiquidity = _positionLiquidity(tokenId, token0, token1);
        if (liquidity == 0 || liquidity > currentLiquidity) revert InsufficientPositionLiquidity();

        POSITION_MANAGER.decreaseLiquidity(
            IUniswapV3NonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        uint256 balance0Before = IERC20(token0).balanceOf(msg.sender);
        uint256 balance1Before = IERC20(token1).balanceOf(msg.sender);
        (amount0Out, amount1Out) = POSITION_MANAGER.collect(
            IUniswapV3NonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (
            IERC20(token0).balanceOf(msg.sender) - balance0Before != amount0Out
                || IERC20(token1).balanceOf(msg.sender) - balance1Before != amount1Out
        ) revert InvalidAssetTransfer();
        emit LiquidityRemoved(key, tokenId, liquidity);

        if (liquidity == currentLiquidity) {
            POSITION_MANAGER.burn(tokenId);
            positionTokenId[key] = 0;
            emit PositionBurned(key, tokenId);
        }
    }

    function compoundPosition(address token0, address token1, bytes calldata data)
        external
        onlyManager
        returns (uint128 liquidityAdded)
    {
        _requireEmptyData(data);
        bytes32 key = _pairKey(token0, token1);
        uint256 tokenId = positionTokenId[key];
        if (tokenId == 0) return 0;
        _positionLiquidity(tokenId, token0, token1);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        (uint256 amount0Collected, uint256 amount1Collected) = POSITION_MANAGER.collect(
            IUniswapV3NonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (
            IERC20(token0).balanceOf(address(this)) - balance0Before != amount0Collected
                || IERC20(token1).balanceOf(address(this)) - balance1Before != amount1Collected
        ) revert InvalidAssetTransfer();
        if (amount0Collected == 0 && amount1Collected == 0) return 0;

        _approve(token0, amount0Collected);
        _approve(token1, amount1Collected);
        uint256 amount0Used;
        uint256 amount1Used;
        (liquidityAdded, amount0Used, amount1Used) = POSITION_MANAGER.increaseLiquidity(
            IUniswapV3NonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Collected,
                amount1Desired: amount1Collected,
                amount0Min: _minimumAmount(amount0Collected),
                amount1Min: _minimumAmount(amount1Collected),
                deadline: block.timestamp
            })
        );
        emit LiquidityIncreased(key, tokenId, liquidityAdded);

        _refundAndClear(token0, balance0Before, amount0Collected, amount0Used);
        _refundAndClear(token1, balance1Before, amount1Collected, amount1Used);
    }

    function getPositionTokenId(address token0, address token1) external view returns (uint256) {
        return positionTokenId[_pairKey(token0, token1)];
    }

    function _pairKey(address token0, address token1) internal pure returns (bytes32) {
        if (token0 == address(0) || token1 == address(0) || token0 >= token1) {
            revert InvalidTokenOrder();
        }
        return keccak256(abi.encode(token0, token1));
    }

    function _requireEmptyData(bytes calldata data) internal pure {
        if (data.length != 0) revert UnsupportedData();
    }

    function _minimumAmount(uint256 desired) internal pure returns (uint256) {
        return Math.mulDiv(desired, MIN_USAGE_BPS, BPS_DENOMINATOR);
    }

    function _pullExactAndApprove(address token, uint256 amount)
        internal
        returns (uint256 balanceBefore)
    {
        IERC20 asset = IERC20(token);
        balanceBefore = asset.balanceOf(address(this));
        if (amount == 0) return balanceBefore;
        asset.safeTransferFrom(msg.sender, address(this), amount);
        if (asset.balanceOf(address(this)) - balanceBefore != amount) {
            revert InvalidAssetTransfer();
        }
        _approve(token, amount);
    }

    function _approve(address token, uint256 amount) internal {
        if (amount == 0) return;
        IERC20 asset = IERC20(token);
        asset.safeApprove(address(POSITION_MANAGER), 0);
        asset.safeApprove(address(POSITION_MANAGER), amount);
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

    function _positionLiquidity(uint256 tokenId, address token0, address token1)
        internal
        view
        returns (uint128 liquidity)
    {
        address positionToken0;
        address positionToken1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        (,, positionToken0, positionToken1, fee, tickLower, tickUpper, liquidity,,,,) =
            POSITION_MANAGER.positions(tokenId);
        if (
            positionToken0 != token0 || positionToken1 != token1 || fee != FEE
                || tickLower != DEFAULT_TICK_LOWER || tickUpper != DEFAULT_TICK_UPPER
        ) revert InvalidPosition();
    }
}
