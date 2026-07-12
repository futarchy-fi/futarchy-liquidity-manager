// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @notice Asset-changing subset of Gnosis Conditional Tokens used by the FLM router.
interface IFutarchyConditionalTokens is IERC1155 {
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);

    function payoutDenominator(bytes32 conditionId) external view returns (uint256);

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256);

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256);

    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    function mergePositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external;

    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
}

/// @notice Live-compatible Gnosis 1155-to-20 factory subset used by the FLM router.
interface IFutarchyWrapped1155Factory {
    function getWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        view
        returns (address);

    function requireWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        returns (address);

    function unwrap(
        address multiToken,
        uint256 tokenId,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external;
}
