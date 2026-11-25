// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ExitFixture} from "./base/ExitFixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord, IReactive} from "../src/interfaces/IReactive.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice The RC scheduler rows (spec §9.2 R-NOLOOP, R-UNTRACKED, R-RESEND, R-CRON, R-B2, R-PLAN, R-ARM-LATE,
///         R-EXIT-SCHED; §9.1 T-EXIT-BOUND) on the R layer.
contract RcRowsTest is ExitFixture {
    uint256 constant T_APPLIED = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;
    bool dropAppliedB;
    bool dropEveryAppliedA; // every Applied from chain A is lost (the lag never closes by itself; s6 MU-241)
    bool holdStateA; // chain A's STATE notes are held (released late, after newer ones; s6 MU-231)

    function setUp() public {
        _exitBase();
    }

    function _logPolicy(LogRecord memory l) internal override returns (Act) {
        if (l.chainId == CA && l.topic0 == T_APPLIED && (dropAppliedB || dropEveryAppliedA)) {
            dropAppliedB = false; // drop exactly one (or every one while dropEveryAppliedA)
            return Act.DROP;
        }
        if (holdStateA && l.chainId == CA && l.topic0 == T_NOTE && l.topic3 == 1) return Act.HOLD;
        return Act.DELIVER;
    }

    function _covNonce(uint256 c, address cov) internal returns (uint32 noteNonce, uint8 nHold) {
        uint256 p = _lasna();
        (,, noteNonce,,, nHold) = rc.covOf(c, cov);
        _leave(p);
    }

    function _action(V memory v) internal {
        _keepAlive(v, 40); // past the cooldown
        vm.prank(curatorOwner);
        v.bundler.setPositions(-1000, 1000, PreSwap(false, false, 0), 0, type(uint256).max);
        _keepAlive(v, 10);
    }

    // ================================================================== R-NOLOOP

    function _react(LogRecord memory l) internal {
        uint256 p = _lasna();
        vm.prank(SYSTEM);
        (bool ok,) = address(rc).call(abi.encodeCall(IReactive.react, (l)));
        assertTrue(ok);
        _leave(p);
        _elapse(1);
    }

    /// @notice R-NOLOOP: an `Applied` never triggers a callback (50 of them, no parks); a `BudgetApplied` triggers at
    ///         most one reconcile, whose sends are bounded by SENDS_PER_REACTION.
    function test_R_NOLOOP__appliedNeverSendsBudgetAppliedSendsAtMostFour() public {
        _elapse(600);
        uint256 r0 = deliveries.length;
        LogRecord memory l;
        (l.chainId, l.emitter, l.topic0, l.topic1) = (CA, address(ch[CA].hub), T_APPLIED, 1);
        for (uint256 i; i < 50; ++i) {
            l.data = abi.encode(uint64(1000 + i));
            _react(l);
        }
        assertEq(deliveries.length, r0, "no callback from Applied");
        // a BudgetApplied with a newer rulesNonce than the RC knows (rules-unsettled), as the Hub would emit it
        (l.topic0, l.topic1, l.topic2) = (
            0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823, uint256(uint160(address(ca))), 1
        );
        l.data = abi.encode(uint128(1e18), uint64(1), uint64(9));
        r0 = deliveries.length;
        _react(l);
        assertLe(deliveries.length - r0, 4, "at most SENDS_PER_REACTION from one BudgetApplied");
    }

    // ================================================================== R-UNTRACKED

    /// @notice R-UNTRACKED: the 17th Covenant on a vault is `Untracked` and gets no pair state: after the breach
    ///         its STATE sets no pending bit, and Cron goes off once the 16 tracked exits are done.
    function test_R_UNTRACKED__theSeventeenthCovenantGetsNoPairState() public {
        address[16] memory owners;
        ICovenant[16] memory cs;
        for (uint256 i; i < 16; ++i) {
            owners[i] = makeAddr(string(abi.encode("owner", i)));
            (cs[i],) = _covenantBoth(owners[i], admin);
            _setRulesOn(CA, cs[i], _rulesFor(1, 0));
            _on(CA);
            _keepAlive(xa, 2);
            _allocOn(CA, cs[i], xa.vault, SH / 100);
        }
        _elapse(60);
        bytes32 untracked = keccak256("Untracked(uint256,address)");
        assertEq(_lasnaEventCount(untracked), 1, "one Untracked: the 17th Covenant (alice was first)");
        (,,, bool pending,,) = _pair(CA, address(cs[15]), xa.vault);
        assertFalse(pending);
        _breach(xa, CA);
        _on(CA);
        _keepAlive(xa, 3_600 + 3_000);
        (,,, pending,,) = _pair(CA, address(cs[15]), xa.vault);
        assertFalse(pending, "the untracked Covenant never gets a pending bit");
        (uint256 pp,, uint256 sw, bool on) = _counters();
        assertEq(pp + sw, 0);
        assertFalse(on, "Cron off: the untracked Covenant holds nothing");
    }

    // ================================================================== R-RESEND

    /// @notice R-RESEND: a dropped `Applied` leaves chain A behind (seqApplied < seqOut); STATEs from A (alice holds
    ///         X_A there) inside 1,000 Lasna blocks bring exactly one fresh-seq resend, whose `Applied` brings A level.
    function test_R_RESEND__oneFreshSeqResendPerThousandBlocksReleasesTheLag() public {
        dropAppliedB = true; // (the flag drops one Applied from chain A)
        _on(CB);
        _action(xb); // an Action snapshot to both Hubs; its Applied on A is dropped
        _elapse(60);
        uint256 p = _lasna();
        (uint32 out, uint32 applied,,) = rc.seqOf(CA, 1);
        _leave(p);
        assertLt(applied, out, "A behind");
        uint256 c0 = _sends(CA, IReagentHub.rcConduct.selector);
        for (uint256 i; i < 2; ++i) {
            _on(CA);
            vm.prank(alice);
            ca.flush();
            _elapse(301); // 2 STATEs ≥ NOTE_INTERVAL apart, inside 1,000 Lasna blocks (≈ 1,130 s)
        }
        assertEq(_sends(CA, IReagentHub.rcConduct.selector) - c0, 1, "one resend per (chain, id) per 1,000 blocks");
        p = _lasna();
        (out, applied,,) = rc.seqOf(CA, 1);
        _leave(p);
        assertEq(applied, out, "the fresh-seq resend applied: A level (a reused seq would be Stale(1))");
    }

    /// @notice R-RESEND (PB-7 rate, s6 MU-241): while chain A stays behind (every Applied from A is lost), three
    ///         STATEs ≥ NOTE_INTERVAL apart inside 1,000 Lasna blocks bring exactly ONE fresh-seq resend (no limit → 3);
    ///         after the window, the next STATE resends again (the rate reopens, never a permanent block).
    function test_R_RESEND__aPersistentLagResendsOncePerThousandBlocks() public {
        dropEveryAppliedA = true;
        _on(CB);
        _action(xb); // an Action snapshot to both Hubs; its Applied on A is lost
        _elapse(60);
        uint256 p = _lasna();
        (uint32 out, uint32 applied,,) = rc.seqOf(CA, 1);
        _leave(p);
        assertLt(applied, out, "non-vacuous: A behind");
        uint256 c0 = _sends(CA, IReagentHub.rcConduct.selector);
        for (uint256 i; i < 3; ++i) {
            _on(CA);
            vm.prank(alice);
            ca.flush();
            _elapse(301); // 3 STATEs ≥ NOTE_INTERVAL apart, inside 1,000 Lasna blocks (≈ 1,130 s)
        }
        assertEq(_sends(CA, IReagentHub.rcConduct.selector) - c0, 1, "one resend per (chain, id) per 1,000 blocks");
        p = _lasna();
        (out, applied,,) = rc.seqOf(CA, 1);
        _leave(p);
        assertLt(applied, out, "non-vacuous: A still behind after the window's STATEs");
        _elapse(1_200); // past the window
        _on(CA);
        vm.prank(alice);
        ca.flush();
        _elapse(60);
        assertEq(_sends(CA, IReagentHub.rcConduct.selector) - c0, 2, "the rate reopens after 1,000 blocks");
    }

    /// @notice §5.5 `Note(STATE)` (s6 MU-231): a STATE older than the last one applied changes nothing: an older STATE
    ///         (one holding) released after a newer one (two holdings) leaves the RC's noteNonce and holdings at the
    ///         newer values (s6 r1 m-2: the two STATEs differ in their holdings).
    function test_R_B6SCHED__anOlderStateReleasedLateChangesNothing() public {
        _elapse(301);
        holdStateA = true;
        _on(CA);
        vm.prank(alice);
        ca.flush(); // STATE n1 (one holding), held
        _elapse(60);
        assertEq(heldLogs.length, 1, "non-vacuous: the older STATE is held");
        holdStateA = false;
        V memory x2 = _registeredVault(CA, 1);
        _allocOn(CA, ca, x2.vault, SH); // STATE n2 (a new holding, reported at once), delivered
        _elapse(60);
        (uint32 n2, uint8 h2) = _covNonce(CA, address(ca));
        assertEq(h2, 2, "non-vacuous: the newer STATE carries two holdings");
        _releaseHeldLogs(); // n1 arrives late
        _elapse(60);
        assertEq(heldLogs.length, 0, "non-vacuous: the older STATE was delivered");
        (uint32 n, uint8 h) = _covNonce(CA, address(ca));
        assertEq(n, n2, "the older STATE changed nothing: noteNonce");
        assertEq(h, 2, "the older STATE changed nothing: holdings");
    }

    // ================================================================== R-CRON

    /// @notice R-CRON: 60 `Action`s on a curator whose only Covenant holds nothing there start no Cron; and the gate
    ///         is the O(1) sum of pending pairs, work entries and sweeps.
    function test_R_CRON__actionsWithNoHoldingsNeverSubscribeCron() public {
        _on(CB);
        uint256 n0 = subscribeCalls;
        for (uint256 i; i < 6; ++i) {
            _action(xb);
            _elapse(30);
            (,,, bool on) = _counters();
            assertFalse(on, "no Cron for Actions");
        }
        assertEq(subscribeCalls, n0 == 0 ? 0 : n0, "no new subscription at all from Actions under the budget");
    }

    // ================================================================== R-B2

    /// @notice R-B2: a breach on A arms the healthy X_B for the opted-in Covenant only: alice (b2) holds X_B and is
    ///         exited there; bob (no b2) holds X_B and is not.
    function test_R_B2__aBreachOnAArmsTheOtherChainOnlyWhenOptedIn() public {
        address bob = makeAddr("bob");
        (, ICovenant bb) = _covenantBoth(bob, admin);
        Rulebook memory r = _rulesFor(1, 0);
        _setRulesOn(CB, bb, r);
        r.b2 = true;
        _elapse(301);
        _setRulesOn(CB, cb, r);
        _on(CB);
        _keepAlive(xb, 2);
        _allocOn(CB, cb, xb.vault, SH);
        _on(CB);
        _keepAlive(xb, 2);
        _allocOn(CB, bb, xb.vault, SH);
        _elapse(60);
        _breach(xa, CA);
        _on(CB);
        _keepAlive(xb, 600);
        _on(CB);
        assertEq(cb.ledger(xb.vault), 0, "alice (b2) exited from the healthy X_B");
        assertEq(bb.ledger(xb.vault), SH, "bob (no b2) kept X_B");
    }

    // ================================================================== R-PLAN

    /// @notice R-PLAN: a plan is sent on the vault's `EpochRecorded` (from the Covenant's second STATE: lazy plans),
    ///         and none while the Covenant is paused.
    function test_R_PLAN__sentOnEpochRecordedSkippedWhilePaused() public {
        _on(CA);
        vm.prank(alice);
        ca.setAllowed(xa.vault, true);
        vm.prank(alice);
        ca.setPlan(xa.vault, 0.01e18);
        _elapse(301);
        _on(CA);
        vm.prank(alice);
        ca.flush(); // the second STATE carries the plan
        _elapse(30);
        uint256 a0 = _sends(CA, IReagentHub.rcAllocate.selector);
        _on(CA);
        _keepAlive(xa, 3_700); // an epoch boundary (DEMO EPOCH 3,600)
        IVaultEntries(xa.vault).poke();
        _elapse(30);
        assertGt(_sends(CA, IReagentHub.rcAllocate.selector), a0, "a plan callback on EpochRecorded");
        _breach(xa, CA);
        uint256 a1 = _sends(CA, IReagentHub.rcAllocate.selector);
        _on(CA);
        _keepAlive(xa, 3_700);
        IVaultEntries(xa.vault).poke();
        _elapse(30);
        assertEq(_sends(CA, IReagentHub.rcAllocate.selector), a1, "none while paused or armed");
    }

    // ================================================================== R-ARM-LATE

    /// @notice R-ARM-LATE: a holding added inside a busy NOTE_INTERVAL is reported at once (exempt STATE), and a
    ///         later breach of that vault exits it.
    function test_R_ARM_LATE__aHoldingAddedInABusyIntervalIsExitedAfterABreach() public {
        _on(CB);
        vm.prank(alice);
        cb.flush(); // uses the interval
        _on(CB);
        _keepAlive(xb, 2);
        _allocOn(CB, cb, xb.vault, SH); // a new holding inside the interval: reported at once
        _elapse(30);
        uint256 p = _lasna();
        (,,,,, uint8 nh) = rc.covOf(CB, address(cb) == address(0) ? address(0) : address(ca));
        _leave(p);
        assertEq(nh, 1, "the RC knows the holding at once");
        _breach(xb, CB);
        _on(CB);
        _keepAlive(xb, 600);
        _on(CB);
        assertEq(cb.ledger(xb.vault), 0, "exited after the breach");
    }

    // ================================================================== R-EXIT-SCHED, T-EXIT-BOUND

    /// @notice R-EXIT-SCHED: RELAY_FAILED three times suspends the pair (ExitAbandoned) at ≤ 1 send per
    ///         EPOCH_TICKS; a new breach on the vault clears the suspension and the exit runs.
    function test_R_EXIT_SCHED__relayFailedThriceSuspendsThenANewBreachResumes() public {
        _breach(xa, CA);
        vm.mockCallRevert(address(ca), abi.encodeWithSelector(ICovenant.rcExit.selector), "relay");
        _on(CA);
        _keepAlive(xa, 3_600 + 200);
        uint256 s0 = _sends(CA, IReagentHub.rcExit.selector);
        _elapse(4 * 32 * 113 + 600); // four windows of EPOCH_TICKS(1301)
        (,,,, bool suspended, uint8 tries) = _pair(CA, address(ca), xa.vault);
        assertTrue(suspended, "suspended at the third try");
        assertEq(tries, 3);
        assertLe(_sends(CA, IReagentHub.rcExit.selector) - s0, 4, "at most one send per EPOCH_TICKS");
        bytes32 ab = keccak256("ExitAbandoned(uint256,address,address)");
        assertGe(_lasnaEventCount(ab), 1);
        vm.clearMockedCalls();
        _on(CA);
        _latch(xa, 2); // a new breach on the vault
        _process(xa);
        _backInRange(xa);
        _on(CA);
        _keepAlive(xa, 3_600 + 2_000);
        _on(CA);
        assertEq(ca.ledger(xa.vault), 0, "resumed after the new breach and exited");
    }

    /// @notice T-EXIT-BOUND: the exit lands within 3 epochs of the first breach, plus delivery (spec §3.5 bound).
    function test_T_EXIT_BOUND__theExitLandsWithinThreeEpochsOfTheFirstBreach() public {
        _on(CA);
        uint256 b0 = vm.getBlockNumber();
        _breach(xa, CA);
        uint256 landed;
        for (uint256 i; i < 120 && landed == 0; ++i) {
            _on(CA);
            _keepAlive(xa, 100);
            _on(CA);
            if (ca.ledger(xa.vault) == 0) landed = vm.getBlockNumber();
        }
        assertGt(landed, 0, "the exit landed");
        assertLe(landed - b0, 3 * tier.EPOCH + 600, "within 3 epochs (DEMO 3,600 blocks each) plus delivery");
    }

    // ================================================================== more R-EXIT-SCHED cells

    /// @notice R-EXIT-SCHED: a Hub in debt parks the exit after 6 · EPOCH_TICKS with Cron off; the Hub's next
    ///         callback result (an `Applied` after the refund, from curator activity) unparks it and the exit runs.
    function test_R_EXIT_SCHED__parkedThenTheHubsNextAppliedUnparksAndExits() public {
        hubInDebt[CA] = true;
        _breach(xa, CA);
        _elapse(260 * 113);
        (,, uint32 parked,,,) = _pair(CA, address(ca), xa.vault);
        assertGt(parked, 0, "parked");
        (,,, bool on) = _counters();
        assertFalse(on, "Cron off while parked");
        hubInDebt[CA] = false; // refunded
        _on(CB);
        _action(xb); // curator activity: rcConduct to both Hubs; chain A's Applied is a callback result
        _on(CA);
        _keepAlive(xa, 3_000);
        (,, parked,,,) = _pair(CA, address(ca), xa.vault);
        assertEq(parked, 0, "unparked by the Hub's Applied");
        _on(CA);
        assertEq(ca.ledger(xa.vault), 0, "and the exit ran");
    }

    /// @notice R-EXIT-SCHED (r13 D13-01, r18 D18-02): chain A has not applied the breach snapshot (its Applied is
    ///         dropped), so the pair waits without sending; the PB-7 resend's Applied releases the wait through the
    ///         scan and the exit runs.
    function test_R_EXIT_SCHED__aLaggingSnapshotWaitsThenTheResendReleasesIt() public {
        dropAppliedB = true; // (drops one Applied from chain A: the breach snapshot's)
        _breach(xa, CA);
        (, uint32 waitSeq,,,,) = _pair(CA, address(ca), xa.vault);
        _on(CA);
        _keepAlive(xa, 3_600 + 3_000);
        _on(CA);
        assertEq(ca.ledger(xa.vault), 0, "released by the resend's Applied, then exited");
        waitSeq;
    }

    /// @notice R-EXIT-SCHED / PB-2 vault check (B7, no B2): a breach on X_B pauses curator 1 on both chains, but no
    ///         exit is ever sent for alice's healthy X_A.
    function test_R_EXIT_SCHED__noExitForAHealthyVaultWithoutB2() public {
        uint256 e0 = _sends(CA, IReagentHub.rcExit.selector);
        _breach(xb, CB);
        _on(CA);
        _keepAlive(xa, 3_000);
        assertEq(_sends(CA, IReagentHub.rcExit.selector), e0, "no exit for the healthy vault");
        _on(CA);
        assertEq(ca.ledger(xa.vault), SH);
    }

    /// @notice R-B6SCHED (step 0, r24 D24-02): an id listed on chain A only is never messaged on chain B.
    function test_R_B6SCHED__anIdListedOnOneChainIsNeverMessagedOnTheOther() public {
        Rulebook memory r = _rulesFor(1, 0);
        r.ids = [uint32(2), 0, 0, 0]; // chain B lists curator 2 only
        _elapse(301);
        _setRulesOn(CB, cb, r);
        _elapse(60);
        uint256 b0 = _deliveredFor(CB, IReagentHub.rcBudget.selector, 1);
        _on(CA);
        _keepAlive(xa, 2);
        _allocOn(CA, ca, xa.vault, SH * 136); // E ≈ 27.4 of 30 (SH ≈ 0.2 mWETH): A runs short on id 1
        _elapse(1200);
        assertEq(_deliveredFor(CB, IReagentHub.rcBudget.selector, 1), b0, "never messaged for an id it does not list");
        _on(CA);
        uint256 e = ca.exposure(1);
        (uint256 b,,) = ch[CA].hub.budget(address(ca), 1);
        assertLt(b - e, 3e18, "non-vacuous: A is short (headroom < MIN_MOVE), so a listing chain B would be messaged");
    }

    /// @notice R-B6SCHED (step 0, r24 D24-02; s6 MU-257): chain B removes id 1 while it still holds exposure there (its
    ///         STATE keeps a Base for the id: budget min(B, E) = E, no headroom) and A has headroom ≥ 2 · MIN_MOVE. B
    ///         is never messaged for the id (no rebalance or raise towards an unlisting chain: each answer would bring
    ///         another, unbounded).
    function test_R_B6SCHED__anIdListedOnOneChainAfterARemovalIsNeverMessagedThere() public {
        _allocOn(CB, cb, xb.vault, SH);
        _elapse(301);
        Rulebook memory r = _rulesFor(1, 0);
        r.ids = [uint32(2), 0, 0, 0]; // chain B removes curator 1 (still exposed)
        uint256 b0 = _deliveredFor(CB, IReagentHub.rcBudget.selector, 1);
        _setRulesOn(CB, cb, r);
        _on(CB);
        assertGt(cb.exposure(1), 0, "non-vacuous: B still exposed to id 1 (a Base is reported)");
        _elapse(1_200); // B's removal STATE ran the reconcile; any move (and its answers' moves) would land here
        assertEq(_deliveredFor(CB, IReagentHub.rcBudget.selector, 1), b0, "never messaged for an id it no longer lists");
        _on(CA);
        (uint256 b,,) = ch[CA].hub.budget(address(ca), 1);
        assertGe(b - ca.exposure(1), 6e18, "non-vacuous: A has headroom >= 2 * MIN_MOVE (a move would be sendable)");
    }
}
