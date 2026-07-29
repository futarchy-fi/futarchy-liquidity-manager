// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    SwaprAlgebraDirectConditionalAdapter
} from "../../src/adapters/SwaprAlgebraDirectConditionalAdapter.sol";
import {SwaprAlgebraLiquidityAdapter} from "../../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {FLMMarketLauncher} from "../../src/factories/FLMMarketLauncher.sol";
import {
    FutarchyLiquidityManagerFactory
} from "../../src/factories/FutarchyLiquidityManagerFactory.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {IFutarchyProposalCore} from "../../src/interfaces/IFutarchyTradingCore.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {FutarchyConditionalRouter} from "../../src/routers/FutarchyConditionalRouter.sol";
import {FutarchyOfficialProposalSource} from "../../src/sources/FutarchyOfficialProposalSource.sol";
import {
    FactoryCompatibleAlgebraPoolStabilityGuard
} from "../mocks/FactoryCompatibleAlgebraPoolStabilityGuard.sol";

interface ILauncherCanonicalWrapped1155FactoryView {
    function factory() external view returns (address);
}

interface ILauncherAlgebraPoolTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract LauncherForkOrganization {
    address internal immutable OWNER = msg.sender;
    mapping(address => bool) public editor;
    uint256 public metadataCount;

    function setEditor(address account) external {
        require(msg.sender == OWNER, "not owner");
        editor[account] = true;
    }

    function createAndAddProposalMetadata(
        address,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        string calldata
    ) external returns (address metadataContract) {
        require(editor[msg.sender], "not editor");
        metadataContract = address(uint160(0xD000 + ++metadataCount));
    }
}

/// @dev Real Gnosis FutarchyFactory proposal creation plus a fresh local FLM stack.
contract FlmLauncherOneSigForkTest is Test {
    uint256 internal constant GNOSIS_FORK_BLOCK = 47_439_000;
    uint256 internal constant BOOTSTRAP_GNO = 10 ether;
    uint256 internal constant BOOTSTRAP_SDAI = 859 ether;
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
    address internal constant CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;
    address internal constant FUTARCHY_FACTORY = 0xa6cB18FCDC17a2B44E5cAd2d80a6D5942d30a345;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;
    address internal constant LIVE_PROPOSAL = 0x1D1F3b43F3C61b815041E9092b1bA7Ca37C63262;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant ALGEBRA_NFPM = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant REALITIO = 0xE78996A233895bE74a66F451f1019cA9734205cc;
    address internal constant REALITY_PROXY = 0xb5786fa17CC3E262d855240a074978C133438e7B;
    address internal constant ARBITRATOR = 0x68154EA682f95BF582b80Dd6453FA401737491Dc;

    struct Fixture {
        FLMMarketLauncher launcher;
        LauncherForkOrganization organization;
        FutarchyOfficialProposalSource source;
        FutarchyLiquidityManager manager;
    }

    function testFork_ownerLaunchesVisibleMarketAndConditionalFlpRedeems() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture.manager);

        FLMMarketLauncher.MarketParams memory p = _params(uint32(block.timestamp + 1 days));
        (address proposal,, uint256 proposalId) = fixture.launcher.launchMarket(p);

        assertEq(proposalId, 0);
        assertEq(fixture.organization.metadataCount(), 1);
        assertTrue(fixture.manager.inConditionalMode());
        (address yesCompany,) = IFutarchyProposalCore(proposal).wrappedOutcome(0);
        (address noCompany,) = IFutarchyProposalCore(proposal).wrappedOutcome(1);
        (address yesCurrency,) = IFutarchyProposalCore(proposal).wrappedOutcome(2);
        (address noCurrency,) = IFutarchyProposalCore(proposal).wrappedOutcome(3);
        _assertPoolPair(fixture.manager.activeYesPool(), yesCompany, yesCurrency);
        _assertPoolPair(fixture.manager.activeNoPool(), noCompany, noCurrency);
        assertNotEq(fixture.manager.activeYesPool(), fixture.manager.activeNoPool());

        uint256 supplyBefore = fixture.manager.totalSupply();
        uint256 shares = supplyBefore / 2;
        uint256 gnoBefore = IERC20(GNO).balanceOf(address(this));
        uint256 sdaiBefore = IERC20(SDAI).balanceOf(address(this));
        (uint256 gnoOut, uint256 sdaiOut) = fixture.manager.redeem(shares, address(this), false);
        assertEq(fixture.manager.totalSupply(), supplyBefore - shares);
        assertGt(gnoOut, 0);
        assertGt(sdaiOut, 0);
        assertEq(IERC20(GNO).balanceOf(address(this)), gnoBefore + gnoOut);
        assertEq(IERC20(SDAI).balanceOf(address(this)), sdaiBefore + sdaiOut);
    }

    function testFork_unboundedOpeningTimeMakesOneCallLaunchRevert() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture.manager);

        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyOfficialProposalSource.ProposalValidationFailed.selector,
                FutarchyOfficialProposalSource.ProposalValidationFailure.OpeningTimeTooFar
            )
        );
        fixture.launcher.launchMarket(_params(uint32(block.timestamp + 8 days)));

        assertEq(fixture.organization.metadataCount(), 0);
        assertEq(fixture.launcher.nextProposalId(), 0);
        assertFalse(fixture.source.officialProposalExtended().exists);
    }

    function _newFixture() private returns (Fixture memory fixture) {
        vm.createSelectFork(
            vm.envOr("GNOSIS_RPC_URL", string("https://rpc.gnosischain.com")), GNOSIS_FORK_BLOCK
        );
        assertGt(FUTARCHY_FACTORY.code.length, 0);
        assertGt(FUTARCHY_ROUTER.code.length, 0);
        assertGt(ALGEBRA_FACTORY.code.length, 0);

        fixture.launcher = new FLMMarketLauncher(address(this));
        fixture.organization = new LauncherForkOrganization();
        FactoryCompatibleAlgebraPoolStabilityGuard guard =
            new FactoryCompatibleAlgebraPoolStabilityGuard(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        guard.GUARD().assertStablePair(GNO, SDAI);
        (address liveWrapper,) = IFutarchyProposalCore(LIVE_PROPOSAL).wrappedOutcome(0);
        IFutarchyWrapped1155Factory wrappedFactory = IFutarchyWrapped1155Factory(
            ILauncherCanonicalWrapped1155FactoryView(liveWrapper).factory()
        );
        FutarchyConditionalRouter router =
            new FutarchyConditionalRouter(IFutarchyConditionalTokens(CTF), wrappedFactory);
        FutarchyLiquidityManagerFactory factory = new FutarchyLiquidityManagerFactory(
            ISwaprAlgebraPositionManager(ALGEBRA_NFPM),
            IAlgebraFactoryLike(ALGEBRA_FACTORY),
            IFutarchyConditionalRouter(address(router)),
            guard,
            IWrappedNative(SDAI),
            FULL_RANGE_LOWER,
            FULL_RANGE_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(_createParams(fixture.launcher), _creationCodes());
        fixture.source = FutarchyOfficialProposalSource(deployed.proposalSource);
        fixture.manager = FutarchyLiquidityManager(payable(deployed.manager));

        fixture.launcher
            .bind(
                address(fixture.source),
                address(fixture.manager),
                FUTARCHY_FACTORY,
                address(fixture.organization),
                GNO,
                SDAI,
                "governance",
                "en_US"
            );
        fixture.organization.setEditor(address(fixture.launcher));
        vm.deal(address(fixture.launcher), 10 ether);
    }

    function _createParams(FLMMarketLauncher launcher)
        private
        view
        returns (FutarchyLiquidityManagerFactory.CreateParams memory)
    {
        return FutarchyLiquidityManagerFactory.CreateParams({
            organization: address(0x100),
            owner: address(this),
            proposalManager: address(launcher),
            bootstrapRecipient: address(this),
            companyToken: IERC20(GNO),
            officialProposer: address(launcher),
            lpTokenName: "Gnosis launcher fLP",
            lpTokenSymbol: "GL-fLP",
            proposalValidationConfigData: abi.encode(
                FutarchyOfficialProposalSource.ProposalValidationConfig({
                    enabled: true,
                    expectedProposalToken: GNO,
                    expectedCollateralToken: SDAI,
                    conditionalTokens: CTF,
                    trustedOracle: REALITY_PROXY,
                    realitio: REALITIO,
                    trustedArbitrator: ARBITRATOR,
                    maxOpeningDelay: 7 days,
                    minTimeout: 1 hours,
                    maxTimeout: 7 days,
                    minConditionalLifetime: 1 days,
                    maxMinBond: 1 ether
                })
            )
        });
    }

    function _creationCodes()
        private
        pure
        returns (FutarchyLiquidityManagerFactory.CreationCodes memory)
    {
        return FutarchyLiquidityManagerFactory.CreationCodes({
            proposalSource: type(FutarchyOfficialProposalSource).creationCode,
            spotAdapter: type(SwaprAlgebraLiquidityAdapter).creationCode,
            conditionalAdapter: type(SwaprAlgebraDirectConditionalAdapter).creationCode,
            manager: type(FutarchyLiquidityManager).creationCode
        });
    }

    function _bootstrap(FutarchyLiquidityManager manager) private {
        deal(GNO, address(this), BOOTSTRAP_GNO);
        deal(SDAI, address(this), BOOTSTRAP_SDAI);
        IERC20(GNO).approve(address(manager), BOOTSTRAP_GNO);
        IERC20(SDAI).approve(address(manager), BOOTSTRAP_SDAI);
        manager.initializeFromBootstrap(BOOTSTRAP_GNO, BOOTSTRAP_SDAI);
        assertGt(manager.totalSupply(), 0);
    }

    function _params(uint32 openingTime)
        private
        pure
        returns (FLMMarketLauncher.MarketParams memory)
    {
        return FLMMarketLauncher.MarketParams({
            marketName: "FLM launcher fork test",
            minBond: 1 ether,
            openingTime: openingTime,
            displayNameQuestion: "Does the FLM launcher activate?",
            displayNameEvent: "FLM launcher",
            description: "Fork-only integration test",
            metadataJson: '{"chain":100,"invertTwapPool":false,"currency_stable_rate":1}'
        });
    }

    function _assertPoolPair(address pool, address tokenA, address tokenB) private view {
        assertGt(pool.code.length, 0);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        assertEq(ILauncherAlgebraPoolTokens(pool).token0(), token0);
        assertEq(ILauncherAlgebraPoolTokens(pool).token1(), token1);
    }
}
