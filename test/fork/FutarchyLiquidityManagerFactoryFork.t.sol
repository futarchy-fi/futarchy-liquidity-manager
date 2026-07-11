// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {
    FutarchyLiquidityManager,
    IWrappedNative
} from "../../src/core/FutarchyLiquidityManager.sol";
import {
    FutarchyLiquidityManagerFactory
} from "../../src/factories/FutarchyLiquidityManagerFactory.sol";
import {IAlgebraFactoryLike} from "../../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../../src/interfaces/IFutarchyConditionalRouter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";
import {AlgebraPoolStabilityGuard} from "../../src/oracles/AlgebraPoolStabilityGuard.sol";
import {FutarchyOfficialProposalSource} from "../../src/sources/FutarchyOfficialProposalSource.sol";

contract FutarchyLiquidityManagerFactoryForkTest is Test {
    address internal constant GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;
    address internal constant SWAPR_ALGEBRA_FACTORY = 0xA0864cCA6E114013AB0e27cbd5B6f4c8947da766;
    address internal constant FUTARCHY_ROUTER = 0x7495a583ba85875d59407781b4958ED6e0E1228f;

    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    function testFork_permissionlessFactoryCreatesRealDependencyBundleBelowGnosisGasLimit() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        AlgebraPoolStabilityGuard guard =
            new AlgebraPoolStabilityGuard(IAlgebraFactoryLike(SWAPR_ALGEBRA_FACTORY));
        FutarchyLiquidityManagerFactory factory = new FutarchyLiquidityManagerFactory(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER),
            IAlgebraFactoryLike(SWAPR_ALGEBRA_FACTORY),
            IFutarchyConditionalRouter(FUTARCHY_ROUTER),
            guard,
            IWrappedNative(WXDAI),
            FULL_RANGE_LOWER,
            FULL_RANGE_UPPER,
            keccak256(type(FutarchyOfficialProposalSource).creationCode),
            keccak256(type(SwaprAlgebraLiquidityAdapter).creationCode),
            keccak256(type(FutarchyLiquidityManager).creationCode)
        );

        FutarchyLiquidityManagerFactory.CreateParams memory params =
            FutarchyLiquidityManagerFactory.CreateParams({
                organization: address(this),
                owner: address(this),
                proposalManager: address(this),
                bootstrapRecipient: address(this),
                companyToken: IERC20(GNO),
                officialProposer: address(this),
                lpTokenName: "Gnosis Fork FLM",
                lpTokenSymbol: "FORK-FLM",
                proposalValidationConfigData: ""
            });
        FutarchyLiquidityManagerFactory.CreationCodes memory codes =
            FutarchyLiquidityManagerFactory.CreationCodes({
                proposalSource: type(FutarchyOfficialProposalSource).creationCode,
                adapter: type(SwaprAlgebraLiquidityAdapter).creationCode,
                manager: type(FutarchyLiquidityManager).creationCode
            });

        bytes memory callData = abi.encodeWithSelector(
            FutarchyLiquidityManagerFactory.createLiquidityManager.selector, params, codes
        );
        uint256 gasBefore = gasleft();
        FutarchyLiquidityManagerFactory.DeployedContracts memory deployed =
            factory.createLiquidityManager(params, codes);
        uint256 executionGas = gasBefore - gasleft();
        uint256 conservativeTransactionGas = executionGas + 21_000 + (callData.length * 16);

        emit log_named_uint("factory create execution gas", executionGas);
        emit log_named_uint(
            "factory create conservative transaction gas", conservativeTransactionGas
        );
        assertLt(conservativeTransactionGas, 13_000_000, "insufficient Gnosis block gas margin");

        SwaprAlgebraLiquidityAdapter spotAdapter =
            SwaprAlgebraLiquidityAdapter(deployed.spotAdapter);
        SwaprAlgebraLiquidityAdapter conditionalAdapter =
            SwaprAlgebraLiquidityAdapter(deployed.conditionalAdapter);
        FutarchyLiquidityManager manager = FutarchyLiquidityManager(payable(deployed.manager));

        assertEq(spotAdapter.MANAGER(), deployed.manager);
        assertEq(conditionalAdapter.MANAGER(), deployed.manager);
        assertEq(address(manager.COMPANY_TOKEN()), GNO);
        assertEq(address(manager.WRAPPED_NATIVE()), WXDAI);
        assertEq(address(manager.CONDITIONAL_ROUTER()), FUTARCHY_ROUTER);
        assertEq(address(manager.POOL_STABILITY_GUARD()), address(guard));
    }
}
