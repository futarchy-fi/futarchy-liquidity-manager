// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";

contract MockWrappedOutcome is ERC20 {
    address private immutable _FACTORY;

    constructor(address factory_) ERC20("Wrapped outcome", "OUT") {
        _FACTORY = factory_;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == _FACTORY, "not factory");
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == _FACTORY, "not factory");
        _burn(account, amount);
    }
}

contract MockRouterWrapped1155Factory is ERC1155Holder, IFutarchyWrapped1155Factory {
    mapping(bytes32 key => address wrapper) private _wrappers;
    uint256 public mintShortfall;

    function setMintShortfall(uint256 amount) external {
        mintShortfall = amount;
    }

    function getWrapped1155(address multiToken, uint256 tokenId, bytes calldata data)
        external
        view
        returns (address)
    {
        return _wrappers[_key(multiToken, tokenId, data)];
    }

    function requireWrapped1155(address multiToken, uint256 tokenId, bytes memory data)
        public
        returns (address wrapper)
    {
        bytes32 key = _key(multiToken, tokenId, data);
        wrapper = _wrappers[key];
        if (wrapper == address(0)) {
            wrapper = address(new MockWrappedOutcome(address(this)));
            _wrappers[key] = wrapper;
        }
    }

    function unwrap(
        address multiToken,
        uint256 tokenId,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external {
        MockWrappedOutcome(requireWrapped1155(multiToken, tokenId, data)).burn(msg.sender, amount);
        IFutarchyConditionalTokens(multiToken)
            .safeTransferFrom(address(this), recipient, tokenId, amount, data);
    }

    function onERC1155Received(
        address operator,
        address,
        uint256 tokenId,
        uint256 value,
        bytes memory data
    ) public override returns (bytes4) {
        uint256 amount = value - mintShortfall;
        MockWrappedOutcome(requireWrapped1155(msg.sender, tokenId, data)).mint(operator, amount);
        return this.onERC1155Received.selector;
    }

    function _key(address multiToken, uint256 tokenId, bytes memory data)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(multiToken, tokenId, keccak256(data)));
    }
}
