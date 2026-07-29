// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {FLMMarketLauncher} from "../src/factories/FLMMarketLauncher.sol";

/// @dev Order: (1) deploy launcher unbound; (2) deploy FLM with proposalManager and
/// officialProposer both set to it; (3) owner calls bind(source, manager, factory, org, tokens...);
/// (4) organization owner calls organization.setEditor(launcher).
contract DeployFLMMarketLauncher is Script {
    using stdJson for string;

    function run() external returns (FLMMarketLauncher launcher) {
        string memory configPath =
            vm.envOr("FLM_LAUNCHER_CONFIG", string("config/gnosis.example.json"));
        string memory outputPath = vm.envOr(
            "FLM_LAUNCHER_DEPLOY_OUTPUT", string("deployments/flm.market-launcher.latest.json")
        );
        address owner = vm.readFile(configPath).readAddress(".owner");

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
