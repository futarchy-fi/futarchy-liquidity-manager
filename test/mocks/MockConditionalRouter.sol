// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {MockMintableERC20} from "./MockMintableERC20.sol";

contract MockConditionalRouter is IFutarchyConditionalRouter {
    using SafeERC20 for IERC20;

    bool public winnerIsYes;
    bool public redeemReverts;
    bool public mergeReverts;
    bool public mergeUnderpays;

    struct OutcomeConfig {
        address yesToken;
        address noToken;
        bool winnerIsYes;
        bool exists;
    }

    mapping(address proposal => mapping(address collateralToken => OutcomeConfig)) public
        outcomeConfig;

    function setOutcomeConfig(
        address proposal,
        address collateralToken,
        address yesToken,
        address noToken,
        bool _winnerIsYes
    ) external {
        winnerIsYes = _winnerIsYes;
        outcomeConfig[proposal][collateralToken] = OutcomeConfig({
            yesToken: yesToken, noToken: noToken, winnerIsYes: _winnerIsYes, exists: true
        });
    }

    function setRedeemReverts(bool value) external {
        redeemReverts = value;
    }

    function setMergeReverts(bool value) external {
        mergeReverts = value;
    }

    function setMergeUnderpays(bool value) external {
        mergeUnderpays = value;
    }

    function splitPosition(address proposal, address collateralToken, uint256 amount) external {
        OutcomeConfig memory cfg = outcomeConfig[proposal][collateralToken];
        require(cfg.exists, "missing outcome config");
        if (amount == 0) return;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        MockMintableERC20(cfg.yesToken).mint(msg.sender, amount);
        MockMintableERC20(cfg.noToken).mint(msg.sender, amount);
    }

    function mergePositions(address proposal, address collateralToken, uint256 amount) external {
        require(!mergeReverts, "merge failed");
        OutcomeConfig memory cfg = outcomeConfig[proposal][collateralToken];
        require(cfg.exists, "missing outcome config");
        if (amount == 0) return;

        uint256 yesBal = IERC20(cfg.yesToken).balanceOf(msg.sender);
        uint256 noBal = IERC20(cfg.noToken).balanceOf(msg.sender);
        uint256 mergeAmount = _min(amount, _min(yesBal, noBal));
        if (mergeAmount == 0) return;

        IERC20(cfg.yesToken).safeTransferFrom(msg.sender, address(this), mergeAmount);
        IERC20(cfg.noToken).safeTransferFrom(msg.sender, address(this), mergeAmount);

        uint256 collateralBal = IERC20(collateralToken).balanceOf(address(this));
        uint256 payout = _min(mergeAmount, collateralBal);
        if (mergeUnderpays && payout > 0) payout--;
        if (payout > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, payout);
        }
    }

    function redeemPositions(address proposal, address collateralToken, uint256 amount) external {
        require(!redeemReverts, "redeem failed");
        OutcomeConfig memory cfg = outcomeConfig[proposal][collateralToken];
        require(cfg.exists, "missing outcome config");
        if (amount == 0) return;

        address winningToken = cfg.winnerIsYes ? cfg.yesToken : cfg.noToken;
        uint256 winningBal = IERC20(winningToken).balanceOf(msg.sender);
        uint256 collateralBal = IERC20(collateralToken).balanceOf(address(this));
        uint256 redeemAmount = _min(amount, _min(winningBal, collateralBal));
        if (redeemAmount == 0) return;

        IERC20(winningToken).safeTransferFrom(msg.sender, address(this), redeemAmount);
        IERC20(collateralToken).safeTransfer(msg.sender, redeemAmount);
    }

    function getWinningOutcomes(bytes32) external view returns (bool[] memory outcomes) {
        outcomes = new bool[](2);
        outcomes[winnerIsYes ? 0 : 1] = true;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
