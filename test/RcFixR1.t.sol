// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ExitFixture} from "./base/ExitFixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice The rc-fix r1 findings as standing cells (each failed on the code the review read; P-13 standing checks).
contract RcFixR1Test is ExitFixture {
    uint256 constant T_APPLIED = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;
    uint256 dropAppliedA;

    function setUp() public {
        _exitBase();
    }

    function _logPolicy(LogRecord memory l) internal override returns (Act) {
        if (dropAppliedA > 0 && l.chainId == CA && l.topic0 == T_APPLIED) {
            --dropAppliedA;
            return Act.DROP;
        }
        return Act.DELIVER;
    }

    function _b6Parked(uint256 c) internal returns (uint32 pl) {
        uint256 p = _lasna();
        (,,,,,, pl) = rc.b6Of(address(ca), 1, c);
        _leave(p);
    }

    function _setBudget(uint256 c, ICovenant cv, uint128 budget) internal {
        _on(c);
        Rulebook memory r = cv.rules();
        r.budget = budget;
        r.agentCapPerEpoch = budget / 10;
        vm.prank(alice);
        cv.setRules(r);
    }

    /// @notice C1-01: a lower in flight to a Hub in debt, then a tighten that lowers capRC below its target: the
    ///         lower is re-sent under the back-off only (not at every opportunity), parks by 6·EPOCH_TICKS, and Cron
    ///         goes off.
    function test_R_B6SCHED__aTightenUnderAnUnansweredLowerBacksOffAndParks() public {
        hubInDebt[CB] = true;
        _elapse(301); // past the base allocation's NOTE_INTERVAL: this STATE is emitted, not coalesced
        _on(CA);
        _keepAlive(xa, 2);
        _allocOn(CA, ca, xa.vault, SH * 136); // E ≈ 27.4 of 30 (SH ≈ 0.2 mWETH): A short → the rebalance lower to B
        _elapse(600);
        _on(CA);
        emit log_named_uint("E_A", ca.exposure(1));
        uint256 s0 = _sends(CB, IReagentHub.rcBudget.selector);
        assertGe(s0, 1);
        _setBudget(CA, ca, 50e18); // cap 30: the target for B falls below the lower in flight
        _elapse(100 * 113);
        uint256 s1 = _sends(CB, IReagentHub.rcBudget.selector);
        assertLe(s1 - s0, 9, "re-sends bounded by the back-off (C1-01: not one per opportunity)");
        assertGt(_b6Parked(CB), 0, "parked after 6 EPOCH_TICKS");
        (,,, bool on) = _counters();
        assertFalse(on, "Cron off");
    }

    /// @notice C1-03: the breach snapshot's Applied on A and its first resend's Applied are both dropped: the waiting
    ///         pair re-sends at the PB-7 rate (every 1,000 Lasna blocks), not once, and the exit lands before a park.
    function test_R_EXIT_SCHED__aWaitingPairResendsAtTheRateNotOnce() public {
        dropAppliedA = 2;
        _breach(xa, CA);
        _on(CA);
        _keepAlive(xa, 3_600 + 4_000);
        _on(CA);
        assertEq(ca.ledger(xa.vault), 0, "the second resend released the wait and the exit ran");
    }

    /// @notice C1-04: the 17th Covenant (Untracked) flushes after the breach: it still gets no pair state, and Cron
    ///         goes off once the tracked exits are done.
    function test_R_UNTRACKED__aStateAfterTheBreachStillGivesNoPairState() public {
        ICovenant[16] memory cs;
        for (uint256 i; i < 16; ++i) {
            address o = makeAddr(string(abi.encode("u", i)));
            (cs[i],) = _covenantBoth(o, admin);
            _setRulesOn(CA, cs[i], _rulesFor(1, 0));
            _on(CA);
            _keepAlive(xa, 2);
            _allocOn(CA, cs[i], xa.vault, SH / 100);
        }
        _elapse(60);
        _breach(xa, CA);
        _elapse(301);
        _on(CA);
        vm.prank(cs[15].owner());
        cs[15].flush(); // the untracked Covenant's STATE after the breach
        _elapse(60);
        (,,, bool pending,,) = _pair(CA, address(cs[15]), xa.vault);
        assertFalse(pending, "no pair state for an untracked Covenant");
        _on(CA);
        _keepAlive(xa, 3_600 + 3_000);
        (uint256 pp,, uint256 sw, bool on) = _counters();
        assertEq(pp + sw, 0);
        assertFalse(on, "Cron off");
    }

    /// @notice C1-02: alice's lowers park on BOTH chains (both Hubs in debt); after the refund one flush brings the
    ///         probe Applieds from both Hubs; the sweep must unpark both b6Parked elements (the first unpark
    ///         shrinks the 1301 list; the 11155111 element must not be skipped).
    function test_R_COUNTERS__aSweepUnparksEveryElementWhenAListShrinks() public {
        hubInDebt[CA] = true;
        hubInDebt[CB] = true;
        _setBudget(CA, ca, 40e18); // cap 24: lowers owed to both chains, both in debt
        _elapse(260 * 113); // > 6 · EPOCH_TICKS on both chains (1301: 192) plus the back-off
        emit log_named_uint("rcBudget to 1301", _sends(CA, IReagentHub.rcBudget.selector));
        emit log_named_uint("rcBudget to 11155111", _sends(CB, IReagentHub.rcBudget.selector));
        for (uint256 i; i < 2; ++i) {
            uint256 p = _lasna();
            (uint96 ab, uint96 e, uint96 unB, uint32 n, uint32 an, uint8 f, uint32 pl) = rc.b6Of(address(ca), 1, i == 0 ? CA : CB);
            _leave(p);
            emit log_named_uint("chain", i == 0 ? CA : CB);
            emit log_named_uint(" appliedB", ab);
            emit log_named_uint(" E", e);
            emit log_named_uint(" unB", unB);
            emit log_named_uint(" nonce", n);
            emit log_named_uint(" flags", f);
            emit log_named_uint(" parkLog", pl);
            an;
        }
        assertGt(_b6Parked(CA), 0, "parked on 1301");
        assertGt(_b6Parked(CB), 0, "parked on 11155111");
        (hubInDebt[CA], hubInDebt[CB]) = (false, false);
        _on(CB);
        vm.prank(alice);
        cb.flush(); // probes to both chains (RC storage shows parks on both)
        _elapse(10 * 113);
        assertEq(_b6Parked(CA), 0, "1301 unparked");
        assertEq(_b6Parked(CB), 0, "11155111 unparked: not skipped by the sweep (C1-02)");
    }
}
