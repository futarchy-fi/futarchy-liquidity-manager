// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    SwaprAlgebraDirectConditionalAdapter
} from "../src/adapters/SwaprAlgebraDirectConditionalAdapter.sol";
import {SwaprAlgebraLiquidityAdapter} from "../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {
    FutarchyLiquidityManagerFactory
} from "../src/factories/FutarchyLiquidityManagerFactory.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockPoolStabilityGuard} from "./mocks/MockPoolStabilityGuard.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract EmptyFactoryDeployment {
    constructor() {
        assembly ("memory-safe") {
            return(0, 0)
        }
    }
}

contract FactoryOnlyAlgebraPositionManager {
    address public immutable factory;

    constructor(address poolFactory) {
        factory = poolFactory;
    }
}

contract FutarchyLiquidityManagerFactoryTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockAlgebraFactoryLike internal algebraFactory;
    MockConditionalRouter internal conditionalRouter;
    MockPoolStabilityGuard internal stabilityGuard;
    FutarchyLiquidityManagerFactory internal factory;

    ISwaprAlgebraPositionManager internal positionManager;

    address internal organization = address(0x0A6);
    address internal owner = address(0x0A11CE);
    address internal proposalManager;
    address internal bootstrapRecipient = address(0xB007);
    address internal officialProposer = address(0x0FF1C1A1);
    address internal creator = address(0xC0FFEE);

    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    function setUp() public {
        proposalManager = address(this);
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        algebraFactory = new MockAlgebraFactoryLike();
        positionManager = ISwaprAlgebraPositionManager(
            address(new FactoryOnlyAlgebraPositionManager(address(algebraFactory)))
        );
        conditionalRouter = new MockConditionalRouter();
        conditionalRouter.setConditionalTokens(address(0xC0DE));
        stabilityGuard = new MockPoolStabilityGuard();
        stabilityGuard.setFactory(address(algebraFactory));

        factory = _newFactory(positionManager, algebraFactory, stabilityGuard);
    }

    function test_anyWalletDeploysDefaultFlmBundle() public {
        vm.prank(creator);
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(
                _createParams(_defaultValidationConfigData()), _creationCodes()
            );

        _assertDeployedBundle(deployed);
    }

    function test_factoryRuntimeFitsEip170() public view {
        assertLt(address(factory).code.length, 24_576);
    }

    function test_managerRuntimeKeepsEip170Reserve() public {
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) return;
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(
                _createParams(_defaultValidationConfigData()), _creationCodes()
            );
        assertLe(deployed.manager.code.length, 24_448);
    }

    function test_adapterBindingIsIrreversibleAndRestrictsLiquidityOperations() public {
        SwaprAlgebraLiquidityAdapter adapter =
            new SwaprAlgebraLiquidityAdapter(positionManager, TICK_LOWER, TICK_UPPER);
        address manager = address(0xB0A7);

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.UnauthorizedBindingAuthority.selector);
        vm.prank(creator);
        adapter.bindManager(manager);

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.ZeroAddress.selector);
        adapter.bindManager(address(0));

        adapter.bindManager(manager);
        assertEq(adapter.MANAGER(), manager);

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.ManagerAlreadyBound.selector);
        adapter.bindManager(address(0xBEEF));

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.UnauthorizedManager.selector);
        adapter.addFullRangeLiquidity(address(1), address(2), 0, 0, "");

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.UnauthorizedManager.selector);
        adapter.addFreshFullRangeLiquidity(address(1), address(2), 1, 1, 1);

        vm.expectRevert(SwaprAlgebraLiquidityAdapter.UnauthorizedManager.selector);
        adapter.removeLiquidityDetailed(address(1), address(2), 1);
    }

    function test_passesInitialProposalValidationConfigToProposalSource() public {
        FutarchyOfficialProposalSource.ProposalValidationConfig memory validation =
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
                maxMinBond: 1 ether
            });

        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(_createParams(abi.encode(validation)), _creationCodes());

        {
            (
                bool enabled,
                address expectedProposalToken,
                address expectedCollateralToken,
                address conditionalTokens,
                address trustedOracle,
                address realitio,
                address trustedArbitrator,,,,,
            ) = FutarchyOfficialProposalSource(deployed.proposalSource).proposalValidationConfig();

            assertTrue(enabled);
            assertEq(expectedProposalToken, address(company));
            assertEq(expectedCollateralToken, address(wrappedNative));
            assertEq(conditionalTokens, address(0xC0DE));
            assertEq(trustedOracle, address(0x0A0));
            assertEq(realitio, address(0));
            assertEq(trustedArbitrator, address(0));
        }
        {
            (
                ,,,,,,,
                uint32 maxOpeningDelay,
                uint32 minTimeout,
                uint32 maxTimeout,
                uint32 minConditionalLifetime,
                uint256 maxMinBond
            ) = FutarchyOfficialProposalSource(deployed.proposalSource).proposalValidationConfig();

            assertEq(maxOpeningDelay, 0);
            assertEq(minTimeout, 0);
            assertEq(maxTimeout, 0);
            assertEq(minConditionalLifetime, 0);
            assertEq(maxMinBond, 1 ether);
        }
    }

    function test_revertsOnZeroCreateParams() public {
        FutarchyLiquidityManagerFactory.CreateParams memory params = _createParams("");
        params.owner = address(0);

        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroAddress.selector);
        factory.createLiquidityManager(params, _creationCodes());
    }

    function test_revertsOnSameCompanyAndCollateralToken() public {
        FutarchyLiquidityManagerFactory.CreateParams memory params =
            _createParams(_defaultValidationConfigData());
        params.companyToken = wrappedNative;

        vm.expectRevert(FutarchyLiquidityManagerFactory.DeploymentFailed.selector);
        factory.createLiquidityManager(params, _creationCodes());
    }

    function test_revertsOnEoaCompanyTokenAndRollsBackBundle() public {
        FutarchyLiquidityManagerFactory.CreateParams memory params =
            _createParams(_defaultValidationConfigData());
        params.companyToken = IERC20(address(0xBEEF));

        vm.expectRevert(FutarchyLiquidityManagerFactory.DeploymentFailed.selector);
        factory.createLiquidityManager(params, _creationCodes());
    }

    function test_revertsOnMutatedCreationCode() public {
        FutarchyLiquidityManagerFactory.CreationCodes memory codes = _creationCodes();
        codes.manager[0] = bytes1(uint8(codes.manager[0]) ^ 1);

        bytes32 expected = factory.MANAGER_CREATION_CODE_HASH();
        bytes32 actual = keccak256(codes.manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyLiquidityManagerFactory.CreationCodeHashMismatch.selector, expected, actual
            )
        );
        factory.createLiquidityManager(_createParams(""), codes);
    }

    function test_revertsOnSwappedCreationCode() public {
        FutarchyLiquidityManagerFactory.CreationCodes memory codes = _creationCodes();
        codes.proposalSource = codes.spotAdapter;

        bytes32 expected = factory.PROPOSAL_SOURCE_CREATION_CODE_HASH();
        bytes32 actual = keccak256(codes.proposalSource);
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyLiquidityManagerFactory.CreationCodeHashMismatch.selector, expected, actual
            )
        );
        factory.createLiquidityManager(_createParams(""), codes);
    }

    function test_revertsOnSwappedAdapterCreationCodes() public {
        FutarchyLiquidityManagerFactory.CreationCodes memory codes = _creationCodes();
        codes.conditionalAdapter = codes.spotAdapter;

        bytes32 expected = factory.CONDITIONAL_ADAPTER_CREATION_CODE_HASH();
        bytes32 actual = keccak256(codes.conditionalAdapter);
        vm.expectRevert(
            abi.encodeWithSelector(
                FutarchyLiquidityManagerFactory.CreationCodeHashMismatch.selector, expected, actual
            )
        );
        factory.createLiquidityManager(_createParams(""), codes);
    }

    function test_revertsWhenManagerInitCodeExceedsEip3860AndRollsBack() public {
        FutarchyLiquidityManagerFactory.CreateParams memory params = _createParams("");
        params.lpTokenName = new string(24_000);
        uint64 nonceBefore = vm.getNonce(address(factory));
        address wouldBeProposalSource = vm.computeCreateAddress(address(factory), nonceBefore);

        vm.expectPartialRevert(FutarchyLiquidityManagerFactory.InitCodeTooLarge.selector);
        factory.createLiquidityManager(params, _creationCodes());

        assertEq(wouldBeProposalSource.code.length, 0);
        assertEq(vm.getNonce(address(factory)), nonceBefore);
    }

    function test_revertsOnEmptyRuntimeAndRollsBack() public {
        FutarchyLiquidityManagerFactory emptyManagerFactory = new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            stabilityGuard,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(EmptyFactoryDeployment).creationCode)
        );
        FutarchyLiquidityManagerFactory.CreationCodes memory codes = _creationCodes();
        codes.manager = type(EmptyFactoryDeployment).creationCode;
        uint64 nonceBefore = vm.getNonce(address(emptyManagerFactory));
        address wouldBeProposalSource =
            vm.computeCreateAddress(address(emptyManagerFactory), nonceBefore);

        vm.expectRevert(FutarchyLiquidityManagerFactory.DeploymentFailed.selector);
        emptyManagerFactory.createLiquidityManager(_createParams(""), codes);

        assertEq(wouldBeProposalSource.code.length, 0);
        assertEq(vm.getNonce(address(emptyManagerFactory)), nonceBefore);
    }

    function test_revertsOnZeroConstructorDependency() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroAddress.selector);
        new FutarchyLiquidityManagerFactory(
            ISwaprAlgebraPositionManager(address(0)),
            algebraFactory,
            conditionalRouter,
            stabilityGuard,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
    }

    function test_revertsOnZeroStabilityGuard() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroAddress.selector);
        new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            MockPoolStabilityGuard(address(0)),
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
    }

    function test_revertsWhenPositionManagerUsesDifferentAlgebraFactory() public {
        ISwaprAlgebraPositionManager mismatchedPositionManager = ISwaprAlgebraPositionManager(
            address(new FactoryOnlyAlgebraPositionManager(address(new MockAlgebraFactoryLike())))
        );

        vm.expectRevert(FutarchyLiquidityManagerFactory.InvalidAmmWiring.selector);
        _newFactory(mismatchedPositionManager, algebraFactory, stabilityGuard);
    }

    function test_revertsWhenStabilityGuardUsesDifferentAlgebraFactory() public {
        MockPoolStabilityGuard mismatchedGuard = new MockPoolStabilityGuard();
        mismatchedGuard.setFactory(address(new MockAlgebraFactoryLike()));

        vm.expectRevert(FutarchyLiquidityManagerFactory.InvalidAmmWiring.selector);
        _newFactory(positionManager, algebraFactory, mismatchedGuard);
    }

    function test_constructorRejectsEoaDependency() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.InvalidDependency.selector);
        new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            IFutarchyConditionalRouter(address(0xBEEF)),
            stabilityGuard,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
    }

    function test_revertsOnInvalidFactoryTickRange() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.InvalidTickRange.selector);
        new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            stabilityGuard,
            IWrappedNative(address(wrappedNative)),
            TICK_UPPER,
            TICK_LOWER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
    }

    function test_revertsOnZeroCreationCodeHash() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroCreationCodeHash.selector);
        new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            stabilityGuard,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            bytes32(0)
        );
    }

    function _assertDeployedBundle(
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed
    ) internal view {
        assertEq(address(factory.POOL_STABILITY_GUARD()), address(stabilityGuard));
        assertTrue(deployed.proposalSource != address(0));
        assertTrue(deployed.spotAdapter != address(0));
        assertTrue(deployed.conditionalAdapter != address(0));
        assertTrue(deployed.manager != address(0));

        FutarchyOfficialProposalSource source =
            FutarchyOfficialProposalSource(deployed.proposalSource);
        assertEq(source.owner(), owner);
        assertEq(source.proposalManager(), proposalManager);
        assertEq(source.officialProposer(), officialProposer);
        assertEq(address(source.ALGEBRA_FACTORY()), address(algebraFactory));
        assertEq(source.activationTarget(), deployed.manager);

        SwaprAlgebraLiquidityAdapter spotAdapter =
            SwaprAlgebraLiquidityAdapter(deployed.spotAdapter);
        SwaprAlgebraDirectConditionalAdapter conditionalAdapter =
            SwaprAlgebraDirectConditionalAdapter(deployed.conditionalAdapter);
        assertEq(address(spotAdapter.POSITION_MANAGER()), address(positionManager));
        assertEq(address(spotAdapter.FACTORY()), address(algebraFactory));
        assertEq(address(conditionalAdapter.FACTORY()), address(algebraFactory));
        assertEq(spotAdapter.MANAGER(), deployed.manager);
        assertEq(conditionalAdapter.MANAGER(), deployed.manager);
        assertEq(spotAdapter.DEFAULT_TICK_LOWER(), TICK_LOWER);
        assertEq(spotAdapter.DEFAULT_TICK_UPPER(), TICK_UPPER);
        assertEq(conditionalAdapter.TICK_LOWER(), TICK_LOWER);
        assertEq(conditionalAdapter.TICK_UPPER(), TICK_UPPER);

        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(deployed.manager));
        assertEq(manager.owner(), owner);
        assertEq(manager.BOOTSTRAP_RECIPIENT(), bootstrapRecipient);
        assertEq(address(manager.COMPANY_TOKEN()), address(company));
        assertEq(address(manager.WRAPPED_NATIVE()), address(wrappedNative));
        assertEq(address(manager.PROPOSAL_SOURCE()), deployed.proposalSource);
        assertEq(address(manager.SPOT_ADAPTER()), deployed.spotAdapter);
        assertEq(address(manager.CONDITIONAL_ADAPTER()), deployed.conditionalAdapter);
        assertEq(address(manager.CONDITIONAL_ROUTER()), address(conditionalRouter));
        assertEq(address(manager.POOL_STABILITY_GUARD()), address(stabilityGuard));
        assertEq(manager.name(), "Organization Futarchy LP");
        assertEq(manager.symbol(), "ORG-FLM");
    }

    function _createParams(bytes memory proposalValidationConfigData)
        internal
        view
        returns (FutarchyLiquidityManagerFactory.CreateParams memory)
    {
        return FutarchyLiquidityManagerFactory.CreateParams({
            organization: organization,
            owner: owner,
            proposalManager: proposalManager,
            bootstrapRecipient: bootstrapRecipient,
            companyToken: company,
            officialProposer: officialProposer,
            lpTokenName: "Organization Futarchy LP",
            lpTokenSymbol: "ORG-FLM",
            proposalValidationConfigData: proposalValidationConfigData
        });
    }

    function _creationCodes()
        internal
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

    function _defaultValidationConfigData() internal view returns (bytes memory) {
        return abi.encode(
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
        );
    }

    function _newFactory(
        ISwaprAlgebraPositionManager positionManager_,
        MockAlgebraFactoryLike algebraFactory_,
        MockPoolStabilityGuard stabilityGuard_
    ) internal returns (FutarchyLiquidityManagerFactory) {
        return new FutarchyLiquidityManagerFactory(
            positionManager_,
            algebraFactory_,
            conditionalRouter,
            stabilityGuard_,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(SwaprAlgebraDirectConditionalAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );
    }
}
