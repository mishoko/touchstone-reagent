// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {B6Fixture} from "./base/B6Fixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice R-B6SCHED fixed cells for the B6 delivery races (spec §5.5 B6 reconcile, `BudgetApplied`, the nonce gates;
///         F-012): each pins one rule the seeded scheduler only reaches by chance. Base sequence (R-BUDGET): A runs
///         short, the RC lowers B (rebalance) and, once that is answered, sends A a raise (to capRC − committed(B)),
///         which these cells hold in flight.
contract RcB6RacesTest is B6Fixture {
    uint256 constant T_NOTE_ = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    bool holdBudgets;
    uint8 stateMode; // 0 deliver; 1 hold alice's 1301 STATE notes; 2 drop them
    mapping(uint256 => uint256) reqs; // rcBudget requests per chain (counted when the RC makes them)

    function setUp() public {
        _b6SetUp();
    }

    function _policy(Req memory q) internal override returns (Act) {
        if (_sel(q.payload) != IReagentHub.rcBudget.selector) return Act.DELIVER;
        ++reqs[q.chainId];
        return holdBudgets ? Act.HOLD : Act.DELIVER;
    }

    function _logPolicy(LogRecord memory l) internal view override returns (Act) {
        if (stateMode != 0 && l.chainId == CA && l.topic0 == T_NOTE_ && l.topic3 == 1 && address(uint160(l.topic2)) == address(ca)) {
            return stateMode == 1 ? Act.HOLD : Act.DROP;
        }
        return Act.DELIVER;
    }

    /// @dev Up to the raise to A held in flight (the rebalance lower to B answered first).
    function _raiseInFlight() internal {
        _allocTo(CA, 28e18); // headroom < MIN_MOVE: A short
        holdBudgets = true;
        _elapse(600);
        holdBudgets = false;
        _releaseHeld(); // the lower to B lands; its answer brings rest and the RC sends A the raise (held)
        holdBudgets = true;
        _elapse(600);
        assertEq(held.length, 1, "the raise to A is in flight");
    }

    function _setBudget(uint256 c, uint128 budget) internal {
        _on(c);
        ICovenant cv = _cov(c);
        Rulebook memory r = cv.rules();
        r.budget = budget;
        r.agentCapPerEpoch = budget / 10;
        vm.prank(alice);
        cv.setRules(r);
    }

    /// @notice MU-252: committed counts the unanswered sends. A raise to A (target 57) is in flight; B tightens its cap
    ///         to 45: Σ committed = 57 + 3 > 45, so B is owed a lower (to max(E_B, 45 − 57) = 0); counted at applied
    ///         only (30 + 3 = 33 ≤ 45) nothing would be sent and the raise would land into Σ B = 60 > 45.
    function test_R_B6SCHED__aTightenUnderARaiseInFlightLowersTheOtherChain() public {
        _raiseInFlight();
        uint256 b0 = reqs[CB];
        _setBudget(CB, 75e18); // cap 45 on 11155111 (its Hub keeps B_B = min(3, 22.5) = 3)
        _elapse(60);
        assertGt(reqs[CB], b0, "a lower to 11155111: committed(1301) counts the raise in flight");
        holdBudgets = false;
        _releaseHeld();
        _elapse(1200);
        _assertEleB();
        _assertCapAtRest();
    }

    /// @notice MU-248: rules-unsettled. A raise to A is in flight when the owner tightens A; A's STATE is delayed. The
    ///         Hub rejects the raise (rulesNonce gate) and answers it with the new r: the RC must not raise again until
    ///         the STATE carrying that r arrives (else every answer brings another rejected raise).
    function test_R_B6SCHED__aRaiseRejectedByARuleChangeWaitsForItsState() public {
        _raiseInFlight();
        stateMode = 1; // the tighten's STATE and the answer's STATE are delayed
        _setBudget(CA, 50e18); // cap 30
        holdBudgets = false;
        _releaseHeld(); // the raise is rejected at the Hub: BudgetApplied(unchanged B, the new r) reaches the RC
        uint256 a0 = reqs[CA];
        _elapse(600);
        assertEq(reqs[CA], a0, "no raise to 1301 before the rule change's STATE arrives (rules-unsettled)");
        stateMode = 0;
        _releaseHeldLogs();
        _elapse(1200);
        _assertCapAtRest(); // (E_A may exceed B_A: the tighten went below spent exposure, which is legal)
    }

    /// @notice MU-244: the nonce gate on STATE budgets. A STATE from A emitted before the raise was applied (budget 30,
    ///         budgetNonce 0) arrives after the raise's answer (57): it must not overwrite the newer applied B (else the
    ///         RC sees A short again and re-raises).
    function test_R_B6SCHED__aStaleStateBudgetNeverOverwritesANewerAnswer() public {
        _raiseInFlight();
        _elapse(301); // past NOTE_INTERVAL: the flush emits a STATE
        stateMode = 1;
        _on(CA);
        vm.prank(alice);
        ca.flush(); // S1: B_A = 30, budgetNonce 0 (held)
        _elapse(20);
        stateMode = 2; // the answer's own STATE is lost
        holdBudgets = false;
        _releaseHeld(); // the raise lands: BudgetApplied(57)
        _elapse(60);
        uint256 a0 = reqs[CA];
        uint256 p = _lasna();
        (uint96 ab0,,,,,,) = rc.b6Of(address(ca), 1, CA);
        _leave(p);
        assertEq(ab0, 57e18, "non-vacuous: the answer recorded B_A = 57");
        stateMode = 0;
        _releaseHeldLogs(); // S1 arrives late (its noteNonce is still newer than the RC's)
        _elapse(60);
        p = _lasna();
        (uint96 ab,,,,,,) = rc.b6Of(address(ca), 1, CA);
        _leave(p);
        assertEq(ab, 57e18, "the stale STATE's older budget is ignored");
        assertEq(reqs[CA], a0, "no re-raise");
    }

    /// @notice R-B6SCHED fixed cell (r22 D22-01): a Covenant listing 4 ids on both chains (1301's STATE carries 4
    ///         `Base`s); a tighten on 1301 makes the RC owe 11155111 a lower for EACH of the 4 ids, all sent and
    ///         answered, and Σ B per id ≤ the new cap at rest.
    function test_R_B6SCHED__aFourBaseTightenOnOneChainLowersAllFourOnTheOther() public {
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c);
            Rulebook memory r = _cov(c).rules();
            r.ids = [uint32(1), 2, 3, 4];
            vm.prank(alice);
            _cov(c).setRules(r);
        }
        _elapse(600);
        uint256 b0 = reqs[CB];
        _setBudget(CA, 50e18); // cap 60 → 30 on 1301 (its Hub clamps B_A to 15 per id; B_B stays 30)
        _elapse(20 * 113);
        assertGe(reqs[CB] - b0, 4, "a lower to 11155111 for each of the 4 ids");
        uint256 p = _lasna();
        for (uint32 id = 1; id <= 4; ++id) {
            (uint96 abA,,,,, uint8 fA,) = rc.b6Of(address(ca), id, CA);
            (uint96 abB,,,,, uint8 fB,) = rc.b6Of(address(ca), id, CB);
            assertEq((fA | fB) & 1, 0, "answered on both chains");
            assertLe(uint256(abA) + abB, 30e18, "sum B per id within the tightened cap");
        }
        _leave(p);
    }
}
