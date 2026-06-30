// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../adapters/SwaprAlgebraLiquidityAdapter.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../core/FutarchyLiquidityManager.sol";
import {IAlgebraFactoryLike} from "../interfaces/IAlgebraFactoryLike.sol";
import {IFutarchyConditionalRouter} from "../interfaces/IFutarchyConditionalRouter.sol";
import {ISwaprAlgebraPositionManager} from "../interfaces/ISwaprAlgebraPositionManager.sol";
import {FutarchyOfficialProposalSource} from "../sources/FutarchyOfficialProposalSource.sol";

/// @title FutarchyLiquidityManagerFactory
/// @notice Permissionless deployment factory for the default per-organization FLM bundle.
/// @dev Deploys the same components as `DeployFutarchyLiquidityManager.s.sol`: proposal source,
/// spot adapter, conditional adapter, and manager. The registry/UI can store the returned
/// `manager` and `proposalSource` as an organization's default FLM wiring.
contract FutarchyLiquidityManagerFactory {
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

    struct DeployedContracts {
        address proposalSource;
        address spotAdapter;
        address conditionalAdapter;
        address manager;
    }

    ISwaprAlgebraPositionManager public immutable POSITION_MANAGER;
    IAlgebraFactoryLike public immutable ALGEBRA_FACTORY;
    IFutarchyConditionalRouter public immutable CONDITIONAL_ROUTER;
    IWrappedNative public immutable WRAPPED_NATIVE;
    int24 public immutable DEFAULT_TICK_LOWER;
    int24 public immutable DEFAULT_TICK_UPPER;

    error ZeroAddress();
    error InvalidTickRange();

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
        IWrappedNative wrappedNative,
        int24 defaultTickLower,
        int24 defaultTickUpper
    ) {
        if (
            address(positionManager) == address(0) || address(algebraFactory) == address(0)
                || address(conditionalRouter) == address(0) || address(wrappedNative) == address(0)
        ) {
            revert ZeroAddress();
        }
        if (defaultTickLower >= defaultTickUpper) revert InvalidTickRange();

        POSITION_MANAGER = positionManager;
        ALGEBRA_FACTORY = algebraFactory;
        CONDITIONAL_ROUTER = conditionalRouter;
        WRAPPED_NATIVE = wrappedNative;
        DEFAULT_TICK_LOWER = defaultTickLower;
        DEFAULT_TICK_UPPER = defaultTickUpper;
    }

    function createLiquidityManager(CreateParams calldata params)
        external
        returns (DeployedContracts memory deployed)
    {
        _validateCreateParams(params);

        deployed.proposalSource = address(
            new FutarchyOfficialProposalSource(
                params.owner,
                params.proposalManager,
                params.officialProposer,
                ALGEBRA_FACTORY,
                params.proposalValidationConfigData
            )
        );

        deployed.spotAdapter = address(
            new SwaprAlgebraLiquidityAdapter(
                POSITION_MANAGER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER
            )
        );
        deployed.conditionalAdapter = address(
            new SwaprAlgebraLiquidityAdapter(
                POSITION_MANAGER, DEFAULT_TICK_LOWER, DEFAULT_TICK_UPPER
            )
        );

        deployed.manager = address(
            new FutarchyLiquidityManager(
                params.bootstrapRecipient,
                params.companyToken,
                WRAPPED_NATIVE,
                params.officialProposer,
                FutarchyOfficialProposalSource(deployed.proposalSource),
                SwaprAlgebraLiquidityAdapter(deployed.spotAdapter),
                SwaprAlgebraLiquidityAdapter(deployed.conditionalAdapter),
                CONDITIONAL_ROUTER,
                params.owner,
                params.lpTokenName,
                params.lpTokenSymbol
            )
        );

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
}
