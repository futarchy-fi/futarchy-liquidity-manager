// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {DeadlineBoundedRealityProxy} from "../src/oracles/DeadlineBoundedRealityProxy.sol";
import {SwaprAlgebraLiquidityAdapter} from "../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {IAlgebraFactoryLike} from "../src/interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {IConditionalTokensCore, IRealityETHCore} from "../src/interfaces/IFutarchyTradingCore.sol";
import {ISwaprAlgebraPositionManager} from "../src/interfaces/ISwaprAlgebraPositionManager.sol";

contract DeployFutarchyLiquidityManager is Script {
    using stdJson for string;

    struct DeployConfig {
        uint256 chainId;
        address owner;
        address proposalManager;
        address bootstrapRecipient;
        address companyToken;
        address officialProposer;
        address wrappedNative;
        address positionManager;
        address algebraFactory;
        address futarchyRouter;
        int24 tickLower;
        int24 tickUpper;
        string lpTokenName;
        string lpTokenSymbol;
        bool deployDeadlineProxy;
        address deadlineConditionalTokens;
        address deadlineRealitio;
        uint256 maxQuestionDuration;
        FutarchyOfficialProposalSource.ProposalValidationConfig validation;
    }

    struct DeployedContracts {
        address proposalSource;
        address deadlineProxy;
        address spotAdapter;
        address conditionalAdapter;
        address manager;
    }

    function run() external {
        string memory configPath =
            vm.envOr("FLM_DEPLOY_CONFIG", string("config/gnosis.example.json"));
        string memory outputPath =
            vm.envOr("FLM_DEPLOY_OUTPUT", string("deployments/flm.latest.json"));
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        bytes32 configHash = keccak256(bytes(vm.readFile(configPath)));
        DeployConfig memory cfg = _readConfig(configPath);
        _assertDeployConfig(cfg);

        vm.startBroadcast(privateKey);

        DeployedContracts memory deployed;

        if (cfg.deployDeadlineProxy) {
            deployed.deadlineProxy = address(
                new DeadlineBoundedRealityProxy(
                    IConditionalTokensCore(cfg.deadlineConditionalTokens),
                    IRealityETHCore(cfg.deadlineRealitio),
                    cfg.maxQuestionDuration
                )
            );
            if (cfg.validation.enabled && cfg.validation.trustedOracle == address(0)) {
                cfg.validation.trustedOracle = deployed.deadlineProxy;
            }
        }

        deployed.proposalSource = address(
            new FutarchyOfficialProposalSource(
                cfg.owner,
                cfg.proposalManager,
                cfg.officialProposer,
                IAlgebraFactoryLike(cfg.algebraFactory),
                _encodeInitialValidationConfig(cfg.validation)
            )
        );

        deployed.spotAdapter = address(
            new SwaprAlgebraLiquidityAdapter(
                ISwaprAlgebraPositionManager(cfg.positionManager), cfg.tickLower, cfg.tickUpper
            )
        );

        deployed.conditionalAdapter = address(
            new SwaprAlgebraLiquidityAdapter(
                ISwaprAlgebraPositionManager(cfg.positionManager), cfg.tickLower, cfg.tickUpper
            )
        );

        deployed.manager = address(
            new FutarchyLiquidityManager(
                cfg.bootstrapRecipient,
                IERC20(cfg.companyToken),
                IWrappedNative(cfg.wrappedNative),
                cfg.officialProposer,
                FutarchyOfficialProposalSource(deployed.proposalSource),
                SwaprAlgebraLiquidityAdapter(deployed.spotAdapter),
                SwaprAlgebraLiquidityAdapter(deployed.conditionalAdapter),
                IFutarchyConditionalRouter(cfg.futarchyRouter),
                cfg.owner,
                cfg.lpTokenName,
                cfg.lpTokenSymbol
            )
        );

        vm.stopBroadcast();

        _writeDeploymentOutput(outputPath, cfg, configHash, deployed);

        console2.log("Config:", configPath);
        console2.log("Output:", outputPath);
        console2.log("Owner:", cfg.owner);
        console2.log("Proposal manager:", cfg.proposalManager);
        console2.log("Bootstrap recipient:", cfg.bootstrapRecipient);
        console2.log("Company token:", cfg.companyToken);
        console2.log("Wrapped native:", cfg.wrappedNative);
        console2.log("Official proposer:", cfg.officialProposer);
        console2.log("Proposal source:", deployed.proposalSource);
        console2.log("Deadline proxy:", deployed.deadlineProxy);
        console2.log("Spot adapter:", deployed.spotAdapter);
        console2.log("Conditional adapter:", deployed.conditionalAdapter);
        console2.log("Liquidity manager:", deployed.manager);
    }

    function _readConfig(string memory path) internal view returns (DeployConfig memory cfg) {
        string memory json = vm.readFile(path);
        cfg.chainId = json.readUint(".chainId");
        cfg.owner = json.readAddress(".owner");
        cfg.proposalManager = json.readAddress(".proposalManager");
        cfg.bootstrapRecipient = json.readAddress(".bootstrapRecipient");
        cfg.companyToken = json.readAddress(".companyToken");
        cfg.officialProposer = json.readAddress(".officialProposer");
        cfg.wrappedNative = json.readAddress(".wrappedNative");
        cfg.positionManager = json.readAddress(".positionManager");
        cfg.algebraFactory = json.readAddress(".algebraFactory");
        cfg.futarchyRouter = json.readAddress(".futarchyRouter");
        cfg.tickLower = int24(json.readInt(".tickLower"));
        cfg.tickUpper = int24(json.readInt(".tickUpper"));
        cfg.lpTokenName = json.readString(".lpTokenName");
        cfg.lpTokenSymbol = json.readString(".lpTokenSymbol");
        cfg.deployDeadlineProxy = json.readBool(".deployDeadlineProxy");
        cfg.deadlineConditionalTokens = json.readAddress(".deadlineProxy.conditionalTokens");
        cfg.deadlineRealitio = json.readAddress(".deadlineProxy.realitio");
        cfg.maxQuestionDuration = json.readUint(".deadlineProxy.maxQuestionDuration");
        cfg.validation = _readValidation(json, ".validation");
    }

    function _readValidation(string memory json, string memory base)
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

    function _assertDeployConfig(DeployConfig memory cfg) internal view {
        require(block.chainid == cfg.chainId, "wrong chain");
        _requireNonzero(cfg.owner, "owner");
        _requireNonzero(cfg.proposalManager, "proposalManager");
        _requireNonzero(cfg.bootstrapRecipient, "bootstrapRecipient");
        _requireNonzero(cfg.companyToken, "companyToken");
        _requireNonzero(cfg.officialProposer, "officialProposer");
        _requireNonzero(cfg.wrappedNative, "wrappedNative");
        _requireNonzero(cfg.positionManager, "positionManager");
        _requireNonzero(cfg.algebraFactory, "algebraFactory");
        _requireNonzero(cfg.futarchyRouter, "futarchyRouter");
        require(cfg.tickLower < cfg.tickUpper, "bad ticks");

        if (cfg.deployDeadlineProxy) {
            _requireNonzero(cfg.deadlineConditionalTokens, "deadline conditionalTokens");
            _requireNonzero(cfg.deadlineRealitio, "deadline realitio");
            require(cfg.maxQuestionDuration != 0, "maxQuestionDuration");
        }
    }

    function _requireNonzero(address value, string memory label) internal pure {
        require(value != address(0), label);
    }

    function _encodeInitialValidationConfig(
        FutarchyOfficialProposalSource.ProposalValidationConfig memory config
    ) internal pure returns (bytes memory) {
        if (!config.enabled) return "";
        return abi.encode(config);
    }

    function _writeDeploymentOutput(
        string memory path,
        DeployConfig memory cfg,
        bytes32 configHash,
        DeployedContracts memory deployed
    ) internal {
        string memory key = "deployment";
        _serializeDeploymentConfig(key, cfg, configHash);
        _serializeDeploymentAddresses(key, deployed);
        string memory output = _serializeDeploymentCodeHashes(key, deployed);
        vm.writeJson(output, path);
    }

    function _serializeDeploymentConfig(
        string memory key,
        DeployConfig memory cfg,
        bytes32 configHash
    ) internal {
        vm.serializeUint(key, "chainId", cfg.chainId);
        vm.serializeBytes32(key, "configHash", configHash);
        vm.serializeAddress(key, "owner", cfg.owner);
        vm.serializeAddress(key, "proposalManager", cfg.proposalManager);
        vm.serializeAddress(key, "bootstrapRecipient", cfg.bootstrapRecipient);
        vm.serializeAddress(key, "companyToken", cfg.companyToken);
        vm.serializeAddress(key, "wrappedNative", cfg.wrappedNative);
        vm.serializeAddress(key, "officialProposer", cfg.officialProposer);
    }

    function _serializeDeploymentAddresses(string memory key, DeployedContracts memory deployed)
        internal
    {
        vm.serializeAddress(key, "proposalSource", deployed.proposalSource);
        vm.serializeAddress(key, "deadlineProxy", deployed.deadlineProxy);
        vm.serializeAddress(key, "spotAdapter", deployed.spotAdapter);
        vm.serializeAddress(key, "conditionalAdapter", deployed.conditionalAdapter);
        vm.serializeAddress(key, "manager", deployed.manager);
    }

    function _serializeDeploymentCodeHashes(string memory key, DeployedContracts memory deployed)
        internal
        returns (string memory)
    {
        vm.serializeBytes32(key, "proposalSourceCodeHash", deployed.proposalSource.codehash);
        vm.serializeBytes32(key, "deadlineProxyCodeHash", deployed.deadlineProxy.codehash);
        vm.serializeBytes32(key, "spotAdapterCodeHash", deployed.spotAdapter.codehash);
        vm.serializeBytes32(key, "conditionalAdapterCodeHash", deployed.conditionalAdapter.codehash);
        return vm.serializeBytes32(key, "managerCodeHash", deployed.manager.codehash);
    }
}
