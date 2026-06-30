// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SwaprAlgebraLiquidityAdapter} from "../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {
    FutarchyLiquidityManagerFactory
} from "../src/factories/FutarchyLiquidityManagerFactory.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract FutarchyLiquidityManagerFactoryTest is Test {
    MockMintableERC20 internal company;
    MockWrappedNative internal wrappedNative;
    MockAlgebraFactoryLike internal algebraFactory;
    MockConditionalRouter internal conditionalRouter;
    FutarchyLiquidityManagerFactory internal factory;

    ISwaprAlgebraPositionManager internal positionManager =
        ISwaprAlgebraPositionManager(address(0xCAFE));

    address internal organization = address(0x0A6);
    address internal owner = address(0x0A11CE);
    address internal proposalManager = address(0x0B055);
    address internal bootstrapRecipient = address(0xB007);
    address internal officialProposer = address(0x0FF1C1A1);
    address internal creator = address(0xC0FFEE);

    int24 internal constant TICK_LOWER = -887_220;
    int24 internal constant TICK_UPPER = 887_220;

    function setUp() public {
        company = new MockMintableERC20("Company", "COMP");
        wrappedNative = new MockWrappedNative();
        algebraFactory = new MockAlgebraFactoryLike();
        conditionalRouter = new MockConditionalRouter();

        factory = new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function test_anyWalletDeploysDefaultFlmBundle() public {
        vm.prank(creator);
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(_createParams(""));

        _assertDeployedBundle(deployed);
    }

    function test_passesInitialProposalValidationConfigToProposalSource() public {
        FutarchyOfficialProposalSource.ProposalValidationConfig memory validation =
            FutarchyOfficialProposalSource.ProposalValidationConfig({
                enabled: true,
                expectedProposalToken: address(company),
                expectedCollateralToken: address(wrappedNative),
                conditionalTokens: address(0xC0DE),
                trustedOracle: address(0x0A0),
                realitio: address(0x0A1),
                trustedArbitrator: address(0x0A2),
                maxOpeningDelay: 7 days,
                minTimeout: 1 hours,
                maxTimeout: 7 days,
                maxMinBond: 1 ether,
                requirePools: true
            });

        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(_createParams(abi.encode(validation)));

        (
            bool enabled,
            address expectedProposalToken,
            address expectedCollateralToken,
            address conditionalTokens,
            address trustedOracle,
            address realitio,
            address trustedArbitrator,
            uint32 maxOpeningDelay,
            uint32 minTimeout,
            uint32 maxTimeout,
            uint256 maxMinBond,
            bool requirePools
        ) = FutarchyOfficialProposalSource(deployed.proposalSource).proposalValidationConfig();

        assertTrue(enabled);
        assertEq(expectedProposalToken, address(company));
        assertEq(expectedCollateralToken, address(wrappedNative));
        assertEq(conditionalTokens, address(0xC0DE));
        assertEq(trustedOracle, address(0x0A0));
        assertEq(realitio, address(0x0A1));
        assertEq(trustedArbitrator, address(0x0A2));
        assertEq(maxOpeningDelay, 7 days);
        assertEq(minTimeout, 1 hours);
        assertEq(maxTimeout, 7 days);
        assertEq(maxMinBond, 1 ether);
        assertTrue(requirePools);
    }

    function test_revertsOnZeroCreateParams() public {
        FutarchyLiquidityManagerFactory.CreateParams memory params = _createParams("");
        params.owner = address(0);

        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroAddress.selector);
        factory.createLiquidityManager(params);
    }

    function test_revertsOnZeroConstructorDependency() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.ZeroAddress.selector);
        new FutarchyLiquidityManagerFactory(
            ISwaprAlgebraPositionManager(address(0)),
            algebraFactory,
            conditionalRouter,
            IWrappedNative(address(wrappedNative)),
            TICK_LOWER,
            TICK_UPPER
        );
    }

    function test_revertsOnInvalidFactoryTickRange() public {
        vm.expectRevert(FutarchyLiquidityManagerFactory.InvalidTickRange.selector);
        new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            IWrappedNative(address(wrappedNative)),
            TICK_UPPER,
            TICK_LOWER
        );
    }

    function _assertDeployedBundle(
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed
    ) internal view {
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

        SwaprAlgebraLiquidityAdapter spotAdapter =
            SwaprAlgebraLiquidityAdapter(deployed.spotAdapter);
        SwaprAlgebraLiquidityAdapter conditionalAdapter =
            SwaprAlgebraLiquidityAdapter(deployed.conditionalAdapter);
        assertEq(address(spotAdapter.POSITION_MANAGER()), address(positionManager));
        assertEq(address(conditionalAdapter.POSITION_MANAGER()), address(positionManager));
        assertEq(spotAdapter.DEFAULT_TICK_LOWER(), TICK_LOWER);
        assertEq(spotAdapter.DEFAULT_TICK_UPPER(), TICK_UPPER);
        assertEq(conditionalAdapter.DEFAULT_TICK_LOWER(), TICK_LOWER);
        assertEq(conditionalAdapter.DEFAULT_TICK_UPPER(), TICK_UPPER);

        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(deployed.manager));
        assertEq(manager.owner(), owner);
        assertEq(manager.BOOTSTRAP_RECIPIENT(), bootstrapRecipient);
        assertEq(address(manager.COMPANY_TOKEN()), address(company));
        assertEq(address(manager.WRAPPED_NATIVE()), address(wrappedNative));
        assertEq(manager.OFFICIAL_PROPOSER(), officialProposer);
        assertEq(address(manager.PROPOSAL_SOURCE()), deployed.proposalSource);
        assertEq(address(manager.SPOT_ADAPTER()), deployed.spotAdapter);
        assertEq(address(manager.CONDITIONAL_ADAPTER()), deployed.conditionalAdapter);
        assertEq(address(manager.CONDITIONAL_ROUTER()), address(conditionalRouter));
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
}
