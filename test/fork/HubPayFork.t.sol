// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReagentHub} from "../../src/ReagentHub.sol";
import {Covenant} from "../../src/Covenant.sol";
import {CovenantExt} from "../../src/CovenantExt.sol";
import {CovenantFactory} from "../../src/CovenantFactory.sol";

interface ICallbackProxy {
    function deliverCallback(uint8 kind, bytes calldata data) external;
    function debt(address) external view returns (uint256);
    function reserves(address) external view returns (uint256);
}

/// @notice T-HUB-PAY (c)'s control: a Hub whose `pay` refuses (the r0 "no pay" design).
contract HubPayRefuses is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function pay(uint256) external pure override {
        revert("no pay");
    }
}

/// @notice T-HUB-PAY (c) on a Unichain Sepolia fork, through the REAL callback proxy (G1: `deliverCallback(uint8,
///         bytes)` from the operator EOA): a Hub with zero reserves and an ETH balance receives a callback; the proxy
///         charges after the call and, reserves being short, calls the Hub's `pay`: the debt is 0 and the callback
///         applied. Control: a Hub whose `pay` refuses keeps a debt.
contract HubPayForkTest is Test {
    address internal constant PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
    address internal constant OPERATOR = 0xF9F61C1D3325e2d4aBb55dd9e0Db84F7A0D914B0;
    string internal constant RPC = "https://unichain-sepolia-rpc.publicnode.com";
    /// @dev Pinned (s2 r2 m-3): the proxy implementation and operator as of this block.
    uint256 internal constant BLOCK = 68622541;
    address internal RC = makeAddr("rc");

    struct Callback {
        uint256 chainId;
        address target;
        uint64 gasLimit;
        bytes payload;
    }

    ReagentHub internal hub;
    CovenantFactory internal factory;

    function setUp() public {
        vm.createSelectFork(RPC, BLOCK);
        CovenantExt ext = new CovenantExt();
        Covenant impl = new Covenant(address(ext));
        factory = new CovenantFactory(RC, address(this), address(impl));
        hub = ReagentHub(payable(factory.HUB()));
    }

    function _deliver(uint64 seq) internal {
        bytes memory payload = abi.encodeCall(ReagentHub.rcConduct, (RC, 7, 1, 0, 0, seq));
        vm.prank(OPERATOR);
        ICallbackProxy(PROXY).deliverCallback(0, abi.encode(Callback(1301, address(hub), 400_000, payload)));
    }

    function test_T_HUB_PAY__theRealProxySettlesFromTheHubsBalance() public {
        assertEq(ICallbackProxy(PROXY).reserves(address(hub)), 0, "no reserves");
        vm.deal(address(hub), 0.01 ether);
        _deliver(1);
        (uint32 b,,, uint64 s) = hub.conduct(7);
        assertEq(b, 1, "the callback applied");
        assertEq(s, 1);
        assertEq(ICallbackProxy(PROXY).debt(address(hub)), 0, "no debt: pay settled the charge");
        assertLt(address(hub).balance, 0.01 ether, "paid from the Hub's balance");
        _deliver(2); // the next delivery is not blocked
        (,,, s) = hub.conduct(7);
        assertEq(s, 2);
    }

    function test_T_HUB_PAY__PC_aHubThatCannotPayFallsIntoDebt() public {
        vm.prank(address(factory));
        HubPayRefuses h = new HubPayRefuses(RC);
        vm.etch(address(hub), address(h).code);
        vm.deal(address(hub), 0.01 ether);
        _deliver(1);
        assertGt(ICallbackProxy(PROXY).debt(address(hub)), 0, "a debt remains");
        assertEq(address(hub).balance, 0.01 ether);
    }
}
