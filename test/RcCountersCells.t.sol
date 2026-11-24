// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ExitFixture} from "./base/ExitFixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice The named R-COUNTERS cells (spec §9.2; F-012): after each step, every counter equals its recount from RC
///         storage (`pendingPairs`, `parkedCount`, `b6ParkedCount`, `b6Active` = the work list, `lowersCount`), and
///         a quiescent end leaves Cron off. Base: alice's Covenant on both chains (id 1) holding SH of X_A.
contract RcCountersCellsTest is ExitFixture {
    uint256 constant T_BUDGET_ = 0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823;
    uint8 exitNoteMode; // 0 deliver; 1 hold alice's EXIT notes; 2 duplicate them
    bool dupBudgetApplied;

    function setUp() public {
        _exitBase();
    }

    function _logPolicy(LogRecord memory l) internal view override returns (Act) {
        if (dupBudgetApplied && l.topic0 == T_BUDGET_) return Act.DUP;
        if (exitNoteMode != 0 && l.topic0 == T_NOTE && l.topic3 == 2 && address(uint160(l.topic2)) == address(ca)) {
            return exitNoteMode == 1 ? Act.HOLD : Act.DUP;
        }
        return Act.DELIVER;
    }

    // ------------------------------------------------------------------ the recount

    /// @dev Every counter against its recount over the given Covenants (both chains), ids and vaults.
    function _recount(address[] memory covs, uint32[] memory ids, address[] memory vA, address[] memory vB) internal {
        uint256 p = _lasna();
        (uint256 pp, uint256 work,,) = rc.counters();
        // the work list and its listed bits (b6Active = the work list's length: one counter, one writer)
        for (uint256 i; i < work; ++i) {
            (uint256 c, address cv) = rc.workAt(i);
            (,,,, bool wl,) = rc.covOf(c, cv);
            assertTrue(wl, "R-COUNTERS: a work-list element has its listed bit");
        }
        uint256 listed;
        for (uint256 j; j < covs.length; ++j) {
            for (uint256 ci; ci < 2; ++ci) {
                (,,,, bool wl,) = rc.covOf(ci == 0 ? CA : CB, covs[j]);
                if (wl) ++listed;
            }
        }
        assertEq(listed, work, "R-COUNTERS: b6Active equals the listed entries");
        // the lowers list's length
        (address h,, uint256 n) = rc.lowersOf();
        uint256 walk;
        while (h != address(0) && walk <= n) {
            (address nx,,) = rc.lowersNext(h);
            h = nx;
            ++walk;
        }
        assertEq(walk, n, "R-COUNTERS: lowersCount equals the list's length");
        // B6 parks per (chain, id): counted = parked and not overflowed
        for (uint256 k; k < ids.length; ++k) {
            for (uint256 ci; ci < 2; ++ci) {
                uint256 c = ci == 0 ? CA : CB;
                uint256 counted;
                for (uint256 j; j < covs.length; ++j) {
                    (,,,,, uint8 f, uint32 pl) = rc.b6Of(covs[j], ids[k], c);
                    if (pl != 0 && f & 8 == 0) ++counted;
                }
                (, uint16 bpc) = rc.parkedOf(c, ids[k]);
                assertEq(bpc, counted, "R-COUNTERS: b6ParkedCount equals the counted B6 parks");
            }
        }
        // pairs: pending bits and parks (the vaults all of id 1 here)
        uint256 pending;
        uint256[2] memory parked;
        for (uint256 j; j < covs.length; ++j) {
            for (uint256 v; v < vA.length; ++v) {
                (,, uint32 pl, bool pd,,) = rc.pairOf(CA, covs[j], vA[v]);
                if (pd) ++pending;
                if (pl != 0) ++parked[0];
            }
            for (uint256 v; v < vB.length; ++v) {
                (,, uint32 pl, bool pd,,) = rc.pairOf(CB, covs[j], vB[v]);
                if (pd) ++pending;
                if (pl != 0) ++parked[1];
            }
        }
        assertEq(pp, pending, "R-COUNTERS: pendingPairs equals the pending bits");
        (uint16 pcA,) = rc.parkedOf(CA, 1);
        (uint16 pcB,) = rc.parkedOf(CB, 1);
        assertEq(pcA, parked[0], "R-COUNTERS: parkedCount (1301) equals the parked pairs");
        assertEq(pcB, parked[1], "R-COUNTERS: parkedCount (11155111) equals the parked pairs");
        _leave(p);
    }

    function _check() internal {
        address[] memory covs = new address[](1);
        covs[0] = address(ca);
        uint32[] memory ids = new uint32[](1);
        ids[0] = 1;
        address[] memory vA = new address[](1);
        vA[0] = xa.vault;
        address[] memory vB = new address[](1);
        vB[0] = xb.vault;
        _recount(covs, ids, vA, vB);
    }

    function _quiet() internal {
        (uint256 pp, uint256 work, uint256 sw, bool on) = _counters();
        assertEq(pp + work + sw, 0, "quiescent: nothing pending, listed or swept");
        assertFalse(on, "quiescent: Cron off");
    }

    function _pairParked() internal returns (bool) {
        (,, uint32 pl,,,) = _pair(CA, address(ca), xa.vault);
        return pl != 0;
    }

    /// @dev X_A breaches with 1301's Hub in debt: the exit is never delivered; the pair parks after 6 · EPOCH_TICKS.
    function _parkTheExit() internal {
        hubInDebt[CA] = true;
        _breach(xa, CA);
        _on(CA);
        _keepAlive(xa, 3_600 + 250 * 113);
        assertTrue(_pairParked(), "the pair parked (non-vacuous)");
        _check();
    }

    // ------------------------------------------------------------------ cells

    /// @notice A parked pair dropped by a STATE (alice leaves X_A while the pair is parked): the pair stops being
    ///         parked and pending at once; every counter matches; Cron goes off.
    function test_R_COUNTERS__aParkedPairDroppedByAState() public {
        _parkTheExit();
        _on(CA);
        _keepAlive(xa, 2);
        vm.prank(alice);
        ca.leave(xa.vault, type(uint256).max, 0, 0);
        _elapse(60);
        assertFalse(_pairParked(), "the dropped holding's pair is not parked");
        _check();
        _elapse(10 * 113);
        _check();
        _quiet();
    }

    /// @notice A parked pair answered DONE, and the DONE duplicated: the exit was delivered but its EXIT note is held
    ///         past the park; released twice, it drops the holding once and decrements the park once.
    function test_R_COUNTERS__aParkedPairAnsweredDoneThenADuplicatedDone() public {
        exitNoteMode = 1; // the exit runs at the Hub; its DONE note is held
        _breach(xa, CA);
        _on(CA);
        _keepAlive(xa, 3_600 + 250 * 113);
        assertEq(ca.ledger(xa.vault), 0, "the exit ran at the destination");
        assertTrue(_pairParked(), "the pair parked while its answer was held (non-vacuous)");
        _check();
        exitNoteMode = 2; // released and duplicated
        // the held notes are re-delivered through the inbox, each duplicated by the policy at release
        _releaseHeldLogs();
        _elapse(60);
        exitNoteMode = 0;
        assertFalse(_pairParked(), "DONE dropped the holding and its park");
        _check();
        _elapse(10 * 113);
        _check();
        _quiet();
    }

    /// @notice A duplicated `BudgetApplied` (every one, R-BUDGET's sequence): answered once; the counters match and
    ///         the sequence completes as without duplicates (B_A 57, B_B 3), Cron off.
    function test_R_COUNTERS__aDuplicatedBudgetAppliedIsAnsweredOnce() public {
        dupBudgetApplied = true;
        _elapse(301); // past NOTE_INTERVAL: the allocation's STATE is emitted, not coalesced
        _on(CA);
        _keepAlive(xa, 2);
        _allocOn(CA, ca, xa.vault, SH * 135); // E_A ≈ 27 of 30: A short (headroom < MIN_MOVE)
        _elapse(600);
        _check();
        _elapse(20 * 113);
        _check();
        uint256 p = _lasna();
        (uint96 abA,,,,, uint8 fA,) = rc.b6Of(address(ca), 1, CA);
        (uint96 abB,,,,, uint8 fB,) = rc.b6Of(address(ca), 1, CB);
        _leave(p);
        assertEq(fA & 1, 0, "no unanswered message on 1301");
        assertEq(fB & 1, 0, "no unanswered message on 11155111");
        assertGt(abA, 30e18, "A was raised (non-vacuous)");
        assertLt(abB, 30e18, "B was lowered (non-vacuous)");
        _quiet();
    }
}
