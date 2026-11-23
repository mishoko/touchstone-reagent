// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {ICovenant, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {MockRefPool} from "touchstone-test/utils/MockRefPool.sol";

/// @notice A-STALE's positive control: the exit pause predicate removed (always paused).
contract CovenantNoPauseCheck is Covenant {
    constructor(address e) Covenant(e) {}

    function _exitPaused(uint32) internal pure override returns (bool) {
        return true;
    }
}

/// @notice A-NOBREACH-EXIT's (and the sibling cell's) positive control: the per-vault check removed.
contract CovenantNoVaultCheck is Covenant {
    constructor(address e) Covenant(e) {}

    function _vaultTriggered(address) internal pure override returns (bool) {
        return true;
    }
}

/// @notice A-AGENT-STALE's positive control: the agent allowed to `unpause`.
contract ExtAgentUnpause is CovenantExt {
    function _mayUnpause() internal view override returns (bool) {
        return msg.sender == owner || msg.sender == agent;
    }
}

/// @notice A-LATEPAUSE's positive control: `paused` without the unpause baseline.
contract HubNoBaseline is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _baseOf(ICovenant, uint32) internal pure override returns (uint32, uint32) {
        return (0, 0);
    }
}

/// @notice The patient exit at delivery (spec §3.5, §5.4; C-04, C-05), on a real Touchstone.
contract ExitTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23;

    function setUp() public {
        _setUpReagent(1301);
        _setUpVaults();
        c = _covenant(alice);
        Rulebook memory r = _rules(IDX, IDY);
        _setRules(c, r);
        vm.prank(alice);
        c.setAgent(agentKey);
        V[] memory all = new V[](3);
        (all[0], all[1], all[2]) = (X, X2, Y);
        _keepAliveAll(all, 2 * tier.EPOCH); // pay accrues, so a breach forfeits and starts a drip
        _alloc(c, X.vault, SH);
    }

    // ------------------------------------------------------------------ helpers

    /// @notice A breach on `v` latched and processed (the drip starts), the RC's snapshot delivered here, and the
    ///         reference back in range with its TWAP settled (spot and reference agree again before any exit).
    function _breach(V memory v, uint32 id) internal {
        IVaultEntries(v.vault).poke(); // checkpoint the accrued pay
        _latch(v, 1);
        _process(v);
        (uint32 b, uint32 g,,) = hub.conduct(id);
        _conduct(id, b + 1, g);
        _settleRef(v);
    }

    function _settleRef(V memory v) internal {
        _backInRange(v);
        _keepAlive(v, 60);
    }

    function _exitOutcome(address vault, uint64 minSeq) internal returns (uint8 o, uint256 a, uint256 b) {
        vm.recordLogs();
        _exit(address(c), vault, minSeq);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(found, "an EXIT note answers every relayed exit");
        return _exitOutcome(d);
    }

    function _toEnd(V memory v) internal {
        uint256 end = _dripEnd(v);
        if (vm.getBlockNumber() < end) _keepAlive(v, end - vm.getBlockNumber() + 10);
    }

    function _swapIn(address impl_, address code) internal {
        vm.etch(impl_, code.code);
    }

    // ================================================================== T-EXIT

    /// @notice T-EXIT: EARLY(DRIP) during the drip with the blocks left; DONE after it, in kind to the owner only;
    ///         a replay after DONE withdraws nothing (DONE(0, 0)).
    function test_T_EXIT__earlyDuringTheDripDoneAfterInKindToTheOwner() public {
        _breach(X, IDX);
        assertGt(_dripEnd(X), vm.getBlockNumber(), "a drip is running");
        (uint8 o, uint256 a, uint256 why) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.EARLY);
        assertEq(why, Outcome.EARLY_DRIP);
        assertEq(a, _dripEnd(X) - vm.getBlockNumber(), "blocksLeft");
        assertEq(c.ledger(X.vault), SH, "nothing withdrawn");
        _toEnd(X);
        uint256 b0 = token0.balanceOf(alice);
        uint256 b1 = token1.balanceOf(alice);
        uint256 cov0 = token0.balanceOf(address(c));
        (o, a, why) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "DONE after the drip");
        assertEq(token0.balanceOf(alice) - b0, a, "out0 to the owner");
        assertEq(token1.balanceOf(alice) - b1, why, "out1 to the owner");
        assertGt(a + why, 0);
        assertEq(token0.balanceOf(address(c)), cov0, "nothing to the Covenant (I-OWN)");
        assertEq(c.ledger(X.vault), 0);
        assertEq(c.exposure(IDX), 0, "exposure leaves with the shares");
        (o, a, why) = _exitOutcome(X.vault, seq); // the replay
        assertEq(o, Outcome.DONE);
        assertEq(a + why, 0, "a replay after DONE withdraws nothing");
    }

    /// @notice T-EXIT: STALE on a healthy vault with no pause; EARLY(NOT_APPLIED) when the Hub lags the RC's seq;
    ///         FAILED (with the error selector) when the reference cannot price the exit.
    function test_T_EXIT__staleNotAppliedAndFailed() public {
        (uint8 o,,) = _exitOutcome(X.vault, 0);
        assertEq(o, Outcome.STALE, "no pause: nothing");
        _breach(X, IDX);
        (uint8 o2,, uint256 why) = _exitOutcome(X.vault, seq + 5);
        assertEq(o2, Outcome.EARLY);
        assertEq(why, Outcome.EARLY_NOT_APPLIED, "the snapshot the RC acted on is not here yet");
        _toEnd(X);
        X.ref.setMode(MockRefPool.Mode.Revert);
        uint256 a;
        (o, a,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.FAILED, "no reference, no exit");
        assertEq(a, uint256(uint32(CovenantBase.RefStale.selector)), "the error selector");
        assertEq(c.ledger(X.vault), SH, "nothing withdrawn");
        X.ref.setMode(MockRefPool.Mode.Ok);
    }

    /// @notice T-EXIT (s2, the LF-3 direction): spot pushed away from the reference before the exit cannot make the
    ///         owner receive less value at the reference: a concentrated position's composition at any other spot is
    ///         worth at least its value at the reference price, so the exit is DONE and the owner's take, valued at
    ///         the reference, is no less than the unmoved exit's.
    function test_T_EXIT__aMovedSpotNeverLowersTheOwnersValue() public {
        _breach(X, IDX);
        _toEnd(X);
        uint256 snap = vm.snapshotState();
        (uint8 o, uint256 a0, uint256 a1) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE);
        uint256 fair = a1 + a0; // valued at the reference tick 0 (price 1 in raw units)
        vm.revertToState(snap);
        _swap(X, true, 6e17); // spot far below the range
        (o, a0, a1) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "a sandwich leg cannot block the exit");
        assertGe(a1 + a0, fair, "value at the reference: never less than the unmoved exit");
    }

    // ================================================================== T-EXIT-PENDING, T-EXIT-REDRIP, T-EXIT-TRIES

    /// @notice T-EXIT-PENDING: a pending breach at delivery → one `processBreach`, then EARLY (the drip it started).
    function test_T_EXIT_PENDING__oneProcessBreachThenEarly() public {
        IVaultEntries(X.vault).poke();
        _latch(X, 1); // latched, not processed
        _conduct(IDX, 1, 0);
        _settleRef(X);
        assertGt(_obs(X).pendingBreaches, 0);
        assertEq(_mode(X), 0);
        (uint8 o,, uint256 why) = _exitOutcome(X.vault, seq);
        assertEq(_obs(X).pendingBreaches, 0, "processed by the exit");
        assertEq(_mode(X), 1, "BREACHED");
        assertEq(o, Outcome.EARLY);
        assertEq(why, Outcome.EARLY_DRIP);
    }

    /// @notice T-EXIT-REDRIP: a second breach restarts the drip; the exit waits for the new end.
    function test_T_EXIT_REDRIP__aSecondBreachMovesTheEnd() public {
        _breach(X, IDX);
        uint256 end1 = _dripEnd(X);
        _keepAlive(X, tier.CURE_BLOCKS / 2);
        _keepAlive(X, 2 * tier.EPOCH); // new pay to forfeit
        _breach(X, IDX);
        uint256 end2 = _dripEnd(X);
        assertGt(end2, end1, "the drip restarted");
        if (vm.getBlockNumber() < end1) _keepAlive(X, end1 - vm.getBlockNumber());
        (uint8 o, uint256 a, uint256 why) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.EARLY);
        assertEq(why, Outcome.EARLY_DRIP);
        assertEq(a, end2 - vm.getBlockNumber(), "waits for the new end");
    }

    /// @notice T-EXIT-TRIES: the Covenant reports EARLY(PENDING) when `processBreach` cannot run, and FAILED with the
    ///         selector; a failed exit changes nothing (the RC counts tries, R-EXIT-SCHED).
    function test_T_EXIT_TRIES__pendingAndFailedReportedNothingChanges() public {
        IVaultEntries(X.vault).poke();
        _latch(X, 1);
        _conduct(IDX, 1, 0);
        _settleRef(X);
        vm.mockCallRevert(X.vault, abi.encodeWithSelector(IVaultEntries.processBreach.selector), "");
        (uint8 o,, uint256 why) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.EARLY);
        assertEq(why, Outcome.EARLY_PENDING, "pending after the attempt");
        vm.clearMockedCalls();
        assertEq(c.ledger(X.vault), SH);
    }

    // ================================================================== A-STALE, I-STALE (C-05)

    /// @notice A-STALE: the owner unpauses (and re-allocates); a late exit does nothing.
    function test_A_STALE__afterUnpauseALateExitDoesNothing() public {
        _breach(X, IDX);
        _replaceX();
        vm.prank(alice);
        c.unpause(IDX);
        _alloc(c, X.vault, SH); // and re-allocates
        _toEnd(X);
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE, "unpaused: the pending exit does nothing");
        assertEq(c.ledger(X.vault), 2 * SH);
    }

    /// @notice A-STALE (r9 D9-02): at k = 2, after `unpause`, one new breach on V arms nothing: the owner is not
    ///         paused (1 < k), so the exit does nothing although V itself breached since its baseline.
    function test_A_STALE__atK2OnePostUnpauseBreachDoesNothing() public {
        _postUnpauseBreachAtK2();
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE, "not paused: nothing");
        assertEq(c.ledger(X.vault), SH);
    }

    function test_A_STALE__PC_withoutThePauseCheckTheExitWithdrawsWhileUnpaused() public {
        _postUnpauseBreachAtK2();
        _swapIn(address(impl), address(new CovenantNoPauseCheck(address(ext))));
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "withdrew although the owner is not paused");
    }

    function _postUnpauseBreachAtK2() internal {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        _breach(X, IDX);
        _replaceX();
        vm.prank(alice);
        c.unpause(IDX); // baseline: one breach
        _keepAlive(X, 2 * tier.EPOCH);
        _breach(X, IDX); // one more: 1 < k = 2 since the baseline
        _toEnd(X);
    }

    /// @notice A-STALE: a `setRules` loosening k does nothing… and the converse cells must exit: a partial `leave`
    ///         while paused; a re-breach of the same vault after unpause → the old pending exit runs.
    function test_A_STALE__looseningDoesNothingConversesExit() public {
        _breach(X, IDX);
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2; // loosened: one breach no longer pauses
        _setRules(c, r);
        _toEnd(X);
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE, "loosened k: nothing");
        // back to k = 1 (paused again), a partial leave meanwhile: the exit runs
        vm.warp(vm.getBlockTimestamp() + 301);
        _setRules(c, _rules(IDX, IDY));
        vm.prank(alice);
        c.leave(X.vault, SH / 4, 0, 0);
        (o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "a partial leave while paused does not cancel the exit");
        assertEq(c.ledger(X.vault), 0);
    }

    /// @notice A-STALE (r8 D8-02): a re-breach of a SIBLING leaves V's old exit UNMET (V has no breach since its
    ///         baseline), while the breached sibling's own exit runs.
    function test_A_STALE__siblingRebreachLeavesTheOldExitUnmet() public {
        _alloc(c, X2.vault, SH);
        _breach(X, IDX);
        _replaceX();
        vm.prank(alice);
        c.unpause(IDX); // X's baseline now includes its breach
        _keepAlive(X2, 2 * tier.EPOCH);
        _breach(X2, IDX); // the sibling breaches: the id is paused again
        _toEnd(X2);
        _toEnd(X);
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE, "X: no breach since its baseline");
        (o,,) = _exitOutcome(X2.vault, seq);
        assertEq(o, Outcome.DONE, "X2's own exit runs");
    }

    function test_A_STALE__PC_withoutTheVaultCheckTheSiblingCaseWithdraws() public {
        _alloc(c, X2.vault, SH);
        _breach(X, IDX);
        _replaceX();
        vm.prank(alice);
        c.unpause(IDX);
        _keepAlive(X2, 2 * tier.EPOCH);
        _breach(X2, IDX);
        _toEnd(X2);
        _toEnd(X);
        _swapIn(address(impl), address(new CovenantNoVaultCheck(address(ext))));
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "X withdrawn on its sibling's breach");
    }

    // ================================================================== A-NOBREACH-EXIT

    /// @notice A-NOBREACH-EXIT: a forged (or reorged) breach record reaches the Hub, but the vault itself has no
    ///         breach: the exit does nothing.
    function test_A_NOBREACH_EXIT__aForgedRecordCannotWithdrawFromAHealthyVault() public {
        _conduct(IDX, 1, 0); // the mirror says paused; no breach on X
        assertTrue(hub.paused(address(c), IDX));
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE);
        assertEq(c.ledger(X.vault), SH);
    }

    function test_A_NOBREACH_EXIT__PC_withoutTheVaultCheckItWithdraws() public {
        _conduct(IDX, 1, 0);
        _swapIn(address(impl), address(new CovenantNoVaultCheck(address(ext))));
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "withdrawn from a healthy vault");
    }

    // ================================================================== A-AGENT-STALE

    /// @notice A-AGENT-STALE: the agent cannot `unpause`, so it cannot void an armed exit.
    function test_A_AGENT_STALE__theAgentCannotVoidAnArmedExit() public {
        _breach(X, IDX);
        _replaceX();
        vm.prank(agentKey);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.unpause(IDX);
        _toEnd(X);
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.DONE, "the armed exit runs");
    }

    function test_A_AGENT_STALE__PC_anAgentThatMayUnpauseVoidsTheExit() public {
        _breach(X, IDX);
        _replaceX();
        CovenantExt badExt = new ExtAgentUnpause();
        _swapIn(address(impl), address(new Covenant(address(badExt))));
        vm.prank(agentKey);
        c.unpause(IDX);
        _toEnd(X);
        (uint8 o,,) = _exitOutcome(X.vault, seq);
        assertEq(o, Outcome.STALE, "voided by the agent");
    }

    // ================================================================== A-LATEPAUSE

    /// @notice A-LATEPAUSE: a snapshot sent before the owner's `unpause` (higher seq, counts not above the
    ///         baseline) arrives after it: no re-pause.
    function test_A_LATEPAUSE__aLateSnapshotDoesNotRepause() public {
        _conduct(IDX, 1, 0); // seq s
        vm.prank(alice);
        c.unpause(IDX);
        assertFalse(hub.paused(address(c), IDX));
        _conduct(IDX, 1, 0); // seq s + 1, sent before the unpause, delivered after it
        assertFalse(hub.paused(address(c), IDX), "still unpaused");
        _conduct(IDX, 2, 0); // a newer breach re-pauses (fails safe)
        assertTrue(hub.paused(address(c), IDX));
    }

    function test_A_LATEPAUSE__PC_withoutTheBaselineTheLateSnapshotRepauses() public {
        _conduct(IDX, 1, 0);
        vm.prank(alice);
        c.unpause(IDX);
        vm.prank(address(factory));
        HubNoBaseline bad = new HubNoBaseline(RC);
        vm.etch(address(hub), address(bad).code);
        _conduct(IDX, 1, 0);
        assertTrue(hub.paused(address(c), IDX), "re-paused by a stale snapshot");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev X's curator re-places (BREACHED → NORMAL) so the owner can unpause and re-allocate.
    function _replaceX() internal {
        _keepAlive(X, 60);
        vm.prank(curatorOwner);
        X.bundler.setPositions(-1000, 1000, PreSwapLib.none(), 0, type(uint256).max);
        _keepAlive(X, 20);
    }
}

import {PreSwap} from "touchstone/types/PreSwap.sol";

library PreSwapLib {
    function none() internal pure returns (PreSwap memory) {
        return PreSwap(false, false, 0);
    }
}
