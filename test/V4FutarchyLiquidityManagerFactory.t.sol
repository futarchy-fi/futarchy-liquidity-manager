// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter
} from "../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../src/adapters/UniswapV3LiquidityAdapter.sol";
import {V4InitializationGate} from "../src/adapters/V4InitializationGate.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {
    V4FutarchyLiquidityManagerFactory
} from "../src/factories/V4FutarchyLiquidityManagerFactory.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {IUniswapV3FactoryLike} from "../src/interfaces/IUniswapV3FactoryLike.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {UniV3PoolStabilityGuard} from "../src/oracles/UniV3PoolStabilityGuard.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockUniswapV3FactoryLike} from "./mocks/MockUniswapV3FactoryLike.sol";
import {
    MockUniswapV3NonfungiblePositionManager
} from "./mocks/MockUniswapV3NonfungiblePositionManager.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract FactoryV4PoolManager {}

contract RevertingV4BundleManager {
    constructor() {
        revert();
    }
}

contract V4FutarchyLiquidityManagerFactoryTest is Test {
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 private constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    int24 private constant TICK_LOWER = -887_270;
    int24 private constant TICK_UPPER = 887_270;

    address private constant ORGANIZATION = address(0x0A6);
    address private constant OWNER = address(0x0A11CE);
    address private constant BOOTSTRAP_RECIPIENT = address(0xB007);
    address private constant OFFICIAL_PROPOSER = address(0x0FF1C1A1);
    address private constant CREATOR = address(0xC0FFEE);

    MockMintableERC20 private company;
    MockWrappedNative private wrappedNative;
    MockUniswapV3NonfungiblePositionManager private spotPositionManager;
    MockConditionalRouter private conditionalRouter;
    UniV3PoolStabilityGuard private stabilityGuard;
    FactoryV4PoolManager private v4PoolManager;
    V4FutarchyLiquidityManagerFactory private factory;

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        spotPositionManager = new MockUniswapV3NonfungiblePositionManager();
        conditionalRouter = new MockConditionalRouter();
        conditionalRouter.setConditionalTokens(address(0xC0DE));
        stabilityGuard =
            new UniV3PoolStabilityGuard(IUniswapV3FactoryLike(spotPositionManager.factory()), 500);
        v4PoolManager = new FactoryV4PoolManager();
        factory = _newFactory(keccak256(type(FutarchyLiquidityManager).creationCode));
    }

    function test_anyWalletAtomicallyDeploysAndBindsV4Bundle() public {
        bytes32 salt = _findHookSalt(factory, CREATOR);
        V4FutarchyLiquidityManagerFactory.CreateParams memory params = _params(salt);
        V4FutarchyLiquidityManagerFactory.CreationCodes memory codes = _codes();
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory predicted =
            factory.predictBundleAddresses(CREATOR, params, codes);
        assertEq(
            predicted.initializationGate,
            factory.predictHookAddress(CREATOR, salt, type(V4InitializationGate).creationCode)
        );

        vm.prank(CREATOR);
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(params, codes);

        _assertBundleAddresses(deployed, predicted);
        assertEq(uint160(predicted.initializationGate) & ALL_HOOK_MASK, BEFORE_INITIALIZE_FLAG);
        _assertBundle(deployed);
    }

    function test_bundlePredictionsSurviveUnrelatedPermissionlessDeployment() public {
        V4FutarchyLiquidityManagerFactory.CreationCodes memory codes = _codes();
        V4FutarchyLiquidityManagerFactory.CreateParams memory intendedParams =
            _params(_findHookSalt(factory, CREATOR));
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory predicted =
            factory.predictBundleAddresses(CREATOR, intendedParams, codes);

        address otherCreator = address(0xB0B);
        V4FutarchyLiquidityManagerFactory.CreateParams memory otherParams =
            _params(_findHookSalt(factory, otherCreator));
        vm.prank(otherCreator);
        factory.createLiquidityManager(otherParams, codes);

        vm.prank(CREATOR);
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(intendedParams, codes);
        _assertBundleAddresses(deployed, predicted);
    }

    function test_creatorBoundSaltCannotBeConsumedByAnotherWallet() public view {
        bytes32 rawSalt = _findHookSalt(factory, CREATOR);
        address intended =
            factory.predictHookAddress(CREATOR, rawSalt, type(V4InitializationGate).creationCode);
        address attacker = address(0xBAD);
        address attackerPrediction =
            factory.predictHookAddress(attacker, rawSalt, type(V4InitializationGate).creationCode);

        assertTrue(attackerPrediction != intended);
        assertTrue(
            factory.effectiveHookSalt(attacker, rawSalt)
                != factory.effectiveHookSalt(CREATOR, rawSalt)
        );
    }

    function test_unminedHookSaltRevertsBeforeAnyChildDeployment() public {
        bytes32 badSalt = _findInvalidHookSalt(factory, CREATOR);
        address predicted =
            factory.predictHookAddress(CREATOR, badSalt, type(V4InitializationGate).creationCode);
        uint64 nonceBefore = vm.getNonce(address(factory));

        vm.expectRevert(
            abi.encodeWithSelector(
                V4FutarchyLiquidityManagerFactory.InvalidHookAddress.selector, predicted
            )
        );
        vm.prank(CREATOR);
        factory.createLiquidityManager(_params(badSalt), _codes());

        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(factory)), nonceBefore);
    }

    function test_lateManagerFailureRollsBackHookAndEveryCreate() public {
        V4FutarchyLiquidityManagerFactory revertingFactory =
            _newFactory(keccak256(type(RevertingV4BundleManager).creationCode));
        bytes32 salt = _findHookSalt(revertingFactory, CREATOR);
        address predicted = revertingFactory.predictHookAddress(
            CREATOR, salt, type(V4InitializationGate).creationCode
        );
        V4FutarchyLiquidityManagerFactory.CreationCodes memory codes = _codes();
        codes.manager = type(RevertingV4BundleManager).creationCode;
        uint64 nonceBefore = vm.getNonce(address(revertingFactory));

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.DeploymentFailed.selector);
        vm.prank(CREATOR);
        revertingFactory.createLiquidityManager(_params(salt), codes);

        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(revertingFactory)), nonceBefore);
    }

    function test_sameTokenManagerFailureAlsoRollsBackMinedHook() public {
        bytes32 salt = _findHookSalt(factory, CREATOR);
        address predicted =
            factory.predictHookAddress(CREATOR, salt, type(V4InitializationGate).creationCode);
        V4FutarchyLiquidityManagerFactory.CreateParams memory params = _params(salt);
        params.companyToken = IERC20(address(wrappedNative));

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.DeploymentFailed.selector);
        vm.prank(CREATOR);
        factory.createLiquidityManager(params, _codes());

        assertEq(predicted.code.length, 0);
    }

    function test_mutatedGateCreationCodeIsRejectedBeforePredictionOrDeployment() public {
        V4FutarchyLiquidityManagerFactory.CreationCodes memory codes = _codes();
        codes.initializationGate[0] = bytes1(uint8(codes.initializationGate[0]) ^ 1);
        bytes32 expected = factory.INITIALIZATION_GATE_CREATION_CODE_HASH();
        bytes32 actual = keccak256(codes.initializationGate);

        vm.expectRevert(
            abi.encodeWithSelector(
                V4FutarchyLiquidityManagerFactory.CreationCodeHashMismatch.selector,
                expected,
                actual
            )
        );
        vm.prank(CREATOR);
        factory.createLiquidityManager(_params(bytes32(0)), codes);
    }

    function test_factoryRuntimeFitsEip170() public view {
        assertLt(address(factory).code.length, 24_576);
    }

    function test_candidateCreationCodeHashesMatchMainnetManifest() public pure {
        assertEq(
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            0xeec528405c315ae9de9317487b7ddaf26bf3748af830bb4dd95538ca09c2afbf
        );
        assertEq(
            keccak256(type(UniswapV3LiquidityAdapter).creationCode),
            0xc2f01cca15a3dc38280b20c05dcce401b71abd0f017fa04abe32550dc18e9a2b
        );
        assertEq(
            keccak256(type(V4InitializationGate).creationCode),
            0x56052e89d8d3305ab4d3c35922882faee512c39fe45102cc0dec86bf7e57f75f
        );
        assertEq(
            keccak256(type(V4ConditionalLiquidityAdapter).creationCode),
            0xba940a9f090ff9120797bb258c48717d0c508bbbc23d9379eb8c10bebcc4fc53
        );
        assertEq(
            keccak256(type(FutarchyLiquidityManager).creationCode),
            0x7accf3e36923467479f9a697e2ae81b5e2da0a8ab31031d61901f04cc253550c
        );
        assertEq(
            keccak256(type(V4FutarchyLiquidityManagerFactory).creationCode),
            0xe6df50aabe5258cd3d084046eb8b3573cad874c50e7aa721257e033374497440
        );
    }

    function test_constructorRejectsPoolManagerCodehashMismatch() public {
        vm.expectRevert(V4FutarchyLiquidityManagerFactory.InvalidDependency.selector);
        _newFactoryWith(
            bytes32(uint256(1)),
            stabilityGuard,
            keccak256(type(FutarchyLiquidityManager).creationCode),
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function test_constructorRejectsCodeLessPoolManagerEvenWhenHashMatches() public {
        vm.etch(address(v4PoolManager), "");

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.InvalidDependency.selector);
        _newFactoryWith(
            address(v4PoolManager).codehash,
            stabilityGuard,
            keccak256(type(FutarchyLiquidityManager).creationCode),
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function test_constructorRejectsUnusableSpotTickPolicy() public {
        bytes32 managerHash = keccak256(type(FutarchyLiquidityManager).creationCode);

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.InvalidTickRange.selector);
        _newFactoryWith(
            address(v4PoolManager).codehash, stabilityGuard, managerHash, -887_280, TICK_UPPER
        );

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.InvalidTickRange.selector);
        _newFactoryWith(
            address(v4PoolManager).codehash, stabilityGuard, managerHash, TICK_LOWER, 887_269
        );
    }

    function test_constructorRejectsSpotGuardForDifferentFactory() public {
        UniV3PoolStabilityGuard wrongGuard =
            new UniV3PoolStabilityGuard(new MockUniswapV3FactoryLike(), 500);

        vm.expectRevert(V4FutarchyLiquidityManagerFactory.InvalidAmmWiring.selector);
        _newFactoryWith(
            address(v4PoolManager).codehash,
            wrongGuard,
            keccak256(type(FutarchyLiquidityManager).creationCode),
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function _assertBundle(V4FutarchyLiquidityManagerFactory.DeployedContracts memory deployed)
        private
        view
    {
        V4InitializationGate gate = V4InitializationGate(deployed.initializationGate);
        assertEq(gate.POOL_MANAGER(), address(v4PoolManager));
        assertEq(gate.BINDING_AUTHORITY(), address(factory));
        assertEq(gate.ADAPTER(), deployed.conditionalAdapter);

        V4ConditionalLiquidityAdapter conditional =
            V4ConditionalLiquidityAdapter(deployed.conditionalAdapter);
        assertEq(address(conditional.POOL_MANAGER()), address(v4PoolManager));
        assertEq(conditional.POOL_MANAGER_CODEHASH(), address(v4PoolManager).codehash);
        assertEq(address(conditional.INITIALIZATION_GATE()), deployed.initializationGate);
        assertEq(conditional.MANAGER(), deployed.manager);

        UniswapV3LiquidityAdapter spot = UniswapV3LiquidityAdapter(deployed.spotAdapter);
        assertEq(address(spot.POSITION_MANAGER()), address(spotPositionManager));
        assertEq(spot.DEFAULT_TICK_LOWER(), TICK_LOWER);
        assertEq(spot.DEFAULT_TICK_UPPER(), TICK_UPPER);
        assertEq(spot.MANAGER(), deployed.manager);

        FutarchyOfficialProposalSource source =
            FutarchyOfficialProposalSource(deployed.proposalSource);
        assertEq(source.owner(), OWNER);
        assertEq(source.LIFECYCLE_COORDINATOR(), address(this));
        assertEq(address(source.ALGEBRA_FACTORY()), deployed.conditionalAdapter);
        assertEq(source.activationTarget(), deployed.manager);

        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(deployed.manager));
        assertEq(manager.owner(), OWNER);
        assertEq(manager.BOOTSTRAP_RECIPIENT(), BOOTSTRAP_RECIPIENT);
        assertEq(address(manager.COMPANY_TOKEN()), address(company));
        assertEq(address(manager.WRAPPED_NATIVE()), address(wrappedNative));
        assertEq(address(manager.PROPOSAL_SOURCE()), deployed.proposalSource);
        assertEq(address(manager.SPOT_ADAPTER()), deployed.spotAdapter);
        assertEq(address(manager.CONDITIONAL_ADAPTER()), deployed.conditionalAdapter);
        assertEq(address(manager.CONDITIONAL_ROUTER()), address(conditionalRouter));
        assertEq(address(manager.POOL_STABILITY_GUARD()), address(stabilityGuard));
    }

    function _assertBundleAddresses(
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory actual,
        V4FutarchyLiquidityManagerFactory.DeployedContracts memory expected
    ) private pure {
        assertEq(actual.proposalSource, expected.proposalSource);
        assertEq(actual.spotAdapter, expected.spotAdapter);
        assertEq(actual.initializationGate, expected.initializationGate);
        assertEq(actual.conditionalAdapter, expected.conditionalAdapter);
        assertEq(actual.manager, expected.manager);
    }

    function _params(bytes32 hookSalt)
        private
        view
        returns (V4FutarchyLiquidityManagerFactory.CreateParams memory)
    {
        return V4FutarchyLiquidityManagerFactory.CreateParams({
            organization: ORGANIZATION,
            owner: OWNER,
            proposalManager: address(this),
            bootstrapRecipient: BOOTSTRAP_RECIPIENT,
            companyToken: company,
            officialProposer: OFFICIAL_PROPOSER,
            lpTokenName: "Organization Futarchy LP",
            lpTokenSymbol: "ORG-FLM",
            proposalValidationConfigData: abi.encode(
                FutarchyOfficialProposalSource.ProposalValidationConfig({
                    enabled: true,
                    expectedProposalToken: address(company),
                    expectedCollateralToken: address(wrappedNative),
                    conditionalTokens: address(0xC0DE),
                    trustedOracle: address(0x0A0),
                    realitio: address(0),
                    trustedArbitrator: address(0),
                    maxOpeningDelay: 0,
                    minTimeout: 0,
                    maxTimeout: 0,
                    minConditionalLifetime: 0,
                    maxMinBond: 0
                })
            ),
            hookSalt: hookSalt
        });
    }

    function _codes()
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

    function _newFactory(bytes32 managerCreationCodeHash)
        private
        returns (V4FutarchyLiquidityManagerFactory)
    {
        return _newFactoryWith(
            address(v4PoolManager).codehash,
            stabilityGuard,
            managerCreationCodeHash,
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function _newFactoryWith(
        bytes32 poolManagerCodehash,
        UniV3PoolStabilityGuard guard,
        bytes32 managerCreationCodeHash,
        int24 tickLower,
        int24 tickUpper
    ) private returns (V4FutarchyLiquidityManagerFactory) {
        return new V4FutarchyLiquidityManagerFactory(
            IUniswapV3NonfungiblePositionManager(address(spotPositionManager)),
            IV4PoolManagerMinimal(address(v4PoolManager)),
            poolManagerCodehash,
            IFutarchyConditionalRouter(address(conditionalRouter)),
            guard,
            IWrappedNative(address(wrappedNative)),
            tickLower,
            tickUpper,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(UniswapV3LiquidityAdapter).creationCode),
            keccak256(type(V4InitializationGate).creationCode),
            keccak256(type(V4ConditionalLiquidityAdapter).creationCode),
            managerCreationCodeHash
        );
    }

    function _findHookSalt(V4FutarchyLiquidityManagerFactory target, address creator)
        private
        view
        returns (bytes32 rawSalt)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(V4InitializationGate).creationCode, abi.encode(v4PoolManager, address(target))
            )
        );
        for (uint256 i; i < 100_000; ++i) {
            bytes32 candidate = bytes32(i);
            address predicted =
                _predict(address(target), keccak256(abi.encode(creator, candidate)), initCodeHash);
            if (uint160(predicted) & ALL_HOOK_MASK == BEFORE_INITIALIZE_FLAG) return candidate;
        }
        revert("salt not found");
    }

    function _findInvalidHookSalt(V4FutarchyLiquidityManagerFactory target, address creator)
        private
        view
        returns (bytes32 rawSalt)
    {
        for (uint256 i; i < 100; ++i) {
            bytes32 candidate = bytes32(i);
            address predicted = target.predictHookAddress(
                creator, candidate, type(V4InitializationGate).creationCode
            );
            if (uint160(predicted) & ALL_HOOK_MASK != BEFORE_INITIALIZE_FLAG) return candidate;
        }
        revert("invalid salt not found");
    }

    function _predict(address deployer, bytes32 salt, bytes32 initCodeHash)
        private
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
            )
        );
    }
}
