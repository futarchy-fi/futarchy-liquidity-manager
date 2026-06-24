// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyLiquidityManager} from "../src/core/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {SwaprAlgebraLiquidityAdapter} from "../src/adapters/SwaprAlgebraLiquidityAdapter.sol";

contract BuildLiquidityOperationBatch is Script {
    using stdJson for string;

    struct BatchConfig {
        uint256 chainId;
        string name;
        address safe;
        address owner;
        string operation;
        address manager;
        address proposalSource;
        address companyToken;
        uint256 companyAmount;
        uint256 nativeValue;
        uint256 shares;
        address recipient;
        bool unwrapNative;
        uint256 proposalId;
        address proposal;
        address creator;
    }

    function run() external {
        string memory configPath =
            vm.envOr("FLM_BATCH_CONFIG", string("config/safe-batch.example.json"));
        string memory outputPath = vm.envOr("FLM_BATCH_OUTPUT", string("out/flm-safe-batch.json"));
        string memory json = vm.readFile(configPath);
        BatchConfig memory cfg = _readBatchConfig(json);

        string memory txs = _buildTransactions(json, cfg);
        string memory batch = _safeBatchJson(cfg, txs);
        vm.writeFile(outputPath, batch);

        console2.log("Config:", configPath);
        console2.log("Output:", outputPath);
        console2.log("Operation:", cfg.operation);
        console2.log("Manager:", cfg.manager);
    }

    function _readBatchConfig(string memory json) internal view returns (BatchConfig memory cfg) {
        cfg.chainId = json.readUint(".chainId");
        cfg.name = json.readString(".name");
        cfg.safe = json.readAddress(".createdFromSafeAddress");
        cfg.owner = json.readAddress(".createdFromOwnerAddress");
        cfg.operation = json.readString(".operation");
        cfg.manager = json.readAddress(".manager");
        cfg.proposalSource = json.readAddress(".proposalSource");
        cfg.companyToken = json.readAddress(".companyToken");
        cfg.companyAmount = json.readUint(".companyAmount");
        cfg.nativeValue = json.readUint(".nativeValue");
        cfg.shares = json.readUintOr(".shares", 0);
        cfg.recipient = json.readAddressOr(".recipient", address(0));
        cfg.unwrapNative = json.readBool(".unwrapNative");
        cfg.proposalId = json.readUint(".proposalId");
        cfg.proposal = json.readAddress(".proposal");
        cfg.creator = json.readAddress(".creator");
    }

    function _buildTransactions(string memory json, BatchConfig memory cfg)
        internal
        view
        returns (string memory txs)
    {
        if (_eq(cfg.operation, "initializeFromBootstrap")) {
            bytes memory approve = abi.encodeCall(IERC20.approve, (cfg.manager, cfg.companyAmount));
            bytes memory init = abi.encodeCall(
                FutarchyLiquidityManager.initializeFromBootstrap,
                (cfg.companyAmount, _addParams(json, ".spotAdd"))
            );
            return _maybeApprovalAndCall(
                cfg.companyToken, cfg.companyAmount, approve, cfg.manager, cfg.nativeValue, init
            );
        }

        if (_eq(cfg.operation, "depositToSpot")) {
            bytes memory approve = abi.encodeCall(IERC20.approve, (cfg.manager, cfg.companyAmount));
            bytes memory deposit = abi.encodeCall(
                FutarchyLiquidityManager.depositToSpot,
                (cfg.companyAmount, _addParams(json, ".spotAdd"))
            );
            return _maybeApprovalAndCall(
                cfg.companyToken, cfg.companyAmount, approve, cfg.manager, cfg.nativeValue, deposit
            );
        }

        if (_eq(cfg.operation, "sync")) {
            return _txJson(
                cfg.manager, 0, abi.encodeCall(FutarchyLiquidityManager.sync, (_syncParams(json)))
            );
        }

        if (_eq(cfg.operation, "redeem")) {
            return _txJson(
                cfg.manager,
                0,
                abi.encodeCall(
                    FutarchyLiquidityManager.redeem,
                    (
                        cfg.shares,
                        cfg.recipient,
                        cfg.unwrapNative,
                        _exitParams(json, ".spotExit"),
                        _dualExitParams(json)
                    )
                )
            );
        }

        if (_eq(cfg.operation, "setOfficialProposal")) {
            return _txJson(
                cfg.proposalSource,
                0,
                abi.encodeCall(
                    FutarchyOfficialProposalSource.setOfficialProposal,
                    (cfg.proposalId, cfg.proposal, cfg.creator)
                )
            );
        }

        if (_eq(cfg.operation, "setProposalValidationConfig")) {
            return _txJson(
                cfg.proposalSource,
                0,
                abi.encodeCall(
                    FutarchyOfficialProposalSource.setProposalValidationConfig,
                    (_validation(json, ".validation"))
                )
            );
        }

        if (_eq(cfg.operation, "armEmergencyExit")) {
            return
                _txJson(
                    cfg.manager, 0, abi.encodeCall(FutarchyLiquidityManager.armEmergencyExit, ())
                );
        }

        if (_eq(cfg.operation, "disarmEmergencyExit")) {
            return _txJson(
                cfg.manager, 0, abi.encodeCall(FutarchyLiquidityManager.disarmEmergencyExit, ())
            );
        }

        if (_eq(cfg.operation, "emergencyExitAllToBootstrapRecipient")) {
            return _txJson(
                cfg.manager,
                0,
                abi.encodeCall(
                    FutarchyLiquidityManager.emergencyExitAllToBootstrapRecipient,
                    (cfg.unwrapNative, _exitParams(json, ".spotExit"), _dualExitParams(json))
                )
            );
        }

        if (_eq(cfg.operation, "sweepIdleToBootstrapRecipient")) {
            return _txJson(
                cfg.manager,
                0,
                abi.encodeCall(
                    FutarchyLiquidityManager.sweepIdleToBootstrapRecipient, (cfg.unwrapNative)
                )
            );
        }

        revert("unsupported operation");
    }

    function _syncParams(string memory json)
        internal
        view
        returns (FutarchyLiquidityManager.SyncParams memory params)
    {
        params.spotCompoundData = _exitParams(json, ".spotExit");
        params.conditionalCompoundData = _dualExitParams(json);
        params.spotToConditionalRemoveData = _exitParams(json, ".spotExit");
        params.spotToConditionalAddData =
            abi.encode(_addParams(json, ".yesAdd"), _addParams(json, ".noAdd"));
        params.conditionalToSpotRemoveData = _dualExitParams(json);
        params.conditionalToSpotAddData = _addParams(json, ".spotAdd");
    }

    function _addParams(string memory json, string memory base)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            SwaprAlgebraLiquidityAdapter.AddParams({
                tickLower: int24(json.readInt(string.concat(base, ".tickLower"))),
                tickUpper: int24(json.readInt(string.concat(base, ".tickUpper"))),
                amount0Min: json.readUint(string.concat(base, ".amount0Min")),
                amount1Min: json.readUint(string.concat(base, ".amount1Min")),
                deadline: json.readUint(string.concat(base, ".deadline")),
                sqrtPriceX96: uint160(json.readUint(string.concat(base, ".sqrtPriceX96")))
            })
        );
    }

    function _exitParams(string memory json, string memory base)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            SwaprAlgebraLiquidityAdapter.ExitParams({
                amount0Min: json.readUint(string.concat(base, ".amount0Min")),
                amount1Min: json.readUint(string.concat(base, ".amount1Min")),
                deadline: json.readUint(string.concat(base, ".deadline"))
            })
        );
    }

    function _dualExitParams(string memory json) internal view returns (bytes memory) {
        return abi.encode(_exitParams(json, ".yesExit"), _exitParams(json, ".noExit"));
    }

    function _validation(string memory json, string memory base)
        internal
        view
        returns (FutarchyOfficialProposalSource.ProposalValidationConfig memory config)
    {
        config.enabled = json.readBool(string.concat(base, ".enabled"));
        config.expectedProposalToken =
            json.readAddress(string.concat(base, ".expectedProposalToken"));
        config.expectedCollateralToken =
            json.readAddress(string.concat(base, ".expectedCollateralToken"));
        config.conditionalTokens = json.readAddress(string.concat(base, ".conditionalTokens"));
        config.trustedOracle = json.readAddress(string.concat(base, ".trustedOracle"));
        config.realitio = json.readAddress(string.concat(base, ".realitio"));
        config.trustedArbitrator = json.readAddress(string.concat(base, ".trustedArbitrator"));
        config.maxOpeningDelay = uint32(json.readUint(string.concat(base, ".maxOpeningDelay")));
        config.minTimeout = uint32(json.readUint(string.concat(base, ".minTimeout")));
        config.maxTimeout = uint32(json.readUint(string.concat(base, ".maxTimeout")));
        config.maxMinBond = json.readUint(string.concat(base, ".maxMinBond"));
        config.requirePools = json.readBool(string.concat(base, ".requirePools"));
    }

    function _maybeApprovalAndCall(
        address token,
        uint256 amount,
        bytes memory approveData,
        address target,
        uint256 value,
        bytes memory callData
    ) internal view returns (string memory) {
        string memory callTx = _txJson(target, value, callData);
        if (amount == 0) return callTx;
        return string.concat(_txJson(token, 0, approveData), ",", callTx);
    }

    function _safeBatchJson(BatchConfig memory cfg, string memory txs)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "{",
            '"version":"1.0",',
            '"chainId":"',
            vm.toString(cfg.chainId),
            '",',
            '"createdAt":0,',
            '"meta":{',
            '"name":"',
            cfg.name,
            '",',
            '"description":"Generated FLM operation batch",',
            '"txBuilderVersion":"1.18.0",',
            '"createdFromSafeAddress":"',
            vm.toString(cfg.safe),
            '",',
            '"createdFromOwnerAddress":"',
            vm.toString(cfg.owner),
            '",',
            '"checksum":"0x0"',
            "},",
            '"transactions":[',
            txs,
            "]",
            "}"
        );
    }

    function _txJson(address to, uint256 value, bytes memory data)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "{",
            '"to":"',
            vm.toString(to),
            '",',
            '"value":"',
            vm.toString(value),
            '",',
            '"data":"',
            vm.toString(data),
            '",',
            '"contractMethod":null,',
            '"contractInputsValues":null',
            "}"
        );
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
