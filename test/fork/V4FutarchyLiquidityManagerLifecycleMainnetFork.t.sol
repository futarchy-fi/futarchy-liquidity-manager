// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter
} from "../../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../../src/adapters/UniswapV3LiquidityAdapter.sol";
import {V4InitializationGate} from "../../src/adapters/V4InitializationGate.sol";
import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {
    V4FutarchyLiquidityManagerFactory
} from "../../src/factories/V4FutarchyLiquidityManagerFactory.sol";
import {
    IFutarchyConditionalTokens
} from "../../src/interfaces/IFutarchyConditionalDependencies.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../../src/interfaces/IPoolStabilityGuard.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {FutarchyConditionalRouter} from "../../src/routers/FutarchyConditionalRouter.sol";
import {FutarchyOfficialProposalSource} from "../../src/sources/FutarchyOfficialProposalSource.sol";
import {MockFutarchyProposalLike} from "../mocks/MockFutarchyProposalLike.sol";
import {MockMintableERC20} from "../mocks/MockMintableERC20.sol";
import {MockRouterWrapped1155Factory} from "../mocks/MockRouterWrapped1155Factory.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "../mocks/MockUniswapV3NonfungiblePositionManager.sol";

interface IMainnetConditionalTokens is IFutarchyConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
}

contract MainnetLifecycleSpotGuard is IPoolStabilityGuard {
    address public immutable FACTORY;
    uint24 public constant FEE = 500;
    uint160 private constant Q96 = 1 << 96;

    constructor(address factory) {
        FACTORY = factory;
    }

    function assertStable(address) external pure {}

    function assertStablePair(address, address) external pure {}

    function assertStablePairAndGetSqrtPrice(address, address) external pure returns (uint160) {
        return Q96;
    }
}

contract V4FutarchyLiquidityManagerLifecycleMainnetForkTest is Test {
    uint256 private constant FORK_BLOCK = 25_542_490;
    uint256 private constant AMOUNT = 100 ether;
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

    function testFork_factoryBundleCompletesRealCtfTwoPoolLifecycle() public {
        if (!vm.envOr("RUN_MAINNET_FORK_TESTS", false)) return;
        vm.createSelectFork(
            vm.envOr("MAINNET_RPC_URL", string("https://rpc.mevblocker.io")), FORK_BLOCK
        );
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);
        assertEq(CONDITIONAL_TOKENS.codehash, CONDITIONAL_TOKENS_CODEHASH);

        IMainnetConditionalTokens ctf = IMainnetConditionalTokens(CONDITIONAL_TOKENS);
        MockRouterWrapped1155Factory wrapperFactory = new MockRouterWrapped1155Factory();
        FutarchyConditionalRouter router = new FutarchyConditionalRouter(ctf, wrapperFactory);
        MockMintableERC20 company = new MockMintableERC20("Company", "COMP");
        MockMintableERC20 collateral = new MockMintableERC20("Collateral", "COLL");
        MockUniswapV3NonfungiblePositionManager spotPositionManager =
            new MockUniswapV3NonfungiblePositionManager();
        MainnetLifecycleSpotGuard guard =
            new MainnetLifecycleSpotGuard(spotPositionManager.factory());

        V4FutarchyLiquidityManagerFactory factory = new V4FutarchyLiquidityManagerFactory(
            IUniswapV3NonfungiblePositionManager(address(spotPositionManager)),
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
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(
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
                }),
                _creationCodes()
            );

        V4ConditionalLiquidityAdapter conditional =
            V4ConditionalLiquidityAdapter(deployed.conditionalAdapter);
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
        source.setOfficialProposal(1, address(proposal), address(this));

        assertTrue(manager.inConditionalMode());
        assertEq(manager.activeConditionId(), conditionId);
        assertEq(manager.activeYesPool(), POOL_MANAGER);
        assertEq(manager.activeNoPool(), POOL_MANAGER);
        assertGt(conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral)), 0);
        assertGt(conditional.positionLiquidity(_pairKey(noCompany, noCollateral)), 0);
        assertEq(source.officialProposalExtended().yesPool, POOL_MANAGER);
        assertEq(source.officialProposalExtended().noPool, POOL_MANAGER);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        ctf.reportPayouts(questionId, payouts);
        source.clearOfficialProposal();
        assertEq(
            uint256(manager.sync()), uint256(FutarchyLiquidityManager.SyncAction.MigratedBackToSpot)
        );

        assertFalse(manager.inConditionalMode());
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(conditional.positionLiquidity(_pairKey(yesCompany, yesCollateral)), 0);
        assertEq(conditional.positionLiquidity(_pairKey(noCompany, noCollateral)), 0);
        assertApproxEqAbs(company.balanceOf(address(manager)), AMOUNT * 80 / 100, 1);
        assertApproxEqAbs(collateral.balanceOf(address(manager)), AMOUNT * 80 / 100, 1);
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
        MockRouterWrapped1155Factory factory,
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
