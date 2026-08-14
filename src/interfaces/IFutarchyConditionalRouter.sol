// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyConditionalRouter {
    function splitPosition(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external;

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
    ) external;

    function mergePositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external;

    function redeemPositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external;

    function consumeLosingPositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external;

    function getPayouts(bytes32 conditionId)
        external
        view
        returns (uint256 denominator, uint256 yesNumerator, uint256 noNumerator);
}
