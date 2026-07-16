// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IConditionalTokensCore, IRealityETHCore} from "../src/interfaces/IFutarchyTradingCore.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
import {DeadlineBoundedRealityProxy} from "../src/oracles/DeadlineBoundedRealityProxy.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockProposalSettlementOracle} from "./mocks/MockProposalSettlementOracle.sol";
import {MockRealityETH} from "./mocks/MockRealityETH.sol";

contract MockLifecycleCoordinator {
    function setOfficialProposal(
        FutarchyOfficialProposalSource source,
        uint256 proposalId,
        address proposal,
        address creator
    ) external {
        source.setOfficialProposal(proposalId, proposal, creator);
    }
}

contract MockConditionalRouterBinding {
    address public immutable CONDITIONAL_TOKENS;

    constructor(address conditionalTokens) {
        CONDITIONAL_TOKENS = conditionalTokens;
    }
}

contract MockOfficialProposalActivationTarget {
    FutarchyOfficialProposalSource public immutable SOURCE;
    MockLifecycleCoordinator public immutable COORDINATOR;
    address public immutable PROPOSAL_SOURCE;
    address public immutable COMPANY_TOKEN;
    address public immutable WRAPPED_NATIVE;
    address public immutable CONDITIONAL_ROUTER;

    bool public canActivate = true;
    bool public revertActivation;
    bool public reenterActivation;
    uint8 public corruptField;
    bool public reentryBlocked;
    bool public observedStoredProposal;
    uint256 public activationCalls;
    uint256 public lastProposalId;
    address public lastProposal;
    IFutarchyOfficialProposalSource.ProposalActivationData private _captured;

    error MockActivationReverted();
    error OnlySource();

    constructor(
        FutarchyOfficialProposalSource source,
        MockLifecycleCoordinator coordinator,
        address companyToken,
        address wrappedNative,
        address conditionalRouter
    ) {
        SOURCE = source;
        COORDINATOR = coordinator;
        PROPOSAL_SOURCE = address(source);
        COMPANY_TOKEN = companyToken;
        WRAPPED_NATIVE = wrappedNative;
        CONDITIONAL_ROUTER = conditionalRouter;
    }

    function canActivateOfficialProposal() external view returns (bool) {
        return canActivate;
    }

    function setCanActivate(bool value) external {
        canActivate = value;
    }

    function setRevertActivation(bool value) external {
        revertActivation = value;
    }

    function setReenterActivation(bool value) external {
        reenterActivation = value;
    }

    function setCorruptField(uint8 value) external {
        corruptField = value;
    }

    function activateOfficialProposal(
        IFutarchyOfficialProposalSource.ProposalActivationData calldata proposal
    ) external {
        if (msg.sender != address(SOURCE)) revert OnlySource();

        FutarchyOfficialProposalSource.OfficialProposal memory stored =
            SOURCE.currentOfficialProposal();
        observedStoredProposal = stored.exists && stored.id == proposal.proposalId
            && stored.proposal == proposal.proposal;

        if (revertActivation) revert MockActivationReverted();

        _captured = proposal;
        if (corruptField == 1) {
            _captured.proposalId ^= 1;
        } else if (corruptField == 2) {
            _captured.proposal = address(uint160(proposal.proposal) ^ 1);
        } else if (corruptField == 3) {
            _captured.conditionId ^= bytes32(uint256(1));
        } else if (corruptField == 4) {
            _captured.proposalToken = address(uint160(proposal.proposalToken) ^ 1);
        } else if (corruptField == 5) {
            _captured.collateralToken = address(uint160(proposal.collateralToken) ^ 1);
        } else if (corruptField == 6) {
            _captured.yesCompanyToken = address(uint160(proposal.yesCompanyToken) ^ 1);
        } else if (corruptField == 7) {
            _captured.noCompanyToken = address(uint160(proposal.noCompanyToken) ^ 1);
        } else if (corruptField == 8) {
            _captured.yesCurrencyToken = address(uint160(proposal.yesCurrencyToken) ^ 1);
        } else if (corruptField == 9) {
            _captured.noCurrencyToken = address(uint160(proposal.noCurrencyToken) ^ 1);
        }

        if (reenterActivation) {
            try COORDINATOR.setOfficialProposal(
                SOURCE, proposal.proposalId + 1, proposal.proposal, address(0xC0FFEE)
            ) {}
            catch (bytes memory reason) {
                reentryBlocked = _selector(reason)
                    == FutarchyOfficialProposalSource.ReentrantOfficialProposal.selector;
            }
        }

        activationCalls++;
        lastProposalId = proposal.proposalId;
        lastProposal = proposal.proposal;
    }

    function capturedOfficialProposal()
        external
        view
        returns (IFutarchyOfficialProposalSource.ProposalActivationData memory proposal)
    {
        return _captured;
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}

contract MockSourceOnlyActivationTarget {
    address public immutable PROPOSAL_SOURCE;

    constructor(address proposalSource) {
        PROPOSAL_SOURCE = proposalSource;
    }
}

contract FutarchyOfficialProposalSourceTest is Test {
    FutarchyOfficialProposalSource internal source;
    MockLifecycleCoordinator internal coordinator;
    MockOfficialProposalActivationTarget internal activationTarget;
    MockAlgebraFactoryLike internal factory;
    MockProposalSettlementOracle internal oracle;
    MockConditionalTokens internal conditionalTokens;
    MockRealityETH internal realitio;
    DeadlineBoundedRealityProxy internal realityProxy;
    MockConditionalRouterBinding internal conditionalRouter;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);
    address internal newProposalManager = address(0x70);
    address internal officialProposer = address(0x1111);
    address internal trustedOracle;
    address internal trustedArbitrator = address(0xA11B);

    address internal company = address(0xA001);
    address internal wxdai = address(0xA002);
    address internal yesComp = address(0xA101);
    address internal noComp = address(0xA102);
    address internal yesCurr = address(0xA103);
    address internal noCurr = address(0xA104);
    address internal yesPool = address(0xB101);
    address internal noPool = address(0xB102);
    bytes32 internal constant CONTENT_HASH = bytes32(uint256(1));

    function setUp() public {
        vm.warp(1_000_000);
        factory = new MockAlgebraFactoryLike();
        coordinator = new MockLifecycleCoordinator();
        conditionalTokens = new MockConditionalTokens();
        realitio = new MockRealityETH();
        realityProxy = new DeadlineBoundedRealityProxy(
            IConditionalTokensCore(address(conditionalTokens)),
            IRealityETHCore(address(realitio)),
            3 days
        );
        trustedOracle = address(realityProxy);
        conditionalRouter = new MockConditionalRouterBinding(address(conditionalTokens));
        _configureAndBind(_nonRealityValidationConfig());
        oracle = new MockProposalSettlementOracle();
    }

    function test_set_and_read_official_proposal() public {
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);

        MockFutarchyProposalLike proposal = _proposal();

        _setOfficialProposal(1, address(proposal), officialProposer);

        (
            uint256 proposalId,
            address creator,
            bool exists,
            bool settled,
            address proposalToken,
            address collateralToken,
            address yesPoolOut,
            address noPoolOut
        ) = source.officialProposal();

        assertEq(proposalId, 1);
        assertEq(creator, officialProposer);
        assertTrue(exists);
        assertFalse(settled);
        assertEq(proposalToken, company);
        assertEq(collateralToken, wxdai);
        assertEq(yesPoolOut, yesPool);
        assertEq(noPoolOut, noPool);

        IFutarchyOfficialProposalSource.OfficialProposalData memory extended =
            source.officialProposalExtended();
        assertEq(extended.proposalId, 1);
        assertEq(extended.proposal, address(proposal));
        assertEq(extended.yesCompanyToken, yesComp);
        assertEq(extended.noCompanyToken, noComp);
        assertEq(extended.yesCurrencyToken, yesCurr);
        assertEq(extended.noCurrencyToken, noCurr);
        assertTrue(activationTarget.observedStoredProposal());
        assertEq(activationTarget.activationCalls(), 1);
        assertEq(activationTarget.lastProposalId(), 1);
        assertEq(activationTarget.lastProposal(), address(proposal));
    }

    function test_official_view_uses_capture_even_after_proposal_mutates() public {
        bytes32 capturedQuestion = bytes32(uint256(1));
        bytes32 capturedCondition =
            conditionalTokens.getConditionId(trustedOracle, capturedQuestion, 2);
        MockFutarchyProposalLike proposal = _proposal();
        conditionalTokens.setOutcomeSlotCount(capturedCondition, 2);
        proposal.setQuestionAndCondition(capturedQuestion, capturedCondition);
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);

        _setOfficialProposal(1, address(proposal), officialProposer);

        proposal.setCollateralTokens(address(0xBAD1), address(0xBAD2));
        proposal.setQuestionAndCondition(bytes32(uint256(2)), bytes32(uint256(0xBAD)));
        proposal.setWrappedOutcome(0, address(0xBAD3));
        proposal.setWrappedOutcome(1, address(0xBAD4));
        proposal.setWrappedOutcome(2, address(0xBAD5));
        proposal.setWrappedOutcome(3, address(0xBAD6));

        IFutarchyOfficialProposalSource.OfficialProposalData memory captured =
            source.officialProposalExtended();
        assertEq(captured.conditionId, capturedCondition);
        assertEq(captured.proposalToken, company);
        assertEq(captured.collateralToken, wxdai);
        assertEq(captured.yesCompanyToken, yesComp);
        assertEq(captured.noCompanyToken, noComp);
        assertEq(captured.yesCurrencyToken, yesCurr);
        assertEq(captured.noCurrencyToken, noCurr);
        assertEq(captured.yesPool, yesPool);
        assertEq(captured.noPool, noPool);
    }

    function test_constructor_rejects_eoa_lifecycle_coordinator() public {
        vm.expectRevert(FutarchyOfficialProposalSource.InvalidLifecycleCoordinator.selector);
        new FutarchyOfficialProposalSource(
            owner, address(0x69), officialProposer, IAlgebraFactoryLike(address(factory)), ""
        );
    }

    function test_binding_is_one_shot_and_checks_reciprocal_target() public {
        FutarchyOfficialProposalSource unbound = _newUnboundSource();
        MockOfficialProposalActivationTarget goodTarget =
            _newActivationTarget(unbound, company, wxdai, address(conditionalRouter));

        vm.prank(nonOwner);
        vm.expectRevert(FutarchyOfficialProposalSource.OnlyBindingAuthority.selector);
        unbound.bindActivationTarget(address(goodTarget));

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidActivationTarget.selector);
        unbound.bindActivationTarget(address(0));

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidActivationTarget.selector);
        unbound.bindActivationTarget(address(0x1234));

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidActivationTarget.selector);
        unbound.bindActivationTarget(address(activationTarget));

        MockSourceOnlyActivationTarget missingReadiness =
            new MockSourceOnlyActivationTarget(address(unbound));
        vm.expectRevert(FutarchyOfficialProposalSource.InvalidActivationTarget.selector);
        unbound.bindActivationTarget(address(missingReadiness));

        goodTarget.setCanActivate(false);
        unbound.bindActivationTarget(address(goodTarget));
        assertEq(unbound.activationTarget(), address(goodTarget));
        assertTrue(unbound.proposalValidationConfigFrozen());

        vm.expectRevert(FutarchyOfficialProposalSource.ActivationTargetAlreadyBound.selector);
        unbound.bindActivationTarget(address(goodTarget));
    }

    function test_binding_rejects_disabled_validation() public {
        FutarchyOfficialProposalSource unbound = _newSource("");
        MockOfficialProposalActivationTarget target =
            _newActivationTarget(unbound, company, wxdai, address(conditionalRouter));

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalValidationConfig.selector);
        unbound.bindActivationTarget(address(target));
        assertFalse(unbound.proposalValidationConfigFrozen());
    }

    function test_binding_rejects_mismatched_base_tokens_or_router_ctf() public {
        FutarchyOfficialProposalSource wrongBaseSource = _newUnboundSource();
        MockOfficialProposalActivationTarget wrongBaseTarget = _newActivationTarget(
            wrongBaseSource, address(0xBAD), wxdai, address(conditionalRouter)
        );
        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalValidationConfig.selector);
        wrongBaseSource.bindActivationTarget(address(wrongBaseTarget));

        FutarchyOfficialProposalSource wrongCtfSource = _newUnboundSource();
        MockConditionalRouterBinding wrongRouter =
            new MockConditionalRouterBinding(address(new MockConditionalTokens()));
        MockOfficialProposalActivationTarget wrongCtfTarget =
            _newActivationTarget(wrongCtfSource, company, wxdai, address(wrongRouter));
        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalValidationConfig.selector);
        wrongCtfSource.bindActivationTarget(address(wrongCtfTarget));
    }

    function test_binding_rejects_strict_oracle_mismatch() public {
        MockConditionalTokens otherConditionalTokens = new MockConditionalTokens();
        DeadlineBoundedRealityProxy wrongCtfOracle = new DeadlineBoundedRealityProxy(
            IConditionalTokensCore(address(otherConditionalTokens)),
            IRealityETHCore(address(realitio)),
            3 days
        );
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config =
            _validationConfig(true);
        config.trustedOracle = address(wrongCtfOracle);
        _expectPolicyBindingFailure(config);

        MockRealityETH otherReality = new MockRealityETH();
        DeadlineBoundedRealityProxy wrongRealityOracle = new DeadlineBoundedRealityProxy(
            IConditionalTokensCore(address(conditionalTokens)),
            IRealityETHCore(address(otherReality)),
            3 days
        );
        config.trustedOracle = address(wrongRealityOracle);
        _expectPolicyBindingFailure(config);
    }

    function test_binding_rejects_deadline_shorter_than_conditional_lifetime() public {
        DeadlineBoundedRealityProxy shortDeadlineOracle = new DeadlineBoundedRealityProxy(
            IConditionalTokensCore(address(conditionalTokens)),
            IRealityETHCore(address(realitio)),
            12 hours
        );
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config =
            _validationConfig(true);
        config.trustedOracle = address(shortDeadlineOracle);

        _expectPolicyBindingFailure(config);
    }

    function test_binding_freezes_valid_policy() public {
        assertTrue(source.proposalValidationConfigFrozen());

        vm.expectRevert(FutarchyOfficialProposalSource.ProposalValidationConfigFrozen.selector);
        source.setProposalValidationConfig(_nonRealityValidationConfig());
    }

    function test_official_setter_requires_immutable_lifecycle_coordinator() public {
        MockFutarchyProposalLike proposal = _proposal();

        vm.expectRevert(FutarchyOfficialProposalSource.OnlyLifecycleCoordinator.selector);
        source.setOfficialProposal(1, address(proposal), officialProposer);

        vm.prank(nonOwner);
        vm.expectRevert(FutarchyOfficialProposalSource.OnlyLifecycleCoordinator.selector);
        source.setOfficialProposal(1, address(proposal), officialProposer);

        source.setProposalManager(newProposalManager);
        vm.prank(newProposalManager);
        vm.expectRevert(FutarchyOfficialProposalSource.OnlyLifecycleCoordinator.selector);
        source.setOfficialProposal(1, address(proposal), officialProposer);

        _setOfficialProposal(1, address(proposal), officialProposer);
        assertEq(source.LIFECYCLE_COORDINATOR(), address(coordinator));
    }

    function test_official_setter_rejects_creator_other_than_official_proposer() public {
        MockFutarchyProposalLike proposal = _proposal();

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidOfficialProposer.selector);
        _setOfficialProposal(1, address(proposal), address(0xBAD));

        assertFalse(source.currentOfficialProposal().exists);
        assertEq(activationTarget.activationCalls(), 0);
    }

    function test_official_setter_rejects_unrepresentable_proposal_id_atomically() public {
        MockFutarchyProposalLike proposal = _proposal();

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalId.selector);
        _setOfficialProposal(uint256(type(uint96).max) + 1, address(proposal), officialProposer);

        assertFalse(source.currentOfficialProposal().exists);
        assertEq(activationTarget.activationCalls(), 0);
    }

    function test_official_setter_reverts_while_target_is_unbound() public {
        FutarchyOfficialProposalSource unbound = _newUnboundSource();
        MockFutarchyProposalLike proposal = _proposal();

        vm.expectRevert(FutarchyOfficialProposalSource.ActivationTargetUnbound.selector);
        coordinator.setOfficialProposal(unbound, 1, address(proposal), officialProposer);
    }

    function test_activation_revert_rolls_back_source_write() public {
        MockFutarchyProposalLike p1 = _proposal();
        MockFutarchyProposalLike p2 = _proposal();
        _setOfficialProposal(1, address(p1), officialProposer);

        activationTarget.setRevertActivation(true);
        vm.expectRevert(MockOfficialProposalActivationTarget.MockActivationReverted.selector);
        _setOfficialProposal(2, address(p2), officialProposer);

        FutarchyOfficialProposalSource.OfficialProposal memory stored =
            source.currentOfficialProposal();
        assertEq(stored.id, 1);
        assertEq(stored.proposal, address(p1));
        assertEq(activationTarget.activationCalls(), 1);
    }

    function test_each_corrupt_capture_field_rolls_back_source_write_and_target_state() public {
        MockFutarchyProposalLike proposal = _proposal();

        for (uint8 field = 1; field <= 9; field++) {
            activationTarget.setCorruptField(field);
            vm.expectRevert(FutarchyOfficialProposalSource.CapturedProposalMismatch.selector);
            _setOfficialProposal(1, address(proposal), officialProposer);

            assertFalse(source.currentOfficialProposal().exists);
            assertEq(activationTarget.activationCalls(), 0);
            assertEq(activationTarget.lastProposal(), address(0));
            assertEq(activationTarget.capturedOfficialProposal().proposal, address(0));
        }
    }

    function test_reentrant_activation_is_blocked() public {
        MockFutarchyProposalLike proposal = _proposal();
        activationTarget.setReenterActivation(true);

        _setOfficialProposal(1, address(proposal), officialProposer);

        assertTrue(activationTarget.reentryBlocked());
        assertEq(activationTarget.activationCalls(), 1);
    }

    function test_settled_with_manual_flag() public {
        MockFutarchyProposalLike proposal = _proposal();
        _setOfficialProposal(7, address(proposal), officialProposer);

        source.setManualSettled(true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_settled_with_oracle_override() public {
        MockFutarchyProposalLike proposal = _proposal();
        _setOfficialProposal(9, address(proposal), officialProposer);
        source.setSettlementOracle(address(oracle));
        oracle.setSettled(address(proposal), true);

        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_target_readiness_controls_later_proposal_admission() public {
        MockFutarchyProposalLike p1 = _proposal();
        MockFutarchyProposalLike p2 = _proposal();
        _setOfficialProposal(1, address(p1), officialProposer);
        activationTarget.setCanActivate(false);

        vm.expectRevert(FutarchyOfficialProposalSource.ActivationUnavailable.selector);
        _setOfficialProposal(2, address(p2), officialProposer);

        assertEq(source.currentOfficialProposal().proposal, address(p1));
    }

    function test_activation_captures_validated_snapshot() public {
        (MockFutarchyProposalLike proposal,, bytes32 conditionId) = _validProposal(true, false);
        _setOfficialProposal(10, address(proposal), officialProposer);

        IFutarchyOfficialProposalSource.ProposalActivationData memory captured =
            activationTarget.capturedOfficialProposal();
        assertEq(captured.proposalId, 10);
        assertEq(captured.proposal, address(proposal));
        assertEq(captured.conditionId, conditionId);
        assertEq(captured.yesCompanyToken, yesComp);
        assertEq(captured.noCompanyToken, noComp);
        assertEq(captured.yesCurrencyToken, yesCurr);
        assertEq(captured.noCurrencyToken, noCurr);
    }

    function test_validation_accepts_non_reality_condition_policy() public {
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, false);

        (bool valid, FutarchyOfficialProposalSource.ProposalValidationFailure failure) =
            source.validateProposal(address(proposal));
        assertTrue(valid);
        assertEq(
            uint256(failure), uint256(FutarchyOfficialProposalSource.ProposalValidationFailure.None)
        );
    }

    function test_validation_config_rejects_missing_dependencies() public {
        FutarchyOfficialProposalSource configurable = _newSource("");
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config =
            _nonRealityValidationConfig();
        config.trustedOracle = address(0);

        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalValidationConfig.selector);
        configurable.setProposalValidationConfig(config);
    }

    function test_constructor_can_set_validation_before_safe_owner_takes_over() public {
        FutarchyOfficialProposalSource configured = new FutarchyOfficialProposalSource(
            nonOwner,
            address(coordinator),
            officialProposer,
            IAlgebraFactoryLike(address(factory)),
            abi.encode(_validationConfig(true))
        );

        assertEq(configured.owner(), nonOwner);
        (bool enabled, address proposalToken, address collateralToken,,,,,,,,,) =
            configured.proposalValidationConfig();
        assertTrue(enabled);
        assertEq(proposalToken, company);
        assertEq(collateralToken, wxdai);
    }

    function test_validation_accepts_well_formed_proposal() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);

        (bool valid, FutarchyOfficialProposalSource.ProposalValidationFailure failure) =
            source.validateProposal(address(proposal));
        assertTrue(valid);
        assertEq(
            uint256(failure), uint256(FutarchyOfficialProposalSource.ProposalValidationFailure.None)
        );

        _setOfficialProposal(11, address(proposal), officialProposer);
        assertTrue(source.currentOfficialProposal().exists);
    }

    function test_validation_rejects_wrong_collateral_pair() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);
        proposal.setCollateralTokens(address(0xBAD), wxdai);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongCollateralPair
        );
        _setOfficialProposal(12, address(proposal), officialProposer);
    }

    function test_validation_rejects_missing_outcome_token() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);
        proposal.setWrappedOutcome(1, address(0));

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MissingOutcomeToken
        );
        _setOfficialProposal(13, address(proposal), officialProposer);
    }

    function test_validation_rejects_every_duplicate_outcome_pair() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);
        address[4] memory outcomes = [yesComp, noComp, yesCurr, noCurr];

        for (uint256 first; first < outcomes.length; first++) {
            for (uint256 second = first + 1; second < outcomes.length; second++) {
                proposal.setWrappedOutcome(second, outcomes[first]);

                (bool valid, FutarchyOfficialProposalSource.ProposalValidationFailure failure) =
                    source.validateProposal(address(proposal));
                assertFalse(valid);
                assertEq(
                    uint256(failure),
                    uint256(
                        FutarchyOfficialProposalSource.ProposalValidationFailure
                        .DuplicateOutcomeToken
                    )
                );

                _expectValidationFailure(
                    FutarchyOfficialProposalSource.ProposalValidationFailure.DuplicateOutcomeToken
                );
                _setOfficialProposal(
                    100 + first * outcomes.length + second, address(proposal), officialProposer
                );
                proposal.setWrappedOutcome(second, outcomes[second]);
            }
        }
    }

    function test_validation_rejects_wrong_ctf_oracle_condition() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        bytes32 wrongConditionId = conditionalTokens.getConditionId(address(0xBAD), questionId, 2);
        conditionalTokens.setOutcomeSlotCount(wrongConditionId, 2);
        proposal.setQuestionAndCondition(questionId, wrongConditionId);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongConditionId
        );
        _setOfficialProposal(15, address(proposal), officialProposer);
    }

    function test_validation_rejects_non_binary_condition() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,, bytes32 conditionId) = _validProposal(true, true);
        conditionalTokens.setOutcomeSlotCount(conditionId, 3);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongOutcomeSlotCount
        );
        _setOfficialProposal(16, address(proposal), officialProposer);
    }

    function test_validation_rejects_missing_reality_question() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, false);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MissingRealityQuestion
        );
        _setOfficialProposal(17, address(proposal), officialProposer);
    }

    function test_validation_rejects_untrusted_arbitrator() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, address(0xBAD), uint32(block.timestamp + 1 hours), 1 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.UntrustedArbitrator
        );
        _setOfficialProposal(18, address(proposal), officialProposer);
    }

    function test_validation_rejects_far_future_opening_time() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 8 days), 1 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.OpeningTimeTooFar
        );
        _setOfficialProposal(19, address(proposal), officialProposer);
    }

    function test_validation_rejects_already_open_question() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(questionId, trustedArbitrator, uint32(block.timestamp), 1 days, 10 ether);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.OpeningTimeTooSoon
        );
        _setOfficialProposal(190, address(proposal), officialProposer);
    }

    function test_validation_rejects_answered_or_arbitrating_question() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        realitio.setQuestionState(questionId, uint32(block.timestamp + 2 hours), false);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.QuestionNotPristine
        );
        _setOfficialProposal(191, address(proposal), officialProposer);

        realitio.setQuestionState(questionId, 0, true);
        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.QuestionNotPristine
        );
        _setOfficialProposal(192, address(proposal), officialProposer);
    }

    function test_validation_rejects_excessive_timeout() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 30 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.TimeoutTooHigh
        );
        _setOfficialProposal(20, address(proposal), officialProposer);
    }

    function test_validation_rejects_too_short_timeout() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 30 minutes, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.TimeoutTooLow
        );
        _setOfficialProposal(21, address(proposal), officialProposer);
    }

    function test_validation_rejects_insufficient_conditional_lifetime() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 22 hours, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.ConditionalLifetimeTooShort
        );
        _setOfficialProposal(211, address(proposal), officialProposer);
    }

    function test_validation_rejects_excessive_min_bond() public {
        _enableValidation();
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 1 days, 101 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MinBondTooHigh
        );
        _setOfficialProposal(22, address(proposal), officialProposer);
    }

    function test_only_owner_guards() public {
        vm.prank(nonOwner);
        vm.expectRevert(FutarchyOfficialProposalSource.OnlyOwnerOrProposalManager.selector);
        source.setOfficialProposer(address(0xCAFE));

        vm.prank(address(coordinator));
        vm.expectRevert();
        source.setProposalManager(newProposalManager);
    }

    function test_owner_can_update_proposal_manager() public {
        source.setProposalManager(newProposalManager);
        assertEq(source.proposalManager(), newProposalManager);
    }

    function test_proposal_manager_can_operate_proposal_source() public {
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);
        MockFutarchyProposalLike proposal = _proposal();

        vm.startPrank(address(coordinator));
        source.setOfficialProposer(officialProposer);
        source.setManualSettled(true);
        source.setSettlementOracle(address(oracle));
        vm.stopPrank();

        _setOfficialProposal(23, address(proposal), officialProposer);
        vm.prank(address(coordinator));
        source.clearOfficialProposal();

        assertEq(source.settlementOracle(), address(oracle));
        (,, bool exists,,,,,) = source.officialProposal();
        assertFalse(exists);
    }

    function _setOfficialProposal(uint256 proposalId, address proposal, address creator) internal {
        coordinator.setOfficialProposal(source, proposalId, proposal, creator);
    }

    function _newUnboundSource() internal returns (FutarchyOfficialProposalSource unbound) {
        unbound = _newSource(abi.encode(_nonRealityValidationConfig()));
    }

    function _newSource(bytes memory validationConfigData)
        internal
        returns (FutarchyOfficialProposalSource created)
    {
        created = new FutarchyOfficialProposalSource(
            owner,
            address(coordinator),
            officialProposer,
            IAlgebraFactoryLike(address(factory)),
            validationConfigData
        );
    }

    function _enableValidation() internal {
        _configureAndBind(_validationConfig(true));
    }

    function _configureAndBind(
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config
    ) internal {
        source = _newSource(abi.encode(config));
        activationTarget = _newActivationTarget(source, company, wxdai, address(conditionalRouter));
        source.bindActivationTarget(address(activationTarget));
    }

    function _newActivationTarget(
        FutarchyOfficialProposalSource targetSource,
        address companyToken,
        address collateralToken,
        address router
    ) internal returns (MockOfficialProposalActivationTarget target) {
        target = new MockOfficialProposalActivationTarget(
            targetSource, coordinator, companyToken, collateralToken, router
        );
    }

    function _expectPolicyBindingFailure(
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config
    ) internal {
        FutarchyOfficialProposalSource unbound = _newSource(abi.encode(config));
        MockOfficialProposalActivationTarget target =
            _newActivationTarget(unbound, company, wxdai, address(conditionalRouter));
        vm.expectRevert(FutarchyOfficialProposalSource.InvalidProposalValidationConfig.selector);
        unbound.bindActivationTarget(address(target));
    }

    function _proposal() internal returns (MockFutarchyProposalLike proposal) {
        (proposal,,) = _validProposal(false, false);
    }

    function _validationConfig(bool enabled)
        internal
        view
        returns (FutarchyOfficialProposalSource.ProposalValidationConfig memory)
    {
        return FutarchyOfficialProposalSource.ProposalValidationConfig({
            enabled: enabled,
            expectedProposalToken: enabled ? company : address(0),
            expectedCollateralToken: enabled ? wxdai : address(0),
            conditionalTokens: enabled ? address(conditionalTokens) : address(0),
            trustedOracle: enabled ? trustedOracle : address(0),
            realitio: enabled ? address(realitio) : address(0),
            trustedArbitrator: enabled ? trustedArbitrator : address(0),
            maxOpeningDelay: enabled ? uint32(7 days) : 0,
            minTimeout: enabled ? uint32(1 hours) : 0,
            maxTimeout: enabled ? uint32(7 days) : 0,
            minConditionalLifetime: enabled ? uint32(1 days) : 0,
            maxMinBond: enabled ? 100 ether : 0
        });
    }

    function _nonRealityValidationConfig()
        internal
        view
        returns (FutarchyOfficialProposalSource.ProposalValidationConfig memory)
    {
        return FutarchyOfficialProposalSource.ProposalValidationConfig({
            enabled: true,
            expectedProposalToken: company,
            expectedCollateralToken: wxdai,
            conditionalTokens: address(conditionalTokens),
            trustedOracle: trustedOracle,
            realitio: address(0),
            trustedArbitrator: address(0),
            maxOpeningDelay: 0,
            minTimeout: 0,
            maxTimeout: 0,
            minConditionalLifetime: 0,
            maxMinBond: 0
        });
    }

    function _validProposal(bool setPools, bool setReality)
        internal
        returns (MockFutarchyProposalLike proposal, bytes32 questionId, bytes32 conditionId)
    {
        if (setPools) {
            factory.setPool(yesComp, yesCurr, yesPool);
            factory.setPool(noComp, noCurr, noPool);
        }

        proposal = new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);
        questionId = keccak256(abi.encodePacked("question", address(proposal)));
        conditionId = conditionalTokens.getConditionId(trustedOracle, questionId, 2);
        conditionalTokens.setOutcomeSlotCount(conditionId, 2);
        proposal.setQuestionAndCondition(questionId, conditionId);

        if (setReality) {
            _setQuestion(
                questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 1 days, 10 ether
            );
        }
    }

    function _setQuestion(
        bytes32 questionId,
        address arbitrator,
        uint32 openingTs,
        uint32 timeout,
        uint256 minBond
    ) internal {
        realitio.setQuestion(questionId, CONTENT_HASH, arbitrator, openingTs, timeout, minBond);
    }

    function _expectValidationFailure(
        FutarchyOfficialProposalSource.ProposalValidationFailure failure
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyOfficialProposalSource.ProposalValidationFailed.selector, failure
            )
        );
    }
}
