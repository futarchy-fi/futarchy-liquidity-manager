// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IV4PoolManagerMinimal,
    V4ConditionalLiquidityAdapter
} from "../adapters/V4ConditionalLiquidityAdapter.sol";
import {UniswapV3LiquidityAdapter} from "../adapters/UniswapV3LiquidityAdapter.sol";
import {V4InitializationGate} from "../adapters/V4InitializationGate.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../core/FutarchyLiquidityManager.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../interfaces/IPoolStabilityGuard.sol";
import {
    IUniswapV3NonfungiblePositionManager
} from "../interfaces/IUniswapV3NonfungiblePositionManager.sol";
import {FutarchyOfficialProposalSource} from "../sources/FutarchyOfficialProposalSource.sol";

interface IUniV3FactoryBoundGuard {
    function FACTORY() external view returns (address);
    function FEE() external view returns (uint24);
}

/// @notice Permissionless atomic deployment factory for the Ethereum-mainnet v4 FLM successor.
/// @dev The caller mines a raw salt whose caller-bound CREATE2 address enables exactly the
/// before-initialize hook bit. Binding the effective salt to msg.sender prevents another wallet
/// from consuming the advertised hook address first.
contract V4FutarchyLiquidityManagerFactory {
    uint256 public constant MAX_INIT_CODE_SIZE = 49_152;
    uint24 public constant SPOT_FEE = 500;
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 private constant BEFORE_INITIALIZE_FLAG = 1 << 13;

    struct CreateParams {
        address organization;
        address owner;
        address proposalManager;
        address bootstrapRecipient;
        IERC20 companyToken;
        address officialProposer;
        string lpTokenName;
        string lpTokenSymbol;
        bytes proposalValidationConfigData;
        bytes32 hookSalt;
    }

    struct CreationCodes {
        bytes proposalSource;
        bytes spotAdapter;
        bytes initializationGate;
        bytes conditionalAdapter;
        bytes manager;
    }

    struct DeployedContracts {
        address proposalSource;
        address spotAdapter;
        address initializationGate;
        address conditionalAdapter;
        address manager;
    }

    IUniswapV3NonfungiblePositionManager public immutable SPOT_POSITION_MANAGER;
    IV4PoolManagerMinimal public immutable V4_POOL_MANAGER;
    bytes32 public immutable V4_POOL_MANAGER_CODEHASH;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;
    IPoolStabilityGuard public immutable POOL_STABILITY_GUARD;
    IWrappedNative public immutable WRAPPED_NATIVE;
    int24 public immutable SPOT_TICK_LOWER;
    int24 public immutable SPOT_TICK_UPPER;
    bytes32 public immutable PROPOSAL_SOURCE_CREATION_CODE_HASH;
    bytes32 public immutable SPOT_ADAPTER_CREATION_CODE_HASH;
    bytes32 public immutable INITIALIZATION_GATE_CREATION_CODE_HASH;
    bytes32 public immutable CONDITIONAL_ADAPTER_CREATION_CODE_HASH;
    bytes32 public immutable MANAGER_CREATION_CODE_HASH;

    error CreationCodeHashMismatch(bytes32 expected, bytes32 actual);
    error DeploymentFailed();
    error HookAddressAlreadyUsed(address hook);
    error InitCodeTooLarge(uint256 size);
    error InvalidAmmWiring();
    error InvalidDependency();
    error InvalidHookAddress(address hook);
    error InvalidLifecycleCoordinator();
    error InvalidTickRange();
    error ZeroAddress();
    error ZeroCreationCodeHash();

    event LiquidityManagerCreated(
        address indexed organization,
        address indexed owner,
        address indexed companyToken,
        address proposalSource,
        address spotAdapter,
        address initializationGate,
        address conditionalAdapter,
        address manager
    );

    constructor(
        IUniswapV3NonfungiblePositionManager spotPositionManager,
        IV4PoolManagerMinimal v4PoolManager,
        bytes32 v4PoolManagerCodehash,
        IFutarchyConditionalRouter conditionalRouter,
        IPoolStabilityGuard poolStabilityGuard,
        IWrappedNative wrappedNative,
        int24 spotTickLower,
        int24 spotTickUpper,
        bytes32 proposalSourceCreationCodeHash,
        bytes32 spotAdapterCreationCodeHash,
        bytes32 initializationGateCreationCodeHash,
        bytes32 conditionalAdapterCreationCodeHash,
        bytes32 managerCreationCodeHash
    ) {
        if (
            address(spotPositionManager) == address(0) || address(v4PoolManager) == address(0)
                || address(conditionalRouter) == address(0)
                || address(poolStabilityGuard) == address(0) || address(wrappedNative) == address(0)
        ) revert ZeroAddress();
        if (
            address(spotPositionManager).code.length == 0
                || address(v4PoolManager).codehash != v4PoolManagerCodehash
                || address(conditionalRouter).code.length == 0
                || address(poolStabilityGuard).code.length == 0
                || address(wrappedNative).code.length == 0
        ) revert InvalidDependency();

        address spotFactory = spotPositionManager.factory();
        if (
            spotFactory == address(0) || spotFactory.code.length == 0
                || IUniV3FactoryBoundGuard(address(poolStabilityGuard)).FACTORY() != spotFactory
                || IUniV3FactoryBoundGuard(address(poolStabilityGuard)).FEE() != SPOT_FEE
        ) revert InvalidAmmWiring();
        if (spotTickLower >= spotTickUpper) revert InvalidTickRange();
        if (
            proposalSourceCreationCodeHash == bytes32(0)
                || spotAdapterCreationCodeHash == bytes32(0)
                || initializationGateCreationCodeHash == bytes32(0)
                || conditionalAdapterCreationCodeHash == bytes32(0)
                || managerCreationCodeHash == bytes32(0)
        ) revert ZeroCreationCodeHash();

        SPOT_POSITION_MANAGER = spotPositionManager;
        V4_POOL_MANAGER = v4PoolManager;
        V4_POOL_MANAGER_CODEHASH = v4PoolManagerCodehash;
        CONDITIONAL_ROUTER = conditionalRouter;
        POOL_STABILITY_GUARD = poolStabilityGuard;
        WRAPPED_NATIVE = wrappedNative;
        SPOT_TICK_LOWER = spotTickLower;
        SPOT_TICK_UPPER = spotTickUpper;
        PROPOSAL_SOURCE_CREATION_CODE_HASH = proposalSourceCreationCodeHash;
        SPOT_ADAPTER_CREATION_CODE_HASH = spotAdapterCreationCodeHash;
        INITIALIZATION_GATE_CREATION_CODE_HASH = initializationGateCreationCodeHash;
        CONDITIONAL_ADAPTER_CREATION_CODE_HASH = conditionalAdapterCreationCodeHash;
        MANAGER_CREATION_CODE_HASH = managerCreationCodeHash;
    }

    function createLiquidityManager(CreateParams calldata params, CreationCodes calldata codes)
        external
        returns (DeployedContracts memory deployed)
    {
        _validateCreateParams(params);
        _validateCreationCode(codes.proposalSource, PROPOSAL_SOURCE_CREATION_CODE_HASH);
        _validateCreationCode(codes.spotAdapter, SPOT_ADAPTER_CREATION_CODE_HASH);
        _validateCreationCode(codes.initializationGate, INITIALIZATION_GATE_CREATION_CODE_HASH);
        _validateCreationCode(codes.conditionalAdapter, CONDITIONAL_ADAPTER_CREATION_CODE_HASH);
        _validateCreationCode(codes.manager, MANAGER_CREATION_CODE_HASH);

        bytes32 effectiveSalt = effectiveHookSalt(msg.sender, params.hookSalt);
        bytes memory gateArgs = abi.encode(V4_POOL_MANAGER, address(this));
        address predictedGate = _predictCreate2(
            effectiveSalt, keccak256(abi.encodePacked(codes.initializationGate, gateArgs))
        );
        if (uint160(predictedGate) & ALL_HOOK_MASK != BEFORE_INITIALIZE_FLAG) {
            revert InvalidHookAddress(predictedGate);
        }
        if (predictedGate.code.length != 0) revert HookAddressAlreadyUsed(predictedGate);

        deployed.initializationGate =
            _deployCreate2(codes.initializationGate, gateArgs, effectiveSalt);
        if (deployed.initializationGate != predictedGate) revert DeploymentFailed();

        deployed.spotAdapter = _deploy(
            codes.spotAdapter, abi.encode(SPOT_POSITION_MANAGER, SPOT_TICK_LOWER, SPOT_TICK_UPPER)
        );
        deployed.conditionalAdapter = _deploy(
            codes.conditionalAdapter,
            abi.encode(
                V4_POOL_MANAGER,
                V4_POOL_MANAGER_CODEHASH,
                V4InitializationGate(deployed.initializationGate)
            )
        );
        deployed.proposalSource = _deploy(
            codes.proposalSource,
            abi.encode(
                params.owner,
                params.proposalManager,
                params.officialProposer,
                deployed.conditionalAdapter,
                params.proposalValidationConfigData
            )
        );
        deployed.manager = _deploy(codes.manager, _managerConstructorArgs(params, deployed));

        V4InitializationGate(deployed.initializationGate).bindAdapter(deployed.conditionalAdapter);
        UniswapV3LiquidityAdapter(deployed.spotAdapter).bindManager(deployed.manager);
        V4ConditionalLiquidityAdapter(deployed.conditionalAdapter).bindManager(deployed.manager);
        FutarchyOfficialProposalSource(deployed.proposalSource)
            .bindActivationTarget(deployed.manager);

        emit LiquidityManagerCreated(
            params.organization,
            params.owner,
            address(params.companyToken),
            deployed.proposalSource,
            deployed.spotAdapter,
            deployed.initializationGate,
            deployed.conditionalAdapter,
            deployed.manager
        );
    }

    function predictHookAddress(
        address creator,
        bytes32 rawSalt,
        bytes calldata initializationGateCreationCode
    ) external view returns (address hook) {
        _validateCreationCode(
            initializationGateCreationCode, INITIALIZATION_GATE_CREATION_CODE_HASH
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                initializationGateCreationCode, abi.encode(V4_POOL_MANAGER, address(this))
            )
        );
        hook = _predictCreate2(effectiveHookSalt(creator, rawSalt), initCodeHash);
    }

    function effectiveHookSalt(address creator, bytes32 rawSalt) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, rawSalt));
    }

    function _validateCreateParams(CreateParams calldata params) private view {
        if (
            params.owner == address(0) || params.proposalManager == address(0)
                || params.bootstrapRecipient == address(0)
                || address(params.companyToken) == address(0)
                || params.officialProposer == address(0)
        ) revert ZeroAddress();
        if (params.proposalManager.code.length == 0) revert InvalidLifecycleCoordinator();
    }

    function _managerConstructorArgs(
        CreateParams calldata params,
        DeployedContracts memory deployed
    ) private view returns (bytes memory) {
        return abi.encode(
            params.bootstrapRecipient,
            params.companyToken,
            WRAPPED_NATIVE,
            deployed.proposalSource,
            deployed.spotAdapter,
            deployed.conditionalAdapter,
            CONDITIONAL_ROUTER,
            POOL_STABILITY_GUARD,
            params.owner,
            FutarchyLiquidityManager.LpTokenMetadata({
                name: params.lpTokenName, symbol: params.lpTokenSymbol
            })
        );
    }

    function _validateCreationCode(bytes calldata creationCode, bytes32 expectedHash) private pure {
        bytes32 actualHash = keccak256(creationCode);
        if (actualHash != expectedHash) {
            revert CreationCodeHashMismatch(expectedHash, actualHash);
        }
    }

    function _deploy(bytes calldata creationCode, bytes memory constructorArgs)
        private
        returns (address deployed)
    {
        bytes memory initCode = _initCode(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
    }

    function _deployCreate2(bytes calldata creationCode, bytes memory constructorArgs, bytes32 salt)
        private
        returns (address deployed)
    {
        bytes memory initCode = _initCode(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
    }

    function _initCode(bytes calldata creationCode, bytes memory constructorArgs)
        private
        pure
        returns (bytes memory initCode)
    {
        uint256 initCodeSize = creationCode.length + constructorArgs.length;
        if (initCodeSize > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(initCodeSize);
        initCode = abi.encodePacked(creationCode, constructorArgs);
    }

    function _predictCreate2(bytes32 salt, bytes32 initCodeHash)
        private
        view
        returns (address predicted)
    {
        predicted = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }
}
