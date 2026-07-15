// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {MockMintableERC20} from "./MockMintableERC20.sol";

contract MockConditionalRouter is IFutarchyConditionalRouter {
    using SafeERC20 for IERC20;

    address public CONDITIONAL_TOKENS;

    bool public winnerIsYes;
    bool public redeemReverts;
    bool public redeemUnderconsumes;
    bool public redeemUnderpays;
    bool public mergeReverts;
    bool public mergeUnderconsumes;
    bool public mergeUnderpays;
    bool public consumeUnderpays;
    uint256 public payoutDenominator;
    uint256 public yesNumerator;
    uint256 public noNumerator;

    struct OutcomeConfig {
        address yesToken;
        address noToken;
        bool winnerIsYes;
        bool exists;
    }

    mapping(address collateralToken => OutcomeConfig) public outcomeConfig;

    function setConditionalTokens(address conditionalTokens) external {
        CONDITIONAL_TOKENS = conditionalTokens;
    }

    function setOutcomeConfig(
        address,
        address collateralToken,
        address yesToken,
        address noToken,
        bool _winnerIsYes
    ) external {
        winnerIsYes = _winnerIsYes;
        outcomeConfig[collateralToken] = OutcomeConfig({
            yesToken: yesToken, noToken: noToken, winnerIsYes: _winnerIsYes, exists: true
        });
    }

    function setRedeemReverts(bool value) external {
        redeemReverts = value;
    }

    function setRedeemUnderpays(bool value) external {
        redeemUnderpays = value;
    }

    function setRedeemUnderconsumes(bool value) external {
        redeemUnderconsumes = value;
    }

    function setMergeReverts(bool value) external {
        mergeReverts = value;
    }

    function setMergeUnderconsumes(bool value) external {
        mergeUnderconsumes = value;
    }

    function setMergeUnderpays(bool value) external {
        mergeUnderpays = value;
    }

    function setConsumeUnderpays(bool value) external {
        consumeUnderpays = value;
    }

    function setPayouts(uint256 denominator, uint256 yesPayout, uint256 noPayout) external {
        payoutDenominator = denominator;
        yesNumerator = yesPayout;
        noNumerator = noPayout;
        if (denominator > 0 && (yesPayout == denominator || noPayout == denominator)) {
            winnerIsYes = yesPayout == denominator;
        }
    }

    function splitPosition(
        address collateralToken,
        bytes32,
        address yesToken,
        address noToken,
        uint256 amount
    ) external {
        OutcomeConfig memory cfg = _config(collateralToken, yesToken, noToken);
        if (amount == 0) return;

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        MockMintableERC20(cfg.yesToken).mint(msg.sender, amount);
        MockMintableERC20(cfg.noToken).mint(msg.sender, amount);
    }

    function splitPositionPairTo(
        bytes32 conditionId,
        address collateralToken1,
        address yesToken1,
        address noToken1,
        uint256 amount1,
        address collateralToken2,
        address yesToken2,
        address noToken2,
        uint256 amount2,
        address recipient
    ) external {
        conditionId;
        _splitTo(collateralToken1, yesToken1, noToken1, amount1, recipient);
        _splitTo(collateralToken2, yesToken2, noToken2, amount2, recipient);
    }

    function _splitTo(
        address collateralToken,
        address yesToken,
        address noToken,
        uint256 amount,
        address recipient
    ) internal {
        OutcomeConfig memory cfg = _config(collateralToken, yesToken, noToken);
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        MockMintableERC20(cfg.yesToken).mint(recipient, amount);
        MockMintableERC20(cfg.noToken).mint(recipient, amount);
    }

    function mergePositions(
        address collateralToken,
        bytes32,
        address yesToken,
        address noToken,
        uint256 amount
    ) external {
        require(!mergeReverts, "merge failed");
        OutcomeConfig memory cfg = _config(collateralToken, yesToken, noToken);
        if (amount == 0) return;

        uint256 yesBal = IERC20(cfg.yesToken).balanceOf(msg.sender);
        uint256 noBal = IERC20(cfg.noToken).balanceOf(msg.sender);
        uint256 mergeAmount = _min(amount, _min(yesBal, noBal));
        if (mergeAmount == 0) return;

        uint256 consumed = mergeUnderconsumes ? mergeAmount - 1 : mergeAmount;
        IERC20(cfg.yesToken).safeTransferFrom(msg.sender, address(this), consumed);
        IERC20(cfg.noToken).safeTransferFrom(msg.sender, address(this), consumed);

        uint256 collateralBal = IERC20(collateralToken).balanceOf(address(this));
        uint256 payout = _min(mergeAmount, collateralBal);
        if (mergeUnderpays && payout > 0) payout--;
        if (payout > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, payout);
        }
    }

    function redeemPositions(
        address collateralToken,
        bytes32,
        address yesToken,
        address noToken,
        uint256 amount
    ) external {
        require(!redeemReverts, "redeem failed");
        OutcomeConfig memory cfg = _config(collateralToken, yesToken, noToken);
        if (amount == 0) return;

        address winningToken = cfg.winnerIsYes ? cfg.yesToken : cfg.noToken;
        uint256 winningBal = IERC20(winningToken).balanceOf(msg.sender);
        uint256 collateralBal = IERC20(collateralToken).balanceOf(address(this));
        uint256 redeemAmount = _min(amount, _min(winningBal, collateralBal));
        if (redeemAmount == 0) return;

        uint256 consumed = redeemUnderconsumes ? redeemAmount - 1 : redeemAmount;
        IERC20(winningToken).safeTransferFrom(msg.sender, address(this), consumed);
        uint256 payout = redeemUnderpays ? redeemAmount - 1 : redeemAmount;
        IERC20(collateralToken).safeTransfer(msg.sender, payout);
    }

    function consumeLosingPositions(
        address collateralToken,
        bytes32,
        address yesToken,
        address noToken,
        uint256 amount
    ) external {
        OutcomeConfig memory cfg = _config(collateralToken, yesToken, noToken);
        address losingToken = cfg.winnerIsYes ? cfg.noToken : cfg.yesToken;
        IERC20(losingToken)
            .safeTransferFrom(msg.sender, address(this), consumeUnderpays ? amount - 1 : amount);
    }

    function getPayouts(bytes32)
        external
        view
        returns (uint256 denominator, uint256 yesPayout, uint256 noPayout)
    {
        return (payoutDenominator, yesNumerator, noNumerator);
    }

    function getWinningOutcomes(bytes32) external view returns (bool[] memory outcomes) {
        outcomes = new bool[](2);
        outcomes[winnerIsYes ? 0 : 1] = true;
    }

    function _config(address collateralToken, address yesToken, address noToken)
        internal
        view
        returns (OutcomeConfig memory cfg)
    {
        cfg = outcomeConfig[collateralToken];
        require(
            cfg.exists && cfg.yesToken == yesToken && cfg.noToken == noToken,
            "missing outcome config"
        );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
