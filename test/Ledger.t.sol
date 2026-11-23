// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {ICovenant, Rulebook, NoteKind, Outcome, Holding, Base} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {MockRefPool} from "touchstone-test/utils/MockRefPool.sol";

/// @notice A-DONATE's positive control: `leave` without the ledger cap.
contract CovenantNoLeaveCap is Covenant {
    constructor(address e) Covenant(e) {}

    function _leaveCap(uint256, uint256) internal pure override returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice A-NOTE-REVERT's positive control: a rate-limited STATE reverts instead of coalescing.
contract ExtLimitReverts is CovenantExt {
    function _limited(uint40 t) internal override {
        if (t < _lastNote + NOTE_INTERVAL) revert TooSoon();
        super._limited(t);
    }
}

/// @notice A-SWEEP-SHARES's positive control: `sweep` without the ledger bound.
contract ExtSweepAll is CovenantExt {
    function _sweepable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

/// @notice A-PLAN-REPLAY's positive control: the epoch gate removed.
contract CovenantNoPlanGate is Covenant {
    constructor(address e) Covenant(e) {}

    function _planDue(uint32, uint32, uint32) internal pure override returns (bool) {
        return true;
    }
}

/// @notice The ledger, `leave`, notes and plans (spec §3.2, §3.7, §5.2–§5.4; PB-9, PB-10; C-06), on a real Touchstone.
contract LedgerTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23;

    function setUp() public {
        _setUpReagent(1301);
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
        vm.startPrank(alice);
        c.setAgent(agentKey);
        c.setAllowed(X.vault, true);
        vm.stopPrank();
    }

    function _swapIn(address code) internal {
        vm.etch(address(impl), code.code);
    }

    // ================================================================== T-LEDGER, A-DONATE, I-SHARES

    /// @notice T-LEDGER: booked on allocate, `leave` and exit; `leave` uses min(ledger, balanceOf).
    function test_T_LEDGER__bookedOnAllocateLeaveAndMin() public {
        _alloc(c, X.vault, SH);
        assertEq(c.ledger(X.vault), SH);
        assertEq(IERC20(X.vault).balanceOf(address(c)), SH);
        uint128 e = c.exposure(IDX);
        vm.prank(alice);
        c.leave(X.vault, SH / 4, 0, 0);
        assertEq(c.ledger(X.vault), SH - SH / 4);
        assertEq(c.exposure(IDX), e - uint128(uint256(e) * (SH / 4) / SH), "pro rata, rounded down");
        vm.prank(alice);
        c.leave(X.vault, type(uint256).max, 0, 0); // more than booked: capped at the ledger
        assertEq(c.ledger(X.vault), 0);
        assertEq(c.exposure(IDX), 0);
    }

    /// @notice A-DONATE: 1 wei of shares donated, then `leave(all)` still works and books exactly the ledger.
    function test_A_DONATE__aDonationNeverBreaksLeave() public {
        _alloc(c, X.vault, SH);
        _donate(1);
        vm.prank(alice);
        c.leave(X.vault, type(uint256).max, 0, 0);
        assertEq(c.ledger(X.vault), 0);
        assertEq(IERC20(X.vault).balanceOf(address(c)), 1, "the donation stays, unbooked");
    }

    function test_A_DONATE__PC_withoutTheCapLeaveReverts() public {
        _alloc(c, X.vault, SH);
        _donate(1);
        _swapIn(address(new CovenantNoLeaveCap(address(ext))));
        vm.prank(alice);
        vm.expectRevert(); // Touchstone refuses to burn more shares than held
        c.leave(X.vault, type(uint256).max, 0, 0);
    }

    function _donate(uint256 s) internal {
        address d = makeAddr("donor");
        token0.mint(d, 1e30);
        token1.mint(d, 1e30);
        vm.startPrank(d);
        token0.approve(X.vault, type(uint256).max);
        token1.approve(X.vault, type(uint256).max);
        IVaultEntries(X.vault).deposit(1e18, type(uint256).max, type(uint256).max, d);
        IERC20(X.vault).transfer(address(c), s);
        vm.stopPrank();
    }

    // ================================================================== A-SWEEP-SHARES

    /// @notice A-SWEEP-SHARES: booked shares never leave through `sweep`; exactly the donation may.
    function test_A_SWEEP_SHARES__bookedSharesCannotBeSwept() public {
        _alloc(c, X.vault, SH);
        vm.prank(alice);
        vm.expectRevert(CovenantBase.NotAllowed.selector);
        c.sweep(X.vault, SH);
        _donate(7);
        vm.prank(alice);
        vm.expectRevert(CovenantBase.NotAllowed.selector);
        c.sweep(X.vault, 8); // d + 1
        vm.prank(alice);
        c.sweep(X.vault, 7); // exactly the donation
        assertEq(IERC20(X.vault).balanceOf(alice), 7);
        assertEq(c.ledger(X.vault), SH);
        assertEq(IERC20(X.vault).balanceOf(address(c)), SH, "I-SHARES: ledger <= balanceOf");
        // idle tokens go to the owner only
        uint256 b = token1.balanceOf(alice);
        vm.prank(alice);
        c.sweep(address(token1), 5);
        assertEq(token1.balanceOf(alice) - b, 5);
    }

    function test_A_SWEEP_SHARES__PC_withoutTheBoundTheLedgerExceedsTheBalance() public {
        _alloc(c, X.vault, SH);
        _swapIn(address(new Covenant(address(new ExtSweepAll()))));
        vm.prank(alice);
        c.sweep(X.vault, SH);
        assertGt(c.ledger(X.vault), IERC20(X.vault).balanceOf(address(c)), "I-SHARES broken");
    }

    // ================================================================== T-LEAVE-MATRIX, I-LEAVE (C-06)

    /// @notice T-LEAVE-MATRIX: `leave` succeeds whenever Touchstone's `withdraw` would, with equal outputs to a twin
    ///         EOA, across Covenant states {fresh, paused, armed, stale ref, Hub mirror paused} × vault modes
    ///         {NORMAL, BREACHED, EXITED, retired}.
    function test_T_LEAVE_MATRIX__leaveEqualsATwinWithdrawInEveryState() public {
        address twin = makeAddr("twin");
        token0.mint(twin, 1e30);
        token1.mint(twin, 1e30);
        vm.startPrank(twin);
        token0.approve(X.vault, type(uint256).max);
        token1.approve(X.vault, type(uint256).max);
        token0.approve(Y.vault, type(uint256).max);
        token1.approve(Y.vault, type(uint256).max);
        vm.stopPrank();
        uint256 n;
        for (uint256 mode; mode < 4; ++mode) {
            for (uint256 st; st < 4; ++st) {
                uint256 snap = vm.snapshotState();
                V memory v = mode == 3 ? Y : X;
                _alloc(c, v.vault, SH);
                vm.prank(twin);
                IVaultEntries(v.vault).deposit(SH, type(uint256).max, type(uint256).max, twin);
                _toMode(v, mode);
                _toState(v, st);
                (uint256 a0, uint256 a1, uint256 t0, uint256 t1) = _leaveBoth(v, twin);
                assertApproxEqAbs(a0, t0, 1, "out0 equals the twin's");
                assertApproxEqAbs(a1, t1, 1, "out1 equals the twin's");
                assertEq(c.ledger(v.vault), 0);
                ++n;
                vm.revertToState(snap);
            }
        }
        assertEq(n, 16);
    }

    function _leaveBoth(V memory v, address twin) internal returns (uint256 a0, uint256 a1, uint256 t0, uint256 t1) {
        uint256 b0 = token0.balanceOf(alice);
        uint256 b1 = token1.balanceOf(alice);
        vm.prank(alice);
        c.leave(v.vault, SH, 0, 0);
        (a0, a1) = (token0.balanceOf(alice) - b0, token1.balanceOf(alice) - b1);
        vm.prank(twin);
        (t0, t1) = IVaultEntries(v.vault).withdraw(SH, 0, 0, twin);
    }

    function _toMode(V memory v, uint256 mode) internal {
        if (mode == 1) {
            _latch(v, 1);
            _process(v); // BREACHED
        } else if (mode == 2) {
            for (uint256 k; k < 3; ++k) {
                _latch(v, 1);
                _process(v);
                _backInRange(v);
                _keepAlive(v, 30);
            }
            require(_mode(v) == 2, "EXITED");
        } else if (mode == 3) {
            vm.prank(curatorOwner);
            v.bundler.retire();
        }
    }

    function _toState(V memory v, uint256 st) internal {
        if (st == 1) _conduct(IDX, 9, 1); // the Hub mirror pauses (paused, armed by the RC)
        if (st == 2) v.ref.setMode(MockRefPool.Mode.Revert); // the reference is stale (an exit would fail)
        if (st == 3) {
            // the mirror paused AND the reference stale AND the STATE window used (the allocation just noted)
            _conduct(IDX, 9, 1);
            v.ref.setMode(MockRefPool.Mode.Revert);
        }
    }

    // ================================================================== T-NOTE, A-NOTE-REVERT

    /// @notice T-NOTE: STATE at most once per interval, the rest coalesced (pending); EXIT/PLAN never limited; a
    ///         `flush` on an idle Covenant emits one fresh STATE; a `flush` inside the interval reverts.
    function test_T_NOTE__rateLimitCoalescingAndFlush() public {
        vm.warp(vm.getBlockTimestamp() + 301);
        _alloc(c, X.vault, SH); // a new holding: reported at once
        vm.recordLogs();
        _alloc(c, X.vault, SH); // same holding, inside the interval: coalesced
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.STATE), 0, "coalesced");
        assertTrue(c.notePending());
        vm.prank(alice);
        vm.expectRevert(CovenantBase.TooSoon.selector);
        c.flush();
        vm.warp(vm.getBlockTimestamp() + 301);
        uint64 nn = c.noteNonce();
        vm.recordLogs();
        vm.prank(agentKey);
        c.flush(); // the agent may flush
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.STATE), 1);
        assertEq(c.noteNonce(), nn + 1, "a fresh noteNonce");
        assertFalse(c.notePending());
        // EXIT notes are never limited: three exits inside one interval each answer
        vm.recordLogs();
        _exit(address(c), X.vault, 0);
        _exit(address(c), X.vault, 0);
        _exit(address(c), X.vault, 0);
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.EXIT), 3);
    }

    /// @notice T-NOTE (r11 D11-04): a STATE that adds a holding is reported at once, even inside a busy interval.
    function test_T_NOTE__aNewHoldingIsReportedInsideABusyInterval() public {
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(alice);
        c.flush(); // the interval is now busy
        vm.recordLogs();
        _alloc(c, X.vault, SH); // a new holding
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.STATE), 1, "reported at once");
        vm.recordLogs();
        _alloc(c, X.vault, SH); // not a new holding: coalesced
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.STATE), 0);
    }

    /// @notice T-NOTE (r20 D20-01): `flush` on an idle Covenant with nothing pending still emits one STATE.
    function test_T_NOTE__flushOnAnIdleCovenantEmits() public {
        vm.warp(vm.getBlockTimestamp() + 301);
        assertFalse(c.notePending());
        vm.recordLogs();
        vm.prank(alice);
        c.flush();
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.STATE), 1);
    }

    /// @notice T-NOTE: rule changes have 2 slots per role per interval; the third reverts TooSoon; the agent's
    ///         slots are its own.
    function test_T_NOTE__twoRuleChangesPerRolePerInterval() public {
        vm.warp(vm.getBlockTimestamp() + 301);
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        r.k = 3;
        _setRules(c, r);
        r.k = 2;
        vm.prank(alice);
        vm.expectRevert(CovenantBase.TooSoon.selector);
        c.setRules(r);
        r.k = 2;
        vm.prank(agentKey);
        c.tighten(r); // the agent's own slot still works
    }

    /// @notice A-NOTE-REVERT: a rate-limited note during `leave` never blocks `leave`.
    function test_A_NOTE_REVERT__aLimitedNoteNeverBlocksLeave() public {
        _alloc(c, X.vault, SH); // emits (new holding)
        vm.prank(alice);
        c.leave(X.vault, SH / 2, 0, 0); // inside the interval: coalesced, no revert
        assertTrue(c.notePending());
        assertEq(c.ledger(X.vault), SH - SH / 2);
    }

    function test_A_NOTE_REVERT__PC_aRevertingLimitBlocksLeave() public {
        _alloc(c, X.vault, SH);
        _swapIn(address(new Covenant(address(new ExtLimitReverts()))));
        vm.prank(alice);
        vm.expectRevert(CovenantBase.TooSoon.selector);
        c.leave(X.vault, SH / 2, 0, 0);
    }

    // ================================================================== T-UNPAUSE

    /// @notice T-UNPAUSE: the baseline; an older snapshot is a no-op; a newer breach re-pauses; reverts while a
    ///         breach is pending; a third owner rule change or unpause in an interval reverts TooSoon.
    function test_T_UNPAUSE__baselineOlderNoopNewerRepausesPendingReverts() public {
        _conduct(IDX, 1, 0);
        assertTrue(hub.paused(address(c), IDX));
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(alice);
        c.unpause(IDX);
        (uint32 bb, uint32 bg) = c.baseline(IDX);
        assertEq(bb, 1);
        assertEq(bg, 0);
        assertFalse(hub.paused(address(c), IDX));
        vm.prank(PROXY);
        hub.rcConduct(RC, IDX, 0, 0, 0, 1); // older: Stale, nothing changes
        assertFalse(hub.paused(address(c), IDX));
        _conduct(IDX, 2, 0); // a newer breach re-pauses
        assertTrue(hub.paused(address(c), IDX));
        _latch(X, 1); // pending on a bound vault
        vm.prank(alice);
        vm.expectRevert(CovenantBase.PendingBreach.selector);
        c.unpause(IDX);
        _process(X);
        vm.prank(alice);
        c.unpause(IDX); // the latch took more than an interval: a fresh window, slot 1
        vm.prank(alice);
        c.unpause(IDY); // slot 2
        vm.prank(alice);
        vm.expectRevert(CovenantBase.TooSoon.selector);
        c.unpause(IDY); // the third in one interval
    }

    // ================================================================== T-PLAN, A-PLAN-REPLAY

    function _planCall(address vault, uint32 e) internal returns (uint8 outcome, uint8 reason) {
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcAllocate{gas: 5_000_000}(RC, address(c), vault, e);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.PLAN);
        assertTrue(found);
        (,, outcome, reason) = abi.decode(d, (address, uint32, uint8, uint8));
    }

    function _epochOf(address vault) internal view returns (uint32) {
        return uint32(_ld(vault, 8) >> 40);
    }

    /// @dev Advance to the vault's next epoch through a real roll (a checkpoint).
    function _roll(V memory v) internal {
        _keepAlive(v, tier.EPOCH);
        IVaultEntries(v.vault).poke();
    }

    /// @notice T-PLAN: one deposit per vault epoch on the closed epoch's `EpochRecorded`; a forged future epoch does
    ///         nothing; any attempt consumes the epoch; reason 9 (id not in ids) and reason 10 (a fifth vault).
    function test_T_PLAN__oncePerEpochReasonsAndForgedEpochs() public {
        vm.prank(alice);
        c.setPlan(X.vault, 0.1e18);
        _roll(X);
        uint32 cur = _epochOf(X.vault);
        (uint8 o,) = _planCall(X.vault, cur + 1000); // forged future epoch: nothing
        assertEq(o, Outcome.SKIPPED);
        assertEq(c.ledger(X.vault), 0);
        (o,) = _planCall(X.vault, cur - 1);
        assertEq(o, Outcome.DONE, "the closed epoch deposits");
        assertGt(c.ledger(X.vault), 0);
        uint256 l1 = c.ledger(X.vault);
        (o,) = _planCall(X.vault, cur - 1); // duplicate delivery
        assertEq(o, Outcome.SKIPPED);
        (o,) = _planCall(X.vault, cur - 2); // a late older epoch in the same current epoch
        assertEq(o, Outcome.SKIPPED);
        assertEq(c.ledger(X.vault), l1, "one deposit per vault epoch");
        _roll(X);
        (o,) = _planCall(X.vault, _epochOf(X.vault) - 1);
        assertEq(o, Outcome.DONE, "the next epoch deposits again");
        // reason 9: the vault's id leaves ids
        Rulebook memory r = _rules(IDY, 0);
        vm.warp(vm.getBlockTimestamp() + 301);
        vm.prank(alice);
        c.setRules(r); // X's id leaves ids (its exposure stays reported)
        _roll(X);
        uint8 why;
        (o, why) = _planCall(X.vault, _epochOf(X.vault) - 1);
        assertEq(o, Outcome.SKIPPED);
        assertEq(why, Outcome.SKIP_NOT_IN_IDS, "reason 9");
    }

    /// @notice A-PLAN-REPLAY: plan callbacks for e, e, e+1000 deposit once.
    function test_A_PLAN_REPLAY__eEPlus1000DepositsOnce() public {
        vm.prank(alice);
        c.setPlan(X.vault, 0.1e18);
        _roll(X);
        uint32 e = _epochOf(X.vault) - 1;
        _planCall(X.vault, e);
        uint256 l1 = c.ledger(X.vault);
        _planCall(X.vault, e);
        _planCall(X.vault, e + 1000);
        assertEq(c.ledger(X.vault), l1, "one deposit");
    }

    function test_A_PLAN_REPLAY__PC_withoutTheEpochGateEachDeposits() public {
        vm.prank(alice);
        c.setPlan(X.vault, 0.1e18);
        _roll(X);
        _swapIn(address(new CovenantNoPlanGate(address(ext))));
        uint32 e = _epochOf(X.vault) - 1;
        _planCall(X.vault, e);
        uint256 l1 = c.ledger(X.vault);
        _planCall(X.vault, e);
        assertGt(c.ledger(X.vault), l1, "the replay deposited again");
    }
}
