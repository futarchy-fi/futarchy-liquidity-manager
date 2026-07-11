// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {AlgebraPoolStabilityGuard} from "../src/oracles/AlgebraPoolStabilityGuard.sol";

contract DeployAlgebraPoolStabilityGuard is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        IAlgebraFactoryLike algebraFactory =
            IAlgebraFactoryLike(vm.envAddress("FLM_ALGEBRA_FACTORY"));
        string memory outputPath = vm.envOr(
            "FLM_GUARD_DEPLOY_OUTPUT", string("deployments/flm.pool-stability-guard.latest.json")
        );

        vm.startBroadcast(privateKey);
        AlgebraPoolStabilityGuard guard = new AlgebraPoolStabilityGuard(algebraFactory);
        vm.stopBroadcast();

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "algebraFactory", address(algebraFactory));
        vm.serializeBytes32(key, "guardCodeHash", address(guard).codehash);
        string memory output = vm.serializeAddress(key, "poolStabilityGuard", address(guard));
        vm.writeJson(output, outputPath);

        console2.log("Output:", outputPath);
        console2.log("Chain ID:", block.chainid);
        console2.log("Algebra factory:", address(algebraFactory));
        console2.log("Pool stability guard:", address(guard));
    }
}
