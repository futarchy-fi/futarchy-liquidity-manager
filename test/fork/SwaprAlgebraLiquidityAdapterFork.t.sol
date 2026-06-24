// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwaprAlgebraLiquidityAdapter} from "../../src/adapters/SwaprAlgebraLiquidityAdapter.sol";
import {ISwaprAlgebraPositionManager} from "../../src/interfaces/ISwaprAlgebraPositionManager.sol";

contract SwaprAlgebraLiquidityAdapterForkTest is Test {
    address internal constant GNOSIS_GNO = 0x9C58BAcC331c9aa871AFD802DB6379a98e80CEdb;
    address internal constant GNOSIS_WXDAI = 0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d;
    address internal constant SWAPR_POSITION_MANAGER = 0x91fD594c46D8B01E62dBDeBed2401dde01817834;

    int24 internal constant FULL_RANGE_LOWER = -887_220;
    int24 internal constant FULL_RANGE_UPPER = 887_220;

    function testFork_add_and_remove_full_range_position() public {
        if (!vm.envOr("RUN_GNOSIS_FORK_TESTS", false)) return;
        vm.createSelectFork(vm.rpcUrl("gnosis"));

        SwaprAlgebraLiquidityAdapter adapter = new SwaprAlgebraLiquidityAdapter(
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER), FULL_RANGE_LOWER, FULL_RANGE_UPPER
        );

        deal(GNOSIS_GNO, address(this), 2 ether);
        deal(GNOSIS_WXDAI, address(this), 2 ether);

        IERC20(GNOSIS_GNO).approve(address(adapter), type(uint256).max);
        IERC20(GNOSIS_WXDAI).approve(address(adapter), type(uint256).max);

        uint256 gnoBefore = IERC20(GNOSIS_GNO).balanceOf(address(this));
        uint256 wxdaiBefore = IERC20(GNOSIS_WXDAI).balanceOf(address(this));

        (uint128 liquidityMinted, uint256 amount0Used, uint256 amount1Used) = adapter.addFullRangeLiquidity(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            1 ether,
            1 ether,
            abi.encode(
                SwaprAlgebraLiquidityAdapter.AddParams({
                    tickLower: FULL_RANGE_LOWER,
                    tickUpper: FULL_RANGE_UPPER,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 20 minutes,
                    sqrtPriceX96: 0
                })
            )
        );

        assertGt(liquidityMinted, 0);
        assertGt(amount0Used, 0);
        assertGt(amount1Used, 0);

        uint256 tokenId = adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI);
        assertGt(tokenId, 0);

        (,,,,,, uint128 currentLiquidity,,,,) =
            ISwaprAlgebraPositionManager(SWAPR_POSITION_MANAGER).positions(tokenId);
        assertEq(currentLiquidity, liquidityMinted);

        (uint256 amount0Out, uint256 amount1Out) = adapter.removeLiquidity(
            GNOSIS_GNO,
            GNOSIS_WXDAI,
            currentLiquidity,
            abi.encode(
                SwaprAlgebraLiquidityAdapter.ExitParams({
                    amount0Min: 0, amount1Min: 0, deadline: block.timestamp + 20 minutes
                })
            )
        );

        assertGt(amount0Out + amount1Out, 0);
        assertEq(adapter.getPositionTokenId(GNOSIS_GNO, GNOSIS_WXDAI), 0);

        uint256 gnoAfter = IERC20(GNOSIS_GNO).balanceOf(address(this));
        uint256 wxdaiAfter = IERC20(GNOSIS_WXDAI).balanceOf(address(this));
        assertGt(gnoAfter + wxdaiAfter, gnoBefore + wxdaiBefore - 2 ether);
    }
}
