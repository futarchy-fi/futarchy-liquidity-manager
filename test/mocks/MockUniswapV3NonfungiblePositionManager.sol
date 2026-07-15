// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    IUniswapV3NonfungiblePositionManager
} from "../../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {MockUniswapV3FactoryLike} from "./MockUniswapV3FactoryLike.sol";

contract MockUniswapV3NonfungiblePositionManager is IUniswapV3NonfungiblePositionManager {
    using SafeERC20 for IERC20;

    error PoolCreationFailed();
    error PoolInitializationFailed();

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    address public immutable factory;

    constructor() {
        factory = address(new MockUniswapV3FactoryLike());
    }

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 principal0;
        uint256 principal1;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 tokenId => Position position) internal _positions;

    uint256 public nextTokenId = 1;
    uint16 public usageBps = uint16(BPS_DENOMINATOR);
    uint256 public mintCalls;
    uint256 public increaseCalls;
    uint256 public decreaseCalls;
    uint256 public collectCalls;
    uint256 public burnCalls;
    uint256 public poolInitializationCalls;
    uint160 public lastPoolSqrtPriceX96;
    uint8 public poolLifecycleFailure;

    uint24 public lastFee;
    uint256 public lastAmount0Min;
    uint256 public lastAmount1Min;
    uint256 public lastDeadline;
    address public lastRecipient;

    function setUsageBps(uint16 value) external {
        require(value <= BPS_DENOMINATOR, "usage bps");
        usageBps = value;
    }

    function setPoolLifecycleFailure(uint8 value) external {
        require(value <= 2, "pool failure");
        poolLifecycleFailure = value;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        mintCalls++;
        _record(params.fee, params.amount0Min, params.amount1Min, params.deadline);
        lastRecipient = params.recipient;
        (amount0, amount1) = _useInputs(
            params.token0,
            params.token1,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min
        );
        liquidity = _liquidity(amount0, amount1);
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            principal0: amount0,
            principal1: amount1,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        increaseCalls++;
        Position storage position = _positions[params.tokenId];
        require(position.token0 != address(0), "position");
        _record(position.fee, params.amount0Min, params.amount1Min, params.deadline);
        (amount0, amount1) = _useInputs(
            position.token0,
            position.token1,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min
        );
        liquidity = _liquidity(amount0, amount1);
        position.liquidity += liquidity;
        position.principal0 += amount0;
        position.principal1 += amount1;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        decreaseCalls++;
        Position storage position = _positions[params.tokenId];
        uint128 liquidityBefore = position.liquidity;
        require(params.liquidity > 0 && params.liquidity <= liquidityBefore, "liquidity");
        _record(position.fee, params.amount0Min, params.amount1Min, params.deadline);

        amount0 = params.liquidity == liquidityBefore
            ? position.principal0
            : (position.principal0 * params.liquidity) / liquidityBefore;
        amount1 = params.liquidity == liquidityBefore
            ? position.principal1
            : (position.principal1 * params.liquidity) / liquidityBefore;
        require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, "minimum");
        require(
            amount0 <= type(uint128).max - position.tokensOwed0
                && amount1 <= type(uint128).max - position.tokensOwed1,
            "owed overflow"
        );

        position.liquidity = liquidityBefore - params.liquidity;
        position.principal0 -= amount0;
        position.principal1 -= amount1;
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
    }

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        collectCalls++;
        Position storage position = _positions[params.tokenId];
        lastRecipient = params.recipient;
        amount0 = _min(position.tokensOwed0, params.amount0Max);
        amount1 = _min(position.tokensOwed1, params.amount1Max);
        position.tokensOwed0 -= uint128(amount0);
        position.tokensOwed1 -= uint128(amount1);
        if (amount0 > 0) IERC20(position.token0).safeTransfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(position.token1).safeTransfer(params.recipient, amount1);
    }

    function burn(uint256 tokenId) external payable {
        Position storage position = _positions[tokenId];
        require(
            position.liquidity == 0 && position.tokensOwed0 == 0 && position.tokensOwed1 == 0,
            "not empty"
        );
        burnCalls++;
        delete _positions[tokenId];
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        nonce = 0;
        operator = address(0);
        token0 = position.token0;
        token1 = position.token1;
        fee = position.fee;
        tickLower = position.tickLower;
        tickUpper = position.tickUpper;
        liquidity = position.liquidity;
        feeGrowthInside0LastX128 = 0;
        feeGrowthInside1LastX128 = 0;
        tokensOwed0 = position.tokensOwed0;
        tokensOwed1 = position.tokensOwed1;
    }

    function accrueFees(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        Position storage position = _positions[tokenId];
        require(
            amount0 <= type(uint128).max - position.tokensOwed0
                && amount1 <= type(uint128).max - position.tokensOwed1,
            "owed overflow"
        );
        if (amount0 > 0) {
            IERC20(position.token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            IERC20(position.token1).safeTransferFrom(msg.sender, address(this), amount1);
        }
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address) {
        if (poolLifecycleFailure == 1) revert PoolCreationFailed();
        address pool = address(0xBEEF);
        MockUniswapV3FactoryLike(factory).setPool(token0, token1, fee, pool);
        if (poolLifecycleFailure == 2) revert PoolInitializationFailed();
        poolInitializationCalls++;
        lastPoolSqrtPriceX96 = sqrtPriceX96;
        return pool;
    }

    function _useInputs(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 amount0, uint256 amount1) {
        amount0 = (amount0Desired * usageBps) / BPS_DENOMINATOR;
        amount1 = (amount1Desired * usageBps) / BPS_DENOMINATOR;
        require(amount0 >= amount0Min && amount1 >= amount1Min, "minimum");
        if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
    }

    function _record(uint24 fee, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        internal
    {
        lastFee = fee;
        lastAmount0Min = amount0Min;
        lastAmount1Min = amount1Min;
        lastDeadline = deadline;
    }

    function _liquidity(uint256 amount0, uint256 amount1) internal pure returns (uint128 value) {
        uint256 minimum = _min(amount0, amount1);
        require(minimum <= type(uint128).max, "liquidity overflow");
        value = uint128(minimum);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
