// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IConditionalTokensCore, IRealityETHCore} from "../src/interfaces/IFutarchyTradingCore.sol";
import {DeadlineBoundedRealityProxy} from "../src/oracles/DeadlineBoundedRealityProxy.sol";
import {FutarchyConditionalRouter} from "../src/routers/FutarchyConditionalRouter.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockPoolStabilityGuard} from "./mocks/MockPoolStabilityGuard.sol";
import {MockRealityETH} from "./mocks/MockRealityETH.sol";
import {MockRouterConditionalTokens} from "./mocks/MockRouterConditionalTokens.sol";
import {MockRouterWrapped1155Factory} from "./mocks/MockRouterWrapped1155Factory.sol";

contract BindingLifecycleCoordinator {
    bool public reachedPostActivation;

    error PostActivationFailure();

    function setOfficial(
        FutarchyOfficialProposalSource source,
        uint256 proposalId,
        address proposal,
        address creator
    ) external {
        source.setOfficialProposal(proposalId, proposal, creator);
    }

    function setOfficialThenRevert(
        FutarchyOfficialProposalSource source,
        uint256 proposalId,
        address proposal,
        address creator
    ) external {
        source.setOfficialProposal(proposalId, proposal, creator);
        reachedPostActivation = true;
        revert PostActivationFailure();
    }
}

contract BindingConditionalTokens is MockRouterConditionalTokens {
    function getConditionId(address oracle, bytes32 questionId, uint256 slots)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, slots));
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payouts.length));
        uint256 denominator;
        for (uint256 i; i < payouts.length; ++i) {
            denominator += payouts[i];
        }
        uint256 yes = payouts.length > 0 ? payouts[0] : 0;
        uint256 no = payouts.length > 1 ? payouts[1] : 0;
        this.setPayout(conditionId, denominator, yes, no);
    }
}

contract AdapterBackedAlgebraFactory is IAlgebraFactoryLike {
    MockFutarchyLiquidityAdapter public adapter;

    function setAdapter(MockFutarchyLiquidityAdapter value) external {
        adapter = value;
    }

    function poolByPair(address tokenA, address tokenB) external view returns (address) {
        if (address(adapter) == address(0)) return address(0);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return adapter.freshPoolByPair(keccak256(abi.encode(token0, token1)));
    }
}

/// @dev The source sees policy-approved metadata while every other caller sees another proposal.
contract CallerDependentProposal {
    address public immutable source;
    address public immutable collateralToken1;
    address public immutable collateralToken2;
    bytes32 public immutable sourceQuestion;
    bytes32 public immutable executionQuestion;
    bytes32 public immutable sourceCondition;
    bytes32 public immutable executionCondition;
    address[4] private _sourceWrappers;
    address[4] private _executionWrappers;

    constructor(
        address source_,
        address collateral1_,
        address collateral2_,
        bytes32 sourceQuestion_,
        bytes32 executionQuestion_,
        bytes32 sourceCondition_,
        bytes32 executionCondition_,
        address[4] memory sourceWrappers_,
        address[4] memory executionWrappers_
    ) {
        source = source_;
        collateralToken1 = collateral1_;
        collateralToken2 = collateral2_;
        sourceQuestion = sourceQuestion_;
        executionQuestion = executionQuestion_;
        sourceCondition = sourceCondition_;
        executionCondition = executionCondition_;
        _sourceWrappers = sourceWrappers_;
        _executionWrappers = executionWrappers_;
    }

    function parentCollectionId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function conditionId() external view returns (bytes32) {
        return msg.sender == source ? sourceCondition : executionCondition;
    }

    function questionId() external view returns (bytes32) {
        return msg.sender == source ? sourceQuestion : executionQuestion;
    }

    function wrappedOutcome(uint256 index) external view returns (address, bytes memory) {
        address wrapper = msg.sender == source ? _sourceWrappers[index] : _executionWrappers[index];
        return (wrapper, "");
    }
}

contract FutarchyProposalBindingTest is Test {
    uint256 private constant AMOUNT = 100 ether;

    function test_atomic_activation_uses_captured_source_snapshot() public {
        BindingLifecycleCoordinator coordinator = new BindingLifecycleCoordinator();
        BindingConditionalTokens ctf = new BindingConditionalTokens();
        MockRouterWrapped1155Factory wrapperFactory = new MockRouterWrapped1155Factory();
        FutarchyConditionalRouter router = new FutarchyConditionalRouter(ctf, wrapperFactory);
        AdapterBackedAlgebraFactory poolFactory = new AdapterBackedAlgebraFactory();
        MockMintableERC20 company = new MockMintableERC20("Company", "COMP");
        MockMintableERC20 collateral = new MockMintableERC20("Collateral", "COLL");
        bytes32 sourceQuestion = keccak256("policy-approved question");
        (FutarchyOfficialProposalSource source, bytes32 sourceCondition) =
            _source(coordinator, ctf, poolFactory, company, collateral, sourceQuestion);
        bytes32 executionQuestion = keccak256("caller-dependent question");
        bytes32 executionCondition = ctf.getConditionId(address(0xBAD), executionQuestion, 2);
        ctf.setOutcomeSlotCount(executionCondition, 2);

        address[4] memory sourceWrappers;
        sourceWrappers[0] = _wrapper(ctf, wrapperFactory, address(company), sourceCondition, 1);
        sourceWrappers[1] = _wrapper(ctf, wrapperFactory, address(company), sourceCondition, 2);
        sourceWrappers[2] = _wrapper(ctf, wrapperFactory, address(collateral), sourceCondition, 1);
        sourceWrappers[3] = _wrapper(ctf, wrapperFactory, address(collateral), sourceCondition, 2);
        address[4] memory executionWrappers;
        executionWrappers[0] =
            _wrapper(ctf, wrapperFactory, address(company), executionCondition, 1);
        executionWrappers[1] =
            _wrapper(ctf, wrapperFactory, address(company), executionCondition, 2);
        executionWrappers[2] =
            _wrapper(ctf, wrapperFactory, address(collateral), executionCondition, 1);
        executionWrappers[3] =
            _wrapper(ctf, wrapperFactory, address(collateral), executionCondition, 2);
        CallerDependentProposal proposal = new CallerDependentProposal(
            address(source),
            address(company),
            address(collateral),
            sourceQuestion,
            executionQuestion,
            sourceCondition,
            executionCondition,
            sourceWrappers,
            executionWrappers
        );

        MockFutarchyLiquidityAdapter spot = new MockFutarchyLiquidityAdapter();
        MockFutarchyLiquidityAdapter conditional = new MockFutarchyLiquidityAdapter();
        poolFactory.setAdapter(conditional);
        FutarchyLiquidityManager manager = new FutarchyLiquidityManager(
            address(this),
            company,
            IWrappedNative(address(collateral)),
            source,
            spot,
            conditional,
            router,
            new MockPoolStabilityGuard(),
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata({name: "FLM", symbol: "FLM"})
        );
        source.bindActivationTarget(address(manager));
        company.mint(address(this), AMOUNT);
        collateral.mint(address(this), AMOUNT);
        company.approve(address(manager), AMOUNT);
        collateral.approve(address(manager), AMOUNT);
        manager.initializeFromBootstrap(AMOUNT, AMOUNT);

        ctf.setSplitShortfallCollateral(address(collateral));
        vm.expectRevert();
        coordinator.setOfficial(source, 1, address(proposal), address(this));
        ctf.setSplitShortfallCollateral(address(0));

        assertFalse(source.currentOfficialProposal().exists);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), AMOUNT);
        assertEq(spot.removeDetailedCalls(), 0);
        assertEq(conditional.addFreshCalls(), 0);
        assertEq(company.balanceOf(address(ctf)), 0);
        for (uint256 i; i < sourceWrappers.length; ++i) {
            assertEq(IERC20(sourceWrappers[i]).balanceOf(address(conditional)), 0);
        }

        vm.expectRevert(BindingLifecycleCoordinator.PostActivationFailure.selector);
        coordinator.setOfficialThenRevert(source, 1, address(proposal), address(this));

        assertFalse(coordinator.reachedPostActivation());
        assertFalse(source.currentOfficialProposal().exists);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), AMOUNT);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(spot.removeDetailedCalls(), 0);
        assertEq(conditional.addFreshCalls(), 0);
        assertEq(poolFactory.poolByPair(sourceWrappers[0], sourceWrappers[2]), address(0));
        assertEq(poolFactory.poolByPair(sourceWrappers[1], sourceWrappers[3]), address(0));

        coordinator.setOfficial(source, 1, address(proposal), address(this));

        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeConditionId(), sourceCondition);
        assertTrue(manager.activeConditionId() != executionCondition);
        assertEq(manager.activeYesCompanyToken(), sourceWrappers[0]);
        assertEq(manager.activeNoCompanyToken(), sourceWrappers[1]);
        assertEq(manager.activeYesCurrencyToken(), sourceWrappers[2]);
        assertEq(manager.activeNoCurrencyToken(), sourceWrappers[3]);

        source.clearOfficialProposal();
        ctf.setPayout(sourceCondition, 1, 1, 0);
        FutarchyLiquidityManager.SyncAction action = manager.sync();
        assertEq(uint256(action), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot));
        assertFalse(manager.inConditionalMode());
        assertEq(company.balanceOf(address(manager)), 80 ether);
        assertEq(collateral.balanceOf(address(manager)), 80 ether);
    }

    function _source(
        BindingLifecycleCoordinator coordinator,
        BindingConditionalTokens ctf,
        AdapterBackedAlgebraFactory poolFactory,
        MockMintableERC20 company,
        MockMintableERC20 collateral,
        bytes32 question
    ) private returns (FutarchyOfficialProposalSource source, bytes32 condition) {
        MockRealityETH reality = new MockRealityETH();
        address oracle = address(
            new DeadlineBoundedRealityProxy(
                IConditionalTokensCore(address(ctf)), IRealityETHCore(address(reality)), 1 days
            )
        );
        condition = ctf.getConditionId(oracle, question, 2);
        ctf.setOutcomeSlotCount(condition, 2);
        reality.setQuestion(
            question,
            bytes32(uint256(1)),
            address(0xA11B),
            uint32(block.timestamp + 1 hours),
            uint32(1 days),
            1 ether
        );
        FutarchyOfficialProposalSource.ProposalValidationConfig memory validation =
            FutarchyOfficialProposalSource.ProposalValidationConfig({
                enabled: true,
                expectedProposalToken: address(company),
                expectedCollateralToken: address(collateral),
                conditionalTokens: address(ctf),
                trustedOracle: oracle,
                realitio: address(reality),
                trustedArbitrator: address(0xA11B),
                maxOpeningDelay: uint32(1 days),
                minTimeout: uint32(1 hours),
                maxTimeout: uint32(2 days),
                minConditionalLifetime: uint32(1 days),
                maxMinBond: 2 ether
            });
        source = new FutarchyOfficialProposalSource(
            address(this), address(coordinator), address(this), poolFactory, abi.encode(validation)
        );
    }

    function _wrapper(
        BindingConditionalTokens ctf,
        MockRouterWrapped1155Factory wrapperFactory,
        address collateral,
        bytes32 conditionId,
        uint256 indexSet
    ) private returns (address) {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = ctf.getPositionId(collateral, collectionId);
        bytes memory data =
            abi.encodePacked(_toString31("OUTCOME"), _toString31("OUTCOME"), uint8(18));
        return wrapperFactory.requireWrapped1155(address(ctf), tokenId, data);
    }

    function _toString31(string memory value) private pure returns (bytes32 encodedString) {
        uint256 length = bytes(value).length;
        assembly ("memory-safe") {
            encodedString := mload(add(value, 0x20))
        }
        bytes32 mask = bytes32(type(uint256).max << ((32 - length) << 3));
        encodedString = (encodedString & mask) | bytes32(length << 1);
    }
}
