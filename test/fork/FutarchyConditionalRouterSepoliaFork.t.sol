// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";
import {FutarchyConditionalRouter} from "../../src/routers/FutarchyConditionalRouter.sol";
import {MockFutarchyRootProposal} from "../mocks/MockFutarchyRootProposal.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";

interface ISepoliaConditionalTokens is IFutarchyConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

contract FutarchyConditionalRouterSepoliaForkTest is Test {
    uint256 private constant FORK_BLOCK = 11_254_684;
    address private constant CTF = 0x8bdC504dC3A05310059c1c67E0A2667309D27B93;
    address private constant W1155 = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    bytes32 private constant CTF_CODEHASH =
        0x962883a35da553c2d46562f362ba99f68041dad91de30a143a785b2d169c7e81;
    bytes32 private constant W1155_CODEHASH =
        0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6;

    function testFork_realCtfAndWrapped1155ConserveSplitMergeAndRedeem() public {
        if (!vm.envOr("RUN_SEPOLIA_FORK_TESTS", false)) return;
        string memory rpcUrl = vm.envOr("SEPOLIA_RPC_URL", string("https://sepolia.drpc.org"));
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(CTF.codehash, CTF_CODEHASH);
        assertEq(W1155.codehash, W1155_CODEHASH);

        ISepoliaConditionalTokens ctf = ISepoliaConditionalTokens(CTF);
        IFutarchyWrapped1155Factory wrappedFactory = IFutarchyWrapped1155Factory(W1155);
        FutarchyConditionalRouter router = new FutarchyConditionalRouter(ctf, wrappedFactory);
        MockMintableERC20 company = new MockMintableERC20("Company", "COMP");
        MockMintableERC20 collateral = new MockMintableERC20("Collateral", "COLL");

        bytes32 questionId = keccak256("flm-sepolia-router-fork");
        ctf.prepareCondition(address(this), questionId, 2);
        bytes32 conditionId = ctf.getConditionId(address(this), questionId, 2);
        MockFutarchyRootProposal proposal =
            new MockFutarchyRootProposal(address(company), address(collateral), conditionId);

        address[4] memory wrappers;
        bytes[4] memory wrapperData;
        for (uint256 i; i < 4; ++i) {
            address baseToken = i < 2 ? address(company) : address(collateral);
            uint256 indexSet = (i % 2) + 1;
            uint256 tokenId = _tokenId(ctf, baseToken, conditionId, indexSet);
            wrapperData[i] = abi.encodePacked(bytes32(i + 1), bytes32(i + 1), uint8(18));
            wrappers[i] = wrappedFactory.requireWrapped1155(CTF, tokenId, wrapperData[i]);
            assertEq(wrappedFactory.getWrapped1155(CTF, tokenId, wrapperData[i]), wrappers[i]);
            proposal.setWrappedOutcome(i, wrappers[i], wrapperData[i]);
        }

        uint256 amount = 10 ether;
        company.mint(address(this), 2 * amount);
        collateral.mint(address(this), 2 * amount);
        company.approve(address(router), type(uint256).max);
        collateral.approve(address(router), type(uint256).max);

        uint256 companyBefore = company.balanceOf(address(this));
        router.splitPosition(address(proposal), address(company), amount);
        assertEq(company.balanceOf(address(this)), companyBefore - amount);
        _assertWrapperReserve(ctf, wrappers[0], address(company), conditionId, 1, amount);
        _assertWrapperReserve(ctf, wrappers[1], address(company), conditionId, 2, amount);
        IERC20(wrappers[0]).approve(address(router), amount);
        IERC20(wrappers[1]).approve(address(router), amount);
        router.mergePositions(address(proposal), address(company), amount);
        assertEq(company.balanceOf(address(this)), companyBefore);
        _assertWrapperReserve(ctf, wrappers[0], address(company), conditionId, 1, 0);
        _assertWrapperReserve(ctf, wrappers[1], address(company), conditionId, 2, 0);

        router.splitPosition(address(proposal), address(collateral), amount);
        uint256 yesCollateralId = _tokenId(ctf, address(collateral), conditionId, 1);
        vm.expectRevert();
        wrappedFactory.unwrap(CTF, yesCollateralId, 1, address(router), wrapperData[2]);
        assertEq(IERC20(wrappers[2]).balanceOf(address(this)), amount);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        ctf.reportPayouts(questionId, payouts);
        IERC20(wrappers[2]).approve(address(router), 4 ether);
        uint256 collateralBefore = collateral.balanceOf(address(this));
        router.redeemPositions(address(proposal), address(collateral), 4 ether);
        assertEq(collateral.balanceOf(address(this)), collateralBefore + 4 ether);
        _assertWrapperReserve(
            ctf, wrappers[2], address(collateral), conditionId, 1, amount - 4 ether
        );
        _assertWrapperReserve(ctf, wrappers[3], address(collateral), conditionId, 2, amount);

        assertEq(company.balanceOf(address(router)), 0);
        assertEq(collateral.balanceOf(address(router)), 0);
        assertEq(ctf.balanceOf(address(router), yesCollateralId), 0);
    }

    function _assertWrapperReserve(
        ISepoliaConditionalTokens ctf,
        address wrapper,
        address baseToken,
        bytes32 conditionId,
        uint256 indexSet,
        uint256 expected
    ) private view {
        uint256 tokenId = _tokenId(ctf, baseToken, conditionId, indexSet);
        assertEq(IERC20(wrapper).totalSupply(), expected);
        assertEq(ctf.balanceOf(W1155, tokenId), expected);
    }

    function _tokenId(
        ISepoliaConditionalTokens ctf,
        address baseToken,
        bytes32 conditionId,
        uint256 indexSet
    ) private view returns (uint256) {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        return ctf.getPositionId(baseToken, collectionId);
    }
}
