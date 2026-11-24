// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {B6Fixture} from "./base/B6Fixture.sol";
import {RcB6} from "../src/RcB6.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice A-B6LAG's positive control: "additive credits" — the RC raises a short chain to the whole cap, ignoring
///         what the other chain holds (no lower-before-raise, no committed(other)).
contract RcB6Additive is RcB6 {
    /// @dev No cross-chain accounting at all: no safety lowers either (else step 1 blocks the control, TRAPS s2).
    function _lowerOwed(uint256, address, uint32, uint256) internal pure override returns (bool, uint256) {
        return (false, 0);
    }

    function _restMove(address cov, uint32 id, uint256 cap, Bud memory bud) internal override returns (bool) {
        for (uint256 ci; ci < 2; ++ci) {
            uint256 c = ci == 0 ? CA : CB;
            if (!_listing(c, cov, id) || _b6b[cov][id][c].flags & F_UN != 0) continue;
            B6a storage x = _b6a[cov][id][c];
            if (x.appliedB - x.E < cap * 5 / 100 && x.appliedB < cap && bud.sends > 0) {
                _sendBudget(c, cov, id, cap, true);
                bud.sends -= 1;
            }
        }
        return false;
    }
}

/// @notice §9.3 A-B6LAG and A-OWNER-RACE (spec §4 I-CAP, I-B6SUM; §7 "B6 headroom spent twice", "racing setRules
///         against an RC raise"), each with its positive control.
contract RcB6AttackTest is B6Fixture {
    uint256 constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    bool holdNotes;
    bool holdBudgets;
    bool additive;

    function setUp() public {}

    function _newB6() internal override returns (address) {
        return additive ? address(new RcB6Additive()) : deployCode("RcB6.sol:RcB6");
    }

    function _logPolicy(LogRecord memory l) internal view override returns (Act) {
        return holdNotes && l.topic0 == T_NOTE ? Act.HOLD : Act.DELIVER;
    }

    function _policy(Req memory q) internal view override returns (Act) {
        return holdBudgets && _sel(q.payload) == IReagentHub.rcBudget.selector ? Act.HOLD : Act.DELIVER;
    }

    function _sumE() internal returns (uint256) {
        return _E(CA) + _E(CB);
    }

    /// @dev Both chains spend all they can: allocate to near B on each, let the RC move budgets, repeat.
    function _spendBoth(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            _allocTo(CA, _B(CA) * 99 / 100);
            _allocTo(CB, _B(CB) * 99 / 100);
            _elapse(900);
        }
    }

    /// @notice A-B6LAG: both chains allocate before any note round-trips (every STATE held), then the notes arrive
    ///         and both keep spending: Σ E never exceeds the cap.
    function test_A_B6LAG__bothChainsSpendBeforeAnyRoundTripStayWithinTheCap() public {
        _b6SetUp();
        holdNotes = true;
        _allocTo(CA, 29e18);
        _allocTo(CB, 29e18);
        assertLe(_sumE(), CAP, "before any round trip: each chain within its split budget");
        holdNotes = false;
        _releaseHeldLogs();
        _elapse(600);
        _spendBoth(3);
        assertLe(_sumE(), CAP, "the attack loses: sum E <= cap");
        _assertCapAtRest();
    }

    /// @notice A-B6LAG/PC: with additive credits the same spending reaches about 2 × cap.
    function test_A_B6LAG__PC_additiveCreditsSpendTheCapTwice() public {
        additive = !vm.envOr("PC_UNMUTATED", false); // the control must fail against the unmutated code (r1 D1-09)
        _b6SetUp();
        holdNotes = true;
        _allocTo(CA, 29e18);
        _allocTo(CB, 29e18);
        holdNotes = false;
        _releaseHeldLogs();
        _elapse(600);
        _spendBoth(3);
        emit log_named_uint("B_A", _B(CA));
        emit log_named_uint("B_B", _B(CB));
        emit log_named_uint("E_A", _E(CA));
        emit log_named_uint("E_B", _E(CB));
        assertGt(_sumE(), CAP * 3 / 2, "the control wins: sum E well above the cap");
    }

    /// @dev A raise to chain A in flight (held), then the owner tightens the cap on A, then the raise lands.
    function _raceSetUp(bool defeatGate) internal returns (uint256 newCap) {
        _b6SetUp();
        _allocTo(CA, 28e18); // A short → the rebalance lowers B, its answer brings rest, then a raise to A
        holdBudgets = true;
        _elapse(600);
        // the lower to B is held; release it alone so the raise to A follows and is held
        holdBudgets = false;
        _releaseHeld();
        holdBudgets = true;
        _elapse(600);
        assertEq(held.length, 1, "the raise to A is in flight");
        // the owner tightens: budget 100 → 50 (cap 30)
        _on(CA);
        Rulebook memory r = ca.rules();
        r.budget = 50e18;
        r.agentCapPerEpoch = 5e18;
        vm.prank(alice);
        ca.setRules(r);
        newCap = 30e18;
        uint64 oldRn = ca.rulesNonce() - 1;
        if (defeatGate) vm.mockCall(address(ca), abi.encodeCall(ICovenant.rulesNonce, ()), abi.encode(oldRn));
        holdBudgets = false;
        _releaseHeld();
        vm.clearMockedCalls();
        _on(CA);
    }

    /// @notice A-OWNER-RACE: the in-flight raise lands after the tighten: the Hub's rulesNonce gate answers it at the
    ///         unchanged B, so B_A stays within the new cap.
    function test_A_OWNER_RACE__aRaiseInFlightCannotLiftATightenedCap() public {
        uint256 newCap = _raceSetUp(false);
        assertLe(_B(CA), newCap / 2 > _E(CA) ? newCap / 2 : _E(CA), "B_A within the tightened split (or E)");
        _elapse(1200);
        _assertEleB();
        uint256 sb = _B(CA) + _B(CB);
        uint256 se = _sumE();
        assertLe(sb, newCap > se ? newCap : se, "the attack loses: sum B <= max(cap', sum E) at quiescence");
    }

    /// @notice A-OWNER-RACE/PC: the gate defeated (the Covenant reports the old rulesNonce at delivery) → the raise
    ///         applies and Σ B exceeds the tightened cap.
    function test_A_OWNER_RACE__PC_withoutTheRulesNonceGateTheRaiseLands() public {
        uint256 newCap = _raceSetUp(!vm.envOr("PC_UNMUTATED", false));
        assertGt(_B(CA) + _B(CB), newCap, "the control wins: sum B > cap'");
    }
}
