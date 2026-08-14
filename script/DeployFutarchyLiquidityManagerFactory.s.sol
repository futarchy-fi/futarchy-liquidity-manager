// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {
    FutarchyLiquidityManagerFactory
} from "../src/factories/FutarchyLiquidityManagerFactory.sol";
import {IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../src/interfaces/IPoolStabilityGuard.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";

contract DeployFutarchyLiquidityManagerFactory is Script {
    int24 internal constant DEFAULT_TICK_LOWER = -887_220;
    int24 internal constant DEFAULT_TICK_UPPER = 887_220;

    string internal constant PROPOSAL_SOURCE_ARTIFACT =
        "src/sources/FutarchyOfficialProposalSource.sol:FutarchyOfficialProposalSource";
    string internal constant SPOT_ADAPTER_ARTIFACT =
        "src/adapters/SwaprAlgebraLiquidityAdapter.sol:SwaprAlgebraLiquidityAdapter";
    string internal constant CONDITIONAL_ADAPTER_ARTIFACT =
        "src/adapters/SwaprAlgebraDirectConditionalAdapter.sol:SwaprAlgebraDirectConditionalAdapter";
    string internal constant MANAGER_ARTIFACT =
        "src/core/FutarchyLiquidityManager.sol:FutarchyLiquidityManager";

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        string memory outputPath =
            vm.envOr("FLM_FACTORY_DEPLOY_OUTPUT", string("deployments/flm.factory.latest.json"));

        ISwaprAlgebraPositionManager positionManager =
            ISwaprAlgebraPositionManager(vm.envAddress("FLM_POSITION_MANAGER"));
        IAlgebraFactoryLike algebraFactory =
            IAlgebraFactoryLike(vm.envAddress("FLM_ALGEBRA_FACTORY"));
        IFutarchyConditionalRouter conditionalRouter =
            IFutarchyConditionalRouter(vm.envAddress("FLM_CONDITIONAL_ROUTER"));
        IPoolStabilityGuard poolStabilityGuard =
            IPoolStabilityGuard(vm.envAddress("FLM_POOL_STABILITY_GUARD"));
        IWrappedNative wrappedNative = IWrappedNative(vm.envAddress("FLM_WRAPPED_NATIVE"));
        bytes32 proposalSourceCreationCodeHash = keccak256(vm.getCode(PROPOSAL_SOURCE_ARTIFACT));
        bytes32 spotAdapterCreationCodeHash = keccak256(vm.getCode(SPOT_ADAPTER_ARTIFACT));
        bytes32 conditionalAdapterCreationCodeHash =
            keccak256(vm.getCode(CONDITIONAL_ADAPTER_ARTIFACT));
        bytes32 managerCreationCodeHash = keccak256(vm.getCode(MANAGER_ARTIFACT));

        vm.startBroadcast(privateKey);
        FutarchyLiquidityManagerFactory factory = new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            poolStabilityGuard,
            wrappedNative,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
            proposalSourceCreationCodeHash,
            spotAdapterCreationCodeHash,
            conditionalAdapterCreationCodeHash,
            managerCreationCodeHash
        );
        vm.stopBroadcast();

        _writeDeploymentOutput(
            outputPath,
            address(factory),
            address(positionManager),
            address(algebraFactory),
            address(conditionalRouter),
            address(poolStabilityGuard),
            address(wrappedNative),
            proposalSourceCreationCodeHash,
            spotAdapterCreationCodeHash,
            conditionalAdapterCreationCodeHash,
            managerCreationCodeHash
        );

        console2.log("Output:", outputPath);
        console2.log("Chain ID:", block.chainid);
        console2.log("Factory:", address(factory));
        console2.log("Position manager:", address(positionManager));
        console2.log("Algebra factory:", address(algebraFactory));
        console2.log("Conditional router:", address(conditionalRouter));
        console2.log("Pool stability guard:", address(poolStabilityGuard));
        console2.log("Wrapped native/collateral:", address(wrappedNative));
        console2.logBytes32(proposalSourceCreationCodeHash);
        console2.logBytes32(spotAdapterCreationCodeHash);
        console2.logBytes32(conditionalAdapterCreationCodeHash);
        console2.logBytes32(managerCreationCodeHash);
    }

    function _writeDeploymentOutput(
        string memory path,
        address factory,
        address positionManager,
        address algebraFactory,
        address conditionalRouter,
        address poolStabilityGuard,
        address wrappedNative,
        bytes32 proposalSourceCreationCodeHash,
        bytes32 spotAdapterCreationCodeHash,
        bytes32 conditionalAdapterCreationCodeHash,
        bytes32 managerCreationCodeHash
    ) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "factory", factory);
        vm.serializeAddress(key, "positionManager", positionManager);
        vm.serializeAddress(key, "algebraFactory", algebraFactory);
        vm.serializeAddress(key, "conditionalRouter", conditionalRouter);
        vm.serializeAddress(key, "poolStabilityGuard", poolStabilityGuard);
        vm.serializeAddress(key, "wrappedNative", wrappedNative);
        vm.serializeBytes32(key, "proposalSourceCreationCodeHash", proposalSourceCreationCodeHash);
        vm.serializeBytes32(key, "spotAdapterCreationCodeHash", spotAdapterCreationCodeHash);
        vm.serializeBytes32(
            key, "conditionalAdapterCreationCodeHash", conditionalAdapterCreationCodeHash
        );
        string memory output =
            vm.serializeBytes32(key, "managerCreationCodeHash", managerCreationCodeHash);
        vm.writeJson(output, path);
    }
}
