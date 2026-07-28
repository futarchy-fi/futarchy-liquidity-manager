// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockConditionalTokens} from "./MockConditionalTokens.sol";
import {MockConditionalRouter} from "./MockConditionalRouter.sol";
import {MockFutarchyProposalLike} from "./MockFutarchyProposalLike.sol";

/// @notice Minimal stand-in for the operator's local condition/wrapper/proposal creation call.
contract MockActivationBundleSetup {
    MockConditionalTokens public immutable conditionalTokens;
    MockConditionalRouter public immutable router;
    MockFutarchyProposalLike public immutable proposal;
    address public immutable oracle;
    address public immutable company;
    address public immutable collateral;
    address public immutable yesCompany;
    address public immutable noCompany;
    address public immutable yesCurrency;
    address public immutable noCurrency;
    bool public created;

    constructor(
        MockConditionalTokens conditionalTokens_,
        MockConditionalRouter router_,
        address oracle_,
        address company_,
        address collateral_,
        address yesCompany_,
        address noCompany_,
        address yesCurrency_,
        address noCurrency_
    ) {
        conditionalTokens = conditionalTokens_;
        router = router_;
        oracle = oracle_;
        company = company_;
        collateral = collateral_;
        yesCompany = yesCompany_;
        noCompany = noCompany_;
        yesCurrency = yesCurrency_;
        noCurrency = noCurrency_;
        proposal = new MockFutarchyProposalLike(
            company_, collateral_, yesCompany_, noCompany_, yesCurrency_, noCurrency_
        );
    }

    function create(bytes32 questionId) external {
        bytes32 conditionId = conditionalTokens.getConditionId(oracle, questionId, 2);
        conditionalTokens.setOutcomeSlotCount(conditionId, 2);
        proposal.setQuestionAndCondition(questionId, conditionId);
        router.setOutcomeConfig(address(proposal), company, yesCompany, noCompany, true);
        router.setOutcomeConfig(address(proposal), collateral, yesCurrency, noCurrency, true);
        created = true;
    }
}
