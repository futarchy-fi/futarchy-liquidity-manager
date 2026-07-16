// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IV4PoolManagerMinimal} from "../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../src/adapters/UniswapV3LiquidityAdapter.sol";
import {V4InitializationGate} from "../src/adapters/V4InitializationGate.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {
    V4FutarchyLiquidityManagerFactory
} from "../src/factories/V4FutarchyLiquidityManagerFactory.sol";
import {IFutarchyConditionalRouter} from "../src/interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../src/interfaces/IPoolStabilityGuard.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../src/interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {V4ConditionalLiquidityAdapter} from "../src/adapters/V4ConditionalLiquidityAdapter.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";

interface IConditionalRouterDependencies {
    function CONDITIONAL_TOKENS() external view returns (address);

    function WRAPPED_1155_FACTORY() external view returns (address);
}

/// @notice Deploys only the hash-pinned Ethereum-mainnet v4 bundle factory.
/// @dev Bundle roles, tokens, validation, salt, and child deployment remain a separate reviewed
/// step.
contract DeployV4MainnetFactory is Script {
    using stdJson for string;

    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    address internal constant SPOT_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    bytes32 internal constant SPOT_POSITION_MANAGER_CODEHASH =
        0x692e658b31cbe3407682854806658d315d61a58c7e4933a2f91d383dc00736c6;
    address internal constant V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 internal constant V4_POOL_MANAGER_CODEHASH =
        0x785f1014552b7ce7d5fb7d0c970ca60edee94fd00425d7ca21609acac7ce1293;
    bytes32 internal constant PROPOSAL_SOURCE_CREATION_CODE_HASH =
        0xeec528405c315ae9de9317487b7ddaf26bf3748af830bb4dd95538ca09c2afbf;
    bytes32 internal constant SPOT_ADAPTER_CREATION_CODE_HASH =
        0xe4ede15bf37a793e628f367d45282a9df1241b3cc401e0d8ee896a055ac40843;
    bytes32 internal constant INITIALIZATION_GATE_CREATION_CODE_HASH =
        0x56052e89d8d3305ab4d3c35922882faee512c39fe45102cc0dec86bf7e57f75f;
    bytes32 internal constant CONDITIONAL_ADAPTER_CREATION_CODE_HASH =
        0x1333c00b08fb2d31f53d11465292f8b869455d8020bd0489059e3e7a3a7af2e3;
    bytes32 internal constant MANAGER_CREATION_CODE_HASH =
        0x530508cbc317688dadfc8711e4bfff2fb23a0b9b5f378eb613c0ca570157e846;
    bytes32 internal constant FACTORY_CREATION_CODE_HASH =
        0xe6df50aabe5258cd3d084046eb8b3573cad874c50e7aa721257e033374497440;

    struct Config {
        uint256 chainId;
        address conditionalRouter;
        bytes32 conditionalRouterCodeHash;
        address conditionalTokens;
        bytes32 conditionalTokensCodeHash;
        address wrapped1155Factory;
        bytes32 wrapped1155FactoryCodeHash;
        address poolStabilityGuard;
        bytes32 poolStabilityGuardCodeHash;
        address wrappedNative;
        bytes32 wrappedNativeCodeHash;
        int24 spotTickLower;
        int24 spotTickUpper;
    }

    struct CreationCodeHashes {
        bytes32 proposalSource;
        bytes32 spotAdapter;
        bytes32 initializationGate;
        bytes32 conditionalAdapter;
        bytes32 manager;
    }

    function run() external returns (V4FutarchyLiquidityManagerFactory factory) {
        string memory configPath =
            vm.envOr("FLM_V4_FACTORY_CONFIG", string("config/mainnet-v4-factory.example.json"));
        string memory outputPath = vm.envOr(
            "FLM_V4_FACTORY_DEPLOY_OUTPUT", string("deployments/flm.v4.factory.mainnet.json")
        );
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        bytes32 configHash = keccak256(bytes(vm.readFile(configPath)));
        Config memory cfg = _readConfig(configPath);
        CreationCodeHashes memory hashes = _creationCodeHashes();

        _assertConfig(cfg);
        _assertCreationCodeHashes(hashes);

        vm.startBroadcast(privateKey);
        factory = new V4FutarchyLiquidityManagerFactory(
            IUniswapV3NonfungiblePositionManager(SPOT_POSITION_MANAGER),
            IV4PoolManagerMinimal(V4_POOL_MANAGER),
            V4_POOL_MANAGER_CODEHASH,
            IFutarchyConditionalRouter(cfg.conditionalRouter),
            IPoolStabilityGuard(cfg.poolStabilityGuard),
            IWrappedNative(cfg.wrappedNative),
            cfg.spotTickLower,
            cfg.spotTickUpper,
            hashes.proposalSource,
            hashes.spotAdapter,
            hashes.initializationGate,
            hashes.conditionalAdapter,
            hashes.manager
        );
        vm.stopBroadcast();

        _writeOutput(outputPath, configHash, cfg, hashes, address(factory));

        console2.log("Config:", configPath);
        console2.log("Output:", outputPath);
        console2.log("Factory:", address(factory));
        console2.logBytes32(address(factory).codehash);
    }

    function _readConfig(string memory path) internal view returns (Config memory cfg) {
        string memory json = vm.readFile(path);
        cfg.chainId = json.readUint(".chainId");
        cfg.conditionalRouter = json.readAddress(".conditionalRouter");
        cfg.conditionalRouterCodeHash = json.readBytes32(".conditionalRouterCodeHash");
        cfg.conditionalTokens = json.readAddress(".conditionalTokens");
        cfg.conditionalTokensCodeHash = json.readBytes32(".conditionalTokensCodeHash");
        cfg.wrapped1155Factory = json.readAddress(".wrapped1155Factory");
        cfg.wrapped1155FactoryCodeHash = json.readBytes32(".wrapped1155FactoryCodeHash");
        cfg.poolStabilityGuard = json.readAddress(".poolStabilityGuard");
        cfg.poolStabilityGuardCodeHash = json.readBytes32(".poolStabilityGuardCodeHash");
        cfg.wrappedNative = json.readAddress(".wrappedNative");
        cfg.wrappedNativeCodeHash = json.readBytes32(".wrappedNativeCodeHash");
        cfg.spotTickLower = _readInt24(json, ".spotTickLower");
        cfg.spotTickUpper = _readInt24(json, ".spotTickUpper");
    }

    function _readInt24(string memory json, string memory path) internal pure returns (int24) {
        int256 value = json.readInt(path);
        require(value >= type(int24).min && value <= type(int24).max, "tick int24 overflow");
        // Range checked immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(value);
    }

    function _assertConfig(Config memory cfg) internal view {
        require(block.chainid == ETHEREUM_MAINNET_CHAIN_ID, "not Ethereum mainnet");
        require(cfg.chainId == ETHEREUM_MAINNET_CHAIN_ID, "wrong config chain");
        _requireCodeHash(
            SPOT_POSITION_MANAGER, SPOT_POSITION_MANAGER_CODEHASH, "spot position manager"
        );
        _requireCodeHash(V4_POOL_MANAGER, V4_POOL_MANAGER_CODEHASH, "v4 PoolManager");
        _requireCodeHash(cfg.conditionalRouter, cfg.conditionalRouterCodeHash, "conditional router");
        _requireCodeHash(cfg.conditionalTokens, cfg.conditionalTokensCodeHash, "conditional tokens");
        _requireCodeHash(
            cfg.wrapped1155Factory, cfg.wrapped1155FactoryCodeHash, "Wrapped1155 factory"
        );
        _requireCodeHash(
            cfg.poolStabilityGuard, cfg.poolStabilityGuardCodeHash, "pool stability guard"
        );
        _requireCodeHash(cfg.wrappedNative, cfg.wrappedNativeCodeHash, "collateral token");

        IConditionalRouterDependencies router =
            IConditionalRouterDependencies(cfg.conditionalRouter);
        require(router.CONDITIONAL_TOKENS() == cfg.conditionalTokens, "router CTF mismatch");
        require(
            router.WRAPPED_1155_FACTORY() == cfg.wrapped1155Factory,
            "router wrapper factory mismatch"
        );
    }

    function _requireCodeHash(address dependency, bytes32 expected, string memory label)
        internal
        view
    {
        require(dependency != address(0) && expected != bytes32(0), label);
        require(dependency.code.length != 0, string.concat(label, " has no code"));
        require(dependency.codehash == expected, string.concat(label, " codehash"));
    }

    function _creationCodeHashes() internal pure returns (CreationCodeHashes memory hashes) {
        hashes.proposalSource = keccak256(type(FutarchyOfficialProposalSource).creationCode);
        hashes.spotAdapter = keccak256(type(UniswapV3LiquidityAdapter).creationCode);
        hashes.initializationGate = keccak256(type(V4InitializationGate).creationCode);
        hashes.conditionalAdapter = keccak256(type(V4ConditionalLiquidityAdapter).creationCode);
        hashes.manager = keccak256(type(FutarchyLiquidityManager).creationCode);
    }

    function _assertCreationCodeHashes(CreationCodeHashes memory hashes) internal pure {
        require(
            hashes.proposalSource == PROPOSAL_SOURCE_CREATION_CODE_HASH, "source artifact drift"
        );
        require(hashes.spotAdapter == SPOT_ADAPTER_CREATION_CODE_HASH, "spot artifact drift");
        require(
            hashes.initializationGate == INITIALIZATION_GATE_CREATION_CODE_HASH,
            "gate artifact drift"
        );
        require(
            hashes.conditionalAdapter == CONDITIONAL_ADAPTER_CREATION_CODE_HASH,
            "conditional artifact drift"
        );
        require(hashes.manager == MANAGER_CREATION_CODE_HASH, "manager artifact drift");
        require(
            keccak256(type(V4FutarchyLiquidityManagerFactory).creationCode)
                == FACTORY_CREATION_CODE_HASH,
            "factory artifact drift"
        );
    }

    function _writeOutput(
        string memory path,
        bytes32 configHash,
        Config memory cfg,
        CreationCodeHashes memory hashes,
        address factory
    ) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBytes32(key, "configHash", configHash);
        vm.serializeAddress(key, "factory", factory);
        vm.serializeBytes32(key, "factoryCreationCodeHash", FACTORY_CREATION_CODE_HASH);
        vm.serializeBytes32(key, "factoryCodeHash", factory.codehash);
        vm.serializeAddress(key, "spotPositionManager", SPOT_POSITION_MANAGER);
        vm.serializeBytes32(key, "spotPositionManagerCodeHash", SPOT_POSITION_MANAGER_CODEHASH);
        vm.serializeAddress(key, "v4PoolManager", V4_POOL_MANAGER);
        vm.serializeBytes32(key, "v4PoolManagerCodeHash", V4_POOL_MANAGER_CODEHASH);
        vm.serializeAddress(key, "conditionalRouter", cfg.conditionalRouter);
        vm.serializeBytes32(key, "conditionalRouterCodeHash", cfg.conditionalRouterCodeHash);
        vm.serializeAddress(key, "conditionalTokens", cfg.conditionalTokens);
        vm.serializeBytes32(key, "conditionalTokensCodeHash", cfg.conditionalTokensCodeHash);
        vm.serializeAddress(key, "wrapped1155Factory", cfg.wrapped1155Factory);
        vm.serializeBytes32(key, "wrapped1155FactoryCodeHash", cfg.wrapped1155FactoryCodeHash);
        vm.serializeAddress(key, "poolStabilityGuard", cfg.poolStabilityGuard);
        vm.serializeBytes32(key, "poolStabilityGuardCodeHash", cfg.poolStabilityGuardCodeHash);
        vm.serializeAddress(key, "wrappedNative", cfg.wrappedNative);
        vm.serializeBytes32(key, "wrappedNativeCodeHash", cfg.wrappedNativeCodeHash);
        vm.serializeInt(key, "spotTickLower", cfg.spotTickLower);
        vm.serializeInt(key, "spotTickUpper", cfg.spotTickUpper);
        vm.serializeBytes32(key, "proposalSourceCreationCodeHash", hashes.proposalSource);
        vm.serializeBytes32(key, "spotAdapterCreationCodeHash", hashes.spotAdapter);
        vm.serializeBytes32(key, "initializationGateCreationCodeHash", hashes.initializationGate);
        vm.serializeBytes32(key, "conditionalAdapterCreationCodeHash", hashes.conditionalAdapter);
        string memory output = vm.serializeBytes32(key, "managerCreationCodeHash", hashes.manager);
        vm.writeJson(output, path);
    }
}
