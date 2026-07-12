// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockFutarchyRootProposal {
    address public collateralToken1;
    address public collateralToken2;
    bytes32 public parentCollectionId;
    bytes32 public conditionId;
    address[4] private _wrappers;
    bytes[4] private _wrapperData;

    constructor(address collateral1, address collateral2, bytes32 conditionId_) {
        collateralToken1 = collateral1;
        collateralToken2 = collateral2;
        conditionId = conditionId_;
    }

    function setParentCollectionId(bytes32 value) external {
        parentCollectionId = value;
    }

    function setCollateralToken2(address value) external {
        collateralToken2 = value;
    }

    function setWrappedOutcome(uint256 index, address wrapper, bytes calldata data) external {
        _wrappers[index] = wrapper;
        _wrapperData[index] = data;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        return (_wrappers[index], _wrapperData[index]);
    }
}
