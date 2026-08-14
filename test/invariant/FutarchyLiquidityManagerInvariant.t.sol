// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    MockFutarchyLiquidityAdapter public immutable spotAdapter;
    MockFutarchyLiquidityAdapter public immutable conditionalAdapter;
    address public immutable officialProposer;

    uint256 public migrations;
    uint256 public settlements;
    uint256 public successfulDeposits;
    uint256 public successfulRedemptions;
    uint256 public feeAccruals;
    uint256 public donations;
    uint256 public emergencyArms;
    uint256 public emergencyDisarms;
    uint256 public emergencyExecutions;
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
        MockFutarchyLiquidityAdapter spotAdapter_,
        MockFutarchyLiquidityAdapter conditionalAdapter_,
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
        spotAdapter = spotAdapter_;
        conditionalAdapter = conditionalAdapter_;
        officialProposer = officialProposer_;
    }

    receive() external payable {}

    function depositToSpot(uint96 companySeed, uint96 nativeSeed) external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;

        uint256 supplyBefore = manager.totalSupply();
        if (supplyBefore == 0) return;
        uint256[3] memory liquidityBefore = _activeLiquidity();
        uint256[6] memory balancesBefore = _accountingBalances();
        uint256 companyAmount = bound(uint256(companySeed), 1e9, 50 ether);
        uint256 nativeAmount = bound(uint256(nativeSeed), 1e9, 50 ether);

        company.mint(address(this), companyAmount);
        vm.deal(address(this), address(this).balance + nativeAmount);
        company.approve(address(manager), companyAmount);

        try manager.depositToSpot{value: nativeAmount}(companyAmount) {
            successfulDeposits++;
            uint256 supplyAfter = manager.totalSupply();
            uint256[3] memory liquidityAfter = _activeLiquidity();
            uint256[6] memory balancesAfter = _accountingBalances();
            for (uint256 i; i < liquidityBefore.length; ++i) {
                assertGe(
                    uint256(liquidityAfter[i]) * supplyBefore,
                    uint256(liquidityBefore[i]) * supplyAfter,
                    "deposit diluted existing liquidity"
                );
            }
            for (uint256 i; i < balancesBefore.length; ++i) {
                assertGe(
                    balancesAfter[i] * supplyBefore,
                    balancesBefore[i] * supplyAfter,
                    "deposit diluted existing assets"
                );
            }
        } catch {}
    }

    function redeem(uint96 sharesSeed) external {
        uint256 balance = manager.balanceOf(address(this));
        if (balance == 0) return;

        uint256 shares = bound(uint256(sharesSeed), 1, balance);
        uint256 supplyBefore = manager.totalSupply();
        uint256[3] memory liquidityBefore = _activeLiquidity();
        uint256[6] memory balancesBefore = _accountingBalances();
        try manager.redeem(shares, address(this), false) {
            successfulRedemptions++;
            uint256 supplyAfter = manager.totalSupply();
            uint256[3] memory liquidityAfter = _activeLiquidity();
            uint256[6] memory balancesAfter = _accountingBalances();
            for (uint256 i; i < liquidityBefore.length; ++i) {
                assertGe(
                    uint256(liquidityAfter[i]) * supplyBefore,
                    uint256(liquidityBefore[i]) * supplyAfter,
                    "redemption diluted survivor liquidity"
                );
            }
            for (uint256 i; i < balancesBefore.length; ++i) {
                assertGe(
                    balancesAfter[i] * supplyBefore,
                    balancesBefore[i] * supplyAfter,
                    "redemption diluted survivor assets"
                );
            }
        } catch {}
    }

    function donate(uint8 tokenSeed, uint96 amountSeed) external {
        if (manager.totalSupply() == 0) return;
        uint256 tokenIndex = uint256(tokenSeed) % 6;
        bool lateOutcome = !manager.inConditionalMode() && settlements != 0 && tokenIndex > 1;
        if (!manager.inConditionalMode() && !lateOutcome) tokenIndex %= 2;
        MockMintableERC20 token = _tokens()[tokenIndex];
        uint256 amount = bound(uint256(amountSeed), 1, 10 ether);
        token.mint(address(manager), amount);
        if (lateOutcome) {
            bool isYes = tokenIndex == 2 || tokenIndex == 4;
            if (isYes == winnerIsYes) {
                MockMintableERC20 backing =
                    tokenIndex < 4 ? company : MockMintableERC20(address(wrappedNative));
                backing.mint(address(router), amount);
            }
        }
        donations++;
    }

    function accrueFees(uint8 pairSeed, uint96 amount0Seed, uint96 amount1Seed) external {
        if (manager.totalSupply() == 0) return;
        if (
            manager.inConditionalMode() && manager.conditionalYesLiquidity() == 0
                && manager.conditionalNoLiquidity() == 0
        ) return;
        if (!manager.inConditionalMode() && manager.spotLiquidity() == 0) return;
        uint256 pair = uint256(pairSeed) % (manager.inConditionalMode() ? 3 : 1);
        (
            MockFutarchyLiquidityAdapter adapter,
            MockMintableERC20 tokenA,
            MockMintableERC20 tokenB
        ) = pair == 0
            ? (spotAdapter, company, MockMintableERC20(address(wrappedNative)))
            : pair == 1
                ? (conditionalAdapter, yesCompany, yesCurrency)
                : (conditionalAdapter, noCompany, noCurrency);
        uint256 amountA = bound(uint256(amount0Seed), 1, 10 ether);
        uint256 amountB = bound(uint256(amount1Seed), 1, 10 ether);
        tokenA.mint(address(this), amountA);
        tokenB.mint(address(this), amountB);
        tokenA.approve(address(adapter), amountA);
        tokenB.approve(address(adapter), amountB);
        if (address(tokenA) < address(tokenB)) {
            adapter.accrueFees(address(tokenA), address(tokenB), amountA, amountB);
        } else {
            adapter.accrueFees(address(tokenB), address(tokenA), amountB, amountA);
        }
        feeAccruals++;
    }

    function migrateToConditional() external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;
        if (
            manager.inConditionalMode() || manager.migrationActive() || manager.spotLiquidity() == 0
        ) {
            return;
        }

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

        try source.activate(address(manager)) {
            try manager.migrateSide(true) {
                try manager.migrateSide(false) {
                    migrations++;
                } catch {}
            } catch {}
        } catch {}
    }

    function settleAndReturnToSpot(bool _winnerIsYes) external {
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
        router.setPayouts(1, winnerIsYes ? 1 : 0, winnerIsYes ? 0 : 1);
        source.setSettled(true);

        try manager.sync() {
            settlements++;
        } catch {}
    }

    function armEmergencyExit() external {
        if (manager.emergencyExitArmedAt() != 0 || manager.emergencyExitExecuted()) return;
        vm.prank(manager.owner());
        manager.armEmergencyExit();
        emergencyArms++;
    }

    function disarmEmergencyExit() external {
        if (manager.emergencyExitArmedAt() == 0 || manager.emergencyExitExecuted()) return;
        vm.prank(manager.owner());
        manager.disarmEmergencyExit();
        emergencyDisarms++;
    }

    function executeEmergencyExit() external {
        uint256 armedAt = manager.emergencyExitArmedAt();
        if (armedAt == 0 || manager.emergencyExitExecuted()) return;
        uint256 readyAt = armedAt + manager.EMERGENCY_EXIT_DELAY();
        if (block.timestamp < readyAt) vm.warp(readyAt);
        manager.executeEmergencyExit();
        emergencyExecutions++;
    }

    function _tokens() internal view returns (MockMintableERC20[6] memory tokens) {
        tokens = [
            company,
            MockMintableERC20(address(wrappedNative)),
            yesCompany,
            noCompany,
            yesCurrency,
            noCurrency
        ];
    }

    function _accountingBalances() internal view returns (uint256[6] memory balances) {
        MockMintableERC20[6] memory tokens = _tokens();
        for (uint256 i; i < tokens.length; ++i) {
            balances[i] = tokens[i].balanceOf(address(manager))
                + tokens[i].balanceOf(address(spotAdapter))
                + tokens[i].balanceOf(address(conditionalAdapter));
        }
        if (!manager.inConditionalMode() && settlements != 0) {
            balances[0] += balances[winnerIsYes ? 2 : 3];
            balances[1] += balances[winnerIsYes ? 4 : 5];
            for (uint256 i = 2; i < balances.length; ++i) {
                balances[i] = 0;
            }
        }
    }

    function _activeLiquidity() internal view returns (uint256[3] memory liquidity) {
        liquidity[0] = manager.spotLiquidity();
        liquidity[1] = manager.conditionalYesLiquidity();
        liquidity[2] = manager.conditionalNoLiquidity();
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
    bytes32 internal constant CONDITION_ID = bytes32(uint256(0xC0DE));

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
        proposal.setQuestionAndCondition(bytes32(uint256(1)), CONDITION_ID);
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
            spotAdapter,
            conditionalAdapter,
            officialProposer
        );

        company.mint(bootstrapRecipient, 100 ether);
        vm.deal(bootstrapRecipient, 100 ether);
        vm.startPrank(bootstrapRecipient);
        company.approve(address(manager), 100 ether);
        manager.initializeFromBootstrap{value: 100 ether}(100 ether);
        manager.transfer(address(handler), manager.balanceOf(bootstrapRecipient));
        vm.stopPrank();

        targetContract(address(handler));
    }

    function test_handlerReachesAtomicActivationAndSettlement() public {
        handler.depositToSpot(1 ether, 1 ether);
        assertEq(handler.successfulDeposits(), 0);

        handler.migrateToConditional();
        assertEq(handler.migrations(), 1);
        assertTrue(manager.inConditionalMode());

        handler.donate(5, 1 ether);
        handler.accrueFees(2, 1 ether, 2 ether);
        handler.redeem(10 ether);
        assertEq(handler.donations(), 1);
        assertEq(handler.feeAccruals(), 1);
        assertEq(handler.successfulRedemptions(), 1);

        handler.settleAndReturnToSpot(true);
        assertEq(handler.settlements(), 1);
        assertFalse(manager.inConditionalMode());

        handler.donate(2, 1 ether);
        assertEq(yesCompany.balanceOf(address(manager)), 1 ether);
        handler.redeem(1 ether);
        assertEq(yesCompany.balanceOf(address(manager)), 0);
        assertEq(handler.successfulRedemptions(), 2);
    }

    function test_handlerReachesEmergencyExecutionAndSettlement() public {
        handler.armEmergencyExit();
        handler.disarmEmergencyExit();
        assertEq(handler.emergencyArms(), 1);
        assertEq(handler.emergencyDisarms(), 1);

        handler.migrateToConditional();
        handler.armEmergencyExit();
        handler.executeEmergencyExit();
        assertTrue(manager.inConditionalMode());
        assertTrue(manager.emergencyExitExecuted());
        assertEq(handler.emergencyExecutions(), 1);

        handler.settleAndReturnToSpot(false);
        assertEq(handler.settlements(), 1);
        assertFalse(manager.inConditionalMode());
        assertTrue(manager.emergencyExitExecuted());
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

    function invariant_allSixTokensRemainInKnownCustody() public view {
        _assertKnownCustody(company);
        _assertKnownCustody(wrappedNative);
        _assertKnownCustody(yesCompany);
        _assertKnownCustody(noCompany);
        _assertKnownCustody(yesCurrency);
        _assertKnownCustody(noCurrency);
    }

    function invariant_zeroSupplyLeavesNoManagedAssets() public view {
        if (manager.totalSupply() != 0) return;
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        _assertZeroManagedBalance(company);
        _assertZeroManagedBalance(wrappedNative);
        _assertZeroManagedBalance(yesCompany);
        _assertZeroManagedBalance(noCompany);
        _assertZeroManagedBalance(yesCurrency);
        _assertZeroManagedBalance(noCurrency);
    }

    function invariant_emergencyExecutionLeavesNoPositionLiquidity() public view {
        if (!manager.emergencyExitExecuted()) return;
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(
            spotAdapter.liquidityByPair(keccak256(abi.encode(manager.TOKEN0(), manager.TOKEN1()))),
            0
        );
        assertEq(
            conditionalAdapter.liquidityByPair(_pairKey(address(yesCompany), address(yesCurrency))),
            0
        );
        assertEq(
            conditionalAdapter.liquidityByPair(_pairKey(address(noCompany), address(noCurrency))), 0
        );
    }

    function _assertKnownCustody(IERC20 token) internal view {
        uint256 known = token.balanceOf(address(manager)) + token.balanceOf(address(spotAdapter))
            + token.balanceOf(address(conditionalAdapter)) + token.balanceOf(address(router))
            + token.balanceOf(address(handler)) + token.balanceOf(bootstrapRecipient)
            + token.balanceOf(address(this));
        assertEq(known, token.totalSupply(), "token escaped modeled custody");
    }

    function _assertZeroManagedBalance(IERC20 token) internal view {
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(spotAdapter)), 0);
        assertEq(token.balanceOf(address(conditionalAdapter)), 0);
    }

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        if (tokenA < tokenB) return keccak256(abi.encode(tokenA, tokenB));
        return keccak256(abi.encode(tokenB, tokenA));
    }
}
