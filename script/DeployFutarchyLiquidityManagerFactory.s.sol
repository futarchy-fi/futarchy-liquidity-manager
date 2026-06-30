// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {
    FutarchyLiquidityManagerFactory
} from "../src/factories/FutarchyLiquidityManagerFactory.sol";
import {IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";

contract DeployFutarchyLiquidityManagerFactory is Script {
    int24 internal constant DEFAULT_TICK_LOWER = -887_220;
    int24 internal constant DEFAULT_TICK_UPPER = 887_220;

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
        IWrappedNative wrappedNative = IWrappedNative(vm.envAddress("FLM_WRAPPED_NATIVE"));

        vm.startBroadcast(privateKey);
        FutarchyLiquidityManagerFactory factory = new FutarchyLiquidityManagerFactory(
            positionManager,
            algebraFactory,
            conditionalRouter,
            wrappedNative,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER
        );
        vm.stopBroadcast();

        _writeDeploymentOutput(
            outputPath,
            address(factory),
            address(positionManager),
            address(algebraFactory),
            address(conditionalRouter),
            address(wrappedNative)
        );

        console2.log("Output:", outputPath);
        console2.log("Chain ID:", block.chainid);
        console2.log("Factory:", address(factory));
        console2.log("Position manager:", address(positionManager));
        console2.log("Algebra factory:", address(algebraFactory));
        console2.log("Conditional router:", address(conditionalRouter));
        console2.log("Wrapped native/collateral:", address(wrappedNative));
    }

    function _writeDeploymentOutput(
        string memory path,
        address factory,
        address positionManager,
        address algebraFactory,
        address conditionalRouter,
        address wrappedNative
    ) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "factory", factory);
        vm.serializeAddress(key, "positionManager", positionManager);
        vm.serializeAddress(key, "algebraFactory", algebraFactory);
        vm.serializeAddress(key, "conditionalRouter", conditionalRouter);
        string memory output = vm.serializeAddress(key, "wrappedNative", wrappedNative);
        vm.writeJson(output, path);
    }
}
