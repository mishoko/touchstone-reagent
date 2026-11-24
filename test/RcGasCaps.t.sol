// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {RcExtGasProbe} from "./base/RcProbe.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {RcB6} from "../src/RcB6.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice The shared R-GAS state builders (F-012): a probe-built RC, guard-cut construction, and the decoders of the
///         probe's per-item events.
abstract contract RcGasCapsBase is RcFixture {
    bytes32 internal constant SKIP = keccak256("reagent.rc.probe.skip");
    bytes32 internal constant T_ITEM = keccak256("ProbeItem(uint8,bytes4,uint256,uint256,bool)");
    bytes32 internal constant T_PHASE = keccak256("ProbePhase(uint8,uint256)");
    uint256 internal constant T_CRON = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    uint256 internal nOwners;

    function _newExt() internal override returns (address) {
        return address(new RcExtGasProbe(_newB6()));
    }

    function _skip(bool on) internal {
        vm.store(address(rc), SKIP, bytes32(uint256(on ? 1 : 0)));
    }

    function _owner() internal returns (address o) {
        o = makeAddr(string(abi.encode("cap-owner", ++nOwners)));
    }

    function _rules(uint32[4] memory ids, uint128 budget) internal pure returns (Rulebook memory r) {
        r.k = 1;
        r.b3 = true;
        r.b4FloorBps = 5_000;
        r.maxShareBps = 6_000;
        r.budget = budget;
        r.agentCapPerEpoch = budget / 10;
        r.ids = ids;
    }

    /// @notice A Covenant whose B6 view, after both chains' first STATEs under divergent caps (A: budget `bA`, B:
    ///         budget `bB`), owes safety lowers on both chains for each of `ids` (spec §5.5 step 1). With `loosen`,
    ///         B then loosens to `bA` and nothing is owed any more. Built under SKIP (the guard fired before the
    ///         first optional item of each STATE), so the owed lowers are listed and unsent: an owing head, or a
    ///         stale lowers-list element once loosened (spec §5.5, s3 rc r8 D8-04).
    function _b6Covenant(uint32[4] memory ids, uint128 bA, uint128 bB, bool loosen) internal returns (ICovenant a) {
        return _b6Covenant2(ids, ids, bA, bB, loosen);
    }

    /// @dev The same with chain B listing `idsB` (8 distinct ids when disjoint: an id listed on one chain only is
    ///      owed a lower there against the other chain's default cap/2, spec §5.5 step 0).
    function _b6Covenant2(uint32[4] memory idsA, uint32[4] memory idsB, uint128 bA, uint128 bB, bool loosen)
        internal
        returns (ICovenant a)
    {
        address o = _owner();
        ICovenant b;
        (a, b) = _covenantBoth(o, admin);
        _setRulesOn(CA, a, _rules(idsA, bA));
        _elapse(5);
        _setRulesOn(CB, b, _rules(idsB, bB));
        _elapse(20);
        if (loosen) {
            _setRulesOn(CB, b, _rules(idsB, bA));
            _elapse(20);
        }
    }

    // ------------------------------------------------------------------ probe decoding

    struct Item {
        uint8 kind; // 1 a pair evaluation, 2 an optional B6 step
        bytes4 sel; // kind 1: 1 = it sent an exit; kind 2: the RcB6 selector
        uint256 gasAt;
        uint256 used;
        bool ok;
    }

    function _items(uint256 from) internal view returns (Item[] memory out) {
        uint256 n;
        for (uint256 i = from; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter == address(rc) && lasnaLogs[i].topics[0] == T_ITEM) ++n;
        }
        out = new Item[](n);
        n = 0;
        for (uint256 i = from; i < lasnaLogs.length; ++i) {
            Vm.Log memory l = lasnaLogs[i];
            if (l.emitter != address(rc) || l.topics[0] != T_ITEM) continue;
            (bytes4 s, uint256 g, uint256 u, bool ok) = abi.decode(l.data, (bytes4, uint256, uint256, bool));
            out[n++] = Item(uint8(uint256(l.topics[1])), s, g, u, ok);
        }
    }

    /// @dev The log index just past the Cron tick that starts at `from`: its last mark is the second cursor end.
    function _tickEnd(uint256 from) internal view returns (uint256) {
        uint256 seen;
        for (uint256 i = from; i < lasnaLogs.length; ++i) {
            Vm.Log memory l = lasnaLogs[i];
            if (l.emitter == address(rc) && l.topics[0] == T_PHASE && uint8(uint256(l.topics[1])) == 2 && ++seen == 2) return i + 1;
        }
        revert("R-GAS: the tick's end mark");
    }

    function _itemsBetween(uint256 from, uint256 to) internal view returns (Item[] memory out) {
        Item[] memory all = _items(from);
        uint256 n;
        for (uint256 i = from; i < to; ++i) {
            if (lasnaLogs[i].emitter == address(rc) && lasnaLogs[i].topics[0] == T_ITEM) ++n;
        }
        out = new Item[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = all[i];
        }
    }

    /// @dev The gasleft at the n-th (0-based) occurrence of a phase mark since `from`.
    function _phase(uint256 from, uint8 phase, uint256 nth) internal view returns (uint256) {
        for (uint256 i = from; i < lasnaLogs.length; ++i) {
            Vm.Log memory l = lasnaLogs[i];
            if (l.emitter != address(rc) || l.topics[0] != T_PHASE || uint8(uint256(l.topics[1])) != phase) continue;
            if (nth == 0) return abi.decode(l.data, (uint256));
            --nth;
        }
        revert("R-GAS: phase mark not found");
    }

    function _lowersHead() internal returns (address h, uint256 n) {
        uint256 p = _lasna();
        (h,, n) = rc.lowersOf();
        _leave(p);
    }

    function _b6(address cov, uint32 id, uint256 c) internal returns (uint96 ab, uint96 unB, uint8 f, uint32 pl) {
        uint256 p = _lasna();
        (ab,, unB,,, f, pl) = rc.b6Of(cov, id, c);
        _leave(p);
    }
}

/// @notice R-GAS (spec §9.2; F-012): a Cron tick at the caps of §5.5 "Deferred work" and the reservation inequality.
///         The tick is the test body's FIRST reaction (cold, F-011), at the live Cron forward, with:
///         - (1) the cursor holding 24 pairs, the first 8 armable and past their drip end (8 due exits);
///         - (2) `STALE_POPS` stale lowers-list heads, then a head owing 8 lowers (4 ids × 2 chains), then 4 more
///           stale heads;
///         - (3) one dirty item: a B6-parked element woken by a callback result (`b6Wake`, its id with no pairs);
///         - work entries behind them.
///         The state is built with Cron withheld (a Lasna backlog) so that no earlier tick consumes it.
contract RcGasCronCapsTest is RcGasCapsBase {
    V e1;
    V e2;
    ICovenant[24] ex;
    ICovenant head;
    ICovenant[8] stale;
    ICovenant parked;
    uint256 stalePops;

    /// @dev The lowers-list Covenants' ids on each chain, and the parked Covenant's ids (both chains).
    function _idsA() internal pure virtual returns (uint32[4] memory) {
        return [uint32(1), 2, 3, 4];
    }

    function _idsB() internal pure virtual returns (uint32[4] memory) {
        return [uint32(1), 2, 3, 4];
    }

    function _idsParked() internal pure virtual returns (uint32[4] memory) {
        return [uint32(5), 0, 0, 0];
    }

    /// @dev Stale heads ahead of the owing head (STALE_POPS in the full cell; 0 isolates "one lower").
    function _staleAhead() internal pure virtual returns (uint256) {
        return 4;
    }

    /// @dev The cursor's pairs: curator 9's two 1301 vaults first in the vault list, 16 and 8 Covenants on them.
    function _buildExits() internal virtual {
        e1 = _registeredVault(CA, 9);
        e2 = _registeredVault(CA, 9);
        _on(CA);
        _age(e1, 400);
        _on(CA);
        _age(e2, 400);
        for (uint256 i; i < 24; ++i) {
            address o = _owner();
            (ex[i],) = _covenantBoth(o, admin);
            _setRulesOn(CA, ex[i], _rules([uint32(9), 0, 0, 0], 100e18));
            V memory v = i < 16 ? e1 : e2;
            _on(CA);
            _keepAlive(v, 2);
            _allocOn(CA, ex[i], v.vault, SH / 100);
        }
    }

    function _breachExits() internal virtual {
        _on(CA);
        _latch(e1, 1);
        _process(e1);
        _backInRange(e1);
        _on(CA);
        _latch(e2, 1);
        _process(e2);
        _backInRange(e2);
    }

    /// @dev The owing head (built under SKIP: its lowers owed and unsent).
    function _buildHead() internal virtual returns (ICovenant) {
        return _b6Covenant2(_idsA(), _idsB(), 100e18, 50e18, false);
    }

    function setUp() public virtual {
        stalePops = _staleAhead();
        _setUpRc();
        cronWithheld = true;
        _buildExits();
        _elapse(30);
        // (3) the B6-parked element (id 5, no vaults): its lower to 11155111 is never answered (Hub in debt), parks
        // after 6 · EPOCH_TICKS, then a probe's Applied after the refund marks id 5 dirty (spec §5.5 step 3)
        hubInDebt[CB] = true;
        parked = _b6Covenant(_idsParked(), 100e18, 50e18, false);
        _elapse(100 * 113);
        _on(CA);
        vm.prank(parked.owner());
        parked.flush(); // the reconcile that parks it
        _elapse(30);
        (,,, uint32 pl) = _b6(address(parked), 5, CB);
        require(pl != 0, "setUp: the B6 park");
        hubInDebt[CB] = false;
        _elapse(301);
        _on(CA);
        vm.prank(parked.owner());
        parked.flush(); // the probe to 11155111; its Applied marks id 5 dirty
        _elapse(30);
        // the exits: their vaults breach, then the drip passes with Cron withheld (nothing evaluates the pairs)
        _breachExits();
        _elapse(40 * 113);
        // (2) the lowers list: [S1..S4, H, S5..S8], all built with the guard firing before any optional item
        _skip(true);
        for (uint256 i; i < stalePops; ++i) {
            stale[i] = _b6Covenant2(_idsA(), _idsB(), 100e18, 50e18, true);
        }
        head = _buildHead();
        for (uint256 i = stalePops; i < stalePops + 4; ++i) {
            stale[i] = _b6Covenant2(_idsA(), _idsB(), 100e18, 50e18, true);
        }
        _skip(false);
        _elapse(30);
        (address h, uint256 n) = _lowersHead();
        require(h == (stalePops > 0 ? address(stale[0]) : address(head)) && n == stalePops + 5, "setUp: the lowers list");
        (,, uint256 sw, bool on) = _countersL();
        require(on && sw > 0, "setUp: Cron subscribed, dirty ids pending");
        // the next Cron event's phase puts this cell's class first (v1.3 rotation: (block / 100) mod 3)
        for (uint256 i; i < 3 && ((lastCronBn + 100) / 100) % 3 != _firstClass(); ++i) {
            _elapse(113);
        }
        require(((lastCronBn + 100) / 100) % 3 == _firstClass(), "setUp: the rotation phase");
    }

    /// @dev The class the measured tick serves first: 0 cursor, 1 lowers, 2 dirty (spec §5.5, v1.3).
    function _firstClass() internal pure virtual returns (uint256) {
        return 0;
    }

    function _countersL() internal returns (uint256 pp, uint256 work, uint256 sw, bool on) {
        uint256 p = _lasna();
        (pp, work, sw, on) = rc.counters();
        _leave(p);
    }

    struct Terms {
        uint256 forward;
        uint256 used;
        uint256 overhead; // dispatch and the delegatecall's 1/64 before the first floor, plus the gaps between floors
        uint256 worst1; // floor (1): CURSOR_FLOOR cursor evaluations (with their exits or resends) and walk steps
        uint256 evals1; // the evaluations floor (1) ran
        uint256 maxEval1; // the dearest of them, with its share of the walk
        uint256 floor2; // floor (2): ≤ STALE_POPS pops and one visit (a single pass each)
        bool floor2ok;
        uint256 item3; // floor (3): one sweep step
        uint256 started; // the class whose floor started first (the highest gasleft): 0 cursor, 1 lowers, 2 dirty
        uint256 drops; // vaults without Covenants the cursor dropped in the tick (each one counted step, V4-01)
        uint256 maxItem;
        bytes4 maxSel;
    }

    /// @dev The reservation's margin rule (spec §5.5): while the Cron forward is the modelled one (until L-GAS pins
    ///      it), the exact reservation must hold with ≥ 10% of the forward to spare.
    uint256 internal constant MARGIN_BPS = 1_000;

    function _cursorFloor() internal view returns (uint256) {
        return RcExtGasProbe(rc.EXT()).cursorFloor();
    }

    /// @dev Runs the next Cron tick as the body's first reaction and splits its gas into the reservation's terms. The
    ///      floors are found by their first occurrence (floor (1) is the first cursor call, (2) the only `b6Floor`,
    ///      (3) the first sweep call: the bulk always follows the three floors), so the split holds in every phase.
    function _nCursorVaults() internal returns (uint256 n) {
        uint256 p = _lasna();
        n = uint256(vm.load(address(rc), bytes32(uint256(24)))); // `_nVaults` (see `_cursorTo`)
        _leave(p);
    }

    uint256 internal nvBefore; // `_nVaults` before the measured tick (a storage slot: `_tick` is at the stack limit)

    function _tick(uint256 forward) internal returns (Terms memory t, bool ok) {
        nvBefore = _nCursorVaults();
        uint256 mark0 = reactGas.length;
        uint256 log0 = lasnaLogs.length;
        forwardOverride = forward;
        cronWithheld = false;
        _elapse(113);
        forwardOverride = 0;
        GasRow memory row = _firstReactionSince(mark0, T_CRON, 0);
        ok = row.ok;
        t.forward = row.forward;
        t.used = row.used;
        uint256 c0 = _phase(log0, 1, 0);
        uint256 c1 = _phase(log0, 2, 0);
        uint256 s0 = _phase(log0, 3, 0);
        uint256 s1 = _phase(log0, 4, 0);
        t.worst1 = c0 - c1;
        t.item3 = s0 - s1;
        Item[] memory it = _itemsBetween(log0, _tickEnd(log0));
        uint256 f2at;
        uint256 f2end;
        uint256 sumEval;
        for (uint256 j; j < it.length; ++j) {
            if (it[j].used > t.maxItem) (t.maxItem, t.maxSel) = (it[j].used, it[j].sel);
            if (it[j].kind == 1 && it[j].gasAt <= c0 && it[j].gasAt > c1) {
                ++t.evals1;
                sumEval += it[j].used;
                if (it[j].used > t.maxEval1) t.maxEval1 = it[j].used;
            }
            if (it[j].sel == RcB6.b6Floor.selector && f2at == 0) {
                (f2at, t.floor2, t.floor2ok) = (it[j].gasAt, it[j].used, it[j].ok);
                f2end = f2at - it[j].used;
            }
        }
        require(f2at != 0, "R-GAS: floor (2) ran");
        t.drops = nvBefore - _nCursorVaults(); // each drop is a counted step of floor (1) (V4-01)
        if (t.evals1 != 0) t.maxEval1 += (t.worst1 - sumEval) / (t.evals1 + t.drops); // its share of the walk
        uint256 first = c0 > f2at ? c0 : f2at;
        if (s0 > first) first = s0;
        t.started = first == c0 ? 0 : first == f2at ? 1 : 2;
        uint256 last = c1 < f2end ? c1 : f2end;
        if (s1 < last) last = s1;
        t.overhead = (row.forward - first) + ((first - last) - (t.worst1 + t.floor2 + t.item3));
        cronWithheld = true;
    }

    /// @dev The exact reservation for this cell's first class (spec §5.5: `(k − 1) · item + GAS_GUARD`); floor (2)'s
    ///      pops and visit are not split inside one step, so its term is the whole floor (conservative); floor (3)'s
    ///      item is read (`_itemAt`) between the loop guard and the step's own guard, so its term is the whole floor
    ///      too (v13 r4 V4-03: a term 0 left the wake unadmitted just above `overhead + GAS_GUARD`).
    function _lhs(Terms memory t) internal view returns (uint256) {
        uint256 cls = _firstClass();
        uint256 term = cls == 0 ? (_cursorFloor() - 1) * t.maxEval1 : cls == 1 ? t.floor2 : t.item3;
        return t.overhead + term + _guard();
    }

    function _guard() internal view returns (uint256) {
        return RcExtGasProbe(rc.EXT()).guard();
    }

    /// @dev Positions the cursor at `vault` (a shape's positioning, like the counters' mid-lap stop): the RC's cursor
    ///      storage (`_vaultList` 23, `_nVaults` 24, `_cursorV` 25, `_cursorC` 26; `forge inspect ReagentRC
    ///      storageLayout`). The lookup checks the layout: no entry matching the vault → the cell fails.
    function _cursorTo(uint256 c, address vault) internal {
        uint256 p = _lasna();
        uint256 n = uint256(vm.load(address(rc), bytes32(uint256(24))));
        uint256 want = (c << 160) | uint160(vault);
        uint256 at = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            if (uint256(vm.load(address(rc), keccak256(abi.encode(i, uint256(23))))) == want) at = i;
        }
        require(at != type(uint256).max, "cursorTo: the vault is not in the cursor list (layout moved?)");
        require(uint256(vm.load(address(rc), bytes32(uint256(25)))) < n, "cursorTo: slot 25 is not the cursor index");
        vm.store(address(rc), bytes32(uint256(25)), bytes32(at));
        vm.store(address(rc), bytes32(uint256(26)), bytes32(0));
        _leave(p);
    }

    /// @notice R-GAS (v1.3): the caps tick, cold, at the live Cron forward, its class first: no revert, the first floor
    ///         served in full, the reservation's terms and margin printed for `audits/rc-gas.json`.
    function test_R_GAS__theFirstFloorIsServedInFullAtTheLiveForward() public {
        uint256 b0 = _budgetSendsTo(address(head));
        (Terms memory t, bool ok) = _tick(0);
        uint256 lhs = _lhs(t);
        console2.log("LIVE class", t.started, "forward", t.forward);
        console2.log("LIVE overhead", t.overhead, "worst(1)", t.worst1);
        console2.log("LIVE maxEval1", t.maxEval1, "evals1", t.evals1);
        console2.log("LIVE floor(2)", t.floor2, "item(3)", t.item3);
        console2.log("LIVE lhs", lhs, "guard", _guard());
        if (lhs <= t.forward) console2.log("LIVE margin", t.forward - lhs);
        else console2.log("LIVE DEFICIT", lhs - t.forward);
        assertTrue(ok, "the tick never reverts at the live forward");
        assertEq(reactReverts, 0);
        uint256 cls = _firstClass();
        assertEq(t.started, cls, "the phase's floor runs first (the rotation, MU-272)");
        if (cls == 0) {
            assertEq(t.evals1 + t.drops, _cursorFloor(), "(1) first: CURSOR_FLOOR steps (evaluations or drops)");
        } else if (cls == 1) {
            assertTrue(t.floor2ok, "(2) first: the step completes");
            if (stalePops <= 1) assertGt(_budgetSendsTo(address(head)), b0, "(2) first: the owing head's lower leaves");
        } else {
            (,,, uint32 pl) = _b6(address(parked), 5, CB);
            assertEq(pl, 0, "(3) first: the woken park is unparked");
        }
        assertLe(lhs, t.forward, "the reservation (exact form) holds at the live Cron forward");
        assertLe(lhs, t.forward * (10_000 - MARGIN_BPS) / 10_000, "the reservation keeps its margin (spec 5.5)");
    }

    /// @notice The terms measured one by one: the same cold tick at an unbounded forward (every guard passes).
    function test_R_GAS__termsOfTheCapsTickAtAnUnboundedForward() public {
        (Terms memory t, bool ok) = _tick(3_000_000);
        assertTrue(ok);
        console2.log("TERMS overhead", t.overhead, "worst(1)", t.worst1);
        console2.log("TERMS maxEval1", t.maxEval1, "evals1", t.evals1);
        console2.log("TERMS floor(2)", t.floor2, "item(3)", t.item3);
        console2.log("TERMS used", t.used, "largest item", t.maxItem);
    }

    mapping(address => uint256) internal budgetReqs; // rcBudget requests per covenant (the RC's address view)

    function _policy(Req memory q) internal override returns (Act) {
        if (_sel(q.payload) == IReagentHub.rcBudget.selector) {
            bytes memory a = new bytes(q.payload.length - 4);
            for (uint256 i; i < a.length; ++i) {
                a[i] = q.payload[i + 4];
            }
            (, address cov) = abi.decode(a, (address, address));
            ++budgetReqs[cov];
        }
        if (_sel(q.payload) == IReagentHub.rcConduct.selector) ++conductReqs;
        if (_sel(q.payload) == IReagentHub.rcExit.selector) ++exitReqs;
        return Act.DELIVER;
    }

    uint256 internal conductReqs; // rcConduct requests (PB-7 resends and probes)
    uint256 internal exitReqs; // rcExit requests
    bytes32 internal constant T_PARKED_ = keccak256("ExitParked(uint256,address,address)");

    /// @dev The measured tick (live forward) parks and resends at least `CURSOR_FLOOR` (4) pairs (non-vacuity of the
    ///      resend-and-park shape, rc-fix r2 C2-02).
    function _assertResendAndPark() internal {
        uint256 c0 = conductReqs;
        uint256 log0 = lasnaLogs.length;
        (, bool ok) = _tick(0);
        assertTrue(ok);
        uint256 parks;
        for (uint256 i = log0; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter == address(rc) && lasnaLogs[i].topics[0] == T_PARKED_) ++parks;
        }
        console2.log("resend-and-park: parks", parks, "conduct sends", conductReqs - c0);
        assertGe(parks, 4, "non-vacuous: the floor's evaluations park");
        assertGe(conductReqs - c0, 4, "non-vacuous: and resend");
    }

    function _budgetSendsTo(address cov) internal view returns (uint256) {
        return budgetReqs[cov];
    }
}

/// @notice The same tick with no stale head ahead: floor (2) is exactly "one lower" (with its list move).
contract RcGasCronCapsNoStaleTest is RcGasCronCapsTest {
    function _staleAhead() internal pure virtual override returns (uint256) {
        return 0;
    }
}

/// @notice The worst items: lowers-list Covenants with 8 distinct ids (4 per chain, disjoint) and a parked Covenant
///         listing 4 ids (its wake scans all of them).
contract RcGasCronCaps8IdsTest is RcGasCronCapsTest {
    function _idsB() internal pure virtual override returns (uint32[4] memory) {
        return [uint32(11), 12, 13, 14];
    }

    function _idsParked() internal pure virtual override returns (uint32[4] memory) {
        return [uint32(5), 6, 7, 8];
    }
}

contract RcGasCronCaps8IdsNoStaleTest is RcGasCronCaps8IdsTest {
    function _staleAhead() internal pure virtual override returns (uint256) {
        return 0;
    }
}

/// @notice V1-02's cursor shape: 8 pairs on 8 different vaults (curator 9: 4 on each chain, one Covenant each), so
///         each of floor (1)'s 8 evaluations is a cold first evaluation of its vault.
contract RcGasCronCapsColdCursorTest is RcGasCronCapsNoStaleTest {
    V[8] ev;

    /// @dev The exit vault's curator: one curator for all 8 (the r1 shape), or 8 curators (V2-01: cold conduct/seq).
    function _exitId(uint256) internal pure virtual returns (uint32) {
        return 9;
    }

    function _buildExits() internal virtual override {
        for (uint256 i; i < 8; ++i) {
            ev[i] = _registeredVault(i < 4 ? CA : CB, _exitId(i));
        }
        for (uint256 i; i < 8; ++i) {
            _on(i < 4 ? CA : CB);
            _age(ev[i], i < 4 ? 400 : 40);
        }
        for (uint256 i; i < 8; ++i) {
            uint256 c = i < 4 ? CA : CB;
            (ICovenant a, ICovenant b) = _covenantBoth(_owner(), admin);
            ICovenant cv = c == CA ? a : b;
            ex[i] = cv;
            _setRulesOn(c, cv, _rules([_exitId(i), 0, 0, 0], 100e18));
            _on(c);
            _keepAlive(ev[i], 2);
            _allocOn(c, cv, ev[i].vault, SH / 100);
        }
    }

    function _breachExits() internal virtual override {
        for (uint256 i; i < 8; ++i) {
            uint256 c = i < 4 ? CA : CB;
            _on(c);
            _latch(ev[i], 1);
            _process(ev[i]);
            _backInRange(ev[i]);
        }
    }
}

/// @notice V1-03's item shape: a head with 8 distinct ids whose first 7 lowers were sent AND applied (so each scan
///         step computes fully and finds nothing owed) and only the last (id 14, 11155111) owed: one full cold scan,
///         then one send, then the unlink (it owes nothing more).
contract RcGasCronCapsLastOnlyTest is RcGasCronCaps8IdsNoStaleTest {
    function _buildHead() internal override returns (ICovenant a) {
        _skip(false);
        a = _b6Covenant2([uint32(1), 2, 3, 4], [uint32(11), 12, 13, 0], 100e18, 50e18, false);
        _elapse(120); // the 7 lowers leave over the answers' reactions (4 per reaction) and are applied
        for (uint256 i; i < 4; ++i) {
            (,, uint8 f,) = _b6(address(a), uint32(i + 1), CA);
            require(f & 1 == 0, "setUp: the A lowers applied");
        }
        _skip(true);
        address o = a.owner();
        _on(CB);
        ICovenant b = ICovenant(toB[address(a)]);
        vm.prank(o);
        b.setRules(_rules([uint32(11), 12, 13, 14], 50e18)); // id 14 added on 11155111: owed, last in the scan
        _elapse(20);
    }
}

/// @notice V2-01 (a): the cold cursor with 8 curators (one vault each): every evaluation's conduct and seq are cold.
contract RcGasCronCapsColdCursor8CuratorsTest is RcGasCronCapsColdCursorTest {
    function _exitId(uint256 i) internal pure override returns (uint32) {
        return uint32(21 + i);
    }
}

/// @notice V2-01 (b): the same with both chains lagging for those ids (their `Applied` lost): each evaluation enters
///         the wait and sends its PB-7 resend (rate-limited per (chain, id), so every one is due) instead of an exit.
contract RcGasCronCapsColdCursorResendTest is RcGasCronCapsColdCursor8CuratorsTest {
    uint256 internal constant T_APPLIED_ = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;

    function _logPolicy(LogRecord memory l) internal view virtual override returns (Act) {
        if (l.topic0 == T_APPLIED_ && l.topic1 >= 21 && l.topic1 <= 28) return Act.DROP;
        return Act.DELIVER;
    }
}

/// @notice rc-fix r2 C2-02 (a): the cursor's first slots are 8 target vaults (curators 21..28, one Covenant each, cold
///         conduct and seq); each Covenant holds 4 vaults and the target LAST, so every evaluation's `_holding` reads
///         4 cold hold slots (the 3 filler vaults are curators 31..33, never breached).
contract RcGasCronCapsColdCursor4HoldTest is RcGasCronCapsColdCursor8CuratorsTest {
    V[3] fill;

    /// @dev The shape starts the floor at the first target (the targets are consecutive in the cursor's list).
    function setUp() public virtual override {
        super.setUp();
        _cursorTo(CA, ev[0].vault);
    }

    function _buildExits() internal virtual override {
        for (uint256 i; i < 8; ++i) {
            ev[i] = _registeredVault(CA, _exitId(i)); // first in the vault list: the cursor's first slots
        }
        for (uint256 j; j < 3; ++j) {
            fill[j] = _registeredVault(CA, uint32(31 + j));
        }
        for (uint256 i; i < 8; ++i) {
            _on(CA);
            _age(ev[i], 400);
        }
        for (uint256 j; j < 3; ++j) {
            _on(CA);
            _age(fill[j], 400);
        }
        for (uint256 i; i < 8; ++i) {
            (ICovenant a,) = _covenantBoth(_owner(), admin);
            ex[i] = a;
            _setRulesOn(CA, a, _rules([uint32(31), 32, 33, _exitId(i)], 100e18));
            for (uint256 j; j < 3; ++j) {
                _on(CA);
                _keepAlive(fill[j], 2);
                _allocOn(CA, a, fill[j].vault, SH / 100);
            }
            _on(CA);
            _keepAlive(ev[i], 2);
            _allocOn(CA, a, ev[i].vault, SH / 100); // the target held last
        }
    }

    function _breachExits() internal virtual override {
        for (uint256 i; i < 8; ++i) {
            _on(CA);
            _latch(ev[i], 1);
            _process(ev[i]);
            _backInRange(ev[i]);
        }
    }

    function test_R_GAS__theCursorsCovenantsHoldFourVaults() public {
        uint256 p = _lasna();
        for (uint256 i; i < 8; ++i) {
            (,,,,, uint8 n) = rc.covOf(CA, address(ex[i]));
            assertEq(n, 4, "non-vacuous: 4 holdings, the target last");
        }
        _leave(p);
    }
}

/// @notice rc-fix r2 C2-02 (b): every cursor evaluation both resends (its chain lagging: `Applied` lost) and parks
///         (its wait began at a STATE more than `6 · EPOCH_TICKS` before the measured tick, Cron withheld meanwhile).
contract RcGasCronCapsColdCursorResendParkTest is RcGasCronCapsColdCursorResendTest {
    function _breachExits() internal virtual override {
        super._breachExits();
        _elapse(40 * 113); // past the drip: the pairs are armable
        for (uint256 i; i < 8; ++i) {
            _on(i < 4 ? CA : CB);
            vm.prank(ex[i].owner());
            ex[i].flush(); // its STATE evaluates the pair: the wait starts (the chain never applies the totals)
        }
        _elapse(200 * 113); // > 6 · EPOCH_TICKS on both chains (1301: 192), and past the PB-7 rate
    }
    function test_R_GAS__eachCursorEvaluationResendsAndParks() public {
        _assertResendAndPark();
    }
}

/// @notice (a) and (b) together: 4 cold holdings, target last, and each evaluation resends and parks.
contract RcGasCronCapsColdCursor4HoldResendParkTest is RcGasCronCapsColdCursor4HoldTest {
    uint256 internal constant T_APPLIED_4 = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;

    function _logPolicy(LogRecord memory l) internal view virtual override returns (Act) {
        if (l.topic0 == T_APPLIED_4 && l.topic1 >= 21 && l.topic1 <= 28) return Act.DROP;
        return Act.DELIVER;
    }

    function _breachExits() internal virtual override {
        super._breachExits();
        _elapse(40 * 113);
        for (uint256 i; i < 8; ++i) {
            _on(CA);
            vm.prank(ex[i].owner());
            ex[i].flush();
        }
        _elapse(200 * 113);
    }
    function test_R_GAS__eachCursorEvaluationResendsAndParks() public {
        _assertResendAndPark();
    }
}

/// @notice (a) with each evaluation entering its wait for the first time and resending (both chains lagging for ids
///         21..28; no earlier STATE): the dearest cursor evaluation found (fresh wait writes + 4 cold holdings).
contract RcGasCronCapsColdCursor4HoldResendTest is RcGasCronCapsColdCursor4HoldTest {
    uint256 internal constant T_APPLIED_5 = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;

    function _logPolicy(LogRecord memory l) internal view virtual override returns (Act) {
        if (l.topic0 == T_APPLIED_5 && l.topic1 >= 21 && l.topic1 <= 28) return Act.DROP;
        return Act.DELIVER;
    }

    function test_R_GAS__eachCursorEvaluationResends() public {
        uint256 c0 = conductReqs;
        (, bool ok) = _tick(0);
        assertTrue(ok);
        assertGe(conductReqs - c0, 4, "non-vacuous: the floor's evaluations resend");
    }
}

/// @notice v13 r4 V4-01: 8 vaults without Covenants registered between consecutive target vaults (curators 41..46, 4
///         vaults each on 1301; registered in their own call frames). An empty vault costs the walk one counted step,
///         once: the cursor drops it (spec §3.5 P). PC (no drop, MU-280): the empty vaults are
///         walked uncounted on every lap and never leave the list.
contract RcGasCronCapsEmptyVaultsTest is RcGasCronCapsColdCursor8CuratorsTest {
    function registerEmptyVault(uint32 id) external {
        require(msg.sender == address(this));
        _registeredVault(CA, id);
    }

    function _buildExits() internal override {
        uint32 e = 41;
        for (uint256 i; i < 8; ++i) {
            ev[i] = _registeredVault(i < 4 ? CA : CB, _exitId(i));
            if (i < 3) {
                for (uint256 j; j < 8; ++j) {
                    this.registerEmptyVault(e + uint32(j / 4)); // its own call frame: setUp's memory stays small
                }
                e += 2;
            }
        }
        for (uint256 i; i < 8; ++i) {
            _on(i < 4 ? CA : CB);
            _age(ev[i], i < 4 ? 400 : 40);
        }
        for (uint256 i; i < 8; ++i) {
            uint256 c = i < 4 ? CA : CB;
            (ICovenant a, ICovenant b) = _covenantBoth(_owner(), admin);
            ICovenant cv = c == CA ? a : b;
            ex[i] = cv;
            _setRulesOn(c, cv, _rules([_exitId(i), 0, 0, 0], 100e18));
            _on(c);
            _keepAlive(ev[i], 2);
            _allocOn(c, cv, ev[i].vault, SH / 100);
        }
    }

    function test_R_GAS__vaultsWithoutCovenantsCostTheCursorOneStepOnce() public {
        uint256 n0 = _nCursorVaults();
        (Terms memory t, bool ok) = _tick(0);
        assertTrue(ok);
        assertEq(t.evals1 + t.drops, _cursorFloor(), "floor (1): k counted steps, an empty vault's drop among them");
        assertGt(t.drops, 0, "non-vacuous: the floor met empty vaults");
        console2.log("empty vaults: worst(1)", t.worst1, "drops", t.drops);
        assertLe(t.worst1, 4 * 120_000, "the floor stays within k dearest steps (no uncounted walk)");
        cronWithheld = false;
        _elapse(30 * 113); // (Cron leaves when its work is done: an empty vault left listed then costs nothing)
        uint256 dropped = n0 - _nCursorVaults();
        console2.log("empty vaults dropped", dropped);
        assertGe(dropped, t.drops, "drops persist");
        assertLe(dropped, 24, "only vaults without Covenants leave the cursor");
        uint256 p = _lasna();
        uint256 n = uint256(vm.load(address(rc), bytes32(uint256(24))));
        for (uint256 i; i < 8; ++i) {
            uint256 want = ((i < 4 ? CA : CB) << 160) | uint160(ev[i].vault);
            bool found;
            for (uint256 j; j < n && !found; ++j) {
                found = uint256(vm.load(address(rc), keccak256(abi.encode(j, uint256(23))))) == want;
            }
            assertTrue(found, "every vault with a Covenant stays listed");
        }
        _leave(p);
    }
}

/// @notice The reservation per rotation phase on each class's worst shape (spec §5.5 v1.3; F-012): cursor first on 8
///         curators, 4 holdings each (target last), each evaluation entering its wait and resending (the dearest
///         measured, rc-fix r2 C2-02); lowers first on one 8-id stale head then an owes-only-last head; dirty first
///         on a 4-id park.
contract RcGasCapsCursorFirstTest is RcGasCronCapsColdCursor4HoldResendTest {}

contract RcGasCapsLowersFirstTest is RcGasCronCapsLastOnlyTest {
    function _staleAhead() internal pure virtual override returns (uint256) {
        return 1;
    }

    function _firstClass() internal pure virtual override returns (uint256) {
        return 1;
    }
}

contract RcGasCapsDirtyFirstTest is RcGasCronCaps8IdsTest {
    function _firstClass() internal pure virtual override returns (uint256) {
        return 2;
    }
}

/// @notice MU-276 (V1-01, V2-06): three Cron events backlogged and reacted at ONE Lasna block still rotate: their first
///         floors are three different classes (the phase is the Cron log's own block, never the reaction's).
contract RcGasCapsBacklogTest is RcGasCronCapsTest {
    function test_R_GAS__aBacklogOfCronEventsStillRotates() public {
        uint256 log0 = lasnaLogs.length;
        cronWithheld = false;
        cronBacklog = true;
        _elapse(3 * 113); // three Cron events queued
        assertEq(cronQueue.length, 3, "non-vacuous: three Cron logs in the backlog");
        _releaseCronBacklog();
        bool[3] memory seen;
        uint256 from = log0;
        for (uint256 k; k < 3; ++k) {
            uint256 end = _tickEnd(from);
            uint256 c0 = _phaseIn(from, end, 1);
            uint256 s0 = _phaseIn(from, end, 3);
            uint256 f2 = _floorIn(from, end);
            uint256 first = c0 > f2 ? c0 : f2;
            if (s0 > first) first = s0;
            seen[first == c0 ? 0 : first == f2 ? 1 : 2] = true;
            from = end;
        }
        assertTrue(seen[0] && seen[1] && seen[2], "each class first once over the three backlogged ticks");
    }

    function _phaseIn(uint256 from, uint256 to, uint8 ph) internal view returns (uint256) {
        for (uint256 i = from; i < to; ++i) {
            Vm.Log memory l = lasnaLogs[i];
            if (l.emitter == address(rc) && l.topics[0] == T_PHASE && uint8(uint256(l.topics[1])) == ph) {
                return abi.decode(l.data, (uint256));
            }
        }
        return 0;
    }

    function _floorIn(uint256 from, uint256 to) internal view returns (uint256) {
        for (uint256 i = from; i < to; ++i) {
            Vm.Log memory l = lasnaLogs[i];
            if (l.emitter != address(rc) || l.topics[0] != T_ITEM) continue;
            (bytes4 s, uint256 g,,) = abi.decode(l.data, (bytes4, uint256, uint256, bool));
            if (s == RcB6.b6Floor.selector) return g;
        }
        return 0;
    }
}

/// @notice R-EXIT-SCHED at the caps, the lap row (spec §3.5, v13 r4 V4-02): two dirty ids (9: 24 pairs and its lap
///         end; 5: its park and its lap end) swept while every Cron tick admits about ONE guarded item (a Cron-only
///         forward of 300k, above every class's first item; warm ticks would otherwise serve more), so each class runs only in the ticks its floor comes
///         first. Both sweeps end within 6 · D ticks; non-vacuous: id 9's 25-step lap took ≥ 25 ticks.
///         PC (MU-272, no rotation): the cursor is always first, the sweeps never end.
contract RcGasChurnLapTest is RcGasCronCapsTest {
    function _on9and5() internal returns (bool on9, bool on5) {
        uint256 p = _lasna();
        (,,, on9) = rc.sweepOf(9);
        (,,, on5) = rc.sweepOf(5);
        _leave(p);
    }

    function test_R_EXIT_SCHED__atTheCapsTwoDirtyIdsEndWithinSixD() public {
        uint256 p = _lasna();
        (, uint16 b5a) = rc.parkedOf(CA, 5);
        (, uint16 b5b) = rc.parkedOf(CB, 5);
        _leave(p);
        uint256 d = (24 + 1) + (uint256(b5a) + b5b + 1);
        (bool a9, bool a5) = _on9and5();
        assertTrue(a9 && a5, "non-vacuous: ids 9 and 5 are being swept");
        uint256 r0 = reactReverts;
        cronForwardOverride = 300_000;
        cronWithheld = false;
        uint256 end9;
        uint256 end5;
        for (uint256 t = 1; t <= 6 * d + 3 && (end9 == 0 || end5 == 0); ++t) {
            _elapse(113);
            (bool on9, bool on5) = _on9and5();
            if (!on9 && end9 == 0) end9 = t;
            if (!on5 && end5 == 0) end5 = t;
        }
        cronForwardOverride = 0;
        console2.log("D", d, "id 9 ended at tick", end9);
        console2.log("id 5 ended at tick", end5);
        assertEq(reactReverts, r0, "no tick reverts at the reduced forward");
        assertTrue(end9 != 0 && end9 <= 6 * d, "id 9's sweep ends within 6 * D ticks");
        assertTrue(end5 != 0 && end5 <= 6 * d, "id 5's sweep ends within 6 * D ticks");
        assertGe(end9, 25, "non-vacuous: one item per tick (a 25-step lap needs >= 25 ticks)");
    }
}
