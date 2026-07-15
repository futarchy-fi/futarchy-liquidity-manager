// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";

contract MockWrappedOutcome is ERC20 {
    address public immutable factory;
    address public immutable multiToken;
    uint256 public immutable tokenId;
    uint8 private immutable _DECIMALS;

    constructor(
        address factory_,
        address multiToken_,
        uint256 tokenId_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        factory = factory_;
        multiToken = multiToken_;
        tokenId = tokenId_;
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == factory, "not factory");
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == factory, "not factory");
        _burn(account, amount);
    }
}

contract MockRouterWrapped1155Factory is ERC1155Holder, IFutarchyWrapped1155Factory {
    mapping(bytes32 key => address wrapper) private _wrappers;
    uint256 public mintShortfall;

    function setMintShortfall(uint256 amount) external {
        mintShortfall = amount;
    }

    function setWrapped1155(
        address multiToken,
        uint256 tokenId,
        bytes calldata data,
        address wrapper
    ) external {
        _wrappers[_key(multiToken, tokenId, data)] = wrapper;
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
            (string memory name, string memory symbol, uint8 decimals) = _decodeMetadata(data);
            wrapper = address(
                new MockWrappedOutcome(address(this), multiToken, tokenId, name, symbol, decimals)
            );
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

    function _decodeMetadata(bytes memory data)
        private
        pure
        returns (string memory name, string memory symbol, uint8 decimals)
    {
        require(data.length == 65, "invalid metadata");
        bytes32 encodedName;
        bytes32 encodedSymbol;
        assembly {
            encodedName := mload(add(data, 0x20))
            encodedSymbol := mload(add(data, 0x40))
        }
        name = _decodeShortString(encodedName);
        symbol = _decodeShortString(encodedSymbol);
        decimals = uint8(data[64]);
    }

    function _decodeShortString(bytes32 encoded) private pure returns (string memory value) {
        uint256 marker = uint8(uint256(encoded));
        require(marker & 1 == 0 && marker >> 1 < 32, "invalid short string");
        bytes memory decoded = new bytes(marker >> 1);
        for (uint256 i; i < decoded.length; ++i) {
            decoded[i] = encoded[i];
        }
        value = string(decoded);
    }
}
