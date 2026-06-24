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
        address collateralToken;
        uint256 companyAmount;
        uint256 collateralAmount;
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
        string memory summaryPath =
            vm.envOr("FLM_BATCH_SUMMARY", string("out/flm-safe-batch.summary.md"));
        string memory json = vm.readFile(configPath);
        BatchConfig memory cfg = _readBatchConfig(json);

        string memory txs = _buildTransactions(json, cfg);
        string memory batch = _safeBatchJson(cfg, txs);
        vm.writeFile(outputPath, batch);
        vm.writeFile(summaryPath, _summaryMarkdown(json, cfg, outputPath));

        console2.log("Config:", configPath);
        console2.log("Output:", outputPath);
        console2.log("Summary:", summaryPath);
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
        cfg.collateralToken = json.readAddress(".collateralToken");
        cfg.companyAmount = json.readUint(".companyAmount");
        cfg.collateralAmount = json.readUint(".collateralAmount");
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
            bytes memory init = _encodeBootstrapCall(json, cfg);
            return _approvalsAndCall(cfg, cfg.manager, cfg.nativeValue, init);
        }

        if (_eq(cfg.operation, "depositToSpot")) {
            bytes memory deposit = _encodeDepositCall(json, cfg);
            return _approvalsAndCall(cfg, cfg.manager, cfg.nativeValue, deposit);
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

    function _encodeBootstrapCall(string memory json, BatchConfig memory cfg)
        internal
        view
        returns (bytes memory)
    {
        if (cfg.collateralAmount > 0) {
            require(cfg.nativeValue == 0, "mixed collateral value");
            require(cfg.collateralToken != address(0), "collateral token");
            return abi.encodeWithSignature(
                "initializeFromBootstrap(uint256,uint256,bytes)",
                cfg.companyAmount,
                cfg.collateralAmount,
                _addParams(json, ".spotAdd")
            );
        }

        return abi.encodeWithSignature(
            "initializeFromBootstrap(uint256,bytes)",
            cfg.companyAmount,
            _addParams(json, ".spotAdd")
        );
    }

    function _encodeDepositCall(string memory json, BatchConfig memory cfg)
        internal
        view
        returns (bytes memory)
    {
        if (cfg.collateralAmount > 0) {
            require(cfg.nativeValue == 0, "mixed collateral value");
            require(cfg.collateralToken != address(0), "collateral token");
            return abi.encodeWithSignature(
                "depositToSpot(uint256,uint256,bytes)",
                cfg.companyAmount,
                cfg.collateralAmount,
                _addParams(json, ".spotAdd")
            );
        }

        return abi.encodeWithSignature(
            "depositToSpot(uint256,bytes)", cfg.companyAmount, _addParams(json, ".spotAdd")
        );
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

    function _approvalsAndCall(
        BatchConfig memory cfg,
        address target,
        uint256 value,
        bytes memory callData
    ) internal view returns (string memory) {
        string memory txs = "";
        if (cfg.companyAmount > 0) {
            txs = _appendTx(
                txs,
                _txJson(
                    cfg.companyToken,
                    0,
                    abi.encodeCall(IERC20.approve, (cfg.manager, cfg.companyAmount))
                )
            );
        }
        if (cfg.collateralAmount > 0) {
            txs = _appendTx(
                txs,
                _txJson(
                    cfg.collateralToken,
                    0,
                    abi.encodeCall(IERC20.approve, (cfg.manager, cfg.collateralAmount))
                )
            );
        }
        return _appendTx(txs, _txJson(target, value, callData));
    }

    function _appendTx(string memory txs, string memory txJson)
        internal
        pure
        returns (string memory)
    {
        if (bytes(txs).length == 0) return txJson;
        return string.concat(txs, ",", txJson);
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

    function _summaryMarkdown(string memory json, BatchConfig memory cfg, string memory outputPath)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "# FLM Safe Batch Summary\n\n",
            _summaryHeader(cfg, outputPath),
            _summaryAdapterParams(json),
            _summaryValidation(json),
            "## Review Checklist\n\n",
            "- Confirm every `to` address in the Safe JSON matches this summary.\n",
            "- Confirm `value` is nonzero only for native-collateral calls.\n",
            "- Confirm slippage minimums and deadlines came from a fresh quote.\n",
            "- Decode every `data` field before signing.\n"
        );
    }

    function _summaryHeader(BatchConfig memory cfg, string memory outputPath)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            _summaryBatchInfo(cfg, outputPath),
            _summaryTargets(cfg),
            _summaryAmounts(cfg),
            _summaryProposal(cfg)
        );
    }

    function _summaryBatchInfo(BatchConfig memory cfg, string memory outputPath)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "- Output: `",
            outputPath,
            "`\n",
            "- Chain ID: `",
            vm.toString(cfg.chainId),
            "`\n",
            "- Operation: `",
            cfg.operation,
            "`\n",
            "- Safe: `",
            vm.toString(cfg.safe),
            "`\n",
            "- Owner: `",
            vm.toString(cfg.owner),
            "`\n"
        );
    }

    function _summaryTargets(BatchConfig memory cfg) internal view returns (string memory) {
        return string.concat(
            "- Manager: `",
            vm.toString(cfg.manager),
            "`\n",
            "- Proposal source: `",
            vm.toString(cfg.proposalSource),
            "`\n",
            "- Company token: `",
            vm.toString(cfg.companyToken),
            "`\n",
            "- Collateral token: `",
            vm.toString(cfg.collateralToken),
            "`\n"
        );
    }

    function _summaryAmounts(BatchConfig memory cfg) internal view returns (string memory) {
        return string.concat(
            "- Company amount: `",
            vm.toString(cfg.companyAmount),
            "`\n",
            "- Collateral amount: `",
            vm.toString(cfg.collateralAmount),
            "`\n",
            "- Native value: `",
            vm.toString(cfg.nativeValue),
            "`\n",
            "- Shares: `",
            vm.toString(cfg.shares),
            "`\n",
            "- Recipient: `",
            vm.toString(cfg.recipient),
            "`\n",
            "- Unwrap native: `",
            vm.toString(cfg.unwrapNative),
            "`\n"
        );
    }

    function _summaryProposal(BatchConfig memory cfg) internal view returns (string memory) {
        return string.concat(
            "- Proposal ID: `",
            vm.toString(cfg.proposalId),
            "`\n",
            "- Proposal: `",
            vm.toString(cfg.proposal),
            "`\n",
            "- Creator: `",
            vm.toString(cfg.creator),
            "`\n\n"
        );
    }

    function _summaryAdapterParams(string memory json) internal view returns (string memory) {
        return string.concat(
            "## Adapter Parameters\n\n",
            _addParamSummary(json, "spotAdd", ".spotAdd"),
            _exitParamSummary(json, "spotExit", ".spotExit"),
            _addParamSummary(json, "yesAdd", ".yesAdd"),
            _addParamSummary(json, "noAdd", ".noAdd"),
            _exitParamSummary(json, "yesExit", ".yesExit"),
            _exitParamSummary(json, "noExit", ".noExit"),
            "\n"
        );
    }

    function _addParamSummary(string memory json, string memory label, string memory base)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "- `",
            label,
            "` tickLower `",
            vm.toString(json.readInt(string.concat(base, ".tickLower"))),
            "`, tickUpper `",
            vm.toString(json.readInt(string.concat(base, ".tickUpper"))),
            "`, amount0Min `",
            vm.toString(json.readUint(string.concat(base, ".amount0Min"))),
            "`, amount1Min `",
            vm.toString(json.readUint(string.concat(base, ".amount1Min"))),
            "`, deadline `",
            vm.toString(json.readUint(string.concat(base, ".deadline"))),
            "`, sqrtPriceX96 `",
            vm.toString(json.readUint(string.concat(base, ".sqrtPriceX96"))),
            "`\n"
        );
    }

    function _exitParamSummary(string memory json, string memory label, string memory base)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "- `",
            label,
            "` amount0Min `",
            vm.toString(json.readUint(string.concat(base, ".amount0Min"))),
            "`, amount1Min `",
            vm.toString(json.readUint(string.concat(base, ".amount1Min"))),
            "`, deadline `",
            vm.toString(json.readUint(string.concat(base, ".deadline"))),
            "`\n"
        );
    }

    function _summaryValidation(string memory json) internal view returns (string memory) {
        return string.concat(
            "## Proposal Validation\n\n",
            _summaryValidationAddresses(json),
            _summaryValidationBounds(json)
        );
    }

    function _summaryValidationAddresses(string memory json) internal view returns (string memory) {
        string memory base = ".validation";
        return string.concat(
            "- Enabled: `",
            vm.toString(json.readBool(string.concat(base, ".enabled"))),
            "`\n",
            "- Expected proposal token: `",
            vm.toString(json.readAddress(string.concat(base, ".expectedProposalToken"))),
            "`\n",
            "- Expected collateral token: `",
            vm.toString(json.readAddress(string.concat(base, ".expectedCollateralToken"))),
            "`\n",
            "- Conditional tokens: `",
            vm.toString(json.readAddress(string.concat(base, ".conditionalTokens"))),
            "`\n",
            "- Trusted oracle: `",
            vm.toString(json.readAddress(string.concat(base, ".trustedOracle"))),
            "`\n",
            "- Realitio: `",
            vm.toString(json.readAddress(string.concat(base, ".realitio"))),
            "`\n",
            "- Trusted arbitrator: `",
            vm.toString(json.readAddress(string.concat(base, ".trustedArbitrator"))),
            "`\n"
        );
    }

    function _summaryValidationBounds(string memory json) internal view returns (string memory) {
        string memory base = ".validation";
        return string.concat(
            "- Max opening delay: `",
            vm.toString(json.readUint(string.concat(base, ".maxOpeningDelay"))),
            "`\n",
            "- Min timeout: `",
            vm.toString(json.readUint(string.concat(base, ".minTimeout"))),
            "`\n",
            "- Max timeout: `",
            vm.toString(json.readUint(string.concat(base, ".maxTimeout"))),
            "`\n",
            "- Max min bond: `",
            vm.toString(json.readUint(string.concat(base, ".maxMinBond"))),
            "`\n",
            "- Require pools: `",
            vm.toString(json.readBool(string.concat(base, ".requirePools"))),
            "`\n\n"
        );
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
