// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFutarchyLiquidityManager {
    function initializeFromBootstrap(uint256 companyAmount, bytes calldata spotAddData)
        external
        payable
        returns (uint128 liquidityMinted);
}
