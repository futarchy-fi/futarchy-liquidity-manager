// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BuildActivationBundle} from "../script/BuildActivationBundle.s.sol";
import {FutarchyLiquidityManager, IWrappedNative} from "../src/core/FutarchyLiquidityManager.sol";
import {FutarchyOfficialProposalSource} from "../src/sources/FutarchyOfficialProposalSource.sol";
import {MockActivationBundleSetup} from "./mocks/MockActivationBundleSetup.sol";
import {MockAlgebraFactoryLike} from "./mocks/MockAlgebraFactoryLike.sol";
import {MockConditionalRouter} from "./mocks/MockConditionalRouter.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockFutarchyLiquidityAdapter} from "./mocks/MockFutarchyLiquidityAdapter.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockPoolStabilityGuard} from "./mocks/MockPoolStabilityGuard.sol";
import {MockWrappedNative} from "./mocks/MockWrappedNative.sol";

contract MockSafeMultiSend {
    function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata data)
        external
        payable
    {
        require(targets.length == values.length && targets.length == data.length, "length");
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory reason) = targets[i].call{value: values[i]}(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}

contract BuildActivationBundleAtomicityTest is Test {
    using stdJson for string;

    uint256 private constant SEED = 100 ether;
    bytes32 private constant QUESTION_ID = keccak256("bundle condition");

    MockSafeMultiSend private safe;
    MockMintableERC20 private company;
    MockWrappedNative private collateral;
    MockMintableERC20 private yesCompany;
    MockMintableERC20 private noCompany;
    MockMintableERC20 private yesCurrency;
    MockMintableERC20 private noCurrency;
    MockConditionalTokens private conditionalTokens;
    MockConditionalRouter private router;
    MockFutarchyLiquidityAdapter private spot;
    MockFutarchyLiquidityAdapter private conditional;
    FutarchyOfficialProposalSource private source;
    FutarchyLiquidityManager private manager;
    MockActivationBundleSetup private setup;
    BuildActivationBundle private builder;

    function setUp() public {
        safe = new MockSafeMultiSend();
        company = new MockMintableERC20("Company", "COMP");
        collateral = new MockWrappedNative();
        yesCompany = new MockMintableERC20("YES_COMP", "YC");
        noCompany = new MockMintableERC20("NO_COMP", "NC");
        yesCurrency = new MockMintableERC20("YES_CURR", "Y$ ");
        noCurrency = new MockMintableERC20("NO_CURR", "N$ ");
        conditionalTokens = new MockConditionalTokens();
        router = new MockConditionalRouter();
        router.setConditionalTokens(address(conditionalTokens));
        spot = new MockFutarchyLiquidityAdapter();
        conditional = new MockFutarchyLiquidityAdapter();
        MockPoolStabilityGuard guard = new MockPoolStabilityGuard();

        source = new FutarchyOfficialProposalSource(
            address(this),
            address(safe),
            address(safe),
            new MockAlgebraFactoryLike(),
            abi.encode(_config())
        );
        manager = new FutarchyLiquidityManager(
            address(safe),
            company,
            IWrappedNative(address(collateral)),
            source,
            spot,
            conditional,
            router,
            guard,
            address(this),
            FutarchyLiquidityManager.LpTokenMetadata("FLM", "FLM")
        );
        source.bindActivationTarget(address(manager));
        setup = new MockActivationBundleSetup(
            conditionalTokens,
            router,
            address(this),
            address(company),
            address(collateral),
            address(yesCompany),
            address(noCompany),
            address(yesCurrency),
            address(noCurrency)
        );
        builder = new BuildActivationBundle();
        _bootstrap();
    }

    function test_emittedBundleAtomicallyCreatesAndSeedsMarket() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory data) =
            _emittedTransactions();
        assertEq(targets.length, 2);
        assertEq(targets[0], address(setup));
        assertEq(targets[1], address(source));
        assertEq(bytes4(data[1]), FutarchyOfficialProposalSource.setOfficialProposal.selector);

        safe.execute(targets, values, data);

        assertTrue(setup.created());
        assertTrue(source.officialProposalExtended().exists);
        assertTrue(manager.inConditionalMode());
        assertGt(manager.conditionalYesLiquidity(), 0);
        assertGt(manager.conditionalNoLiquidity(), 0);
        assertGt(conditional.addFreshCalls(), 1);
    }

    function test_emittedBundlePrecreatedPoolFailsAtomicallyWithoutMovingFunds() public {
        conditional.setFreshPool(address(yesCompany), address(yesCurrency), address(0xBEEF));
        (address[] memory targets, uint256[] memory values, bytes[] memory data) =
            _emittedTransactions();

        vm.expectRevert();
        safe.execute(targets, values, data);

        assertFalse(setup.created());
        assertFalse(source.officialProposalExtended().exists);
        assertFalse(manager.inConditionalMode());
        assertEq(manager.spotLiquidity(), SEED);
        assertEq(manager.conditionalYesLiquidity(), 0);
        assertEq(manager.conditionalNoLiquidity(), 0);
        assertEq(spot.totalLiquidity(), SEED);
        assertEq(conditional.addFreshCalls(), 0);
        assertEq(company.balanceOf(address(conditional)), 0);
        assertEq(collateral.balanceOf(address(conditional)), 0);
    }

    function _bootstrap() private {
        company.mint(address(safe), SEED);
        collateral.mint(address(safe), SEED);
        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory data = new bytes[](3);
        targets[0] = address(company);
        data[0] = abi.encodeCall(IERC20.approve, (address(manager), SEED));
        targets[1] = address(collateral);
        data[1] = abi.encodeCall(IERC20.approve, (address(manager), SEED));
        targets[2] = address(manager);
        data[2] = abi.encodeWithSignature("initializeFromBootstrap(uint256,uint256)", SEED, SEED);
        safe.execute(targets, values, data);
    }

    function _emittedTransactions()
        private
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory data)
    {
        string memory batch = builder.build(_json());
        targets = new address[](2);
        values = new uint256[](2);
        data = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            string memory base = string.concat(".transactions[", vm.toString(i), "]");
            targets[i] = batch.readAddress(string.concat(base, ".to"));
            values[i] = batch.readUint(string.concat(base, ".value"));
            data[i] = batch.readBytes(string.concat(base, ".data"));
        }
    }

    function _json() private view returns (string memory) {
        return string.concat(
            '{"chainId":31337,"name":"test","createdFromSafeAddress":"',
            vm.toString(address(safe)),
            '","createdFromOwnerAddress":"',
            vm.toString(address(this)),
            '","proposalSource":"',
            vm.toString(address(source)),
            '","proposalId":1,"proposal":"',
            vm.toString(address(setup.proposal())),
            '","creator":"',
            vm.toString(address(safe)),
            '","preActivationTargets":["',
            vm.toString(address(setup)),
            '"],"preActivationValues":[0],"preActivationData":["',
            vm.toString(abi.encodeCall(MockActivationBundleSetup.create, (QUESTION_ID))),
            '"]}'
        );
    }

    function _config()
        private
        view
        returns (FutarchyOfficialProposalSource.ProposalValidationConfig memory)
    {
        return FutarchyOfficialProposalSource.ProposalValidationConfig({
            enabled: true,
            expectedProposalToken: address(company),
            expectedCollateralToken: address(collateral),
            conditionalTokens: address(conditionalTokens),
            trustedOracle: address(this),
            realitio: address(0),
            trustedArbitrator: address(0),
            maxOpeningDelay: 0,
            minTimeout: 0,
            maxTimeout: 0,
            minConditionalLifetime: 0,
            maxMinBond: 0
        });
    }
}
