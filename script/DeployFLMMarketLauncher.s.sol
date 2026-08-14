// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FLMMarketLauncher} from "../src/factories/FLMMarketLauncher.sol";

/// @dev Order: (1) deploy launcher unbound; (2) deploy FLM with proposalManager and
/// officialProposer both set to it; (3) owner calls bind(source, manager, factory, org, tokens...);
/// No Organization editor permission is needed for existing-market activation.
contract DeployFLMMarketLauncher is Script {
    function run() external returns (FLMMarketLauncher launcher) {
        string memory outputPath = vm.envOr(
            "FLM_LAUNCHER_DEPLOY_OUTPUT", string("deployments/flm.market-launcher.latest.json")
        );
        address owner = vm.envAddress("FLM_LAUNCHER_OWNER");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        launcher = new FLMMarketLauncher(owner);
        vm.stopBroadcast();

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "owner", owner);
        string memory output = vm.serializeAddress(key, "launcher", address(launcher));
        vm.writeJson(output, outputPath);
        console2.log("Launcher:", address(launcher));
        console2.log("Owner:", owner);
        console2.log("Output:", outputPath);
    }
}
