// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFutarchyLiquidityAdapter} from "../../src/interfaces/IFutarchyLiquidityAdapter.sol";

/// @notice Minimal deterministic adapter for high-level tests.
///         Liquidity units are modeled as min(token0, token1) amounts.
contract MockFutarchyLiquidityAdapter is IFutarchyLiquidityAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint128 public totalLiquidity;
    mapping(bytes32 => uint128) public liquidityByPair;
    mapping(bytes32 => uint256) public principal0ByPair;
    mapping(bytes32 => uint256) public principal1ByPair;
    mapping(bytes32 => uint256) public fee0ByPair;
    mapping(bytes32 => uint256) public fee1ByPair;
    uint16 public amount0UsageBps = uint16(BPS_DENOMINATOR);
    uint16 public amount1UsageBps = uint16(BPS_DENOMINATOR);
    uint16 public nextAddUsageBps;
    bool public zeroRemoveOutput;
    bool public addReverts;

    function setAddUsageBps(uint16 amount0Bps, uint16 amount1Bps) external {
        require(amount0Bps <= BPS_DENOMINATOR && amount1Bps <= BPS_DENOMINATOR, "invalid bps");
        amount0UsageBps = amount0Bps;
        amount1UsageBps = amount1Bps;
    }

    function setNextAddUsageBps(uint16 usageBps) external {
        require(usageBps > 0 && usageBps <= BPS_DENOMINATOR, "invalid bps");
        nextAddUsageBps = usageBps;
    }

    function setZeroRemoveOutput(bool value) external {
        zeroRemoveOutput = value;
    }

    function setAddReverts(bool value) external {
        addReverts = value;
    }

    function accrueFees(address token0, address token1, uint256 amount0, uint256 amount1) external {
        bytes32 pairKey = keccak256(abi.encode(token0, token1));
        if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);
        fee0ByPair[pairKey] += amount0;
        fee1ByPair[pairKey] += amount1;
    }

    function addFullRangeLiquidity(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        bytes calldata
    ) external returns (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used) {
        require(!addReverts, "LP add failed");
        bytes32 pairKey = keccak256(abi.encode(token0, token1));
        if (nextAddUsageBps > 0) {
            amount0Used = (amount0Desired * nextAddUsageBps) / BPS_DENOMINATOR;
            amount1Used = (amount1Desired * nextAddUsageBps) / BPS_DENOMINATOR;
            nextAddUsageBps = 0;
        } else {
            amount0Used = (amount0Desired * amount0UsageBps) / BPS_DENOMINATOR;
            amount1Used = (amount1Desired * amount1UsageBps) / BPS_DENOMINATOR;
        }
        uint256 liq = amount0Used < amount1Used ? amount0Used : amount1Used;
        liquidityMinted = uint128(liq);

        if (amount0Used > 0) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0Used);
        }
        if (amount1Used > 0) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1Used);
        }

        liquidityByPair[pairKey] += liquidityMinted;
        totalLiquidity += liquidityMinted;
        principal0ByPair[pairKey] += amount0Used;
        principal1ByPair[pairKey] += amount1Used;
    }

    function removeLiquidity(address token0, address token1, uint128 liquidity, bytes calldata)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        bytes32 pairKey = keccak256(abi.encode(token0, token1));
        uint128 liquidityBefore = liquidityByPair[pairKey];
        require(liquidity <= liquidityBefore, "insufficient liquidity");
        uint256 principal0 = liquidity == liquidityBefore
            ? principal0ByPair[pairKey]
            : (principal0ByPair[pairKey] * liquidity) / liquidityBefore;
        uint256 principal1 = liquidity == liquidityBefore
            ? principal1ByPair[pairKey]
            : (principal1ByPair[pairKey] * liquidity) / liquidityBefore;
        liquidityByPair[pairKey] = liquidityBefore - liquidity;
        totalLiquidity -= liquidity;
        principal0ByPair[pairKey] -= principal0;
        principal1ByPair[pairKey] -= principal1;

        if (!zeroRemoveOutput) {
            amount0Out = principal0 + fee0ByPair[pairKey];
            amount1Out = principal1 + fee1ByPair[pairKey];
            fee0ByPair[pairKey] = 0;
            fee1ByPair[pairKey] = 0;
        }
        if (amount0Out > 0) {
            IERC20(token0).safeTransfer(msg.sender, amount0Out);
        }
        if (amount1Out > 0) {
            IERC20(token1).safeTransfer(msg.sender, amount1Out);
        }
    }

    function compoundPosition(address, address, bytes calldata) external pure returns (uint128) {
        return 0;
    }
}
