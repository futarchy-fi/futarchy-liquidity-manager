// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter
} from "../../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../../src/adapters/UniswapV3LiquidityAdapter.sol";
import {V4InitializationGate, V4PoolKey} from "../../src/adapters/V4InitializationGate.sol";
import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {
    V4FutarchyLiquidityManagerFactory
} from "../../src/factories/V4FutarchyLiquidityManagerFactory.sol";
import {
    IFutarchyConditionalTokens,
    IFutarchyWrapped1155Factory
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {IUniswapV3FactoryLike} from "../../src/interfaces/IUniswapV3FactoryLike.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {UniV3PoolStabilityGuard} from "../../src/oracles/UniV3PoolStabilityGuard.sol";
import {
    FutarchyConditionalRouter,
    ICanonicalWrapped1155
} from "../../src/routers/FutarchyConditionalRouter.sol";
import {FutarchyOfficialProposalSource} from "../../src/sources/FutarchyOfficialProposalSource.sol";
import {MockFutarchyProposalLike} from "../mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";
import {
    IV4PoolManagerDonate,
    MainnetV4Donor
} from "./V4ConditionalLiquidityAdapterMainnetFork.t.sol";

interface IMainnetConditionalTokens is IFutarchyConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

interface IMainnetUniV3Pool {
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

contract V4FutarchyLiquidityManagerLifecycleMainnetForkTest is Test {
    enum ActivationFault {
        None,
        SpotRemoval,
        FirstCtfSplit,
        SecondCtfSplit,
        FirstWrapperMint,
        SecondAssetWrapperMint,
        FirstV4Initialize,
        FirstV4Liquidity,
        SecondV4Initialize,
        SecondV4Liquidity
    }

    uint256 private constant FORK_BLOCK = 25_542_490;
    uint256 private constant FORK_BLOCK_GAS_LIMIT = 60_000_000;
    uint256 private constant MAX_CONSERVATIVE_TRANSACTION_GAS = FORK_BLOCK_GAS_LIMIT / 2;
    uint256 private constant AMOUNT = 100 ether;
    uint256 private constant DONATION = 1 ether;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 private constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    int24 private constant TICK_LOWER = -887_270;
    int24 private constant TICK_UPPER = 887_270;

    address private constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 private constant POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    address private constant CONDITIONAL_TOKENS = 0xC59b0e4De5F1248C1140964E0fF287B192407E0C;
    bytes32 private constant CONDITIONAL_TOKENS_CODEHASH =
        0x710326c6e1e66bc95ad81734a3c08448d7aa9fd0636c4477003fdababc3d1c1c;
    address private constant WRAPPED_1155_FACTORY = 0xD194319D1804C1051DD21Ba1Dc931cA72410B79f;
    bytes32 private constant WRAPPED_1155_FACTORY_CODEHASH =
        0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6;
    address private constant SPOT_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    bytes32 private constant SPOT_POSITION_MANAGER_CODEHASH =
        0x692e658b31cbe3407682854806658d315d61a58c7e4933a2f91d383dc00736c6;
    address private constant SPOT_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    bytes32 private constant SPOT_FACTORY_CODEHASH =
        0x4d7b8525cd5d14343fa67a732fba5b24cddba11620ca88392f4ec6c52f91fd69;

    function testFork_factoryBundleCompletesRealCtfTwoPoolLifecycle() public {
        _runLifecycle(true, false, ActivationFault.None);
    }

    function testFork_singleLegDonationPaysZeroWhenThatLegLoses() public {
        _runLifecycle(false, false, ActivationFault.None);
    }

    function testFork_partialExitReturnsAsymmetricFeeInKind() public {
        _runLifecycle(true, true, ActivationFault.None);
    }

    function testFork_realCompanyMergeFailurePaysExactInKindAndRemainsRedeemable() public {
        _runLifecycle(true, false, ActivationFault.None, true, false);
    }

    function testFork_lateRealSettlementMergeFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.None, false, true);
    }

    function testFork_outsiderEmergencyExitSettlesAndPreservesAllShares() public {
        _runLifecycle(true, false, ActivationFault.None, false, false, true);
    }

    function testFork_spotRemovalFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.SpotRemoval);
    }

    function testFork_firstRealCtfSplitFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.FirstCtfSplit);
    }

    function testFork_secondRealCtfSplitFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.SecondCtfSplit);
    }

    function testFork_firstRealWrapperMintFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.FirstWrapperMint);
    }

    function testFork_secondAssetRealWrapperMintFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.SecondAssetWrapperMint);
    }

    function testFork_firstRealV4InitializeFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.FirstV4Initialize);
    }

    function testFork_firstRealV4LiquidityFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.FirstV4Liquidity);
    }

    function testFork_secondRealV4InitializeFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.SecondV4Initialize);
    }

    function testFork_secondRealV4LiquidityFailureRollsBackAndRetrySucceeds() public {
        _runLifecycle(true, false, ActivationFault.SecondV4Liquidity);
    }

    function _runLifecycle(bool yesWins, bool singleLegBeforeExit, ActivationFault activationFault)
        private
    {
        _runLifecycle(yesWins, singleLegBeforeExit, activationFault, false, false);
    }

    function _runLifecycle(
        bool yesWins,
        bool singleLegBeforeExit,
        ActivationFault activationFault,
        bool companyMergeFault,
        bool settlementMergeFault
    ) private {
        _runLifecycle(
            yesWins,
            singleLegBeforeExit,
            activationFault,
            companyMergeFault,
            settlementMergeFault,
            false
        );
    }

    function _runLifecycle(
        bool yesWins,
        bool singleLegBeforeExit,
        ActivationFault activationFault,
        bool companyMergeFault,
        bool settlementMergeFault,
        bool emergencyLifecycle
    ) private {
        if (!vm.envOr("RUN_MAINNET_FORK_TESTS", false)) return;
        vm.createSelectFork(
            vm.envOr("MAINNET_RPC_URL", string("https://rpc.mevblocker.io")), FORK_BLOCK
        );
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);
        assertEq(CONDITIONAL_TOKENS.codehash, CONDITIONAL_TOKENS_CODEHASH);
        assertEq(WRAPPED_1155_FACTORY.codehash, WRAPPED_1155_FACTORY_CODEHASH);
        assertEq(SPOT_POSITION_MANAGER.codehash, SPOT_POSITION_MANAGER_CODEHASH);
        assertEq(SPOT_FACTORY.codehash, SPOT_FACTORY_CODEHASH);
        assertEq(block.gaslimit, FORK_BLOCK_GAS_LIMIT);

        IMainnetConditionalTokens ctf = IMainnetConditionalTokens(CONDITIONAL_TOKENS);
        IFutarchyWrapped1155Factory wrapperFactory =
            IFutarchyWrapped1155Factory(WRAPPED_1155_FACTORY);
        FutarchyConditionalRouter router = new FutarchyConditionalRouter(ctf, wrapperFactory);
        MockMintableERC20 company = new MockMintableERC20("Company", "COMP");
        MockMintableERC20 collateral = new MockMintableERC20("Collateral", "COLL");
        IUniswapV3NonfungiblePositionManager spotPositionManager =
            IUniswapV3NonfungiblePositionManager(SPOT_POSITION_MANAGER);
        assertEq(spotPositionManager.factory(), SPOT_FACTORY);
        (address spotToken0, address spotToken1) = address(company) < address(collateral)
            ? (address(company), address(collateral))
            : (address(collateral), address(company));
        address spotPool = spotPositionManager.createAndInitializePoolIfNecessary(
            spotToken0, spotToken1, 500, uint160(1 << 96)
        );
        assertGt(spotPool.code.length, 0);
        IMainnetUniV3Pool(spotPool).increaseObservationCardinalityNext(2);
        vm.warp(block.timestamp + 30 minutes + 1);
        UniV3PoolStabilityGuard guard =
            new UniV3PoolStabilityGuard(IUniswapV3FactoryLike(SPOT_FACTORY), 500);

        V4FutarchyLiquidityManagerFactory factory = new V4FutarchyLiquidityManagerFactory(
            spotPositionManager,
            IV4PoolManagerMinimal(POOL_MANAGER),
            POOL_MANAGER_CODEHASH,
            IFutarchyConditionalRouter(address(router)),
            guard,
            IWrappedNative(address(collateral)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(UniswapV3LiquidityAdapter).creationCode),
            keccak256(type(V4InitializationGate).creationCode),
            keccak256(type(V4ConditionalLiquidityAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );

        bytes32 questionId = keccak256("FLM mainnet lifecycle fixture");
        ctf.prepareCondition(address(this), questionId, 2);
        bytes32 conditionId = ctf.getConditionId(address(this), questionId, 2);
        FutarchyOfficialProposalSource.ProposalValidationConfig memory validation =
            FutarchyOfficialProposalSource.ProposalValidationConfig({
                enabled: true,
                expectedProposalToken: address(company),
                expectedCollateralToken: address(collateral),
                conditionalTokens: address(ctf),
                trustedOracle: address(this),
                realitio: address(0),
                trustedArbitrator: address(0),
                maxOpeningDelay: 0,
                minTimeout: 0,
                maxTimeout: 0,
                minConditionalLifetime: 0,
                maxMinBond: 0
            });
        bytes32 rawSalt = _findHookSalt(factory);
        V4FutarchyLiquidityManagerFactory.CreateParams memory createParams =
            V4FutarchyLiquidityManagerFactory.CreateParams({
                organization: address(0xFA0),
                owner: address(this),
                proposalManager: address(this),
                bootstrapRecipient: address(this),
                companyToken: company,
                officialProposer: address(this),
                lpTokenName: "Mainnet Lifecycle FLM",
                lpTokenSymbol: "ML-FLM",
                proposalValidationConfigData: abi.encode(validation),
                hookSalt: rawSalt
            });
        V4FutarchyLiquidityManagerFactory.CreationCodes memory creationCodes = _creationCodes();
        bytes memory factoryCalldata = abi.encodeWithSelector(
            V4FutarchyLiquidityManagerFactory.createLiquidityManager.selector,
            createParams,
            creationCodes
        );
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory predicted =
            factory.predictBundleAddresses(address(this), createParams, creationCodes);
        uint256 gasBefore = gasleft();
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(createParams, creationCodes);
        uint256 factoryTransactionGas =
            gasBefore - gasleft() + 21_000 + (factoryCalldata.length * 16);
        emit log_named_uint("conservative factory transaction gas", factoryTransactionGas);
        assertLt(
            factoryTransactionGas,
            MAX_CONSERVATIVE_TRANSACTION_GAS,
            "factory transaction has less than half-block headroom"
        );
        assertEq(deployed.proposalSource, predicted.proposalSource);
        assertEq(deployed.spotAdapter, predicted.spotAdapter);
        assertEq(deployed.initializationGate, predicted.initializationGate);
        assertEq(deployed.conditionalAdapter, predicted.conditionalAdapter);
        assertEq(deployed.manager, predicted.manager);

        V4ConditionalLiquidityAdapter conditional =
            V4ConditionalLiquidityAdapter(deployed.conditionalAdapter);
        UniswapV3LiquidityAdapter spot = UniswapV3LiquidityAdapter(deployed.spotAdapter);
        FutarchyOfficialProposalSource source =
            FutarchyOfficialProposalSource(deployed.proposalSource);
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(deployed.manager));
        assertEq(address(source.ALGEBRA_FACTORY()), address(conditional));

        address yesCompany = _wrapper(ctf, wrapperFactory, address(company), conditionId, 1);
        address noCompany = _wrapper(ctf, wrapperFactory, address(company), conditionId, 2);
        address yesCollateral = _wrapper(ctf, wrapperFactory, address(collateral), conditionId, 1);
        address noCollateral = _wrapper(ctf, wrapperFactory, address(collateral), conditionId, 2);
        MockFutarchyProposalLike proposal = new MockFutarchyProposalLike(
            address(company),
            address(collateral),
            yesCompany,
            noCompany,
            yesCollateral,
            noCollateral
        );
        proposal.setQuestionAndCondition(questionId, conditionId);

        company.mint(address(this), AMOUNT);
        collateral.mint(address(this), AMOUNT);
        company.approve(address(manager), AMOUNT);
        collateral.approve(address(manager), AMOUNT);
        manager.initializeFromBootstrap(AMOUNT, AMOUNT);
        if (activationFault != ActivationFault.None) {
            _exerciseActivationRollback(
                activationFault,
                source,
                proposal,
                router,
                manager,
                spot,
                conditional,
                company,
                collateral,
                [yesCompany, noCompany, yesCollateral, noCollateral]
            );
            return;
        }
        bytes memory activationCalldata = abi.encodeWithSelector(
            FutarchyOfficialProposalSource.setOfficialProposal.selector,
            uint256(1),
            address(proposal),
            address(this)
        );
        gasBefore = gasleft();
        source.setOfficialProposal(1, address(proposal), address(this));
        uint256 activationTransactionGas =
            gasBefore - gasleft() + 21_000 + (activationCalldata.length * 16);
        emit log_named_uint("conservative activation transaction gas", activationTransactionGas);
        assertLt(
            activationTransactionGas,
            MAX_CONSERVATIVE_TRANSACTION_GAS,
            "activation transaction has less than half-block headroom"
        );

        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeConditionId(), conditionId);
        assertEq(manager.activeYesPool(), POOL_MANAGER);
        assertEq(manager.activeNoPool(), POOL_MANAGER);
        assertGt(conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral)), 0);
        assertGt(conditional.positionLiquidity(_pairKey(noCompany, noCollateral)), 0);
        assertEq(source.officialProposalExtended().yesPool, POOL_MANAGER);
        assertEq(source.officialProposalExtended().noPool, POOL_MANAGER);

        MainnetV4Donor donor = new MainnetV4Donor(IV4PoolManagerDonate(POOL_MANAGER));
        company.mint(address(this), DONATION);
        collateral.mint(address(this), DONATION);
        company.approve(address(router), DONATION);
        collateral.approve(address(router), DONATION);
        router.splitPositionPairTo(
            conditionId,
            address(company),
            yesCompany,
            noCompany,
            DONATION,
            address(collateral),
            yesCollateral,
            noCollateral,
            DONATION,
            address(donor)
        );
        donor.donate(_v4PoolKey(conditional, yesCompany, yesCollateral), DONATION, DONATION);
        donor.donate(_v4PoolKey(conditional, noCompany, noCollateral), DONATION, DONATION);
        assertEq(IERC20(yesCompany).balanceOf(address(donor)), 0);
        assertEq(IERC20(noCompany).balanceOf(address(donor)), 0);
        assertEq(IERC20(yesCollateral).balanceOf(address(donor)), 0);
        assertEq(IERC20(noCollateral).balanceOf(address(donor)), 0);
        if (emergencyLifecycle) {
            _exerciseEmergencyLifecycle(
                ctf,
                source,
                proposal,
                manager,
                spot,
                conditional,
                company,
                collateral,
                questionId,
                conditionId,
                [yesCompany, noCompany, yesCollateral, noCollateral]
            );
            return;
        }
        if (singleLegBeforeExit) {
            _donateSingleYesCompany(
                company,
                router,
                conditionId,
                yesCompany,
                noCompany,
                conditional,
                yesCollateral,
                donor
            );
        }

        uint256 supplyBeforePartial = manager.totalSupply();
        uint256 partialShares = supplyBeforePartial / 3;
        address partialHolder = address(0xBEEF);
        assertTrue(manager.transfer(partialHolder, partialShares));
        uint256 spotTokenId = spot.getPositionTokenId(address(company), address(collateral));
        uint128 spotLiquidityBefore = manager.spotLiquidity();
        uint128 yesLiquidityBefore = manager.conditionalYesLiquidity();
        uint128 noLiquidityBefore = manager.conditionalNoLiquidity();
        bytes memory redemptionCalldata = abi.encodeWithSelector(
            FutarchyLiquidityManager.redeem.selector, partialShares, partialHolder, false
        );
        if (companyMergeFault) {
            vm.mockCallRevert(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    IFutarchyConditionalTokens.mergePositions.selector,
                    bytes32(uint256(uint160(address(company))))
                ),
                abi.encodeWithSignature("Error(string)", "injected merge fault")
            );
        }
        vm.prank(partialHolder);
        gasBefore = gasleft();
        (uint256 partialCompanyOut, uint256 partialCollateralOut) =
            manager.redeem(partialShares, partialHolder, false);
        uint256 redemptionTransactionGas =
            gasBefore - gasleft() + 21_000 + (redemptionCalldata.length * 16);
        emit log_named_uint(
            "conservative partial redemption transaction gas", redemptionTransactionGas
        );
        assertLt(
            redemptionTransactionGas,
            MAX_CONSERVATIVE_TRANSACTION_GAS,
            "partial redemption has less than half-block headroom"
        );

        uint256 expectedPartialOut = (AMOUNT + DONATION) * partialShares / supplyBeforePartial;
        assertEq(manager.totalSupply(), supplyBeforePartial - partialShares);
        assertEq(
            manager.spotLiquidity(),
            spotLiquidityBefore
                - uint128(uint256(spotLiquidityBefore) * partialShares / supplyBeforePartial)
        );
        assertEq(
            manager.conditionalYesLiquidity(),
            yesLiquidityBefore
                - uint128(uint256(yesLiquidityBefore) * partialShares / supplyBeforePartial)
        );
        assertEq(
            manager.conditionalNoLiquidity(),
            noLiquidityBefore
                - uint128(uint256(noLiquidityBefore) * partialShares / supplyBeforePartial)
        );
        assertEq(
            spot.getPositionTokenId(address(company), address(collateral)),
            spotTokenId,
            "partial redemption replaced spot NFT"
        );
        uint256 partialYesCompany = IERC20(yesCompany).balanceOf(partialHolder);
        if (companyMergeFault) {
            uint256 partialNoCompany = IERC20(noCompany).balanceOf(partialHolder);
            assertGt(partialYesCompany, 0);
            assertEq(partialNoCompany, partialYesCompany);
            assertEq(company.balanceOf(partialHolder), partialCompanyOut);
            assertEq(collateral.balanceOf(partialHolder), partialCollateralOut);
            assertLt(partialCompanyOut, expectedPartialOut);
            assertApproxEqAbs(partialCompanyOut + partialYesCompany, expectedPartialOut, 4);
            assertApproxEqAbs(partialCollateralOut, expectedPartialOut, 4);
            assertEq(IERC20(yesCollateral).balanceOf(partialHolder), 0);
            assertEq(IERC20(noCollateral).balanceOf(partialHolder), 0);

            vm.clearMockedCalls();
            uint256[] memory mergeFaultPayouts = new uint256[](2);
            mergeFaultPayouts[0] = 1;
            ctf.reportPayouts(questionId, mergeFaultPayouts);
            source.clearOfficialProposal();
            assertEq(
                uint256(manager.sync()),
                uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot)
            );

            vm.startPrank(partialHolder);
            IERC20(yesCompany).approve(address(router), partialYesCompany);
            router.redeemPositions(
                address(company), conditionId, yesCompany, noCompany, partialYesCompany
            );
            IERC20(noCompany).approve(address(router), partialNoCompany);
            router.consumeLosingPositions(
                address(company), conditionId, yesCompany, noCompany, partialNoCompany
            );
            vm.stopPrank();
            assertEq(IERC20(yesCompany).balanceOf(partialHolder), 0);
            assertEq(IERC20(noCompany).balanceOf(partialHolder), 0);
            assertEq(company.balanceOf(partialHolder), partialCompanyOut + partialYesCompany);

            manager.redeem(manager.balanceOf(address(this)), address(this), false);
            assertEq(manager.totalSupply(), 0);
            assertEq(manager.spotLiquidity(), 0);
            assertEq(spot.getPositionTokenId(address(company), address(collateral)), 0);
            assertApproxEqAbs(
                company.balanceOf(address(this)) + company.balanceOf(partialHolder),
                AMOUNT + DONATION,
                5
            );
            assertApproxEqAbs(
                collateral.balanceOf(address(this)) + collateral.balanceOf(partialHolder),
                AMOUNT + DONATION,
                5
            );
            return;
        }

        assertEq(company.balanceOf(partialHolder), partialCompanyOut);
        assertEq(collateral.balanceOf(partialHolder), partialCollateralOut);
        assertApproxEqAbs(
            partialCompanyOut, expectedPartialOut, 4, "company fees were not paid pro rata"
        );
        assertApproxEqAbs(
            partialCollateralOut, expectedPartialOut, 4, "collateral fees were not paid pro rata"
        );
        if (singleLegBeforeExit) {
            assertApproxEqAbs(
                partialYesCompany,
                DONATION * partialShares / supplyBeforePartial,
                4,
                "asymmetric fee was not paid in kind"
            );
        } else {
            assertEq(partialYesCompany, 0);
        }
        assertEq(IERC20(noCompany).balanceOf(partialHolder), 0);
        assertEq(IERC20(yesCollateral).balanceOf(partialHolder), 0);
        assertEq(IERC20(noCollateral).balanceOf(partialHolder), 0);

        company.mint(address(this), DONATION);
        collateral.mint(address(this), DONATION);
        company.approve(address(router), DONATION);
        collateral.approve(address(router), DONATION);
        router.splitPositionPairTo(
            conditionId,
            address(company),
            yesCompany,
            noCompany,
            DONATION,
            address(collateral),
            yesCollateral,
            noCollateral,
            DONATION,
            address(donor)
        );
        donor.donate(_v4PoolKey(conditional, yesCompany, yesCollateral), DONATION, DONATION);
        donor.donate(_v4PoolKey(conditional, noCompany, noCollateral), DONATION, DONATION);

        if (!singleLegBeforeExit) {
            _donateSingleYesCompany(
                company,
                router,
                conditionId,
                yesCompany,
                noCompany,
                conditional,
                yesCollateral,
                donor
            );
        }

        uint256[] memory payouts = new uint256[](2);
        payouts[yesWins ? 0 : 1] = 1;
        ctf.reportPayouts(questionId, payouts);
        source.clearOfficialProposal();
        if (settlementMergeFault) {
            uint128 yesPositionBefore =
                conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral));
            uint128 noPositionBefore =
                conditional.positionLiquidity(_pairKey(noCompany, noCollateral));
            uint256 companyManagerBefore = company.balanceOf(address(manager));
            uint256 collateralManagerBefore = collateral.balanceOf(address(manager));
            uint256 companyCtfBefore = company.balanceOf(CONDITIONAL_TOKENS);
            uint256 collateralCtfBefore = collateral.balanceOf(CONDITIONAL_TOKENS);
            address[4] memory settlementOutcomes =
                [yesCompany, noCompany, yesCollateral, noCollateral];
            uint256[4] memory suppliesBefore;
            uint256[4] memory managerBalancesBefore;
            uint256[4] memory poolManagerBalancesBefore;
            uint256[4] memory factoryUnderlyingBefore;
            uint256[4] memory routerAllowancesBefore;
            for (uint256 i; i < settlementOutcomes.length; ++i) {
                address outcome = settlementOutcomes[i];
                suppliesBefore[i] = IERC20(outcome).totalSupply();
                managerBalancesBefore[i] = IERC20(outcome).balanceOf(address(manager));
                poolManagerBalancesBefore[i] = IERC20(outcome).balanceOf(POOL_MANAGER);
                routerAllowancesBefore[i] =
                    IERC20(outcome).allowance(address(manager), address(router));
                factoryUnderlyingBefore[i] =
                    ctf.balanceOf(WRAPPED_1155_FACTORY, ICanonicalWrapped1155(outcome).tokenId());
            }

            bytes memory settlementFaultData =
                abi.encodeWithSignature("Error(string)", "injected settlement fault");
            vm.mockCallRevert(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    IFutarchyConditionalTokens.mergePositions.selector,
                    bytes32(uint256(uint160(address(collateral))))
                ),
                settlementFaultData
            );
            vm.expectCall(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    IFutarchyConditionalTokens.mergePositions.selector,
                    bytes32(uint256(uint160(address(company))))
                )
            );
            vm.expectCall(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    IFutarchyConditionalTokens.redeemPositions.selector,
                    bytes32(uint256(uint160(address(company))))
                )
            );
            vm.expectRevert(settlementFaultData);
            manager.sync();

            assertTrue(manager.inConditionalMode());
            assertEq(manager.activeProposal(), address(proposal));
            assertEq(manager.activeConditionId(), conditionId);
            assertEq(manager.conditionalYesLiquidity(), yesPositionBefore);
            assertEq(manager.conditionalNoLiquidity(), noPositionBefore);
            assertEq(
                conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral)),
                yesPositionBefore
            );
            assertEq(
                conditional.positionLiquidity(_pairKey(noCompany, noCollateral)), noPositionBefore
            );
            assertEq(company.balanceOf(address(manager)), companyManagerBefore);
            assertEq(collateral.balanceOf(address(manager)), collateralManagerBefore);
            assertEq(company.balanceOf(CONDITIONAL_TOKENS), companyCtfBefore);
            assertEq(collateral.balanceOf(CONDITIONAL_TOKENS), collateralCtfBefore);
            FutarchyOfficialProposalSource.OfficialProposal memory clearedOfficial =
                source.currentOfficialProposal();
            assertFalse(clearedOfficial.exists);
            for (uint256 i; i < settlementOutcomes.length; ++i) {
                address outcome = settlementOutcomes[i];
                assertEq(IERC20(outcome).totalSupply(), suppliesBefore[i]);
                assertEq(IERC20(outcome).balanceOf(address(manager)), managerBalancesBefore[i]);
                assertEq(IERC20(outcome).balanceOf(POOL_MANAGER), poolManagerBalancesBefore[i]);
                assertEq(
                    IERC20(outcome).allowance(address(manager), address(router)),
                    routerAllowancesBefore[i]
                );
                assertEq(
                    ctf.balanceOf(WRAPPED_1155_FACTORY, ICanonicalWrapped1155(outcome).tokenId()),
                    factoryUnderlyingBefore[i]
                );
            }
            vm.clearMockedCalls();
        }
        assertEq(
            uint256(manager.sync()), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot)
        );

        assertFalse(manager.inConditionalMode());
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral)), 0);
        assertEq(conditional.positionLiquidity(_pairKey(noCompany, noCollateral)), 0);

        uint256 remainingShares = manager.balanceOf(address(this));
        manager.redeem(remainingShares, address(this), false);
        assertEq(manager.totalSupply(), 0);
        assertEq(manager.spotLiquidity(), 0);
        assertEq(spot.getPositionTokenId(address(company), address(collateral)), 0);
        assertEq(company.balanceOf(partialHolder), partialCompanyOut);
        assertEq(collateral.balanceOf(partialHolder), partialCollateralOut);
        assertApproxEqAbs(
            company.balanceOf(address(this)) + company.balanceOf(partialHolder)
                + (yesWins ? partialYesCompany : 0),
            AMOUNT + ((yesWins ? 3 : 2) * DONATION),
            5
        );
        assertApproxEqAbs(
            collateral.balanceOf(address(this)) + collateral.balanceOf(partialHolder),
            AMOUNT + (2 * DONATION),
            5
        );
        assertEq(company.balanceOf(address(manager)), 0);
        assertEq(collateral.balanceOf(address(manager)), 0);
        assertEq(IERC20(noCompany).balanceOf(address(this)), DONATION);

        if (singleLegBeforeExit) {
            vm.startPrank(partialHolder);
            IERC20(yesCompany).approve(address(router), partialYesCompany);
            router.redeemPositions(
                address(company), conditionId, yesCompany, noCompany, partialYesCompany
            );
            vm.stopPrank();
            assertEq(IERC20(yesCompany).balanceOf(partialHolder), 0);
            assertApproxEqAbs(
                company.balanceOf(address(this)) + company.balanceOf(partialHolder),
                AMOUNT + (3 * DONATION),
                5
            );
        }
    }

    function _exerciseEmergencyLifecycle(
        IMainnetConditionalTokens ctf,
        FutarchyOfficialProposalSource source,
        MockFutarchyProposalLike proposal,
        FutarchyLiquidityManager manager,
        UniswapV3LiquidityAdapter spot,
        V4ConditionalLiquidityAdapter conditional,
        MockMintableERC20 company,
        MockMintableERC20 collateral,
        bytes32 questionId,
        bytes32 conditionId,
        address[4] memory outcomes
    ) private {
        address outsider = address(0xCAFE);
        uint256 supplyBefore = manager.totalSupply();
        uint256[6] memory outsiderBalancesBefore = [
            company.balanceOf(outsider),
            collateral.balanceOf(outsider),
            IERC20(outcomes[0]).balanceOf(outsider),
            IERC20(outcomes[1]).balanceOf(outsider),
            IERC20(outcomes[2]).balanceOf(outsider),
            IERC20(outcomes[3]).balanceOf(outsider)
        ];

        manager.armEmergencyExit();
        assertFalse(manager.emergencyExitReady());
        vm.warp(block.timestamp + manager.EMERGENCY_EXIT_DELAY());
        assertTrue(manager.emergencyExitReady());
        vm.prank(outsider);
        manager.executeEmergencyExit();

        assertTrue(manager.emergencyExitExecuted());
        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeProposal(), address(proposal));
        assertEq(manager.activeConditionId(), conditionId);
        assertEq(manager.totalSupply(), supplyBefore);
        assertEq(manager.balanceOf(outsider), 0);
        assertEq(manager.spotLiquidity(), 0);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(spot.getPositionTokenId(address(company), address(collateral)), 0);
        assertEq(conditional.positionLiquidity(_pairKey(outcomes[0], outcomes[2])), 0);
        assertEq(conditional.positionLiquidity(_pairKey(outcomes[1], outcomes[3])), 0);
        for (uint256 i; i < outcomes.length; ++i) {
            assertGt(IERC20(outcomes[i]).balanceOf(address(manager)), 0);
            assertEq(IERC20(outcomes[i]).balanceOf(outsider), outsiderBalancesBefore[i + 2]);
        }
        assertEq(company.balanceOf(outsider), outsiderBalancesBefore[0]);
        assertEq(collateral.balanceOf(outsider), outsiderBalancesBefore[1]);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        ctf.reportPayouts(questionId, payouts);
        source.clearOfficialProposal();
        vm.prank(outsider);
        assertEq(
            uint256(manager.sync()), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot)
        );

        assertFalse(manager.inConditionalMode());
        assertEq(manager.activeProposal(), address(0));
        assertEq(manager.activeConditionId(), bytes32(0));
        assertEq(manager.totalSupply(), supplyBefore);
        assertEq(manager.spotLiquidity(), 0);
        for (uint256 i; i < outcomes.length; ++i) {
            assertEq(IERC20(outcomes[i]).balanceOf(address(manager)), 0);
            assertEq(IERC20(outcomes[i]).balanceOf(outsider), outsiderBalancesBefore[i + 2]);
        }

        manager.redeem(supplyBefore, address(this), false);
        assertEq(manager.totalSupply(), 0);
        assertApproxEqAbs(company.balanceOf(address(this)), AMOUNT + DONATION, 5);
        assertApproxEqAbs(collateral.balanceOf(address(this)), AMOUNT + DONATION, 5);
        assertEq(company.balanceOf(address(manager)), 0);
        assertEq(collateral.balanceOf(address(manager)), 0);
        assertEq(company.balanceOf(outsider), outsiderBalancesBefore[0]);
        assertEq(collateral.balanceOf(outsider), outsiderBalancesBefore[1]);
    }

    function _exerciseActivationRollback(
        ActivationFault fault,
        FutarchyOfficialProposalSource source,
        MockFutarchyProposalLike proposal,
        FutarchyConditionalRouter router,
        FutarchyLiquidityManager manager,
        UniswapV3LiquidityAdapter spot,
        V4ConditionalLiquidityAdapter conditional,
        MockMintableERC20 company,
        MockMintableERC20 collateral,
        address[4] memory outcomes
    ) private {
        uint128 spotLiquidityBefore = manager.spotLiquidity();
        uint256 spotTokenIdBefore = spot.getPositionTokenId(address(company), address(collateral));
        uint128 spotNftLiquidityBefore = _spotPositionLiquidity(spotTokenIdBefore);
        uint256 companyBalanceBefore = company.balanceOf(address(manager));
        uint256 collateralBalanceBefore = collateral.balanceOf(address(manager));
        uint256 companyCtfBalanceBefore = company.balanceOf(CONDITIONAL_TOKENS);
        uint256 collateralCtfBalanceBefore = collateral.balanceOf(CONDITIONAL_TOKENS);
        uint256 companyRouterBalanceBefore = company.balanceOf(address(router));
        uint256 collateralRouterBalanceBefore = collateral.balanceOf(address(router));
        uint256 companyRouterAllowanceBefore = company.allowance(address(manager), address(router));
        uint256 collateralRouterAllowanceBefore =
            collateral.allowance(address(manager), address(router));
        uint256 companyCtfAllowanceBefore = company.allowance(address(router), CONDITIONAL_TOKENS);
        uint256 collateralCtfAllowanceBefore =
            collateral.allowance(address(router), CONDITIONAL_TOKENS);
        uint256[4] memory suppliesBefore;
        uint256[4] memory routerUnderlyingBefore;
        uint256[4] memory factoryUnderlyingBefore;
        uint256[4] memory poolManagerBalancesBefore;
        for (uint256 i; i < outcomes.length; ++i) {
            suppliesBefore[i] = IERC20(outcomes[i]).totalSupply();
            poolManagerBalancesBefore[i] = IERC20(outcomes[i]).balanceOf(POOL_MANAGER);
            uint256 tokenId = ICanonicalWrapped1155(outcomes[i]).tokenId();
            routerUnderlyingBefore[i] =
                IFutarchyConditionalTokens(CONDITIONAL_TOKENS).balanceOf(address(router), tokenId);
            factoryUnderlyingBefore[i] = IFutarchyConditionalTokens(CONDITIONAL_TOKENS)
                .balanceOf(WRAPPED_1155_FACTORY, tokenId);
        }

        bytes memory faultData = abi.encodeWithSignature("Error(string)", "injected fault");
        if (fault == ActivationFault.SpotRemoval) {
            vm.mockCallRevert(
                SPOT_POSITION_MANAGER,
                IUniswapV3NonfungiblePositionManager.decreaseLiquidity.selector,
                faultData
            );
        } else if (
            fault == ActivationFault.FirstCtfSplit || fault == ActivationFault.SecondCtfSplit
        ) {
            address
                faultedCollateral = fault == ActivationFault.FirstCtfSplit
                    ? address(company)
                    : address(collateral);
            vm.mockCallRevert(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    IFutarchyConditionalTokens.splitPosition.selector,
                    bytes32(uint256(uint160(faultedCollateral)))
                ),
                faultData
            );
        } else if (
            fault == ActivationFault.FirstWrapperMint
                || fault == ActivationFault.SecondAssetWrapperMint
        ) {
            uint256 tokenId = ICanonicalWrapped1155(
                    fault == ActivationFault.FirstWrapperMint ? outcomes[0] : outcomes[2]
                ).tokenId();
            vm.mockCallRevert(
                CONDITIONAL_TOKENS,
                abi.encodePacked(
                    bytes4(keccak256("safeTransferFrom(address,address,uint256,uint256,bytes)")),
                    bytes32(uint256(uint160(address(router)))),
                    bytes32(uint256(uint160(WRAPPED_1155_FACTORY))),
                    bytes32(tokenId)
                ),
                faultData
            );
        } else if (fault == ActivationFault.FirstV4Initialize) {
            vm.mockCallRevert(POOL_MANAGER, IV4PoolManagerMinimal.initialize.selector, faultData);
        } else if (fault == ActivationFault.SecondV4Initialize) {
            vm.mockCallRevert(
                POOL_MANAGER,
                abi.encodeWithSelector(
                    IV4PoolManagerMinimal.initialize.selector,
                    _v4PoolKey(conditional, outcomes[1], outcomes[3]),
                    uint160(1 << 96)
                ),
                faultData
            );
        } else {
            V4PoolKey memory key = fault == ActivationFault.FirstV4Liquidity
                ? _v4PoolKey(conditional, outcomes[0], outcomes[2])
                : _v4PoolKey(conditional, outcomes[1], outcomes[3]);
            vm.mockCallRevert(
                POOL_MANAGER,
                abi.encodePacked(
                    IV4PoolManagerMinimal.modifyLiquidity.selector,
                    bytes32(uint256(uint160(key.currency0))),
                    bytes32(uint256(uint160(key.currency1)))
                ),
                faultData
            );
        }

        vm.expectRevert(faultData);
        source.setOfficialProposal(1, address(proposal), address(this));

        FutarchyOfficialProposalSource.OfficialProposal memory official =
            source.currentOfficialProposal();
        assertFalse(official.exists);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), spotLiquidityBefore);
        assertEq(spot.getPositionTokenId(address(company), address(collateral)), spotTokenIdBefore);
        assertEq(_spotPositionLiquidity(spotTokenIdBefore), spotNftLiquidityBefore);
        assertEq(company.balanceOf(address(manager)), companyBalanceBefore);
        assertEq(collateral.balanceOf(address(manager)), collateralBalanceBefore);
        assertEq(company.balanceOf(CONDITIONAL_TOKENS), companyCtfBalanceBefore);
        assertEq(collateral.balanceOf(CONDITIONAL_TOKENS), collateralCtfBalanceBefore);
        assertEq(company.balanceOf(address(router)), companyRouterBalanceBefore);
        assertEq(collateral.balanceOf(address(router)), collateralRouterBalanceBefore);
        assertEq(company.allowance(address(manager), address(router)), companyRouterAllowanceBefore);
        assertEq(
            collateral.allowance(address(manager), address(router)), collateralRouterAllowanceBefore
        );
        assertEq(company.allowance(address(router), CONDITIONAL_TOKENS), companyCtfAllowanceBefore);
        assertEq(
            collateral.allowance(address(router), CONDITIONAL_TOKENS), collateralCtfAllowanceBefore
        );
        assertEq(conditional.positionLiquidity(_pairKey(outcomes[0], outcomes[2])), 0);
        assertEq(conditional.positionLiquidity(_pairKey(outcomes[1], outcomes[3])), 0);
        assertEq(conditional.poolByPair(outcomes[0], outcomes[2]), address(0));
        assertEq(conditional.poolByPair(outcomes[1], outcomes[3]), address(0));
        for (uint256 i; i < outcomes.length; ++i) {
            assertEq(IERC20(outcomes[i]).totalSupply(), suppliesBefore[i]);
            assertEq(IERC20(outcomes[i]).balanceOf(address(manager)), 0);
            assertEq(IERC20(outcomes[i]).balanceOf(address(router)), 0);
            assertEq(IERC20(outcomes[i]).balanceOf(address(conditional)), 0);
            assertEq(IERC20(outcomes[i]).balanceOf(POOL_MANAGER), poolManagerBalancesBefore[i]);
            uint256 tokenId = ICanonicalWrapped1155(outcomes[i]).tokenId();
            assertEq(
                IFutarchyConditionalTokens(CONDITIONAL_TOKENS).balanceOf(address(router), tokenId),
                routerUnderlyingBefore[i]
            );
            assertEq(
                IFutarchyConditionalTokens(CONDITIONAL_TOKENS)
                    .balanceOf(WRAPPED_1155_FACTORY, tokenId),
                factoryUnderlyingBefore[i]
            );
        }

        vm.clearMockedCalls();
        source.setOfficialProposal(1, address(proposal), address(this));
        assertTrue(manager.inConditionalMode());
        assertGt(conditional.positionLiquidity(_pairKey(outcomes[0], outcomes[2])), 0);
        assertGt(conditional.positionLiquidity(_pairKey(outcomes[1], outcomes[3])), 0);
    }

    function _donateSingleYesCompany(
        MockMintableERC20 company,
        FutarchyConditionalRouter router,
        bytes32 conditionId,
        address yesCompany,
        address noCompany,
        V4ConditionalLiquidityAdapter conditional,
        address yesCollateral,
        MainnetV4Donor donor
    ) private {
        company.mint(address(this), DONATION);
        company.approve(address(router), DONATION);
        router.splitPosition(address(company), conditionId, yesCompany, noCompany, DONATION);
        assertTrue(IERC20(yesCompany).transfer(address(donor), DONATION));
        V4PoolKey memory yesPoolKey = _v4PoolKey(conditional, yesCompany, yesCollateral);
        if (yesPoolKey.currency0 == yesCompany) {
            donor.donate(yesPoolKey, DONATION, 0);
        } else {
            donor.donate(yesPoolKey, 0, DONATION);
        }
        assertEq(IERC20(yesCompany).balanceOf(address(donor)), 0);
        assertEq(IERC20(noCompany).balanceOf(address(this)), DONATION);
    }

    function _creationCodes()
        private
        pure
        returns (V4FutarchyLiquidityManagerFactory.CreationCodes memory)
    {
        return V4FutarchyLiquidityManagerFactory.CreationCodes({
            proposalSource: type(FutarchyOfficialProposalSource).creationCode,
            spotAdapter: type(UniswapV3LiquidityAdapter).creationCode,
            initializationGate: type(V4InitializationGate).creationCode,
            conditionalAdapter: type(V4ConditionalLiquidityAdapter).creationCode,
            manager: type(FutarchyLiquidityManager).creationCode
        });
    }

    function _findHookSalt(V4FutarchyLiquidityManagerFactory factory)
        private
        view
        returns (bytes32 rawSalt)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(V4InitializationGate).creationCode, abi.encode(POOL_MANAGER, address(factory))
            )
        );
        for (uint256 i; i < 100_000; ++i) {
            bytes32 candidate = bytes32(i);
            bytes32 salt = factory.effectiveHookSalt(address(this), candidate);
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xff), address(factory), salt, initCodeHash)
                        )
                    )
                )
            );
            if (uint160(predicted) & ALL_HOOK_MASK == BEFORE_INITIALIZE_FLAG) return candidate;
        }
        revert("salt not found");
    }

    function _wrapper(
        IMainnetConditionalTokens ctf,
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

    function _spotPositionLiquidity(uint256 tokenId) private view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) =
            IUniswapV3NonfungiblePositionManager(SPOT_POSITION_MANAGER).positions(tokenId);
    }

    function _v4PoolKey(V4ConditionalLiquidityAdapter adapter, address tokenA, address tokenB)
        private
        view
        returns (V4PoolKey memory key)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        key = V4PoolKey({
            currency0: token0,
            currency1: token1,
            fee: adapter.FEE(),
            tickSpacing: adapter.TICK_SPACING(),
            hooks: address(adapter.INITIALIZATION_GATE())
        });
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
