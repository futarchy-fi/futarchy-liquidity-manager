// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAlgebraFactoryLike {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}
