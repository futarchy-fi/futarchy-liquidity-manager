// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";

/// @notice Builds the one Safe transaction that creates a local condition/proposal then activates
/// FLM.
/// @dev `preActivation*` are intentionally raw: the local operator's proposal implementation owns
/// its ABI.
contract BuildActivationBundle is Script {
    using stdJson for string;

    struct Config {
        uint256 chainId;
        string name;
        address safe;
        address owner;
        address proposalSource;
        uint256 proposalId;
        address proposal;
        address creator;
        address[] preActivationTargets;
        uint256[] preActivationValues;
        bytes[] preActivationData;
    }

    function run() external {
        string memory configPath = vm.envOr(
            "FLM_ACTIVATION_CONFIG", string("config/batches/activation-bundle.example.json")
        );
        string memory outputPath =
            vm.envOr("FLM_ACTIVATION_OUTPUT", string("out/flm-activation-bundle.json"));
        string memory batch = build(vm.readFile(configPath));
        vm.writeFile(outputPath, batch);
        console2.log("Config:", configPath);
        console2.log("Output:", outputPath);
    }

    function build(string memory json) public view returns (string memory) {
        Config memory cfg = _read(json);
        require(
            cfg.preActivationTargets.length == cfg.preActivationValues.length
                && cfg.preActivationTargets.length == cfg.preActivationData.length,
            "pre-activation lengths"
        );

        string memory txs;
        for (uint256 i; i < cfg.preActivationTargets.length; ++i) {
            txs = _append(
                txs,
                _tx(
                    cfg.preActivationTargets[i],
                    cfg.preActivationValues[i],
                    cfg.preActivationData[i]
                )
            );
        }
        txs = _append(
            txs,
            _tx(
                cfg.proposalSource,
                0,
                abi.encodeCall(
                    FutarchyOfficialProposalSource.setOfficialProposal,
                    (cfg.proposalId, cfg.proposal, cfg.creator)
                )
            )
        );
        return _batch(cfg, txs);
    }

    function _read(string memory json) private pure returns (Config memory cfg) {
        cfg.chainId = json.readUint(".chainId");
        cfg.name = json.readString(".name");
        cfg.safe = json.readAddress(".createdFromSafeAddress");
        cfg.owner = json.readAddress(".createdFromOwnerAddress");
        cfg.proposalSource = json.readAddress(".proposalSource");
        cfg.proposalId = json.readUint(".proposalId");
        cfg.proposal = json.readAddress(".proposal");
        cfg.creator = json.readAddress(".creator");
        cfg.preActivationTargets = json.readAddressArray(".preActivationTargets");
        cfg.preActivationValues = json.readUintArray(".preActivationValues");
        cfg.preActivationData = json.readBytesArray(".preActivationData");
    }

    function _batch(Config memory cfg, string memory txs) private view returns (string memory) {
        return string.concat(
            "{",
            '"version":"1.0",',
            '"chainId":"',
            vm.toString(cfg.chainId),
            '",',
            '"createdAt":0,',
            '"meta":{"name":"',
            cfg.name,
            '","description":"Atomic FLM activation: local condition/proposal setup then setOfficialProposal",',
            '"txBuilderVersion":"1.18.0",',
            '"createdFromSafeAddress":"',
            vm.toString(cfg.safe),
            '",',
            '"createdFromOwnerAddress":"',
            vm.toString(cfg.owner),
            '","checksum":"0x0"},',
            '"transactions":[',
            txs,
            "]}"
        );
    }

    function _tx(address to, uint256 value, bytes memory data)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "{\"to\":\"",
            vm.toString(to),
            "\",\"value\":\"",
            vm.toString(value),
            "\",\"data\":\"",
            vm.toString(data),
            "\",\"contractMethod\":null,\"contractInputsValues\":null}"
        );
    }

    function _append(string memory txs, string memory txJson)
        private
        pure
        returns (string memory)
    {
        return bytes(txs).length == 0 ? txJson : string.concat(txs, ",", txJson);
    }
}
