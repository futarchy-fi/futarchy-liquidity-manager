// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockMintableERC20 is ERC20 {
    bool public approvalReverts;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function setApprovalReverts(bool value) external {
        approvalReverts = value;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        require(!approvalReverts, "approval failed");
        return super.approve(spender, amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
