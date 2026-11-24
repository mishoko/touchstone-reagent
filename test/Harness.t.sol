// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcEnv, MockSystem} from "./base/RcEnv.sol";
import {LogRecord, CallbackV1, IRnkSystem} from "../src/interfaces/IReactive.sol";
import {IReagentHub, ICovenant} from "../src/interfaces/IReagent.sol";

/// @notice A minimal reactive contract for the harness's own tests: it subscribes, unsubscribes and requests
///         callbacks on command, and counts reactions.
contract ProbeRC {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 public reacts;
    uint256 public lastChain;
    address public lastEmitter;
    uint256 public lastTopic2;
    uint256 public lastBlock;
    uint256[] public seen; // the chain id of each reaction, in order
    CallbackV1 internal onReact; // a request made from inside the next react (if armed)
    bool internal armed;

    function sub(uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        IRnkSystem(SYSTEM).subscribe(c, e, t0, t1, t2, t3);
    }

    function unsub(uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        IRnkSystem(SYSTEM).unsubscribe(c, e, t0, t1, t2, t3);
    }

    function seenCount() external view returns (uint256) {
        return seen.length;
    }

    function arm(CallbackV1 calldata cfg) external {
        onReact = cfg;
        armed = true;
    }

    function react(LogRecord calldata l) external {
        require(msg.sender == SYSTEM, "not system");
        ++reacts;
        (lastChain, lastEmitter, lastTopic2, lastBlock) = (l.chainId, l.emitter, l.topic2, block.number);
        seen.push(l.chainId);
        if (armed) {
            armed = false;
            IRnkSystem(SYSTEM).requestCallbackV_1_0(onReact);
        }
    }
}

contract HarnessTest is RcEnv {
    ProbeRC probe;
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");
    bytes32 constant APPLIED = keccak256("Applied(uint32,uint64)");
    bytes32 constant NOTE = keccak256("Note(address,address,uint8,bytes)");

    function setUp() public {
        _setUpTwoChains();
        probe = new ProbeRC();
        _deployReagent(address(probe), admin);
    }

    /// @dev Delivers one rcConduct to `c`'s Hub through the harness proxy, as if the probe had requested it.
    function _conductVia(uint256 c, uint64 gasLimit, uint64 seq_) internal {
        bytes memory p = abi.encodeCall(IReagentHub.rcConduct, (address(0), 7, 1, 0, 0, seq_));
        { uint256 _p = _lasna(); probe.arm(CallbackV1(c, address(ch[CA].hub), gasLimit, p)); _leave(_p); } // the canonical (chain A) Hub address
        // any subscribed log triggers the armed request
        { uint256 _p = _lasna(); probe.sub(LASNA, CRON, CRON100, IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(113); // exactly 100 Lasna blocks: one Cron100 tick
        _elapse(30); // the callback's delivery (3 s / 13.2 s) and the answer's reaction (one Lasna block)
        { uint256 _p = _lasna(); probe.unsub(LASNA, CRON, CRON100, IGNORE, IGNORE, IGNORE); _leave(_p); }
    }

    function _seenOn(uint256 c) internal view returns (uint256 n) {
        for (uint256 i; i < probe.seenCount(); ++i) {
            if (probe.seen(i) == c) ++n;
        }
    }

    function test_HARNESS__deliversOnlyOnALiveSubscription() public {
        // a Hub log with no subscription never reaches the RC (control for the cells below)
        _conductVia(CB, 300_000, 1);
        _conductVia(CB, 300_000, 2); // Applied on B: unsubscribed
        assertEq(_seenOn(CB), 0, "no Applied reaction without a subscription");
        // subscribed: the next Applied reaches it once
        { uint256 _p = _lasna(); probe.sub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _conductVia(CB, 300_000, 3);
        assertEq(_seenOn(CB), 1, "one Applied");
        assertEq(probe.lastEmitter(), address(ch[CA].hub), "chain B's Hub is reported at the one live address");
        // a duplicate subscription: one reaction per matching subscription
        { uint256 _p = _lasna(); probe.sub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _conductVia(CB, 300_000, 4);
        assertEq(_seenOn(CB), 3, "two reactions for the next Applied");
        // an inexact unsubscribe is silent and removes nothing; the exact one removes one
        { uint256 _p = _lasna(); probe.unsub(CB, address(ch[CA].hub), uint256(APPLIED), 0, IGNORE, IGNORE); _leave(_p); }
        assertEq(unsubscribeMisses, 1);
        { uint256 _p = _lasna(); probe.unsub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _conductVia(CB, 300_000, 5);
        assertEq(_seenOn(CB), 4, "one again");
    }

    function test_HARNESS__injectsTheRcAndTranslatesTheHub() public {
        _conductVia(CB, 300_000, 1);
        (uint32 b,,, uint64 s) = ch[CB].hub.conduct(7);
        assertEq(b, 1);
        assertEq(s, 1, "chain B's Hub applied: recipient translated, first word = the RC");
        (b,,,) = ch[CA].hub.conduct(7);
        assertEq(b, 0, "chain A untouched");
        assertEq(_deliveredCount(CB, IReagentHub.rcConduct.selector, 1), 1);
    }

    function test_HARNESS__dropsUnder100kAndSubtractsF() public {
        _conductVia(CB, 99_999, 1);
        assertEq(_deliveredCount(CB, bytes4(0), 3), 1, "dropped under the 100k minimum");
        // F on 11155111 is 243.3k: a 250k limit leaves ~6.6k of entry gas, not enough for the Hub: charged, no retry
        _conductVia(CB, 250_000, 2);
        assertEq(_deliveredCount(CB, bytes4(0), 2), 1, "reverted for gas");
        (,,, uint64 s) = ch[CB].hub.conduct(7);
        assertEq(s, 0);
        // the same limit on 1301 (F 177.2k) leaves ~71k: applied
        _conductVia(CA, 250_000, 3);
        (,,, s) = ch[CA].hub.conduct(7);
        assertEq(s, 3);
    }

    function test_HARNESS__perChainClocks() public {
        uint256 a0 = _bn(CA);
        uint256 b0 = _bn(CB);
        uint256 l0 = _bn(LASNA);
        _elapse(132);
        assertEq(_bn(CA) - a0, 132);
        assertEq(_bn(CB) - b0, 10);
        assertEq(_bn(LASNA) - l0, 116);
        _on(CB);
        assertEq(block.chainid, CB);
        assertEq(vm.getBlockNumber(), _bn(CB));
        advance(5); // five 13.2 s blocks on B move A by 66 blocks
        assertEq(_bn(CA) - a0, 198);
    }

    function test_HARNESS__cronOnlyWhileSubscribed() public {
        _elapse(1130); // 10 Cron100 ticks, unsubscribed
        _pump();
        assertEq(probe.reacts(), 0);
        { uint256 _p = _lasna(); probe.sub(LASNA, CRON, CRON100, IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(1130);
        _pump();
        assertEq(probe.reacts(), 10);
        assertEq(probe.lastBlock() % 100, 0, "Cron at a multiple of 100");
    }

    function test_HARNESS__translatesOnlyTheHubAndCovenants() public {
        // the Touchstone factories differ per chain live and are never translated (s3 rc r2 D2-06)
        assertTrue(address(ch[CA].ts) != address(ch[CB].ts));
        assertEq(toA[address(ch[CB].ts)], address(0));
        assertEq(toA[address(ch[CB].factory)], address(0), "the CovenantFactory is not seen by the RC");
        assertEq(toA[address(ch[CB].hub)], address(ch[CA].hub));
        // live: the addresses equal on both chains are exactly the deterministic set (ext, impl, CovenantFactory,
        // Hub; audits/deployments-*.json); of those the RC sees only the Hub (Note/Applied/BudgetApplied emitter)
        string memory a = vm.readFile("./audits/deployments-1301.json");
        string memory b = vm.readFile("./audits/deployments-11155111.json");
        string[4] memory ks = ["ext", "impl", "factory", "hub"];
        for (uint256 i; i < 4; ++i) {
            string memory k = string.concat(".steps.reagent.reads.addresses.", ks[i]);
            assertEq(vm.parseJsonAddress(a, k), vm.parseJsonAddress(b, k), "deterministic on both chains");
        }
        assertEq(toA[address(ch[CB].ts)], address(0), "the Touchstone factories differ live");
    }

    /// @notice The mock system burns the measured Lasna cost of each call, to within 500 gas of its body (never under) (s3 rc r3
    ///         D3-06, r4 D4-07): the caller-side cost is taken from a no-op with the same argument shapes.
    function test_HARNESS__mockSystemCostsAreCalibrated() public {
        _on(LASNA);
        sys.nopSub(CA, address(1), 1, IGNORE, IGNORE, IGNORE); // warm the account for both measurements
        uint256 g0 = gasleft();
        sys.nopSub(CA, address(1), 1, IGNORE, IGNORE, IGNORE);
        uint256 base = g0 - gasleft();
        g0 = gasleft();
        sys.subscribe(CA, address(1), 1, IGNORE, IGNORE, IGNORE);
        uint256 used = g0 - gasleft() - base;
        assertGe(used, 9_932, "the cold live cost, charged on every call");
        assertLe(used, 9_932 + 500);
        bytes memory p = new bytes(1260);
        CallbackV1 memory cb = CallbackV1(CA, address(2), 100_000, p);
        g0 = gasleft();
        sys.nopReq(cb);
        base = g0 - gasleft();
        g0 = gasleft();
        sys.requestCallbackV_1_0(cb);
        used = g0 - gasleft() - base;
        assertGe(used, 12_887 + 8_000, "260 B measured + 8 gas per further byte");
        assertLe(used, 12_887 + 8_000 + 500);
        _on(CA);
    }

    /// @notice Two Cron ticks in one `_elapse`: tick 1's callback is answered, and its `Applied` reaches the RC,
    ///         before tick 2 runs (each reaction and its callbacks run at the event's own time, s3 rc r4 D4-05).
    function test_HARNESS__answersArriveBetweenTicks() public {
        { uint256 _p = _lasna();
          probe.sub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE);
          probe.sub(LASNA, CRON, CRON100, IGNORE, IGNORE, IGNORE);
          probe.arm(CallbackV1(CB, address(ch[CA].hub), 300_000, abi.encodeCall(IReagentHub.rcConduct, (address(0), 7, 1, 0, 0, 1))));
          _leave(_p); }
        _elapse(113 * 2 + 5);
        assertEq(probe.seenCount(), 3);
        assertEq(probe.seen(0), LASNA, "tick 1");
        assertEq(probe.seen(1), CB, "its answer, before tick 2");
        assertEq(probe.seen(2), LASNA, "tick 2");
    }

    /// @notice A per-log policy can drop, duplicate and hold origin logs (R-B6SCHED's log scheduler, D4-05).
    function test_HARNESS__logPolicyDropDupHold() public {
        { uint256 _p = _lasna(); probe.sub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(3);
        policy = Act.DUP;
        _hubApplied(1);
        assertEq(probe.reacts(), 2, "duplicated");
        policy = Act.DROP;
        _hubApplied(2);
        assertEq(probe.reacts(), 2, "dropped");
        policy = Act.HOLD;
        _hubApplied(3);
        assertEq(probe.reacts(), 2, "held");
        policy = Act.DELIVER;
        _releaseHeldLogs();
        _elapse(2);
        assertEq(probe.reacts(), 3, "released late");
    }

    Act internal policy;

    function _logPolicy(LogRecord memory) internal view override returns (Act) {
        return policy;
    }

    function _hubApplied(uint64 seq_) internal {
        _on(CB);
        vm.prank(ch[CB].proxy);
        ch[CB].hub.rcConduct(address(probe), 7, 1, 0, 0, seq_);
        _elapse(2);
    }

    /// @notice A log that originated before a subscription took effect is not delivered, even when it arrives after
    ///         (the harness matches at the origin block, s3 rc r3 D3-07).
    function test_HARNESS__matchesAtTheOriginBlock() public {
        lagBlocks = 50; // the reaction comes 50 Lasna blocks after the origin
        _on(CB);
        vm.prank(ch[CB].proxy);
        ch[CB].hub.rcConduct(address(probe), 7, 1, 0, 0, 1); // an Applied on B, now
        { uint256 _p = _lasna(); probe.sub(CB, address(ch[CA].hub), uint256(APPLIED), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(113);
        _pump();
        assertEq(probe.reacts(), 0, "subscribed after the origin: missed, as live");
        // the same with the subscription in effect before the origin: delivered
        _elapse(10);
        _on(CB);
        vm.prank(ch[CB].proxy);
        ch[CB].hub.rcConduct(address(probe), 7, 2, 0, 0, 2);
        _elapse(113);
        _pump();
        assertEq(probe.reacts(), 1);
    }

    function test_HARNESS__subscriptionLag() public {
        subLag = 300;
        { uint256 _p = _lasna(); probe.sub(LASNA, CRON, CRON100, IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(113 * 2); // two ticks inside the lag
        _pump();
        assertEq(probe.reacts(), 0, "not yet in effect");
        _elapse(113 * 3);
        _pump();
        assertGt(probe.reacts(), 0);
    }

    function test_HARNESS__covenantTranslated() public {
        (ICovenant a, ICovenant b) = _covenantBoth(alice, admin);
        assertTrue(address(a) != address(b), "one EVM: distinct clones");
        { uint256 _p = _lasna(); probe.sub(CB, address(ch[CA].hub), uint256(NOTE), IGNORE, IGNORE, IGNORE); _leave(_p); }
        _elapse(3); // the subscription takes effect before the note's origin
        _on(CB);
        vm.prank(alice);
        b.flush();
        _elapse(3); // the reaction comes one Lasna block after the origin
        assertEq(probe.lastTopic2(), uint256(uint160(address(a))), "chain B's Covenant reported as the one address");
    }
}
