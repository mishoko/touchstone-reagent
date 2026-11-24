// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {RcExtGasProbe} from "./base/RcProbe.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";

/// @notice R-COUNTERS / R-B6SCHED cells on the sweep's b6Parked walk (spec §5.5 step 3, §3.5 sweeps; F-012):
///         16 Covenants listing id 1 are B6-parked on BOTH chains (both Hubs in debt; 32 elements, more than one
///         Cron tick's 24 sweep items), and a 17th listing id 2 is parked on 11155111. Curator 1 has a 1301 vault
///         (no holders) whose latch marks id 1 dirty.
contract RcCountersParkTest is RcFixture {
    V x;
    ICovenant[16] pa;
    ICovenant[16] pb;
    ICovenant qa;
    ICovenant qb;

    function _rules(uint32 id, uint128 budget) internal pure returns (Rulebook memory r) {
        r.k = 1;
        r.b3 = true;
        r.b4FloorBps = 5_000;
        r.maxShareBps = 6_000;
        r.budget = budget;
        r.agentCapPerEpoch = budget / 10;
        r.ids = [id, 0, 0, 0];
    }

    /// @dev Divergent caps (A 60, B 30): the RC owes lowers on both chains (A to 15, B to 0), spec §5.5 step 1.
    function _parkedPair(uint256 i, uint32 id) internal returns (ICovenant a, ICovenant b) {
        (a, b) = _covenantBoth(makeAddr(string(abi.encode("park-owner", id, i))), admin);
        _setRulesOn(CA, a, _rules(id, 100e18));
        _elapse(3);
        _setRulesOn(CB, b, _rules(id, 50e18));
        _elapse(20);
    }

    function setUp() public virtual {
        _setUpRc();
        x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        (hubInDebt[CA], hubInDebt[CB]) = (true, true);
        for (uint256 i; i < 16; ++i) {
            (pa[i], pb[i]) = _parkedPair(i, 1);
        }
        (qa, qb) = _parkedPair(0, 2);
        _elapse(300 * 113); // > 6 · EPOCH_TICKS on both chains (1301: 192) plus the back-off and the entries served late
        emit log_named_uint("parked CA id1", _parked(CA, 1));
        emit log_named_uint("parked CB id1", _parked(CB, 1));
        emit log_named_uint("parked CB id2", _parked(CB, 2));
        {
            uint256 p = _lasna();
            (uint96 ab, uint96 e, uint96 unB, uint32 n, uint32 an, uint8 f, uint32 pl) = rc.b6Of(address(pa[0]), 1, CA);
            emit log_named_uint("A appliedB", ab);
            emit log_named_uint("A unB", unB);
            emit log_named_uint("A flags", f);
            emit log_named_uint("A parkLog", pl);
            (ab, e, unB, n, an, f, pl) = rc.b6Of(address(pa[0]), 1, CB);
            emit log_named_uint("B appliedB", ab);
            emit log_named_uint("B unB", unB);
            emit log_named_uint("B flags", f);
            emit log_named_uint("B parkLog", pl);
            e; n; an;
            _leave(p);
        }
        require(_parked(CA, 1) == 16 && _parked(CB, 1) == 16, "setUp: 16 parks per chain for id 1");
        require(_parked(CB, 2) == 1, "setUp: the id-2 park");
        (,,, bool on) = _counters();
        require(!on, "setUp: Cron off once everything is parked");
    }

    function _parked(uint256 c, uint32 id) internal returns (uint16 n) {
        uint256 p = _lasna();
        (, n) = rc.parkedOf(c, id);
        _leave(p);
    }

    function _counters() internal returns (uint256 pp, uint256 work, uint256 sw, bool on) {
        uint256 p = _lasna();
        (pp, work, sw, on) = rc.counters();
        _leave(p);
    }

    /// @dev Moves the wall clock to just after the next Cron tick (its reaction and callbacks run).
    function _toNextTick() internal {
        uint256 next = lastCronBn + 100;
        uint256 nowBn = lasnaBlock();
        _elapse(((next - nowBn) * 1130) / 1000 + 1);
    }

    /// @dev A refunded Hub on `c` and one flush by `cv` there: its STATE probes every (chain, id) where RC storage
    ///      shows it parked; the probe's `Applied` is the callback result that makes the parks wakeable (spec §3.5).
    ///      With `redebt`, the Hub is in debt again right after that one result: the wakes' own resends are then never
    ///      answered, so no later callback result re-marks the id (every later lap would heal a skipped element).
    function _wakeVia(uint256 c, ICovenant cv, bool redebt) internal {
        hubInDebt[c] = false;
        _on(c);
        vm.prank(cv.owner());
        cv.flush();
        _elapse(20);
        if (redebt) hubInDebt[c] = true;
    }

    /// @notice MU-267: one callback result, then no other: the sweep it starts (a fresh one: a single lap) must wake
    ///         every wakeable park although each unpark shrinks the walked list (the walk steps back every time).
    function test_R_COUNTERS__oneResultWakesEveryParkInTheSweepsOnlyLap() public {
        _wakeVia(CB, pb[0], true);
        _elapse(20 * 113); // the lap spans several ticks (each wake is a guarded item); < 6 · EPOCH_TICKS (no re-park)
        assertEq(_parked(CB, 1), 0, "every 11155111 park of id 1 woke (no element skipped by a shrinking walk)");
        assertEq(_parked(CA, 1), 16, "1301's parks stay: no callback result there");
    }

    /// @notice MU-250 and MU-259: a fresh sweep of id 1 (one lap) started by a latch walks its 1301 elements first
    ///         (none wakes: no callback result yet, MU-259); then one 1301 result marks id 1 MID-lap: the sweep gets one
    ///         more full lap, so the elements visited before the mark wake too, with no further result.
    function test_R_COUNTERS__aMidLapMarkGetsAnotherFullLap() public {
        _on(CA);
        _latch(x, 1); // marks id 1 dirty: a fresh sweep (one lap)
        _backInRange(x);
        _stopInsideTheLap();
        assertEq(_parked(CA, 1), 16, "no park wakes without a callback result after it (MU-259)");
        assertEq(_parked(CB, 1), 16, "no park wakes without a callback result after it (MU-259)");
        _wakeVia(CA, pa[0], true); // one result: it re-marks id 1 MID-lap, after 1301 elements were walked
        _elapse(20 * 113);
        assertEq(_parked(CA, 1), 0, "the elements visited before the mark woke in the extra lap (MU-250)");
        assertEq(_parked(CB, 1), 16, "11155111 saw no callback result");
    }

    /// @dev Steps tick by tick until id 1's fresh sweep has walked some of its 1301 elements (they come first) but
    ///      not finished its only lap; asserts that position (non-vacuity of "mid-lap").
    function _stopInsideTheLap() internal {
        for (uint256 i; i < 40; ++i) {
            uint256 p = _lasna();
            (uint32 pos, uint32 lap, uint32 endLap, bool on) = rc.sweepOf(1);
            _leave(p);
            if (on && lap == 0 && pos > 0) {
                assertEq(endLap, 1, "a fresh sweep: its only lap");
                assertLt(pos, 32, "inside the lap");
                return;
            }
            _toNextTick();
        }
        revert("the sweep never stopped inside its lap");
    }

    /// @notice MU-266: the dirty ids are served round-robin: id 2's single park wakes in the first tick after its mark
    ///         while id 1's sweep (32 elements, re-marked mid-lap) is still running.
    function test_R_COUNTERS__dirtyIdsAreServedRoundRobin() public {
        _on(CA);
        _latch(x, 1); // id 1 dirty: a fresh sweep at the next tick
        _toNextTick();
        _toNextTick(); // id 1's sweep: 24 of 32 elements walked
        _on(CA);
        _process(x); // BreachProcessed re-marks id 1 mid-lap: one more full lap (40 items still to walk)
        _backInRange(x);
        _wakeVia(CB, qb, false); // id 2 marked by its probe's Applied; id 1 sees no callback result
        _toNextTick();
        assertEq(_parked(CB, 2), 0, "id 2's park woke in the next tick (round-robin, no head-of-line)");
        (,, uint256 sw,) = _counters();
        assertGt(sw, 0, "non-vacuous: id 1's sweep was still running");
    }
}

/// @notice MU-273 (spec §5.5 floor (3), v13 r1 V1-09): a lap end is the sweep step's item. With an id whose lap is
///         empty (a vault without holders, no parks) ahead of an id with one wakeable park, floor (3) ends that lap and
///         serves nothing more; the park wakes later in the tick (the bulk). Observed by the probe's phase marks.
contract RcCountersLapEndTest is RcCountersParkTest {
    bytes32 internal constant T_ITEM_ = keccak256("ProbeItem(uint8,bytes4,uint256,uint256,bool)");
    bytes32 internal constant T_PHASE_ = keccak256("ProbePhase(uint8,uint256)");

    function _newExt() internal override returns (address) {
        return address(new RcExtGasProbe(_newB6()));
    }

    function test_R_GAS__aLapEndIsFloorThreesItem() public {
        V memory x3 = _registeredVault(CA, 3); // curator 3: no holders, no parks: an empty lap
        _on(CA);
        _age(x3, 40);
        cronWithheld = true;
        _on(CA);
        _latch(x3, 1); // marks id 3 (first in the dirty list)
        _backInRange(x3);
        _elapse(5);
        _wakeVia(CB, qb, false); // id 2's park wakeable, id 2 marked second
        uint256 log0 = lasnaLogs.length;
        cronWithheld = false;
        _toNextTick();
        // floor (3) is the tick's first sweep call: its span holds no item (only id 3's lap end)
        (uint256 s0, uint256 s1, bool found) = _firstSweepSpan(log0);
        assertTrue(found, "the tick ran its sweep floor");
        for (uint256 i = log0; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter != address(rc) || lasnaLogs[i].topics[0] != T_ITEM_) continue;
            (, uint256 g,,) = abi.decode(lasnaLogs[i].data, (bytes4, uint256, uint256, bool));
            assertFalse(g <= s0 && g > s1, "floor (3) served only the lap end (no item inside its span)");
        }
        uint256 p = _lasna();
        (,,, bool on3) = rc.sweepOf(3);
        _leave(p);
        assertFalse(on3, "id 3's empty lap ended");
        assertEq(_parked(CB, 2), 0, "id 2's park still woke in the tick (the bulk)");
    }

    function _firstSweepSpan(uint256 from) internal view returns (uint256 s0, uint256 s1, bool found) {
        for (uint256 i = from; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter != address(rc) || lasnaLogs[i].topics[0] != T_PHASE_) continue;
            uint8 ph = uint8(uint256(lasnaLogs[i].topics[1]));
            uint256 g = abi.decode(lasnaLogs[i].data, (uint256));
            if (ph == 3 && !found) (s0, found) = (g, true);
            else if (ph == 4 && found) return (s0, g, true);
        }
    }
}

/// @notice R-COUNTERS (F-012, rc-fix r2 C2-03): an overflowed (17th) B6 park on 11155111 for id 1 (the list holds 16)
///         is counted nowhere and unparks only through its own STATE after a callback result (spec §5.5 step 3).
contract RcCountersOverflowTest is RcCountersParkTest {
    ICovenant p17a;
    ICovenant p17b;

    function setUp() public override {
        super.setUp();
        (p17a, p17b) = _parkedPair(16, 1); // the hubs are still in debt
        _elapse(300 * 113);
        uint256 p = _lasna();
        (,,,,, uint8 f, uint32 pl) = rc.b6Of(address(p17a), 1, CB);
        _leave(p);
        require(pl != 0 && f & 8 != 0, "setUp: the 17th park overflowed on 11155111");
        require(_parked(CB, 1) == 16, "setUp: still 16 counted");
    }

    function _b6Flags(ICovenant cv, uint256 c) internal returns (uint8 f, uint32 pl) {
        uint256 p = _lasna();
        (,,,,, f, pl) = rc.b6Of(address(cv), 1, c);
        _leave(p);
    }

    /// @notice MU-278: one result on 11155111 (its own flush's probe), then its own second STATE unparks it, clearing
    ///         only its flag (it is on no list); the counted parks are unaffected by it and wake by the sweep.
    function test_R_COUNTERS__anOverflowedParkUnparksThroughItsOwnState() public {
        hubInDebt[CB] = false;
        _on(CB);
        vm.prank(p17b.owner());
        p17b.flush(); // its STATE probes (CB, 1): the Applied is a callback result after its park
        _elapse(301);
        (uint8 f0, uint32 pl0) = _b6Flags(p17a, CB);
        assertTrue(pl0 != 0 && f0 & 8 != 0, "not yet: an overflowed park is on no walked list (the sweep cannot wake it)");
        _on(CB);
        vm.prank(p17b.owner());
        p17b.flush(); // its own STATE after the answer: `_unparkOwn`
        _elapse(30);
        (uint8 f1, uint32 pl1) = _b6Flags(p17a, CB);
        assertEq(pl1, 0, "the overflowed park unparked through its own STATE");
        assertEq(f1 & 8, 0, "its overflow flag cleared");
        _elapse(20 * 113);
        assertEq(_parked(CB, 1), 0, "the 16 counted parks woke by the sweep; no counter underflowed");
        (,, uint256 sw,) = _counters();
        assertEq(sw, 0, "the sweeps ended");
    }

    /// @notice A B6-parked Covenant whose next STATE drops the id (ids → [2]) or sets cap 0 on 11155111: the counters
    ///         stay exact (the park stays counted until it wakes) and nothing leaks or underflows.
    function test_R_COUNTERS__aParkedCovenantDroppingTheIdOrTheCap() public {
        _on(CB);
        Rulebook memory r = _rules(2, 50e18); // pb[0] drops id 1 on 11155111
        vm.prank(pb[0].owner());
        pb[0].setRules(r);
        _on(CB);
        r = _rules(1, 50e18);
        r.maxShareBps = 0; // pb[1]: B6 off (cap 0)
        vm.prank(pb[1].owner());
        pb[1].setRules(r);
        _elapse(30);
        assertEq(_parked(CB, 1), 16, "still counted: the parks wake only by a callback result");
        // the rule changes' STATEs probed (CB, 1) while the Hub was in debt (dropped): that probe holds the PB-7 rate
        // key (R-RESEND, RESEND_BLOCKS = 1,000 Lasna blocks ≈ 1,130 s), so the wake's probe must come after it
        _elapse(1_140);
        _wakeVia(CB, pb[2], false);
        _elapse(20 * 113);
        assertEq(_parked(CB, 1), 0, "every counted park woke, including the two whose rules changed");
        (,, uint256 sw,) = _counters();
        assertEq(sw, 0, "the sweeps ended");
    }

    bool watching;
    mapping(address => uint256) wokeTick;
    mapping(address => uint256) sentTick;
    mapping(uint256 => uint256) sentIn; // first resends per tick
    mapping(uint256 => uint256) wokeIn; // wakes per tick

    function _policy(Req memory q) internal override returns (Act) {
        if (_sel(q.payload) == IReagentHub.rcBudget.selector && q.chainId == CB) {
            bytes memory a = new bytes(q.payload.length - 4);
            for (uint256 i; i < a.length; ++i) {
                a[i] = q.payload[i + 4];
            }
            (, address cv) = abi.decode(a, (address, address));
            if (watching && sentTick[cv] == 0) {
                sentTick[cv] = tickNow();
                ++sentIn[tickNow()];
            }
        }
        return Act.DELIVER;
    }

    /// @notice W = 16 (R-COUNTERS r10 D10-02, r12 D12-01): one result wakes 16 counted parks; each woken Covenant's
    ///         resend leaves within ⌈16 / RECONCILE_PER_TICK⌉ + 2 ticks of its own wake (its back-off was reset).
    function test_R_COUNTERS__sixteenWokenEntriesResendWithinTheirBound() public {
        hubInDebt[CB] = false;
        _on(CB);
        vm.prank(pa[0].owner());
        pb[0].flush();
        _elapse(20); // the probe's Applied lands; the next requests are the wakes' resends
        watching = true;
        cronForwardOverride = 30_000_000; // the wakes are not cut by gas: W reaches 16 (rc-fix r3 C3-05)
        uint256 maxWoke;
        uint256 start = tickNow() + 1;
        for (uint256 t; t < 30; ++t) {
            _toNextTick();
            uint256 now_ = tickNow();
            for (uint256 i; i < 16; ++i) {
                (, uint32 pl) = _b6Flags(pa[i], CB);
                if (pl == 0 && wokeTick[address(pa[i])] == 0) {
                    wokeTick[address(pa[i])] = now_;
                    if (++wokeIn[now_] > maxWoke) maxWoke = wokeIn[now_];
                }
            }
            if (sentIn[now_] != 0 || wokeIn[now_] != 0) {
                console2.log("tick", now_, "woke", wokeIn[now_]);
                console2.log("  first resends", sentIn[now_]);
            }
        }
        cronForwardOverride = 0;
        // W: the woken entries owed a resend at a tick = woken before it and unsent + woken in it
        uint256 maxW;
        uint256 woke;
        uint256 sent;
        for (uint256 tk = start; tk <= tickNow(); ++tk) {
            woke += wokeIn[tk];
            if (woke - sent > maxW) maxW = woke - sent;
            assertLe(sentIn[tk], 8, "at most RECONCILE_PER_TICK resends per tick: the entries spread");
            sent += sentIn[tk];
        }
        console2.log("max W", maxW, "max woken in a tick", maxWoke);
        assertEq(maxW, 16, "non-vacuous: W = 16 woken entries owed at once");
        for (uint256 i; i < 16; ++i) {
            uint256 w = wokeTick[address(pa[i])];
            assertGt(w, 0, "woken");
            assertGt(sentTick[address(pa[i])], 0, "resent after its wake");
            assertLe(sentTick[address(pa[i])], w + 2 + 2, "within ceil(16/8) + 2 ticks of its wake");
        }
    }
}
