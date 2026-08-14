// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../interfaces/IFutarchyConditionalDependencies.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";

interface ICanonicalWrapped1155 is IERC20Metadata {
    function factory() external view returns (address);

    function multiToken() external view returns (address);

    function tokenId() external view returns (uint256);
}

/// @title FutarchyConditionalRouter
/// @notice Converts root binary futarchy collateral to and from Wrapped1155 outcome ERC20s.
/// @dev Deliberately excludes nested conditions. Every asset-changing path preserves pre-existing
/// ERC20 balances and verifies exact 1:1 deltas before returning assets to the caller. Winning
/// ERC1155 balances sent to the predictable address before deployment are discarded on redemption.
contract FutarchyConditionalRouter is IFutarchyConditionalRouter, ERC1155Holder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant ROOT_COLLECTION = bytes32(0);
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IFutarchyConditionalTokens public immutable CONDITIONAL_TOKENS;
    IFutarchyWrapped1155Factory public immutable WRAPPED_1155_FACTORY;

    bytes32 private _expectedReceiptHash;

    bytes32 private constant SINGLE_RECEIPT_DOMAIN = keccak256("FLM_SINGLE_RECEIPT_V1");
    bytes32 private constant BATCH_RECEIPT_DOMAIN = keccak256("FLM_BATCH_RECEIPT_V1");

    struct Position {
        IERC20 wrapper;
        bytes data;
        uint256 tokenId;
    }

    error InvalidDependency();
    error ZeroAmount();
    error InvalidCollateral();
    error NonBinaryCondition();
    error InvalidWrapper(uint256 index, address expected, address actual);
    error InvalidBalanceDelta();
    error InvalidWinningOutcome();
    error InvalidRecipient();
    error UnexpectedConditionalTokenBalance(uint256 tokenId);
    error UnexpectedERC1155Receipt();
    error InvalidWrapperMetadata(address wrapper);

    constructor(
        IFutarchyConditionalTokens conditionalTokens,
        IFutarchyWrapped1155Factory wrapped1155Factory
    ) {
        if (
            address(conditionalTokens).code.length == 0
                || address(wrapped1155Factory).code.length == 0
        ) revert InvalidDependency();

        CONDITIONAL_TOKENS = conditionalTokens;
        WRAPPED_1155_FACTORY = wrapped1155Factory;
    }

    function splitPosition(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (Position memory yesPosition, Position memory noPosition) =
            _positions(collateralToken, conditionId, yesToken, noToken);

        _splitPositionTo(collateralToken, conditionId, amount, yesPosition, noPosition, msg.sender);
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
    ) external nonReentrant {
        if (amount1 == 0 || amount2 == 0) revert ZeroAmount();
        if (recipient.code.length == 0) revert InvalidRecipient();
        (Position memory yesPosition1, Position memory noPosition1) =
            _positions(collateralToken1, conditionId, yesToken1, noToken1);
        (Position memory yesPosition2, Position memory noPosition2) =
            _positions(collateralToken2, conditionId, yesToken2, noToken2);

        _splitPositionTo(
            collateralToken1, conditionId, amount1, yesPosition1, noPosition1, recipient
        );
        _splitPositionTo(
            collateralToken2, conditionId, amount2, yesPosition2, noPosition2, recipient
        );
    }

    function _splitPositionTo(
        address collateralToken,
        bytes32 conditionId,
        uint256 amount,
        Position memory yesPosition,
        Position memory noPosition,
        address recipient
    ) private {
        IERC20 collateral = IERC20(collateralToken);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 ctfCollateralBefore = collateral.balanceOf(address(CONDITIONAL_TOKENS));
        uint256 yesUnderlyingBefore =
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId);
        uint256 noUnderlyingBefore = CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId);

        _pullExact(collateral, msg.sender, amount);
        collateral.safeApprove(address(CONDITIONAL_TOKENS), amount);
        _expectBatch(yesPosition.tokenId, noPosition.tokenId, amount);
        CONDITIONAL_TOKENS.splitPosition(
            collateralToken, ROOT_COLLECTION, conditionId, _binaryPartition(), amount
        );
        _requireReceiptConsumed();
        if (collateral.allowance(address(this), address(CONDITIONAL_TOKENS)) != 0) {
            collateral.safeApprove(address(CONDITIONAL_TOKENS), 0);
        }
        if (
            collateral.balanceOf(address(this)) != collateralBefore
                || collateral.balanceOf(address(CONDITIONAL_TOKENS)) != ctfCollateralBefore + amount
        ) revert InvalidBalanceDelta();

        _wrapAndSend(yesPosition, amount, recipient);
        _wrapAndSend(noPosition, amount, recipient);
        if (
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId) != yesUnderlyingBefore
                || CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId)
                    != noUnderlyingBefore
        ) revert InvalidBalanceDelta();
    }

    function mergePositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (Position memory yesPosition, Position memory noPosition) =
            _positions(collateralToken, conditionId, yesToken, noToken);

        IERC20 collateral = IERC20(collateralToken);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 yesUnderlyingBefore =
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId);
        uint256 noUnderlyingBefore = CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId);

        _pullAndUnwrap(yesPosition, amount);
        _pullAndUnwrap(noPosition, amount);
        if (
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId)
                    != yesUnderlyingBefore + amount
                || CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId)
                    != noUnderlyingBefore + amount
        ) revert InvalidBalanceDelta();

        CONDITIONAL_TOKENS.mergePositions(
            collateralToken, ROOT_COLLECTION, conditionId, _binaryPartition(), amount
        );
        if (
            collateral.balanceOf(address(this)) != collateralBefore + amount
                || CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId)
                    != yesUnderlyingBefore
                || CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId)
                    != noUnderlyingBefore
        ) revert InvalidBalanceDelta();

        _transferExact(collateral, msg.sender, amount);
        if (collateral.balanceOf(address(this)) != collateralBefore) revert InvalidBalanceDelta();
    }

    function redeemPositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _validateCondition(collateralToken, conditionId, yesToken, noToken);
        uint256 winningIndexSet = _winningIndexSet(conditionId);
        uint256 outcomeIndex = winningIndexSet == 1 ? 0 : 1;
        Position memory winningPosition = _position(
            collateralToken, conditionId, outcomeIndex, outcomeIndex == 0 ? yesToken : noToken
        );
        uint256 preexisting = CONDITIONAL_TOKENS.balanceOf(address(this), winningPosition.tokenId);
        if (preexisting != 0) {
            CONDITIONAL_TOKENS.safeTransferFrom(
                address(this), DEAD, winningPosition.tokenId, preexisting, ""
            );
            if (CONDITIONAL_TOKENS.balanceOf(address(this), winningPosition.tokenId) != 0) {
                revert UnexpectedConditionalTokenBalance(winningPosition.tokenId);
            }
        }

        IERC20 collateral = IERC20(collateralToken);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        _pullAndUnwrap(winningPosition, amount);
        if (CONDITIONAL_TOKENS.balanceOf(address(this), winningPosition.tokenId) != amount) {
            revert InvalidBalanceDelta();
        }

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = winningIndexSet;
        CONDITIONAL_TOKENS.redeemPositions(collateralToken, ROOT_COLLECTION, conditionId, indexSets);
        if (
            collateral.balanceOf(address(this)) != collateralBefore + amount
                || CONDITIONAL_TOKENS.balanceOf(address(this), winningPosition.tokenId) != 0
        ) revert InvalidBalanceDelta();

        _transferExact(collateral, msg.sender, amount);
        if (collateral.balanceOf(address(this)) != collateralBefore) revert InvalidBalanceDelta();
    }

    function consumeLosingPositions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _validateCondition(collateralToken, conditionId, yesToken, noToken);
        uint256 losingIndexSet = _winningIndexSet(conditionId) == 1 ? 2 : 1;
        uint256 outcomeIndex = losingIndexSet == 1 ? 0 : 1;
        Position memory losingPosition = _position(
            collateralToken, conditionId, outcomeIndex, outcomeIndex == 0 ? yesToken : noToken
        );

        IERC20 collateral = IERC20(collateralToken);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 underlyingBefore =
            CONDITIONAL_TOKENS.balanceOf(address(this), losingPosition.tokenId);
        _pullAndUnwrap(losingPosition, amount);
        if (
            CONDITIONAL_TOKENS.balanceOf(address(this), losingPosition.tokenId)
                != underlyingBefore + amount
        ) revert InvalidBalanceDelta();

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = losingIndexSet;
        CONDITIONAL_TOKENS.redeemPositions(collateralToken, ROOT_COLLECTION, conditionId, indexSets);
        if (
            collateral.balanceOf(address(this)) != collateralBefore
                || CONDITIONAL_TOKENS.balanceOf(address(this), losingPosition.tokenId) != 0
        ) revert InvalidBalanceDelta();
    }

    function getPayouts(bytes32 conditionId)
        external
        view
        returns (uint256 denominator, uint256 yesNumerator, uint256 noNumerator)
    {
        if (CONDITIONAL_TOKENS.getOutcomeSlotCount(conditionId) != 2) {
            revert NonBinaryCondition();
        }
        denominator = CONDITIONAL_TOKENS.payoutDenominator(conditionId);
        yesNumerator = CONDITIONAL_TOKENS.payoutNumerators(conditionId, 0);
        noNumerator = CONDITIONAL_TOKENS.payoutNumerators(conditionId, 1);
    }

    function getWinningOutcomes(bytes32 conditionId) external view returns (bool[] memory winning) {
        uint256 outcomeCount = CONDITIONAL_TOKENS.getOutcomeSlotCount(conditionId);
        winning = new bool[](outcomeCount);
        for (uint256 i; i < outcomeCount; ++i) {
            winning[i] = CONDITIONAL_TOKENS.payoutNumerators(conditionId, i) != 0;
        }
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 tokenId,
        uint256 amount,
        bytes memory
    ) public override returns (bytes4) {
        if (
            _expectedReceiptHash != keccak256(abi.encode(SINGLE_RECEIPT_DOMAIN, tokenId, amount))
                || msg.sender != address(CONDITIONAL_TOKENS)
                || operator != address(WRAPPED_1155_FACTORY)
                || from != address(WRAPPED_1155_FACTORY)
        ) revert UnexpectedERC1155Receipt();
        _expectedReceiptHash = bytes32(0);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] memory tokenIds,
        uint256[] memory amounts,
        bytes memory
    ) public override returns (bytes4) {
        if (
            tokenIds.length != 2 || amounts.length != 2
                || _expectedReceiptHash
                    != keccak256(
                        abi.encode(
                            BATCH_RECEIPT_DOMAIN, tokenIds[0], tokenIds[1], amounts[0], amounts[1]
                        )
                    ) || msg.sender != address(CONDITIONAL_TOKENS) || operator != address(this)
                || from != address(0)
        ) revert UnexpectedERC1155Receipt();
        _expectedReceiptHash = bytes32(0);
        return this.onERC1155BatchReceived.selector;
    }

    function _positions(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken
    ) private view returns (Position memory yesPosition, Position memory noPosition) {
        _validateCondition(collateralToken, conditionId, yesToken, noToken);
        yesPosition = _position(collateralToken, conditionId, 0, yesToken);
        noPosition = _position(collateralToken, conditionId, 1, noToken);
    }

    function _position(
        address collateralToken,
        bytes32 conditionId,
        uint256 outcomeIndex,
        address wrapper
    ) private view returns (Position memory position) {
        uint256 indexSet = outcomeIndex == 0 ? 1 : 2;
        bytes32 collectionId =
            CONDITIONAL_TOKENS.getCollectionId(ROOT_COLLECTION, conditionId, indexSet);
        position.tokenId = CONDITIONAL_TOKENS.getPositionId(collateralToken, collectionId);
        position.data = _wrapperData(wrapper, position.tokenId);
        address expected = WRAPPED_1155_FACTORY.getWrapped1155(
            address(CONDITIONAL_TOKENS), position.tokenId, position.data
        );
        if (wrapper != expected || wrapper.code.length == 0) {
            revert InvalidWrapper(outcomeIndex, expected, wrapper);
        }
        position.wrapper = IERC20(wrapper);
    }

    function _validateCondition(
        address collateralToken,
        bytes32 conditionId,
        address yesToken,
        address noToken
    ) private view {
        if (collateralToken == address(0)) revert InvalidCollateral();
        if (conditionId == bytes32(0) || CONDITIONAL_TOKENS.getOutcomeSlotCount(conditionId) != 2) {
            revert NonBinaryCondition();
        }
        if (yesToken == address(0) || noToken == address(0) || yesToken == noToken) {
            revert InvalidWrapperMetadata(address(0));
        }
    }

    function _wrapperData(address wrapper, uint256 expectedTokenId)
        private
        view
        returns (bytes memory data)
    {
        if (wrapper.code.length == 0) revert InvalidWrapperMetadata(wrapper);
        ICanonicalWrapped1155 wrapped = ICanonicalWrapped1155(wrapper);

        address factory;
        address multiToken;
        uint256 tokenId;
        string memory name;
        string memory symbol;
        uint8 decimals;
        try wrapped.factory() returns (address value) {
            factory = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        try wrapped.multiToken() returns (address value) {
            multiToken = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        try wrapped.tokenId() returns (uint256 value) {
            tokenId = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        if (
            factory != address(WRAPPED_1155_FACTORY) || multiToken != address(CONDITIONAL_TOKENS)
                || tokenId != expectedTokenId
        ) revert InvalidWrapperMetadata(wrapper);

        try wrapped.name() returns (string memory value) {
            name = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        try wrapped.symbol() returns (string memory value) {
            symbol = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        try wrapped.decimals() returns (uint8 value) {
            decimals = value;
        } catch {
            revert InvalidWrapperMetadata(wrapper);
        }
        data = abi.encodePacked(_toString31(name, wrapper), _toString31(symbol, wrapper), decimals);
    }

    function _toString31(string memory value, address wrapper)
        private
        pure
        returns (bytes32 encodedString)
    {
        uint256 length = bytes(value).length;
        if (length >= 32) revert InvalidWrapperMetadata(wrapper);
        assembly {
            encodedString := mload(add(value, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - length) << 3));
        encodedString = (encodedString & mask) | bytes32(length << 1);
    }

    function _winningIndexSet(bytes32 conditionId) private view returns (uint256) {
        uint256 denominator = CONDITIONAL_TOKENS.payoutDenominator(conditionId);
        uint256 yesNumerator = CONDITIONAL_TOKENS.payoutNumerators(conditionId, 0);
        uint256 noNumerator = CONDITIONAL_TOKENS.payoutNumerators(conditionId, 1);
        if (
            denominator == 0 || (yesNumerator == 0) == (noNumerator == 0)
                || (yesNumerator != 0 && yesNumerator != denominator)
                || (noNumerator != 0 && noNumerator != denominator)
        ) revert InvalidWinningOutcome();
        return yesNumerator != 0 ? 1 : 2;
    }

    function _wrapAndSend(Position memory position, uint256 amount, address recipient) private {
        uint256 wrapperBefore = position.wrapper.balanceOf(address(this));
        uint256 recipientBefore = position.wrapper.balanceOf(recipient);
        CONDITIONAL_TOKENS.safeTransferFrom(
            address(this), address(WRAPPED_1155_FACTORY), position.tokenId, amount, position.data
        );
        if (position.wrapper.balanceOf(address(this)) != wrapperBefore + amount) {
            revert InvalidBalanceDelta();
        }
        position.wrapper.safeTransfer(recipient, amount);
        if (
            position.wrapper.balanceOf(address(this)) != wrapperBefore
                || position.wrapper.balanceOf(recipient) != recipientBefore + amount
        ) {
            revert InvalidBalanceDelta();
        }
    }

    function _pullAndUnwrap(Position memory position, uint256 amount) private {
        uint256 wrapperBefore = position.wrapper.balanceOf(address(this));
        _pullExact(position.wrapper, msg.sender, amount);
        _expectSingle(position.tokenId, amount);
        WRAPPED_1155_FACTORY.unwrap(
            address(CONDITIONAL_TOKENS), position.tokenId, amount, address(this), position.data
        );
        _requireReceiptConsumed();
        if (position.wrapper.balanceOf(address(this)) != wrapperBefore) {
            revert InvalidBalanceDelta();
        }
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) != beforeBalance + amount) {
            revert InvalidBalanceDelta();
        }
    }

    function _transferExact(IERC20 token, address recipient, uint256 amount) private {
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        if (token.balanceOf(recipient) != beforeBalance + amount) revert InvalidBalanceDelta();
    }

    function _expectBatch(uint256 tokenId0, uint256 tokenId1, uint256 amount) private {
        if (_expectedReceiptHash != bytes32(0)) revert UnexpectedERC1155Receipt();
        _expectedReceiptHash =
            keccak256(abi.encode(BATCH_RECEIPT_DOMAIN, tokenId0, tokenId1, amount, amount));
    }

    function _expectSingle(uint256 tokenId, uint256 amount) private {
        if (_expectedReceiptHash != bytes32(0)) revert UnexpectedERC1155Receipt();
        _expectedReceiptHash = keccak256(abi.encode(SINGLE_RECEIPT_DOMAIN, tokenId, amount));
    }

    function _requireReceiptConsumed() private view {
        if (_expectedReceiptHash != bytes32(0)) revert UnexpectedERC1155Receipt();
    }

    function _binaryPartition() private pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }
}
