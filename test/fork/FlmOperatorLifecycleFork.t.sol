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
import {MockFutarchyProposalLike} from "../mocks/MockFutarchyProposalLike.sol";

interface IGnosisConditionalTokens is IFutarchyConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

interface ICanonicalWrapped1155FactoryView {
    function factory() external view returns (address);
}

interface IAlgebraFactoryCreator is IAlgebraFactoryLike {
    function createPool(address tokenA, address tokenB) external returns (address pool);
}

/// @dev A real Gnosis CTF/Algebra lifecycle with a local binary condition. The router is a fresh
/// repo deployment backed by the live CTF and canonical Wrapped1155 factory because the supplied
/// live router lacks the frozen source's dependency-getter ABI. The condition id is computed as
/// CTF.getConditionId(address(this), QUESTION_ID, 2), so it cannot be mistaken for Seer's.
contract FlmOperatorLifecycleForkTest is Test {
    uint256 internal constant GNOSIS_FORK_BLOCK = 47_439_000;
    uint256 internal constant GNOSIS_BLOCK_GAS_LIMIT = 17_000_000;
    uint256 internal constant MIN_DEPLOYMENT_GAS_HEADROOM = 3_000_000;
    uint256 internal constant MIN_ACTIVATION_GAS_HEADROOM = 1_000_000;
    uint256 internal constant BOOTSTRAP_GNO = 10 ether;
    uint256 internal constant BOOTSTRAP_SDAI = 859 ether;
    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    address internal constant OPERATOR_SAFE = 0x63f539CA3D8dad592c7050D205cdf079AfF830f6;
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant SDAI = 0xaf204776c7245bF4147c2612BF6e5972Ee483701;
    address internal constant CTF = 0xCeAfDD6bc0bEF976fdCd1112955828E00543c0Ce;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;
    address internal constant LIVE_PROPOSAL = 0x1D1F3b43F3C61b815041E9092b1bA7Ca37C63262;
    address internal constant ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant ALGEBRA_NFPM = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    bytes32 internal constant QUESTION_ID = keccak256("FLM Gnosis operator-mode fork fixture v1");

    struct Fixture {
        IGnosisConditionalTokens ctf;
        FutarchyOfficialProposalSource source;
        SwaprAlgebraLiquidityAdapter spot;
        SwaprAlgebraDirectConditionalAdapter conditional;
        FutarchyLiquidityManager manager;
        MockFutarchyProposalLike proposal;
        bytes32 conditionId;
        address router;
        address[4] outcomes;
    }

    function testFork_operatorSafeCompletesRealCtfAlgebraLifecycleWithinGasMargins() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture);

        bytes memory activationCall = abi.encodeWithSelector(
            FutarchyOfficialProposalSource.setOfficialProposal.selector,
            uint256(1),
            address(fixture.proposal),
            OPERATOR_SAFE
        );
        uint256 gasBefore = gasleft();
        vm.prank(OPERATOR_SAFE);
        fixture.source.setOfficialProposal(1, address(fixture.proposal), OPERATOR_SAFE);
        uint256 activationGas = gasBefore - gasleft() + 21_000 + (activationCall.length * 16);
        emit log_named_uint("operator activation conservative transaction gas", activationGas);
        assertLt(
            activationGas + MIN_ACTIVATION_GAS_HEADROOM,
            GNOSIS_BLOCK_GAS_LIMIT,
            "activation lacks 1M Gnosis gas headroom"
        );

        assertTrue(fixture.manager.inConditionalMode());
        assertEq(fixture.manager.activeConditionId(), fixture.conditionId);
        assertGt(fixture.manager.conditionalYesLiquidity(), 0);
        assertGt(fixture.manager.conditionalNoLiquidity(), 0);
        assertGt(fixture.manager.activeYesPool().code.length, 0);
        assertGt(fixture.manager.activeNoPool().code.length, 0);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        fixture.ctf.reportPayouts(QUESTION_ID, payouts);
        assertEq(
            uint256(fixture.manager.sync()),
            uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot)
        );
        assertFalse(fixture.manager.inConditionalMode());

        uint256 safeGnoBefore = IERC20(GNO).balanceOf(OPERATOR_SAFE);
        uint256 safeSdaiBefore = IERC20(SDAI).balanceOf(OPERATOR_SAFE);
        uint256 shares = fixture.manager.balanceOf(OPERATOR_SAFE);
        vm.prank(OPERATOR_SAFE);
        fixture.manager.redeem(shares, OPERATOR_SAFE, false);
        assertEq(fixture.manager.totalSupply(), 0);
        assertEq(fixture.manager.spotLiquidity(), 0);
        assertGt(IERC20(GNO).balanceOf(OPERATOR_SAFE), safeGnoBefore);
        assertGt(IERC20(SDAI).balanceOf(OPERATOR_SAFE), safeSdaiBefore);
    }

    function testFork_firstCtfSplitRevertRestoresOperatorState() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture);

        bytes memory fault = abi.encodeWithSignature("Error(string)", "first CTF split fault");
        vm.mockCallRevert(
            CTF,
            abi.encodePacked(
                IFutarchyConditionalTokens.splitPosition.selector, bytes32(uint256(uint160(GNO)))
            ),
            fault
        );
        _assertActivationRollback(fixture, fault);
        vm.clearMockedCalls();
    }

    function testFork_poolCreateRevertRestoresOperatorState() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture);

        bytes memory fault =
            abi.encodeWithSignature("Error(string)", "first Algebra pool create fault");
        vm.mockCallRevert(ALGEBRA_FACTORY, IAlgebraFactoryCreator.createPool.selector, fault);
        _assertActivationRollback(fixture, fault);
        vm.clearMockedCalls();
    }

    function testFork_firstMintRevertRestoresOperatorState() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        Fixture memory fixture = _newFixture();
        _bootstrap(fixture);

        // This callback is reached only by the first newly-created Algebra pool's mint.
        bytes memory fault = abi.encodeWithSignature("Error(string)", "first Algebra mint fault");
        vm.mockCallRevert(
            address(fixture.conditional),
            SwaprAlgebraDirectConditionalAdapter.algebraMintCallback.selector,
            fault
        );
        _assertActivationRollback(fixture, fault);
        vm.clearMockedCalls();
    }

    function _newFixture() private returns (Fixture memory fixture) {
        vm.createSelectFork(
            vm.envOr("GNOSIS_RPC_URL", string("https://rpc.gnosischain.com")), GNOSIS_FORK_BLOCK
        );
        assertGt(OPERATOR_SAFE.code.length, 0, "operator Safe missing at pinned block");
        assertGt(GNO.code.length, 0);
        assertGt(SDAI.code.length, 0);
        assertGt(CTF.code.length, 0);
        assertGt(FUTARCHY_ROUTER.code.length, 0);
        assertGt(LIVE_PROPOSAL.code.length, 0);
        assertGt(ALGEBRA_FACTORY.code.length, 0);
        assertGt(ALGEBRA_NFPM.code.length, 0);

        fixture.ctf = IGnosisConditionalTokens(CTF);
        // The production router is not this repo's router implementation, so its dependency
        // getters are not part of the ABI. Derive the canonical factory from the supplied live
        // proposal's wrapper instead of assuming those getters exist.
        (address liveWrapper,) = IFutarchyProposalCore(LIVE_PROPOSAL).wrappedOutcome(0);
        IFutarchyWrapped1155Factory wrappedFactory =
            IFutarchyWrapped1155Factory(ICanonicalWrapped1155FactoryView(liveWrapper).factory());
        assertGt(address(wrappedFactory).code.length, 0, "router wrapper factory missing");

        FactoryCompatibleAlgebraPoolStabilityGuard guard =
            new FactoryCompatibleAlgebraPoolStabilityGuard(IAlgebraFactoryLike(ALGEBRA_FACTORY));
        guard.GUARD().assertStablePair(GNO, SDAI);
        fixture.router = address(new FutarchyConditionalRouter(fixture.ctf, wrappedFactory));
        FutarchyLiquidityManagerFactory factory = new FutarchyLiquidityManagerFactory(
            ISwaprAlgebraPositionManager(ALGEBRA_NFPM),
            IAlgebraFactoryLike(ALGEBRA_FACTORY),
            IFutarchyConditionalRouter(fixture.router),
            guard,
            IWrappedNative(SDAI),
            FULL_RANGE_LOWER,
            FULL_RANGE_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
        FutarchyLiquidityManagerFactory.CreateParams memory params =
            FutarchyLiquidityManagerFactory.CreateParams({
                organization: OPERATOR_SAFE,
                owner: OPERATOR_SAFE,
                proposalManager: OPERATOR_SAFE,
                bootstrapRecipient: OPERATOR_SAFE,
                companyToken: IERC20(GNO),
                officialProposer: OPERATOR_SAFE,
                lpTokenName: "Gnosis Operator FLM",
                lpTokenSymbol: "GO-FLM",
                proposalValidationConfigData: abi.encode(
                    FutarchyOfficialProposalSource.ProposalValidationConfig({
                        enabled: true,
                        expectedProposalToken: GNO,
                        expectedCollateralToken: SDAI,
                        conditionalTokens: CTF,
                        trustedOracle: address(this),
                        realitio: address(0),
                        trustedArbitrator: address(0),
                        maxOpeningDelay: 0,
                        minTimeout: 0,
                        maxTimeout: 0,
                        minConditionalLifetime: 0,
                        maxMinBond: 0
                    })
                )
            });
        FutarchyLiquidityManagerFactory.CreationCodes memory codes =
            FutarchyLiquidityManagerFactory.CreationCodes({
                proposalSource: type(FutarchyOfficialProposalSource).creationCode,
                spotAdapter: type(SwaprAlgebraLiquidityAdapter).creationCode,
                conditionalAdapter: type(SwaprAlgebraDirectConditionalAdapter).creationCode,
                manager: type(FutarchyLiquidityManager).creationCode
            });
        bytes memory deploymentCall = abi.encodeWithSelector(
            FutarchyLiquidityManagerFactory.createLiquidityManager.selector, params, codes
        );
        uint256 gasBefore = gasleft();
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(params, codes);
        uint256 deploymentGas = gasBefore - gasleft() + 21_000 + (deploymentCall.length * 16);
        emit log_named_uint("operator bundle conservative transaction gas", deploymentGas);
        assertLt(
            deploymentGas + MIN_DEPLOYMENT_GAS_HEADROOM,
            GNOSIS_BLOCK_GAS_LIMIT,
            "bundle lacks 3M Gnosis gas headroom"
        );

        fixture.source = FutarchyOfficialProposalSource(deployed.proposalSource);
        fixture.spot = SwaprAlgebraLiquidityAdapter(deployed.spotAdapter);
        fixture.conditional = SwaprAlgebraDirectConditionalAdapter(deployed.conditionalAdapter);
        fixture.manager = FutarchyLiquidityManager(payable(deployed.manager));
        assertEq(fixture.manager.BOOTSTRAP_RECIPIENT(), OPERATOR_SAFE);

        fixture.ctf.prepareCondition(address(this), QUESTION_ID, 2);
        fixture.conditionId = fixture.ctf.getConditionId(address(this), QUESTION_ID, 2);
        fixture.outcomes[0] = _wrapper(fixture.ctf, wrappedFactory, GNO, fixture.conditionId, 1);
        fixture.outcomes[1] = _wrapper(fixture.ctf, wrappedFactory, GNO, fixture.conditionId, 2);
        fixture.outcomes[2] = _wrapper(fixture.ctf, wrappedFactory, SDAI, fixture.conditionId, 1);
        fixture.outcomes[3] = _wrapper(fixture.ctf, wrappedFactory, SDAI, fixture.conditionId, 2);
        fixture.proposal = new MockFutarchyProposalLike(
            GNO,
            SDAI,
            fixture.outcomes[0],
            fixture.outcomes[1],
            fixture.outcomes[2],
            fixture.outcomes[3]
        );
        fixture.proposal.setQuestionAndCondition(QUESTION_ID, fixture.conditionId);
    }

    function _bootstrap(Fixture memory fixture) private {
        deal(GNO, OPERATOR_SAFE, 2 * BOOTSTRAP_GNO);
        deal(SDAI, OPERATOR_SAFE, 2 * BOOTSTRAP_SDAI);
        vm.startPrank(OPERATOR_SAFE);
        IERC20(GNO).approve(address(fixture.manager), BOOTSTRAP_GNO);
        IERC20(SDAI).approve(address(fixture.manager), BOOTSTRAP_SDAI);
        fixture.manager.initializeFromBootstrap(BOOTSTRAP_GNO, BOOTSTRAP_SDAI);
        vm.stopPrank();

        assertGt(fixture.manager.spotLiquidity(), 0);
        assertGt(fixture.spot.getPositionTokenId(GNO, SDAI), 0);
        assertEq(fixture.manager.balanceOf(OPERATOR_SAFE), fixture.manager.totalSupply());
    }

    function _assertActivationRollback(Fixture memory fixture, bytes memory fault) private {
        uint128 spotLiquidityBefore = fixture.manager.spotLiquidity();
        uint256 spotTokenIdBefore = fixture.spot.getPositionTokenId(GNO, SDAI);
        uint256 managerGnoBefore = IERC20(GNO).balanceOf(address(fixture.manager));
        uint256 managerSdaiBefore = IERC20(SDAI).balanceOf(address(fixture.manager));
        uint256 ctfGnoBefore = IERC20(GNO).balanceOf(CTF);
        uint256 ctfSdaiBefore = IERC20(SDAI).balanceOf(CTF);
        uint256 routerGnoBefore = IERC20(GNO).balanceOf(fixture.router);
        uint256 routerSdaiBefore = IERC20(SDAI).balanceOf(fixture.router);

        vm.expectRevert(fault);
        vm.prank(OPERATOR_SAFE);
        fixture.source.setOfficialProposal(1, address(fixture.proposal), OPERATOR_SAFE);

        assertFalse(fixture.source.officialProposalExtended().exists);
        assertFalse(fixture.manager.inConditionalMode());
        assertEq(fixture.manager.spotLiquidity(), spotLiquidityBefore);
        assertEq(fixture.spot.getPositionTokenId(GNO, SDAI), spotTokenIdBefore);
        assertEq(IERC20(GNO).balanceOf(address(fixture.manager)), managerGnoBefore);
        assertEq(IERC20(SDAI).balanceOf(address(fixture.manager)), managerSdaiBefore);
        assertEq(IERC20(GNO).balanceOf(CTF), ctfGnoBefore);
        assertEq(IERC20(SDAI).balanceOf(CTF), ctfSdaiBefore);
        assertEq(IERC20(GNO).balanceOf(fixture.router), routerGnoBefore);
        assertEq(IERC20(SDAI).balanceOf(fixture.router), routerSdaiBefore);
        assertEq(fixture.manager.conditionalYesLiquidity(), 0);
        assertEq(fixture.manager.conditionalNoLiquidity(), 0);
        assertEq(
            fixture.conditional
            .positionLiquidity(_pairKey(fixture.outcomes[0], fixture.outcomes[2])),
            0
        );
        assertEq(
            fixture.conditional
            .positionLiquidity(_pairKey(fixture.outcomes[1], fixture.outcomes[3])),
            0
        );
        assertEq(
            fixture.conditional.poolByPair(fixture.outcomes[0], fixture.outcomes[2]), address(0)
        );
        assertEq(
            fixture.conditional.poolByPair(fixture.outcomes[1], fixture.outcomes[3]), address(0)
        );
    }

    function _wrapper(
        IGnosisConditionalTokens ctf,
        IFutarchyWrapped1155Factory factory,
        address collateral,
        bytes32 conditionId,
        uint256 indexSet
    ) private returns (address) {
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, indexSet);
        uint256 tokenId = ctf.getPositionId(collateral, collectionId);
        bytes memory data =
            abi.encodePacked(_toString31("OUTCOME"), _toString31("OUTCOME"), uint8(18));
        return factory.requireWrapped1155(address(ctf), tokenId, data);
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        return tokenA < tokenB
            ? keccak256(abi.encode(tokenA, tokenB))
            : keccak256(abi.encode(tokenB, tokenA));
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
