// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    IConditionalTokensCore,
    IFutarchyProposalCore,
    IRealityETHCore
} from "../../src/interfaces/IFutarchyTradingCore.sol";

interface IFutarchyProposalRealityView {
    function realityProxy() external view returns (address);
}

interface IFutarchyRealityProxyView {
    function realitio() external view returns (address);
}

contract FutarchyProposalWiringForkTest is Test {
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant GNOSIS_CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;
    address internal constant DEFAULT_COMPANY_TOKEN = 0x9494C281a02c9ae5f72b224B514793ad2DD8cA17;
    address internal constant DEFAULT_PROPOSAL = 0x81829a8ee62D306e3fD9D5b79D02C7624437BE37;

    function testFork_proposal_exposes_expected_tokens_and_binary_ctf_condition() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        address proposalAddress = vm.envOr("TEST_FUTARCHY_PROPOSAL", DEFAULT_PROPOSAL);
        address expectedCompany = vm.envOr("TEST_COMPANY_TOKEN", DEFAULT_COMPANY_TOKEN);
        address expectedCollateral = vm.envOr("TEST_COLLATERAL_TOKEN", GNOSIS_WXDAI);

        IFutarchyProposalCore proposal = IFutarchyProposalCore(proposalAddress);

        assertEq(proposal.collateralToken1(), expectedCompany, "company token mismatch");
        assertEq(proposal.collateralToken2(), expectedCollateral, "collateral token mismatch");

        bytes32 questionId = proposal.questionId();
        bytes32 conditionId = proposal.conditionId();
        assertTrue(questionId != bytes32(0), "missing Reality question id");
        assertTrue(conditionId != bytes32(0), "missing CTF condition id");
        _assertRealityWiring(proposalAddress, questionId, conditionId);

        assertEq(IConditionalTokensCore(GNOSIS_CTF).getOutcomeSlotCount(conditionId), 2);
        IConditionalTokensCore(GNOSIS_CTF).payoutDenominator(conditionId);

        (address yesCompany,) = proposal.wrappedOutcome(0);
        (address noCompany,) = proposal.wrappedOutcome(1);
        (address yesCurrency,) = proposal.wrappedOutcome(2);
        (address noCurrency,) = proposal.wrappedOutcome(3);

        assertTrue(yesCompany != address(0) && noCompany != address(0), "company outcomes missing");
        assertTrue(
            yesCurrency != address(0) && noCurrency != address(0), "currency outcomes missing"
        );
        assertTrue(yesCompany != noCompany, "YES/NO company outcomes identical");
        assertTrue(yesCurrency != noCurrency, "YES/NO currency outcomes identical");

        string memory companySymbol = IERC20Metadata(expectedCompany).symbol();
        string memory collateralSymbol = IERC20Metadata(expectedCollateral).symbol();

        assertTrue(_startsWith(IERC20Metadata(yesCompany).symbol(), "YES_"));
        assertTrue(_startsWith(IERC20Metadata(noCompany).symbol(), "NO_"));
        assertTrue(_contains(IERC20Metadata(yesCompany).symbol(), companySymbol));
        assertTrue(_contains(IERC20Metadata(noCompany).symbol(), companySymbol));

        assertTrue(_startsWith(IERC20Metadata(yesCurrency).symbol(), "YES_"));
        assertTrue(_startsWith(IERC20Metadata(noCurrency).symbol(), "NO_"));
        assertTrue(_contains(IERC20Metadata(yesCurrency).symbol(), collateralSymbol));
        assertTrue(_contains(IERC20Metadata(noCurrency).symbol(), collateralSymbol));
    }

    function _assertRealityWiring(address proposalAddress, bytes32 questionId, bytes32 conditionId)
        internal
        view
    {
        address realityProxy = IFutarchyProposalRealityView(proposalAddress).realityProxy();
        assertTrue(realityProxy != address(0), "missing Reality proxy");
        address realitio = IFutarchyRealityProxyView(realityProxy).realitio();
        assertTrue(realitio != address(0), "missing Realitio");
        assertEq(
            IConditionalTokensCore(GNOSIS_CTF).getConditionId(realityProxy, questionId, 2),
            conditionId,
            "condition oracle mismatch"
        );

        (
            bytes32 contentHash,
            address arbitrator,
            uint32 openingTs,
            uint32 timeout,,,,,,,
            uint256 minBond
        ) = IRealityETHCore(realitio).questions(questionId);

        assertTrue(contentHash != bytes32(0), "missing Reality content");
        assertTrue(arbitrator != address(0), "missing Reality arbitrator");
        assertGt(openingTs, 0, "missing Reality opening time");
        assertGt(timeout, 0, "missing Reality timeout");
        assertGt(minBond, 0, "missing Reality min bond");
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > valueBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0) return true;
        if (needleBytes.length > valueBytes.length) return false;

        for (uint256 i; i <= valueBytes.length - needleBytes.length; ++i) {
            bool matchFound = true;
            for (uint256 j; j < needleBytes.length; ++j) {
                if (valueBytes[i + j] != needleBytes[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) return true;
        }
        return false;
    }
}
