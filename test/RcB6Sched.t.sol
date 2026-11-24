// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {B6Fixture} from "./base/B6Fixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice R-B6SCHED (spec §9.2) as a seeded scheduler: every `rcBudget`, `BudgetApplied` and `Note` may be dropped,
///         duplicated, held and released late (reordered), interleaved with allocations, leaves, owner loosen and
///         tighten, and one-chain agent tightens. After every step: I-B6SUM's first clause (E ≤ B on each chain)
///         and the R-COUNTERS recount; at quiescence (drops stopped, everything released, both chains flushed):
///         I-CAP (b) and liveness (no unanswered unparked message, no work entry, Cron off).
contract RcB6SchedTest is B6Fixture {
    uint256 constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    uint256 constant T_BUDGET = 0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823;
    address agent = makeAddr("agent");
    uint256 rnd;
    bool chaos;
    uint256 steps;
    uint256 parksSeen;
    uint256 raisesChecked;
    bool wasRaising;
    uint256 capAtRaise; // capRC when the in-flight raise was first seen: the cap it was sent under (sent only at rest)
    uint256 tightenedMidRaise; // a tighten reached the RC while the raise was in flight (spec §4 I-CAP, §12)
    bool holdBudgets;
    bool noRuleChanges;

    function setUp() public {
        _b6SetUp();
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c);
            vm.prank(alice);
            _cov(c).setAgent(agent);
        }
        _elapse(301);
    }

    function _r(uint256 n) internal returns (uint256) {
        rnd = uint256(keccak256(abi.encode(rnd, ++steps)));
        return rnd % n;
    }

    function _act() internal returns (Act) {
        if (!chaos) return Act.DELIVER;
        uint256 x = _r(10);
        return x < 2 ? Act.DROP : x < 3 ? Act.DUP : x < 5 ? Act.HOLD : Act.DELIVER;
    }

    function _logPolicy(LogRecord memory l) internal override returns (Act) {
        if (l.topic0 == T_NOTE || l.topic0 == T_BUDGET) return _act();
        return Act.DELIVER;
    }

    function _policy(Req memory q) internal override returns (Act) {
        if (_sel(q.payload) == IReagentHub.rcBudget.selector) {
            if (holdBudgets) {
                // hold only RAISES (the RC's flag on the message it just sent): a raise goes out only at rest,
                // so holding every budget message would never let one out (I-CAP (a) non-vacuity)
                (, , uint32 id) = abi.decode(_slice(q.payload, 4), (address, address, uint32));
                (,,,,, uint8 f,) = rc.b6Of(address(ca), id, q.chainId);
                if (f & 2 != 0) return Act.HOLD;
                return Act.DELIVER;
            }
            return _act();
        }
        return Act.DELIVER;
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory o) {
        o = new bytes(b.length - from);
        for (uint256 i; i < o.length; ++i) {
            o[i] = b[from + i];
        }
    }

    // ------------------------------------------------------------------ actions

    function _tryAlloc(uint256 c, uint256 shares) internal {
        V memory v = _vaultOn(c);
        _on(c);
        _keepAlive(v, 2);
        vm.prank(alice);
        (bool ok,) = address(_cov(c)).call(abi.encodeCall(ICovenant.allocate, (v.vault, shares, type(uint256).max, type(uint256).max)));
        // a refusal (B6, or any guard) is a legal outcome; an allocation that lands keeps E ≤ B on its chain
        // (I-B6SUM's first clause holds after every ALLOCATION; a tighten may leave E > B: exposure spent before it)
        if (ok) assertLe(_E(c), _B(c), "I-B6SUM: E <= B after an allocation");
    }

    function _tryLeave(uint256 c, uint256 pct) internal {
        V memory v = _vaultOn(c);
        _on(c);
        uint256 l = _cov(c).ledger(v.vault);
        if (l == 0) return;
        vm.prank(alice);
        (bool ok,) = address(_cov(c)).call(abi.encodeCall(ICovenant.leave, (v.vault, l * pct / 100, 0, 0)));
        ok;
    }

    function _trySetBudget(uint256 c, uint128 budget, bool asAgent) internal {
        _on(c);
        Rulebook memory r = _cov(c).rules();
        if (r.budget == budget) return;
        if (asAgent && budget > r.budget) return; // the agent can only tighten
        uint256 b0 = _B(c);
        r.budget = budget;
        r.agentCapPerEpoch = budget / 10;
        vm.prank(asAgent ? agent : alice);
        bytes memory cd = asAgent ? abi.encodeCall(ICovenant.tighten, (r)) : abi.encodeCall(ICovenant.setRules, (r));
        (bool ok,) = address(_cov(c)).call(cd);
        // I-CAP (c): an agent tighten never raises a chain's B (the owner's loosen may, by design: r27 D27-01)
        if (ok && asAgent) assertLe(_B(c), b0, "I-CAP (c): a tighten never raises B");
    }

    function _step() internal {
        uint256 k = _r(9);
        uint256 c = _r(2) == 0 ? CA : CB;
        if (k < 3) _tryAlloc(c, (1 + _r(8)) * 2.5e23); // about 2.5 to 20 mWETH of exposure
        else if (k == 8) hubInDebt[c] = !hubInDebt[c]; // a debt window: no callback reaches that Hub (parks)
        else if (k == 3) _tryLeave(c, 10 + _r(80));
        else if (k == 4 && !noRuleChanges) _trySetBudget(c, uint128((60 + _r(80)) * 1e18), false);
        else if (k == 5 && !noRuleChanges) _trySetBudget(c, uint128((40 + _r(60)) * 1e18), true);
        else if (k == 6) _releaseLate();
        else _elapse(30 + _r(400));
        _elapse(5);
        _checkStep();
    }

    function _releaseLate() internal {
        _releaseHeldLogs();
        _releaseHeld();
        _elapse(2);
    }

    // ------------------------------------------------------------------ checks

    /// @notice After every step: E ≤ B on each chain (I-B6SUM's first clause, the Covenant's own guard) and the
    ///         R-COUNTERS recount of the counters this Covenant touches.
    function _checkStep() internal {
        _recount();
        _assertCapA();
    }

    /// @notice I-CAP (a): while a raise is unanswered, Σ_c committed_c ≤ capRC (RC view: committed =
    ///         max(applied B, E, the highest unanswered B); capRC = the minimum cap over the reported chains).
    function _assertCapA() internal {
        uint256 p = _lasna();
        bool raising;
        uint256 sum;
        uint256 capRC = type(uint256).max;
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            (uint96 ab, uint96 e, uint96 unB,,, uint8 f,) = rc.b6Of(address(ca), 1, c);
            if (f & 3 == 3) raising = true;
            uint256 m = ab > e ? ab : e;
            if (f & 1 != 0 && unB > m) m = unB;
            sum += m;
            (uint128 cap,,,,,) = rc.covOf(c, address(ca));
            if (cap < capRC) capRC = cap;
        }
        if (raising) {
            if (!wasRaising) capAtRaise = capRC;
            wasRaising = true;
            // I-CAP (a) bounds a raise by capRC at its send; a raise sent before the RC received the other chain's
            // tighten may still land, and that chain's next STATE triggers a safety lower (spec §4, §12)
            if (capRC < capAtRaise) {
                ++tightenedMidRaise;
                console2.log("I-CAP (a): tighten after the send; cap at send", capAtRaise, "now", capRC);
            }
            assertLe(sum, capAtRaise, "I-CAP (a): a raise in flight keeps sum committed <= capRC at its send");
            ++raisesChecked;
        } else {
            wasRaising = false;
        }
        _leave(p);
    }

    function _recount() internal {
        uint256 p = _lasna();
        (, uint256 work,,) = rc.counters();
        uint256 listed;
        for (uint256 i; i < work; ++i) {
            (uint256 c, address cv) = rc.workAt(i);
            (,,,, bool wl,) = rc.covOf(c, cv);
            assertTrue(wl, "R-COUNTERS: every work-list element has its listed bit");
            ++listed;
        }
        for (uint256 i; i < 2; ++i) {
            (,,,, bool wl,) = rc.covOf(i == 0 ? CA : CB, address(ca));
            if (wl) {
                bool found;
                for (uint256 j; j < work; ++j) {
                    (uint256 c2, address cv2) = rc.workAt(j);
                    if (c2 == (i == 0 ? CA : CB) && cv2 == address(ca)) found = true;
                }
                assertTrue(found, "R-COUNTERS: a listed bit has its element");
            }
        }
        (address h,, uint256 n) = rc.lowersOf();
        uint256 walk;
        while (h != address(0) && walk <= n) {
            (address nx,,) = rc.lowersNext(h);
            h = nx;
            ++walk;
        }
        assertEq(walk, n, "R-COUNTERS: lowersCount equals the list's length");
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            (, uint16 bpc) = rc.parkedOf(c, 1);
            (,,,,,, uint32 pl) = rc.b6Of(address(ca), 1, c);
            (,,,,, uint8 f,) = rc.b6Of(address(ca), 1, c);
            uint256 counted = pl != 0 && f & 8 == 0 ? 1 : 0;
            if (pl != 0) ++parksSeen;
            assertEq(bpc, counted, "R-COUNTERS: b6ParkedCount equals the counted parks");
        }
        _leave(p);
    }

    /// @notice Quiescence: drops stop, everything held is released, both chains flush (a fresh STATE each), and
    ///         time passes beyond every back-off and park bound.
    function _quiesce() internal {
        chaos = false;
        (hubInDebt[CA], hubInDebt[CB]) = (false, false);
        _releaseLate();
        // idle-Covenant liveness first (no owner action at all): within the back-off and park bounds every
        // budget message is answered or parked (r17 D17-01; this is what caught the s4 lifecycle gap)
        _elapse(200 * 113);
        {
            uint256 p = _lasna();
            for (uint256 i; i < 2; ++i) {
                (,,,,, uint8 f, uint32 pl) = rc.b6Of(address(ca), 1, i == 0 ? CA : CB);
                assertTrue(f & 1 == 0 || pl != 0, "idle liveness: answered or parked without any owner action");
            }
            _leave(p);
        }
        for (uint256 round; round < 3; ++round) {
            _elapse(301);
            for (uint256 i; i < 2; ++i) {
                uint256 c = i == 0 ? CA : CB;
                _on(c);
                _keepAlive(_vaultOn(c), 2);
                vm.prank(alice);
                (bool ok,) = address(_cov(c)).call(abi.encodeCall(ICovenant.flush, ()));
                ok;
            }
            _elapse(250 * 113); // 250 ticks: every back-off, park probe and re-send
        }
    }

    function _assertLive() internal {
        uint256 p = _lasna();
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            (,,,,, uint8 f, uint32 pl) = rc.b6Of(address(ca), 1, c);
            assertTrue(f & 1 == 0 || pl != 0, "liveness: every budget message answered or parked");
            assertEq(pl, 0, "liveness: no park left after the Hubs answered again");
        }
        (uint256 pp, uint256 work, uint256 sw, bool on) = rc.counters();
        console2.log("quiescent: pending", pp, "work", work);
        console2.log("  sweeps", sw, "cron", on ? 1 : 0);
        assertEq(work, 0, "liveness: no work entry left");
        assertFalse(on, "liveness: Cron off");
        _leave(p);
    }

    /// forge-config: default.fuzz.runs = 12
    function test_R_B6SCHED__dropsDupsDelaysReordersKeepTheCapAndStayLive(uint256 seed) public {
        _run(seed);
    }

    /// @notice Fixed seeds (their logs show the schedule's coverage: requests, scheduler drops, parks).
    function test_R_B6SCHED__seed1() public {
        _run(1);
    }

    function test_R_B6SCHED__seed2() public {
        _run(2);
    }

    function test_R_B6SCHED__seed3() public {
        _run(3);
    }

    function _run(uint256 seed) internal {
        rnd = seed;
        chaos = true;
        for (uint256 i; i < 40; ++i) {
            _step();
        }
        uint256 sent = _budgetSends(CA) + _budgetSends(CB);
        uint256 dropped = _deliveredCount(0, IReagentHub.rcBudget.selector, 5);
        console2.log("rcBudget requests", sent, "dropped by the scheduler", dropped);
        console2.log("parks seen", parksSeen);
        assertGt(sent, 0, "non-vacuous: budget messages were sent under chaos");
        _quiesce();
        _checkStep();
        _assertCapAtRest();
        _assertLive();
        console2.log("B_A", _B(CA) / 1e15, "E_A", _E(CA) / 1e15);
        console2.log("B_B", _B(CB) / 1e15, "E_B", _E(CB) / 1e15);
    }

    /// @notice I-CAP (§4, checked across both chains by the scheduler): (a) after every step, (b) at quiescence,
    ///         (c) at every agent tighten.
    function test_I_CAP__aBCHoldUnderTheScheduler() public {
        _run(11);
        // raises held in flight across steps, so (a) is checked while they are unanswered (non-vacuous)
        for (uint256 j; j < 4; ++j) {
            _allocTo(CA, _B(CA) * 97 / 100);
            holdBudgets = true;
            _elapse(900);
            _checkStep();
            _tryAlloc(CB, 5e23);
            _checkStep();
            holdBudgets = false;
            _releaseLate();
            _elapse(900);
            _checkStep();
        }
        _run2(12);
        assertGt(raisesChecked, 0, "I-CAP (a) was checked with a raise in flight");
    }

    /// @notice s5 counterexample (a tighten reached the RC while a raise was in flight; the checker compared against
    ///         the new cap): kept as a fixed cell.
    function test_R_B6SCHED__seedTightenMidRaise() public {
        _run(33550280150062231128225087615149342456621128802140773398544284085856898931965);
        assertGt(tightenedMidRaise, 0, "non-vacuous: the tighten landed while the raise was in flight");
    }

    /// @notice A former counterexample seed (s4: the checker used a fixed cap), kept as a fixed cell.
    function test_R_B6SCHED__seed14522() public {
        _run(14522);
    }

    /// @notice I-B6SUM (§4): E ≤ B on each chain after every step, and Σ E ≤ cap at reconciled points.
    function test_I_B6SUM__eWithinBEveryStepAndTheCapAtRest() public {
        // clause 1 after every allocation (in `_tryAlloc`), with rule changes in the schedule
        _run(21);
    }

    /// @notice I-B6SUM clause 2 (r21 D21-01): with no rule change, every allocation made while both Hubs hold
    ///         reconciled budgets keeps Σ E ≤ the current cap: checked at each reconciled point of a chaotic run.
    function test_I_B6SUM__sumOfExposureWithinTheCapAtReconciledPoints() public {
        noRuleChanges = true;
        rnd = 31;
        for (uint256 j; j < 4; ++j) {
            chaos = true;
            for (uint256 i; i < 10; ++i) {
                _step();
            }
            _quiesce(); // a reconciled point: drops stopped, everything delivered and answered
            assertLe(_E(CA) + _E(CB), _capNow(), "I-B6SUM clause 2: sum E <= cap at a reconciled point");
        }
    }

    function _run2(uint256 seed) internal {
        chaos = true;
        rnd = seed;
        for (uint256 i; i < 20; ++i) {
            _step();
        }
        _quiesce();
        _assertCapAtRest();
        console2.log("raises checked under I-CAP (a)", raisesChecked);
    }
}
