// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {
    RcGasCronCapsTest,
    RcGasCronCapsNoStaleTest,
    RcGasCapsLowersFirstTest,
    RcGasCronCapsLastOnlyTest,
    RcGasCapsBase,
    RcGasCapsCursorFirstTest,
    RcGasCronCapsColdCursor4HoldTest
} from "./RcGasCaps.t.sol";
import {RcExtGasProbe, RcB6BurnProbe} from "./base/RcProbe.sol";
import {B6Fixture} from "./base/B6Fixture.sol";
import {ICovenant, IReagentHub} from "../src/interfaces/IReagent.sol";

/// @notice R-GAS guard cells (spec §5.5 "Deferred work" v1.3, §9.2; F-012): a head owing 8 lowers (4 shared ids × 2
///         chains, built guard-cut), served by its own STATE — the body's first reaction (cold).
contract RcGasGuardHeadTest is RcGasCronCapsNoStaleTest {
    uint256 internal constant T_NOTE_ = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    bytes32 internal constant T_ITEM_ = keccak256("ProbeItem(uint8,bytes4,uint256,uint256,bool)");

    function _listed(address cov) internal returns (bool l) {
        uint256 p = _lasna();
        (,, l) = rc.lowersNext(cov);
        _leave(p);
    }

    function _flushHead() internal {
        _elapse(301); // past NOTE_INTERVAL (Cron withheld: nothing reacts meanwhile)
        _on(CA);
        vm.prank(head.owner());
        head.flush();
        _elapse(2);
    }

    /// @notice MU-269: a non-Cron reaction sends 4 of the head's 8 owed lowers (SENDS_PER_REACTION): the head still owes,
    ///         so it stays on the lowers list (moved to the tail): "owed and unsent ⇒ listed" (R-COUNTERS).
    function test_R_COUNTERS__aHeadThatStillOwesAfterItsSendsStaysListed() public {
        uint256 b0 = budgetReqs[address(head)];
        _flushHead();
        assertEq(budgetReqs[address(head)] - b0, 4, "4 lowers sent (SENDS_PER_REACTION)");
        assertTrue(_listed(address(head)), "the head still owes 4: it stays listed");
    }

    /// @dev The first optional B6 step of the next reaction: its gasleft at `_b6Opt` and whether it ran.
    function _firstB6(uint256 log0) internal view returns (uint256 gasAt, uint256 used, bool ok) {
        for (uint256 i = log0; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter != address(rc) || lasnaLogs[i].topics[0] != T_ITEM_) continue;
            if (uint8(uint256(lasnaLogs[i].topics[1])) != 2) continue;
            (, uint256 g, uint256 u, bool o) = abi.decode(lasnaLogs[i].data, (bytes4, uint256, uint256, bool));
            return (g, u, o);
        }
        revert("no optional B6 step");
    }

    /// @dev The head's STATE at `forward`, from the snapshot `snap` (cold every time).
    function _at(uint256 snap, uint256 forward) internal returns (uint256 gasAt, uint256 used, bool ok, uint256 sent) {
        vm.revertToState(snap);
        uint256 log0 = lasnaLogs.length;
        uint256 b0 = budgetReqs[address(head)];
        forwardOverride = forward;
        _flushHead();
        forwardOverride = 0;
        (gasAt, used, ok) = _firstB6(log0);
        sent = budgetReqs[address(head)] - b0;
    }

    /// @notice The guard's flip point (spec §6, s3 rc r5 D5-08; v1.3 two frames): with gasleft at the first optional
    ///         B6 step = GAS_GUARD + ε, the step runs AND its first lower is sent (the inner frame admits the visit,
    ///         V1-04/V2-02); at GAS_GUARD − ε it does not start (deferred, the entry listed).
    function test_R_GAS__theGuardFlipPointServesAtGPlusAndDefersAtGMinus() public {
        uint256 g = RcExtGasProbe(rc.EXT()).guard();
        uint256 snap = vm.snapshotState();
        (uint256 at1,,,) = _at(snap, 3_000_000);
        // gasAt grows by 63/64 per unit of forward (the RC → RcExt delegatecall keeps 1/64)
        uint256 fPlus = 3_000_000 - ((at1 - (g + 300)) * 64) / 63;
        uint256 fMinus = 3_000_000 - ((at1 - (g - 300)) * 64) / 63;
        (uint256 aP, uint256 uP, bool okP, uint256 sP) = _at(snap, fPlus);
        console2.log("flip +: gasAt", aP, "used", uP);
        console2.log("flip +: sent", sP, "forward", fPlus);
        assertGe(aP, g, "non-vacuous: at or above the guard");
        assertLt(aP, g + 2_000, "non-vacuous: within epsilon");
        assertTrue(okP, "G + eps: the step runs");
        assertGt(sP, 0, "G + eps: the visit is admitted inside and sends (two frames)");
        (uint256 aM, uint256 uM,, uint256 sM) = _at(snap, fMinus);
        console2.log("flip -: gasAt", aM, "used", uM);
        assertLt(aM, g, "non-vacuous: below the guard");
        assertGt(aM + 2_000, g, "non-vacuous: within epsilon");
        assertLt(uM, 1_000, "G - eps: the step does not start");
        assertEq(sM, 0, "G - eps: nothing sent (deferred)");
        assertTrue(_listed(address(head)), "G - eps: still listed (owed, deferred)");
    }
}

/// @notice MU-245 (spec §5.5 floor (2), v1.3): at the exact reservation of a lowers-first tick (one 8-id stale head,
///         then a head owing only its last lower), floor (2) pops the stale head AND serves the owing head; with no
///         gas left for (4), nothing else would.
contract RcGasGuardFloor2Test is RcGasCapsLowersFirstTest {
    function test_R_GAS__atTheExactReservationFloorTwoPopsAndServes() public {
        uint256 snap = vm.snapshotState();
        (Terms memory t,) = _tick(3_000_000);
        uint256 lhs = t.overhead + t.floor2 + _guard();
        vm.revertToState(snap);
        uint256 b0 = _budgetSendsTo(address(head));
        (, bool ok) = _tick(lhs);
        console2.log("reduced forward", lhs);
        assertTrue(ok);
        assertGt(_budgetSendsTo(address(head)), b0, "floor (2): the stale head popped and the owing head served");
    }
}

/// @notice V2-07 and MU-262: an optional B6 step forced to run out of gas (it burns everything it was given) never
///         reverts its reaction: the caller kept `TAIL` for its own work (the entry, the Cron subscribe).
contract RcGasGuardTailTest is B6Fixture {
    bytes32 internal constant BURN = keccak256("reagent.rc.probe.burn");

    function setUp() public {
        _b6SetUp();
    }

    function _newB6() internal override returns (address) {
        return address(new RcB6BurnProbe());
    }

    function test_R_GAS__aStepOutOfGasLeavesTheCallerItsTail() public {
        (,,, bool on) = _countersB();
        assertFalse(on, "non-vacuous: Cron off, so the reaction's end subscribes it");
        vm.store(address(rc), BURN, bytes32(uint256(1)));
        uint256 r0 = reactReverts;
        uint256 mark = reactGas.length;
        _elapse(301);
        _on(CA);
        vm.prank(alice);
        ca.flush(); // a STATE: its optional B6 steps (a) and (d) burn out
        _elapse(5);
        assertGt(reactGas.length, mark, "the STATE reacted");
        assertEq(reactReverts, r0, "the reaction never reverts: the step kept the caller's TAIL");
        vm.store(address(rc), BURN, bytes32(0));
        (, uint256 work,,) = _countersB();
        assertGt(work, 0, "the cut step stays owed on the listed entry");
    }

    function _countersB() internal returns (uint256 pp, uint256 work, uint256 sw, bool on) {
        uint256 p = _lasna();
        (pp, work, sw, on) = rc.counters();
        _leave(p);
    }
}

/// @notice MU-274 (spec §6 `GAS_GUARD`): the guard covers the largest item admitted inside an optional B6 step — the
///         owes-only-last lowers visit, measured cold — plus `TAIL` and the call's overhead allowance.
contract RcGasGuardCoverTest is RcGasCronCapsLastOnlyTest {
    function test_R_GAS__theGuardCoversTheLargestMeasuredItem() public {
        (Terms memory t, bool ok) = _tick(3_000_000);
        assertTrue(ok);
        uint256 g = _guard();
        console2.log("largest item (owes-only-last visit)", t.floor2, "guard", g);
        assertGe(g, t.floor2 + 40_000 + 5_000, "GAS_GUARD >= the largest item + TAIL + 5,000");
    }
}

/// @notice V2-07 / C2-03 at the Cron sites: with every optional B6 step burning all it was given, a caps tick in each
///         phase (lowers first: `b6Floor`; dirty first: `b6Wake`) never reverts — the tick kept its TAIL.
contract RcGasGuardCronTailLowersTest is RcGasCapsLowersFirstTest {
    bytes32 internal constant BURN = keccak256("reagent.rc.probe.burn");

    function _newB6() internal override returns (address) {
        return address(new RcB6BurnProbe());
    }

    function test_R_GAS__aBurntCronStepNeverRevertsTheTick() public {
        vm.store(address(rc), BURN, bytes32(uint256(1)));
        (Terms memory t, bool ok) = _tick(0);
        vm.store(address(rc), BURN, bytes32(0));
        assertTrue(ok, "the tick lands although its first B6 step ran out of gas");
        assertFalse(t.floor2ok, "non-vacuous: floor (2)'s step was burnt");
        assertEq(reactReverts, 0);
    }
}

contract RcGasGuardCronTailDirtyTest is RcGasCronCapsTest {
    bytes32 internal constant BURN = keccak256("reagent.rc.probe.burn");

    function _newB6() internal override returns (address) {
        return address(new RcB6BurnProbe());
    }

    function _firstClass() internal pure override returns (uint256) {
        return 2;
    }

    function test_R_GAS__aBurntCronStepNeverRevertsTheTick() public {
        vm.store(address(rc), BURN, bytes32(uint256(1)));
        (, bool ok) = _tick(0);
        vm.store(address(rc), BURN, bytes32(0));
        assertTrue(ok, "the tick lands although its b6Wake ran out of gas");
        (,,, uint32 pl) = _b6(address(parked), 5, CB);
        assertGt(pl, 0, "non-vacuous: the burnt wake left the park parked (it keeps its place)");
        assertEq(reactReverts, 0);
    }
}

/// @notice rc-fix r3 C3-01 (V3-01's standing check): at the EXACT cursor-first reservation `overhead + (k − 1) · eval +
///         GAS_GUARD` (terms from the live tick), floor (1) still serves its k evaluations AND each one's resend:
///         an evaluation is admitted once by its caller's guard (PC MU-282: the resend re-gated → k − 1 resends).
contract RcGasGuardCursorResendTest is RcGasCapsCursorFirstTest {
    function test_R_GAS__atTheExactCursorReservationEveryEvaluationResends() public {
        uint256 snap = vm.snapshotState();
        (Terms memory t,) = _tick(0);
        uint256 lhs = _lhs(t);
        vm.revertToState(snap);
        uint256 c0 = conductReqs;
        (Terms memory u, bool ok) = _tick(lhs);
        console2.log("exact cursor reservation", lhs, "evals", u.evals1);
        assertTrue(ok);
        assertEq(u.evals1, _cursorFloor(), "k evaluations at the exact reservation");
        assertGe(conductReqs - c0, _cursorFloor(), "and k resends (no second gate inside an evaluation)");
    }
}

/// @notice C3-01 for exits (PC MU-281: the exit re-gated at GAS_GUARD → k − 1 exits).
contract RcGasGuardCursorExitTest is RcGasCronCapsColdCursor4HoldTest {
    function test_R_GAS__atTheExactCursorReservationEveryEvaluationExits() public {
        uint256 snap = vm.snapshotState();
        (Terms memory t,) = _tick(0);
        uint256 lhs = _lhs(t);
        vm.revertToState(snap);
        uint256 x0 = exitReqs;
        (Terms memory u, bool ok) = _tick(lhs);
        console2.log("exact cursor reservation", lhs, "evals", u.evals1);
        assertTrue(ok);
        assertEq(u.evals1, _cursorFloor(), "k evaluations at the exact reservation");
        assertGe(exitReqs - x0, _cursorFloor(), "and k exits (no second gate inside an evaluation)");
    }
}
