// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../interfaces/IFutarchyConditionalDependencies.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";

interface IFutarchyRootProposal {
    function collateralToken1() external view returns (address);

    function collateralToken2() external view returns (address);

    function parentCollectionId() external view returns (bytes32);

    function conditionId() external view returns (bytes32);

    function wrappedOutcome(uint256 index)
        external
        view
        returns (address wrapped1155, bytes memory data);
}

/// @title FutarchyConditionalRouter
/// @notice Converts root binary futarchy collateral to and from Wrapped1155 outcome ERC20s.
/// @dev Deliberately excludes nested conditions. Every asset-changing path preserves pre-existing
/// router balances and verifies exact 1:1 deltas before returning assets to the caller.
contract FutarchyConditionalRouter is IFutarchyConditionalRouter, ERC1155Holder, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 private constant ROOT_COLLECTION = bytes32(0);

    IFutarchyConditionalTokens public immutable CONDITIONAL_TOKENS;
    IFutarchyWrapped1155Factory public immutable WRAPPED_1155_FACTORY;

    bool private _acceptingUnderlying;
    bool private _acceptingBatch;
    uint256 private _expectedTokenId0;
    uint256 private _expectedTokenId1;
    uint256 private _expectedAmount;

    struct Position {
        IERC20 wrapper;
        bytes data;
        uint256 tokenId;
    }

    error InvalidDependency();
    error ZeroAmount();
    error InvalidProposal();
    error NonRootProposal();
    error InvalidCollateral();
    error NonBinaryCondition();
    error InvalidWrapper(uint256 index, address expected, address actual);
    error InvalidBalanceDelta();
    error InvalidWinningOutcome();
    error UnexpectedConditionalTokenBalance(uint256 tokenId);
    error UnexpectedERC1155Receipt();

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

    function splitPosition(address proposal, address collateralToken, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        (IFutarchyRootProposal proposalLike, bytes32 conditionId, bool firstCollateral) =
            _validatedProposal(proposal, collateralToken);
        (Position memory yesPosition, Position memory noPosition) =
            _positions(proposalLike, collateralToken, conditionId, firstCollateral);

        IERC20 collateral = IERC20(collateralToken);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        uint256 yesUnderlyingBefore =
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId);
        uint256 noUnderlyingBefore = CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId);

        _pullExact(collateral, msg.sender, amount);
        _forceApprove(collateral, address(CONDITIONAL_TOKENS), amount);
        _expectBatch(yesPosition.tokenId, noPosition.tokenId, amount);
        CONDITIONAL_TOKENS.splitPosition(
            collateralToken, ROOT_COLLECTION, conditionId, _binaryPartition(), amount
        );
        _requireReceiptConsumed();
        _forceApprove(collateral, address(CONDITIONAL_TOKENS), 0);
        if (collateral.balanceOf(address(this)) != collateralBefore) revert InvalidBalanceDelta();

        _wrapAndSend(yesPosition, amount, msg.sender);
        _wrapAndSend(noPosition, amount, msg.sender);
        if (
            CONDITIONAL_TOKENS.balanceOf(address(this), yesPosition.tokenId) != yesUnderlyingBefore
                || CONDITIONAL_TOKENS.balanceOf(address(this), noPosition.tokenId)
                    != noUnderlyingBefore
        ) revert InvalidBalanceDelta();
    }

    function mergePositions(address proposal, address collateralToken, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        (IFutarchyRootProposal proposalLike, bytes32 conditionId, bool firstCollateral) =
            _validatedProposal(proposal, collateralToken);
        (Position memory yesPosition, Position memory noPosition) =
            _positions(proposalLike, collateralToken, conditionId, firstCollateral);

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

        collateral.safeTransfer(msg.sender, amount);
        if (collateral.balanceOf(address(this)) != collateralBefore) revert InvalidBalanceDelta();
    }

    function redeemPositions(address proposal, address collateralToken, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        (IFutarchyRootProposal proposalLike, bytes32 conditionId, bool firstCollateral) =
            _validatedProposal(proposal, collateralToken);
        uint256 winningIndexSet = _winningIndexSet(conditionId);
        uint256 outcomeIndex = winningIndexSet == 1 ? 0 : 1;
        Position memory winningPosition =
            _position(proposalLike, collateralToken, conditionId, firstCollateral, outcomeIndex);
        if (CONDITIONAL_TOKENS.balanceOf(address(this), winningPosition.tokenId) != 0) {
            revert UnexpectedConditionalTokenBalance(winningPosition.tokenId);
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

        collateral.safeTransfer(msg.sender, amount);
        if (collateral.balanceOf(address(this)) != collateralBefore) revert InvalidBalanceDelta();
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
            !_acceptingUnderlying || _acceptingBatch || msg.sender != address(CONDITIONAL_TOKENS)
                || operator != address(WRAPPED_1155_FACTORY)
                || from != address(WRAPPED_1155_FACTORY) || tokenId != _expectedTokenId0
                || amount != _expectedAmount
        ) revert UnexpectedERC1155Receipt();
        _acceptingUnderlying = false;
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
            !_acceptingUnderlying || !_acceptingBatch || msg.sender != address(CONDITIONAL_TOKENS)
                || operator != address(this) || from != address(0) || tokenIds.length != 2
                || amounts.length != 2 || tokenIds[0] != _expectedTokenId0
                || tokenIds[1] != _expectedTokenId1 || amounts[0] != _expectedAmount
                || amounts[1] != _expectedAmount
        ) revert UnexpectedERC1155Receipt();
        _acceptingUnderlying = false;
        return this.onERC1155BatchReceived.selector;
    }

    function _validatedProposal(address proposal, address collateralToken)
        private
        view
        returns (IFutarchyRootProposal proposalLike, bytes32 conditionId, bool firstCollateral)
    {
        if (proposal.code.length == 0) {
            revert InvalidProposal();
        }
        proposalLike = IFutarchyRootProposal(proposal);
        if (proposalLike.parentCollectionId() != ROOT_COLLECTION) revert NonRootProposal();

        address collateral1 = proposalLike.collateralToken1();
        address collateral2 = proposalLike.collateralToken2();
        if (collateral1 == address(0) || collateral2 == address(0) || collateral1 == collateral2) {
            revert InvalidProposal();
        }
        if (collateralToken == collateral1) {
            firstCollateral = true;
        } else if (collateralToken != collateral2) {
            revert InvalidCollateral();
        }

        conditionId = proposalLike.conditionId();
        if (conditionId == bytes32(0) || CONDITIONAL_TOKENS.getOutcomeSlotCount(conditionId) != 2) {
            revert NonBinaryCondition();
        }
    }

    function _positions(
        IFutarchyRootProposal proposal,
        address collateralToken,
        bytes32 conditionId,
        bool firstCollateral
    ) private view returns (Position memory yesPosition, Position memory noPosition) {
        yesPosition = _position(proposal, collateralToken, conditionId, firstCollateral, 0);
        noPosition = _position(proposal, collateralToken, conditionId, firstCollateral, 1);
    }

    function _position(
        IFutarchyRootProposal proposal,
        address collateralToken,
        bytes32 conditionId,
        bool firstCollateral,
        uint256 outcomeIndex
    ) private view returns (Position memory position) {
        uint256 proposalIndex = firstCollateral ? outcomeIndex : outcomeIndex + 2;
        address wrapper;
        (wrapper, position.data) = proposal.wrappedOutcome(proposalIndex);
        uint256 indexSet = outcomeIndex == 0 ? 1 : 2;
        bytes32 collectionId =
            CONDITIONAL_TOKENS.getCollectionId(ROOT_COLLECTION, conditionId, indexSet);
        position.tokenId = CONDITIONAL_TOKENS.getPositionId(collateralToken, collectionId);
        address expected = WRAPPED_1155_FACTORY.getWrapped1155(
            address(CONDITIONAL_TOKENS), position.tokenId, position.data
        );
        if (wrapper != expected || wrapper.code.length == 0) {
            revert InvalidWrapper(proposalIndex, expected, wrapper);
        }
        position.wrapper = IERC20(wrapper);
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
        CONDITIONAL_TOKENS.safeTransferFrom(
            address(this), address(WRAPPED_1155_FACTORY), position.tokenId, amount, position.data
        );
        if (position.wrapper.balanceOf(address(this)) != wrapperBefore + amount) {
            revert InvalidBalanceDelta();
        }
        position.wrapper.safeTransfer(recipient, amount);
        if (position.wrapper.balanceOf(address(this)) != wrapperBefore) {
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

    function _forceApprove(IERC20 token, address spender, uint256 amount) private {
        if (token.allowance(address(this), spender) != 0) token.safeApprove(spender, 0);
        token.safeApprove(spender, amount);
    }

    function _expectBatch(uint256 tokenId0, uint256 tokenId1, uint256 amount) private {
        if (_acceptingUnderlying) revert UnexpectedERC1155Receipt();
        _acceptingUnderlying = true;
        _acceptingBatch = true;
        _expectedTokenId0 = tokenId0;
        _expectedTokenId1 = tokenId1;
        _expectedAmount = amount;
    }

    function _expectSingle(uint256 tokenId, uint256 amount) private {
        if (_acceptingUnderlying) revert UnexpectedERC1155Receipt();
        _acceptingUnderlying = true;
        _acceptingBatch = false;
        _expectedTokenId0 = tokenId;
        _expectedAmount = amount;
    }

    function _requireReceiptConsumed() private view {
        if (_acceptingUnderlying) revert UnexpectedERC1155Receipt();
    }

    function _binaryPartition() private pure returns (uint256[] memory partition) {
        partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
    }
}
