// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../adapters/SwaprAlgebraLiquidityAdapter.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../core/FutarchyLiquidityManager.sol";
import {IAlgebraFactoryLike} from "../interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";
import {IPoolStabilityGuard} from "../interfaces/IPoolStabilityGuard.sol";
import {ISwaprAlgebraPositionManager} from "../interfaces/ISwaprAlgebraPositionManager.sol";

/// @title FutarchyLiquidityManagerFactory
/// @notice Permissionless deployment factory for the default per-organization FLM bundle.
/// @dev Callers supply the pinned bare creation code to keep this factory below EIP-170. The
/// factory verifies each hash, appends all constructor arguments, deploys the four-contract bundle,
/// and irreversibly binds both adapters to the manager in one transaction.
contract FutarchyLiquidityManagerFactory {
    uint256 public constant MAX_INIT_CODE_SIZE = 49_152;

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
    }

    struct CreationCodes {
        bytes proposalSource;
        bytes adapter;
        bytes manager;
    }

    struct DeployedContracts {
        address proposalSource;
        address spotAdapter;
        address conditionalAdapter;
        address manager;
    }

    ISwaprAlgebraPositionManager public immutable POSITION_MANAGER;
    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;
    IPoolStabilityGuard public immutable POOL_STABILITY_GUARD;
    IWrappedNative public immutable WRAPPED_NATIVE;
    int24 public immutable DEFAULT_TICK_LOWER;
    int24 public immutable DEFAULT_TICK_UPPER;
    bytes32 public immutable PROPOSAL_SOURCE_CREATION_CODE_HASH;
    bytes32 public immutable ADAPTER_CREATION_CODE_HASH;
    bytes32 public immutable MANAGER_CREATION_CODE_HASH;

    error ZeroAddress();
    error ZeroCreationCodeHash();
    error InvalidTickRange();
    error CreationCodeHashMismatch(bytes32 expected, bytes32 actual);
    error InitCodeTooLarge(uint256 size);
    error DeploymentFailed();

    event LiquidityManagerCreated(
        address indexed organization,
        address indexed owner,
        address indexed companyToken,
        address proposalSource,
        address spotAdapter,
        address conditionalAdapter,
        address manager
    );

    constructor(
        ISwaprAlgebraPositionManager positionManager,
        IAlgebraFactoryLike algebraFactory,
        IFutarchyConditionalRouter conditionalRouter,
        IPoolStabilityGuard poolStabilityGuard,
        IWrappedNative wrappedNative,
        int24 defaultTickLower,
        int24 defaultTickUpper,
        bytes32 proposalSourceCreationCodeHash,
        bytes32 adapterCreationCodeHash,
        bytes32 managerCreationCodeHash
    ) {
        if (
            address(positionManager) == address(0) || address(algebraFactory) == address(0)
                || address(conditionalRouter) == address(0)
                || address(poolStabilityGuard) == address(0) || address(wrappedNative) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (defaultTickLower >= defaultTickUpper) revert InvalidTickRange();
        if (
            proposalSourceCreationCodeHash == bytes32(0) || adapterCreationCodeHash == bytes32(0)
                || managerCreationCodeHash == bytes32(0)
        ) {
            revert ZeroCreationCodeHash();
        }

        POSITION_MANAGER = positionManager;
        ALGEBRA_FACTORY = algebraFactory;
        CONDITIONAL_ROUTER = conditionalRouter;
        POOL_STABILITY_GUARD = poolStabilityGuard;
        WRAPPED_NATIVE = wrappedNative;
        DEFAULT_TICK_LOWER = defaultTickLower;
        DEFAULT_TICK_UPPER = defaultTickUpper;
        PROPOSAL_SOURCE_CREATION_CODE_HASH = proposalSourceCreationCodeHash;
        ADAPTER_CREATION_CODE_HASH = adapterCreationCodeHash;
        MANAGER_CREATION_CODE_HASH = managerCreationCodeHash;
    }

    function createLiquidityManager(CreateParams calldata params, CreationCodes calldata codes)
        external
        returns (DeployedContracts memory deployed)
    {
        _validateCreateParams(params);
        _validateCreationCode(codes.proposalSource, PROPOSAL_SOURCE_CREATION_CODE_HASH);
        _validateCreationCode(codes.adapter, ADAPTER_CREATION_CODE_HASH);
        _validateCreationCode(codes.manager, MANAGER_CREATION_CODE_HASH);

        deployed.proposalSource = _deploy(
            codes.proposalSource,
            abi.encode(
                params.owner,
                params.proposalManager,
                params.officialProposer,
                ALGEBRA_FACTORY,
                params.proposalValidationConfigData
            )
        );

        bytes memory adapterConstructorArgs =
            abi.encode(POSITION_MANAGER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER);
        deployed.spotAdapter = _deploy(codes.adapter, adapterConstructorArgs);
        deployed.conditionalAdapter = _deploy(codes.adapter, adapterConstructorArgs);

        deployed.manager = _deploy(codes.manager, _managerConstructorArgs(params, deployed));

        SwaprAlgebraLiquidityAdapter(deployed.spotAdapter).bindManager(deployed.manager);
        SwaprAlgebraLiquidityAdapter(deployed.conditionalAdapter).bindManager(deployed.manager);

        emit LiquidityManagerCreated(
            params.organization,
            params.owner,
            address(params.companyToken),
            deployed.proposalSource,
            deployed.spotAdapter,
            deployed.conditionalAdapter,
            deployed.manager
        );
    }

    function _validateCreateParams(CreateParams calldata params) internal pure {
        if (
            params.owner == address(0) || params.proposalManager == address(0)
                || params.bootstrapRecipient == address(0)
                || address(params.companyToken) == address(0)
                || params.officialProposer == address(0)
        ) {
            revert ZeroAddress();
        }
    }

    function _managerConstructorArgs(
        CreateParams calldata params,
        DeployedContracts memory deployed
    ) internal view returns (bytes memory) {
        return abi.encode(
            params.bootstrapRecipient,
            params.companyToken,
            WRAPPED_NATIVE,
            params.officialProposer,
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

    function _validateCreationCode(bytes calldata creationCode, bytes32 expectedHash)
        internal
        pure
    {
        bytes32 actualHash = keccak256(creationCode);
        if (actualHash != expectedHash) {
            revert CreationCodeHashMismatch(expectedHash, actualHash);
        }
    }

    function _deploy(bytes calldata creationCode, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        uint256 initCodeSize = creationCode.length + constructorArgs.length;
        if (initCodeSize > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(initCodeSize);

        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed();
    }
}
