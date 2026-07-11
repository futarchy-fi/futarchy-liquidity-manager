// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {MockConditionalRouter} from "../mocks/MockConditionalRouter.sol";
import {MockFutarchyLiquidityAdapter} from "../mocks/MockFutarchyLiquidityAdapter.sol";
import {MockFutarchyProposalLike} from "../mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";
import {MockOfficialProposalSource} from "../mocks/MockOfficialProposalSource.sol";
import {MockPoolStabilityGuard} from "../mocks/MockPoolStabilityGuard.sol";
import {MockWrappedNative} from "../mocks/MockWrappedNative.sol";

contract FutarchyLiquidityManagerHandler is Test {
    FutarchyLiquidityManager public immutable manager;
    MockOfficialProposalSource public immutable source;
    MockConditionalRouter public immutable router;
    MockMintableERC20 public immutable company;
    MockWrappedNative public immutable wrappedNative;
    MockMintableERC20 public immutable yesCompany;
    MockMintableERC20 public immutable noCompany;
    MockMintableERC20 public immutable yesCurrency;
    MockMintableERC20 public immutable noCurrency;
    MockFutarchyProposalLike public immutable proposal;
    address public immutable officialProposer;

    uint256 public migrations;
    uint256 public settlements;
    bool public winnerIsYes = true;

    constructor(
        FutarchyLiquidityManager manager_,
        MockOfficialProposalSource source_,
        MockConditionalRouter router_,
        MockMintableERC20 company_,
        MockWrappedNative wrappedNative_,
        MockMintableERC20 yesCompany_,
        MockMintableERC20 noCompany_,
        MockMintableERC20 yesCurrency_,
        MockMintableERC20 noCurrency_,
        MockFutarchyProposalLike proposal_,
        address officialProposer_
    ) {
        manager = manager_;
        source = source_;
        router = router_;
        company = company_;
        wrappedNative = wrappedNative_;
        yesCompany = yesCompany_;
        noCompany = noCompany_;
        yesCurrency = yesCurrency_;
        noCurrency = noCurrency_;
        proposal = proposal_;
        officialProposer = officialProposer_;
    }

    receive() external payable {}

    function depositToSpot(uint96 companySeed, uint96 nativeSeed) external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;

        uint256 companyAmount = bound(uint256(companySeed), 1e9, 50 ether);
        uint256 nativeAmount = bound(uint256(nativeSeed), 1e9, 50 ether);

        company.mint(address(this), companyAmount);
        vm.deal(address(this), address(this).balance + nativeAmount);
        company.approve(address(manager), companyAmount);

        try manager.depositToSpot{value: nativeAmount}(companyAmount) {} catch {}
    }

    function redeem(uint96 sharesSeed) external {
        uint256 balance = manager.balanceOf(address(this));
        if (balance == 0) return;

        uint256 shares = bound(uint256(sharesSeed), 1, balance);
        try manager.redeem(shares, address(this), false) {} catch {}
    }

    function migrateToConditional() external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;
        if (manager.inConditionalMode() || manager.spotLiquidity() == 0) return;

        source.createProposalExtended(
            address(proposal),
            officialProposer,
            address(company),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency),
            address(0xA11CE),
            address(0xB0B)
        );

        try manager.sync() {
            migrations++;
        } catch {}
    }

    function settleAndReturnToSpot(bool _winnerIsYes) external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;
        if (!manager.inConditionalMode()) return;

        winnerIsYes = _winnerIsYes;
        router.setOutcomeConfig(
            address(proposal),
            address(company),
            address(yesCompany),
            address(noCompany),
            winnerIsYes
        );
        router.setOutcomeConfig(
            address(proposal),
            address(wrappedNative),
            address(yesCurrency),
            address(noCurrency),
            winnerIsYes
        );
        source.setSettled(true);

        try manager.sync() {
            settlements++;
        } catch {}
    }
}

contract FutarchyLiquidityManagerInvariantTest is StdInvariant, Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockMintableERC20 internal yesCompany;
    MockMintableERC20 internal noCompany;
    MockMintableERC20 internal yesCurrency;
    MockMintableERC20 internal noCurrency;
    MockFutarchyProposalLike internal proposal;
    MockOfficialProposalSource internal source;
    MockFutarchyLiquidityAdapter internal spotAdapter;
    MockFutarchyLiquidityAdapter internal conditionalAdapter;
    MockConditionalRouter internal router;
    FutarchyLiquidityManager internal manager;
    FutarchyLiquidityManagerHandler internal handler;

    address internal bootstrapRecipient = address(0xB007);
    address internal officialProposer = address(0xC0DE);
    address internal owner = address(this);

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        yesCompany = new MockMintableERC20("YES_COMP", "YES_COMP");
        noCompany = new MockMintableERC20("NO_COMP", "NO_COMP");
        yesCurrency = new MockMintableERC20("YES_WNATIVE", "YES_WNATIVE");
        noCurrency = new MockMintableERC20("NO_WNATIVE", "NO_WNATIVE");
        proposal = new MockFutarchyProposalLike(
            address(company),
            address(wrappedNative),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
        source = new MockOfficialProposalSource();
        spotAdapter = new MockFutarchyLiquidityAdapter();
        conditionalAdapter = new MockFutarchyLiquidityAdapter();
        router = new MockConditionalRouter();
        MockPoolStabilityGuard stabilityGuard = new MockPoolStabilityGuard();

        router.setOutcomeConfig(
            address(proposal), address(company), address(yesCompany), address(noCompany), true
        );
        router.setOutcomeConfig(
            address(proposal),
            address(wrappedNative),
            address(yesCurrency),
            address(noCurrency),
            true
        );

        manager = new FutarchyLiquidityManager(
            bootstrapRecipient,
            company,
            IWrappedNative(address(wrappedNative)),
            officialProposer,
            source,
            spotAdapter,
            conditionalAdapter,
            router,
            stabilityGuard,
            owner,
            FutarchyLiquidityManager.LpTokenMetadata({name: "Futarchy LP", symbol: "fLP"})
        );

        handler = new FutarchyLiquidityManagerHandler(
            manager,
            source,
            router,
            company,
            wrappedNative,
            yesCompany,
            noCompany,
            yesCurrency,
            noCurrency,
            proposal,
            officialProposer
        );
        targetContract(address(handler));
    }

    function invariant_conditionalAccountingIsConsistent() public view {
        if (manager.inConditionalMode()) {
            assertTrue(manager.activeProposal() != address(0));
            assertTrue(manager.activeYesCompanyToken() != address(0));
            assertTrue(manager.activeNoCompanyToken() != address(0));
            assertTrue(manager.activeYesCurrencyToken() != address(0));
            assertTrue(manager.activeNoCurrencyToken() != address(0));
        } else {
            assertEq(manager.conditionalYesLiquidity(), 0);
            assertEq(manager.conditionalNoLiquidity(), 0);
            assertEq(manager.activeProposal(), address(0));
        }
    }

    function invariant_adapterLiquidityMatchesManagerAccounting() public view {
        bytes32 spotKey = keccak256(abi.encode(manager.TOKEN0(), manager.TOKEN1()));
        assertEq(spotAdapter.liquidityByPair(spotKey), manager.spotLiquidity());

        if (manager.inConditionalMode()) {
            bytes32 yesKey =
                _pairKey(manager.activeYesCompanyToken(), manager.activeYesCurrencyToken());
            bytes32 noKey =
                _pairKey(manager.activeNoCompanyToken(), manager.activeNoCurrencyToken());
            assertEq(conditionalAdapter.liquidityByPair(yesKey), manager.conditionalYesLiquidity());
            assertEq(conditionalAdapter.liquidityByPair(noKey), manager.conditionalNoLiquidity());
        }
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        if (tokenA < tokenB) return keccak256(abi.encode(tokenA, tokenB));
        return keccak256(abi.encode(tokenB, tokenA));
    }
}
