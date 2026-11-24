// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {B6Fixture} from "./base/B6Fixture.sol";

/// @notice B6 reconcile on the R layer (spec §5.5 steps 0–3; §9.2 R-BUDGET).
contract RcB6Test is B6Fixture {
    function setUp() public {
        _b6SetUp();
    }

    function _log(string memory w) internal {
        console2.log(w);
        console2.log("  B_A", _B(CA) / 1e15, "E_A", _E(CA) / 1e15);
        console2.log("  B_B", _B(CB) / 1e15, "E_B", _E(CB) / 1e15);
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            (uint96 ab, uint96 e, uint96 unB, uint32 n, uint32 an, uint8 f, uint32 pl) = rc.b6Of(address(ca), 1, c);
            console2.log("  rc view chain", c);
            console2.log("   appliedB", ab / 1e15, "E", e / 1e15);
            console2.log("   unB", unB / 1e15, "nonce", n);
            console2.log("   appliedNonce", an, "flags", f);
            console2.log("   parkLog", pl);
            (uint128 cap, uint32 rn, uint32 nn, uint32 us, bool wl, uint8 nh) = rc.covOf(c, address(ca));
            console2.log("   cap", cap / 1e15, "rulesNonce", rn);
            console2.log("   noteNonce", nn, "unsettled", us);
            console2.log("   workListed", wl ? 1 : 0, "nHold", nh);
        }
    }

    /// @notice R-BUDGET: chain A runs short; the RC lowers B (rebalance with hysteresis), its `BudgetApplied`
    ///         brings rest, then A is raised by what was freed; it completes with no action of the owner.
    function test_R_BUDGET__lowerThenAnswerThenRaiseCompletesForAnIdleCovenant() public {
        assertEq(_B(CA), 30e18, "the cap/2 default");
        assertEq(_B(CB), 30e18);
        _allocTo(CA, 28e18); // headroom 2 < MIN_MOVE 3: short
        _elapse(600);
        _log("after");
        assertEq(_B(CB), 3e18, "the donor keeps MIN_MOVE of headroom (step 1b)");
        assertEq(_B(CA), 57e18, "A raised to capRC - committed(B) (step 2)");
        assertEq(_budgetSends(CB), 1, "one lower");
        assertEq(_budgetSends(CA), 1, "one raise");
        _assertEleB();
        _assertCapAtRest();
        (uint256 pp, uint256 work, uint256 sw, bool on) = rc.counters();
        assertEq(work, 0, "no work entry left");
        assertEq(pp + sw, 0);
        assertFalse(on, "Cron off");
    }

    function _parked(uint256 c) internal returns (uint32 pl, uint16 count) {
        uint256 p = _lasna();
        (,,,,,, pl) = rc.b6Of(address(ca), 1, c);
        (, count) = rc.parkedOf(c, 1);
        _leave(p);
    }

    /// @notice R-B6SCHED (the park cells, r17 D17-03, r18 D18-01): a lower to a Hub in debt is re-sent under the
    ///         back-off, parks after 6·EPOCH_TICKS (no Cron for it), and wakes on the next callback result from
    ///         that Hub for the id (an `Action` snapshot's `Applied`): the sweep unparks it, it is re-sent and
    ///         answered, and every counter returns to 0.
    function test_R_B6SCHED__parkWhileInDebtThenACallbackResultWakesAndResends() public {
        hubInDebt[CB] = true;
        _allocTo(CA, 28e18);
        _elapse(60);
        uint256 sends0 = _budgetSends(CB);
        assertGe(sends0, 1, "the rebalance lower was requested");
        _log("after the first send");
        (uint256 pp0, uint256 w0, uint256 sw0, bool on0) = rc.counters();
        console2.log("counters", pp0, w0, sw0);
        console2.log("cron", on0 ? 1 : 0, "sends B", sends0);
        _elapse(100 * 113); // > 6 · EPOCH_TICKS(11155111) = 90 ticks
        _log("after 100 ticks");
        console2.log("sends B", _budgetSends(CB), "tick", tickNow());
        (uint32 pl, uint16 n) = _parked(CB);
        assertGt(pl, 0, "parked after 6 EPOCH_TICKS without an answer");
        assertEq(n, 1, "counted on b6Parked");
        uint256 sendsParked = _budgetSends(CB);
        assertLe(sendsParked, sends0 + 8, "re-sends bounded by the back-off before the park");
        (,, , bool on) = rc.counters();
        assertFalse(on, "a parked message holds no Cron (A-CRON-PIN class)");
        _elapse(50 * 113);
        assertEq(_budgetSends(CB), sendsParked, "nothing sent while parked");
        // the refund, then the owner's flush on chain B (spec §12 runbook): its STATE triggers the bounded probe
        // rcConduct, whose Applied (a callback result) marks the id dirty; the sweep's b6Parked item unparks it
        hubInDebt[CB] = false;
        _on(CB);
        vm.prank(alice);
        cb.flush();
        _elapse(40 * 113);
        (pl, n) = _parked(CB);
        assertEq(pl, 0, "unparked by the sweep after the callback result");
        assertEq(n, 0, "b6ParkedCount back to 0");
        assertGt(_budgetSends(CB), sendsParked, "re-sent after the wake");
        assertEq(_B(CB), 3e18, "the lower landed");
        _elapse(60 * 113);
        assertEq(_B(CA), 57e18, "then the raise");
        (uint256 pp, uint256 work, uint256 sw, bool on2) = rc.counters();
        assertEq(work + pp + sw, 0);
        assertFalse(on2);
    }
}
