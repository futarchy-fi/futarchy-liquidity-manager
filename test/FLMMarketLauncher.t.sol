// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    FLMMarketLauncher,
    IFutarchyFactory,
    IOrganization,
    IFutarchyOfficialProposalSourceWriter
} from "../src/factories/FLMMarketLauncher.sol";

contract LauncherCallLog {
    uint256 public next;
    uint256 public factoryCall;
    uint256 public organizationCall;
    uint256 public sourceCall;

    function markFactory() external {
        factoryCall = ++next;
    }

    function markOrganization() external {
        organizationCall = ++next;
    }

    function markSource() external {
        sourceCall = ++next;
    }
}

contract MockLauncherFactory is IFutarchyFactory {
    LauncherCallLog internal immutable LOG;
    CreateParams internal _last;
    uint256 public proposalCount;

    constructor(LauncherCallLog log_) {
        LOG = log_;
    }

    function createProposal(CreateParams calldata params) external returns (address proposal) {
        LOG.markFactory();
        _last = params;
        proposal = address(uint160(0x1000 + ++proposalCount));
    }

    function last() external view returns (CreateParams memory) {
        return _last;
    }
}

contract MockLauncherOrganization is IOrganization {
    LauncherCallLog internal immutable LOG;
    uint256 public metadataCount;
    address public proposalAddress;
    string public displayNameQuestion;
    string public displayNameEvent;
    string public description;
    string public metadata;
    string public metadataURI;

    constructor(LauncherCallLog log_) {
        LOG = log_;
    }

    function createAndAddProposalMetadata(
        address proposalAddress_,
        string calldata displayNameQuestion_,
        string calldata displayNameEvent_,
        string calldata description_,
        string calldata metadata_,
        string calldata metadataURI_
    ) external returns (address metadataContract) {
        LOG.markOrganization();
        proposalAddress = proposalAddress_;
        displayNameQuestion = displayNameQuestion_;
        displayNameEvent = displayNameEvent_;
        description = description_;
        metadata = metadata_;
        metadataURI = metadataURI_;
        metadataContract = address(uint160(0x2000 + ++metadataCount));
    }
}

contract MockLauncherSource is IFutarchyOfficialProposalSourceWriter {
    LauncherCallLog internal immutable LOG;
    bool public shouldRevert;
    uint256 public proposalId;
    address public proposal;
    address public creator;

    constructor(LauncherCallLog log_) {
        LOG = log_;
    }

    function setOfficialProposal(uint256 proposalId_, address proposal_, address creator_)
        external
    {
        if (shouldRevert) revert("validation failed");
        LOG.markSource();
        proposalId = proposalId_;
        proposal = proposal_;
        creator = creator_;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }
}

contract MockLauncherManager {
    uint256 public redeemCalls;

    function redeem(uint256, address, bool) external {
        ++redeemCalls;
    }
}

contract FLMMarketLauncherTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant COMPANY = address(0xC0A1);
    address internal constant CURRENCY = address(0xC0FFEE);

    LauncherCallLog internal callLog;
    MockLauncherFactory internal factory;
    MockLauncherOrganization internal organization;
    MockLauncherSource internal source;
    MockLauncherManager internal manager;
    FLMMarketLauncher internal launcher;

    function setUp() public {
        callLog = new LauncherCallLog();
        factory = new MockLauncherFactory(callLog);
        organization = new MockLauncherOrganization(callLog);
        source = new MockLauncherSource(callLog);
        manager = new MockLauncherManager();
        launcher = new FLMMarketLauncher(OWNER);
        vm.prank(OWNER);
        launcher.bind(
            address(source),
            address(manager),
            address(factory),
            address(organization),
            COMPANY,
            CURRENCY,
            "governance",
            "en_US"
        );
    }

    function test_prepareAndActivateMarket_callDependenciesInOrder() public {
        FLMMarketLauncher.MarketParams memory p = _params();
        vm.prank(OWNER);
        (address proposal, address metadataContract, uint256 proposalId) = launcher.prepareMarket(p);

        IFutarchyFactory.CreateParams memory created = factory.last();
        assertEq(proposal, address(0x1001));
        assertEq(metadataContract, address(0x2001));
        assertEq(proposalId, 0);
        assertEq(callLog.factoryCall(), 1);
        assertEq(callLog.organizationCall(), 2);
        assertEq(callLog.sourceCall(), 0);
        assertEq(created.marketName, p.marketName);
        assertEq(created.companyToken, COMPANY);
        assertEq(created.currencyToken, CURRENCY);
        assertEq(created.category, "governance");
        assertEq(created.language, "en_US");
        assertEq(created.minBond, p.minBond);
        assertEq(created.openingTime, p.openingTime);
        assertEq(organization.proposalAddress(), proposal);
        assertEq(organization.displayNameQuestion(), p.displayNameQuestion);
        assertEq(organization.displayNameEvent(), p.displayNameEvent);
        assertEq(organization.description(), p.description);
        assertEq(organization.metadata(), p.metadataJson);
        assertEq(organization.metadataURI(), "");
        assertEq(launcher.pendingProposalId(), proposalId);
        assertEq(launcher.pendingProposal(), proposal);
        assertEq(launcher.nextProposalId(), 1);

        vm.prank(OWNER);
        launcher.activateMarket();
        assertEq(callLog.sourceCall(), 3);
        assertEq(source.proposalId(), proposalId);
        assertEq(source.proposal(), proposal);
        assertEq(source.creator(), address(launcher));
        assertEq(launcher.pendingProposal(), address(0));
    }

    function test_prepareAndActivateMarket_revertForNonOwner() public {
        vm.expectRevert();
        vm.prank(OTHER);
        launcher.prepareMarket(_params());

        vm.prank(OWNER);
        launcher.prepareMarket(_params());
        vm.expectRevert();
        vm.prank(OTHER);
        launcher.activateMarket();
    }

    function test_activateMarket_sourceFailurePreservesPendingMarket() public {
        vm.prank(OWNER);
        (address proposal,,) = launcher.prepareMarket(_params());
        source.setShouldRevert(true);
        vm.expectRevert();
        vm.prank(OWNER);
        launcher.activateMarket();

        assertEq(factory.proposalCount(), 1);
        assertEq(organization.metadataCount(), 1);
        assertEq(source.proposalId(), 0);
        assertEq(launcher.pendingProposal(), proposal);
        assertEq(launcher.nextProposalId(), 1);
    }

    function test_prepareMarket_revertsWhileAnotherMarketIsPending() public {
        vm.startPrank(OWNER);
        launcher.prepareMarket(_params());
        vm.expectRevert(FLMMarketLauncher.MarketAlreadyPending.selector);
        launcher.prepareMarket(_params());
        vm.stopPrank();
    }

    function test_activateMarket_revertsWithoutPendingMarket() public {
        vm.expectRevert(FLMMarketLauncher.NoPendingMarket.selector);
        vm.prank(OWNER);
        launcher.activateMarket();
    }

    function test_launcherAbiHasNoRedeemOrErc20TransferPath() public {
        (bool redeemOk,) = address(launcher)
            .call(abi.encodeWithSignature("redeem(uint256,address,bool)", 1, OWNER, false));
        (bool transferOk,) =
            address(launcher).call(abi.encodeWithSignature("transfer(address,uint256)", OWNER, 1));
        assertFalse(redeemOk);
        assertFalse(transferOk);
        assertEq(manager.redeemCalls(), 0);
    }

    function test_bind_isOneShot() public {
        vm.expectRevert(FLMMarketLauncher.AlreadyBound.selector);
        vm.prank(OWNER);
        launcher.bind(
            address(source),
            address(manager),
            address(factory),
            address(organization),
            COMPANY,
            CURRENCY,
            "governance",
            "en_US"
        );
    }

    function _params() private pure returns (FLMMarketLauncher.MarketParams memory) {
        return FLMMarketLauncher.MarketParams({
            marketName: "Should FLM launch?",
            minBond: 1 ether,
            openingTime: 1_900_000_000,
            displayNameQuestion: "Should FLM launch?",
            displayNameEvent: "FLM launch",
            description: "A test market",
            metadataJson: '{"chain":100,"invertTwapPool":false}'
        });
    }
}
