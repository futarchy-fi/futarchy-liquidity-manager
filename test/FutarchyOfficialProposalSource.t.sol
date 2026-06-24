// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {
    IFutarchyOfficialProposalSource
} from "../src/interfaces/IFutarchyOfficialProposalSource.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyProposalLike} from "./mocks/MockFutarchyProposalLike.sol";
import {MockProposalSettlementOracle} from "./mocks/MockProposalSettlementOracle.sol";
import {MockRealityETH} from "./mocks/MockRealityETH.sol";

contract FutarchyOfficialProposalSourceTest is Test {
    FutarchyOfficialProposalSource internal source;
    MockAlgebraFactoryLike internal factory;
    MockProposalSettlementOracle internal oracle;
    MockConditionalTokens internal conditionalTokens;
    MockRealityETH internal realitio;

    address internal owner = address(this);
    address internal nonOwner = address(0xBEEF);
    address internal officialProposer = address(0x1111);
    address internal trustedOracle = address(0xCAFE);
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
        source = new FutarchyOfficialProposalSource(
            owner, officialProposer, IAlgebraFactoryLike(address(factory))
        );
        oracle = new MockProposalSettlementOracle();
        conditionalTokens = new MockConditionalTokens();
        realitio = new MockRealityETH();
    }

    function test_set_and_read_official_proposal() public {
        factory.setPool(yesComp, yesCurr, yesPool);
        factory.setPool(noComp, noCurr, noPool);

        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(proposal), officialProposer);

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
    }

    function test_settled_with_manual_flag() public {
        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);
        source.setOfficialProposal(7, address(proposal), officialProposer);

        source.setManualSettled(true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_settled_with_oracle_override() public {
        MockFutarchyProposalLike proposal =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);
        source.setOfficialProposal(9, address(proposal), officialProposer);
        source.setManualSettled(false);
        source.setSettlementOracle(address(oracle));

        oracle.setSettled(address(proposal), true);
        (,,, bool settled,,,,) = source.officialProposal();
        assertTrue(settled);
    }

    function test_cannot_set_new_unsettled_official_proposal() public {
        MockFutarchyProposalLike p1 =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);
        MockFutarchyProposalLike p2 =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(p1), officialProposer);
        vm.expectRevert(FutarchyOfficialProposalSource.ActiveOfficialProposalExists.selector);
        source.setOfficialProposal(2, address(p2), officialProposer);
    }

    function test_can_replace_after_settlement() public {
        MockFutarchyProposalLike p1 =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);
        MockFutarchyProposalLike p2 =
            new MockFutarchyProposalLike(company, wxdai, yesComp, noComp, yesCurr, noCurr);

        source.setOfficialProposal(1, address(p1), officialProposer);
        source.setManualSettled(true);
        source.setOfficialProposal(2, address(p2), officialProposer);

        (uint256 proposalId,, bool exists,,,,,) = source.officialProposal();
        assertEq(proposalId, 2);
        assertTrue(exists);
    }

    function test_validation_accepts_well_formed_proposal() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);

        (bool valid, FutarchyOfficialProposalSource.ProposalValidationFailure failure) =
            source.validateProposal(address(proposal));
        assertTrue(valid);
        assertEq(
            uint256(failure), uint256(FutarchyOfficialProposalSource.ProposalValidationFailure.None)
        );

        source.setOfficialProposal(11, address(proposal), officialProposer);
        (uint256 proposalId,, bool exists,,,,,) = source.officialProposal();
        assertEq(proposalId, 11);
        assertTrue(exists);
    }

    function test_validation_rejects_wrong_collateral_pair() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);
        proposal.setCollateralTokens(address(0xBAD), wxdai);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongCollateralPair
        );
        source.setOfficialProposal(12, address(proposal), officialProposer);
    }

    function test_validation_rejects_missing_outcome_token() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, true);
        proposal.setWrappedOutcome(1, address(0));

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MissingOutcomeToken
        );
        source.setOfficialProposal(13, address(proposal), officialProposer);
    }

    function test_validation_rejects_missing_conditional_pool() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,,) = _validProposal(false, true);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MissingPool
        );
        source.setOfficialProposal(14, address(proposal), officialProposer);
    }

    function test_validation_rejects_wrong_ctf_oracle_condition() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        bytes32 wrongConditionId = conditionalTokens.getConditionId(address(0xBAD), questionId, 2);
        conditionalTokens.setOutcomeSlotCount(wrongConditionId, 2);
        proposal.setQuestionAndCondition(questionId, wrongConditionId);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongConditionId
        );
        source.setOfficialProposal(15, address(proposal), officialProposer);
    }

    function test_validation_rejects_non_binary_condition() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,, bytes32 conditionId) = _validProposal(true, true);
        conditionalTokens.setOutcomeSlotCount(conditionId, 3);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.WrongOutcomeSlotCount
        );
        source.setOfficialProposal(16, address(proposal), officialProposer);
    }

    function test_validation_rejects_missing_reality_question() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal,,) = _validProposal(true, false);

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MissingRealityQuestion
        );
        source.setOfficialProposal(17, address(proposal), officialProposer);
    }

    function test_validation_rejects_untrusted_arbitrator() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, address(0xBAD), uint32(block.timestamp + 1 hours), 1 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.UntrustedArbitrator
        );
        source.setOfficialProposal(18, address(proposal), officialProposer);
    }

    function test_validation_rejects_far_future_opening_time() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 8 days), 1 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.OpeningTimeTooFar
        );
        source.setOfficialProposal(19, address(proposal), officialProposer);
    }

    function test_validation_rejects_excessive_timeout() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 30 days, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.TimeoutTooHigh
        );
        source.setOfficialProposal(20, address(proposal), officialProposer);
    }

    function test_validation_rejects_too_short_timeout() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 30 minutes, 10 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.TimeoutTooLow
        );
        source.setOfficialProposal(21, address(proposal), officialProposer);
    }

    function test_validation_rejects_excessive_min_bond() public {
        _enableValidation(true);
        (MockFutarchyProposalLike proposal, bytes32 questionId,) = _validProposal(true, true);
        _setQuestion(
            questionId, trustedArbitrator, uint32(block.timestamp + 1 hours), 1 days, 101 ether
        );

        _expectValidationFailure(
            FutarchyOfficialProposalSource.ProposalValidationFailure.MinBondTooHigh
        );
        source.setOfficialProposal(22, address(proposal), officialProposer);
    }

    function test_only_owner_guards() public {
        vm.prank(nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        source.setOfficialProposer(address(0xCAFE));
    }

    function _enableValidation(bool requirePools) internal {
        source.setProposalValidationConfig(
            FutarchyOfficialProposalSource.ProposalValidationConfig({
                enabled: true,
                expectedProposalToken: company,
                expectedCollateralToken: wxdai,
                conditionalTokens: address(conditionalTokens),
                trustedOracle: trustedOracle,
                realitio: address(realitio),
                trustedArbitrator: trustedArbitrator,
                maxOpeningDelay: uint32(7 days),
                minTimeout: uint32(1 hours),
                maxTimeout: uint32(7 days),
                maxMinBond: 100 ether,
                requirePools: requirePools
            })
        );
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
