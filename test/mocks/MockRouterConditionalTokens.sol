// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {
    IFutarchyConditionalTokens
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";

contract MockRouterConditionalTokens is ERC1155, IFutarchyConditionalTokens {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) private _outcomeSlotCount;
    mapping(bytes32 => uint256) public override payoutDenominator;
    mapping(bytes32 => mapping(uint256 => uint256)) public override payoutNumerators;
    address public splitShortfallCollateral;

    constructor() ERC1155("") {}

    function setOutcomeSlotCount(bytes32 conditionId, uint256 count) external {
        _outcomeSlotCount[conditionId] = count;
    }

    function setPayout(bytes32 conditionId, uint256 denominator, uint256 yes, uint256 no) external {
        payoutDenominator[conditionId] = denominator;
        payoutNumerators[conditionId][0] = yes;
        payoutNumerators[conditionId][1] = no;
    }

    function mintPosition(address to, uint256 tokenId, uint256 amount) external {
        _mint(to, tokenId, amount, "");
    }

    function setSplitShortfallCollateral(address collateralToken) external {
        splitShortfallCollateral = collateralToken;
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return _outcomeSlotCount[conditionId];
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(address collateralToken, bytes32 collectionId)
        external
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(collateralToken, collectionId)));
    }

    function splitPosition(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(parentCollectionId == bytes32(0) && partition.length == 2, "bad partition");
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(collateralToken, conditionId, partition[0]);
        tokenIds[1] = _tokenId(collateralToken, conditionId, partition[1]);
        uint256 mintAmount = collateralToken == splitShortfallCollateral ? amount - 1 : amount;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = mintAmount;
        amounts[1] = mintAmount;
        _mintBatch(msg.sender, tokenIds, amounts, "");
    }

    function mergePositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        require(parentCollectionId == bytes32(0) && partition.length == 2, "bad partition");
        _burn(msg.sender, _tokenId(collateralToken, conditionId, partition[0]), amount);
        _burn(msg.sender, _tokenId(collateralToken, conditionId, partition[1]), amount);
        IERC20(collateralToken).safeTransfer(msg.sender, amount);
    }

    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        require(parentCollectionId == bytes32(0), "not root");
        uint256 denominator = payoutDenominator[conditionId];
        require(denominator != 0, "unresolved");

        uint256 payout;
        for (uint256 i; i < indexSets.length; ++i) {
            uint256 tokenId = _tokenId(collateralToken, conditionId, indexSets[i]);
            uint256 amount = balanceOf(msg.sender, tokenId);
            if (amount != 0) {
                _burn(msg.sender, tokenId, amount);
                uint256 outcomeIndex = indexSets[i] == 1 ? 0 : 1;
                payout += amount * payoutNumerators[conditionId][outcomeIndex] / denominator;
            }
        }
        IERC20(collateralToken).safeTransfer(msg.sender, payout);
    }

    function _tokenId(address collateralToken, bytes32 conditionId, uint256 indexSet)
        private
        pure
        returns (uint256)
    {
        bytes32 collectionId = keccak256(abi.encode(bytes32(0), conditionId, indexSet));
        return uint256(keccak256(abi.encode(collateralToken, collectionId)));
    }
}
