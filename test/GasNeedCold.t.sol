// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {GasNeedBase} from "./GasNeed.t.sol";
import {ICovenant, IReagentHub} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice F-011 (s4): `vm.cool` cools an account but not its storage slots (forge 1.5.0, `test/F011Cool.t.sol`),
///         so a need measured after a worst-state build in the same test body under-prices every slot the build
///         touched. Here the worst state is built in `setUp` (committed), and the test body is a new transaction:
///         the delivery at the formula gasLimit runs FIRST, every account and slot cold, original = committed; the
///         minimum is searched from a snapshot taken at the body's start (each probe reverts to that cold state).
contract GasNeedColdExitTest is GasNeedBase {
    function setUp() public override {
        super.setUp();
        _exitWorstState();
    }

    /// @notice T-GAS-EXIT, cold: DONE at the formula gasLimit as the first call of a transaction, and the Hub's
    ///         NEED ≥ 1.3 × the cold minimum of the Covenant's exit at the worst case.
    function test_T_GAS_EXIT__coldDoneAtTheFormulaLimitAndNeedCoversTheColdMinimum() public {
        (uint256 needExit,) = hub.needs();
        uint256 snap = vm.snapshotState();
        bytes memory d = abi.encodeCall(IReagentHub.rcExit, (RC, address(c), X.vault, seq, 1));
        assertTrue(_exitDone(_deliver(d, _entry(_gasLimit(needExit)))), "DONE at the formula gasLimit, cold");
        vm.revertToState(snap);
        bytes memory cd = abi.encodeCall(ICovenant.rcExit, (X.vault, seq, 1));
        Need memory n = _search(address(hub), address(c), cd, _exitDone);
        console2.log("rcExit cold minimum entry", n.entry, "NEED", needExit);
        assertGe(needExit, n.entry * 13 / 10, "NEED >= 1.3 x the cold minimum");
        _freshCount(address(hub), address(c), cd, n); // last: a state diff makes later calls cheaper
        if (_chain() == 1301) _record("rcExit", n);
    }
}

contract GasNeedColdPlanTest is GasNeedBase {
    uint32 internal planE;

    function setUp() public override {
        super.setUp();
        vm.prank(owner2);
        c.leave(Z.vault, type(uint256).max, 0, 0);
        vm.startPrank(owner2);
        c.setAllowed(X3.vault, true);
        c.setPlan(X3.vault, 0.1e18);
        vm.stopPrank();
        _toEpochBoundary(X3);
        IVaultEntries(X3.vault).poke();
        planE = uint32(_ld(X3.vault, 8) >> 40) - 1;
    }

    /// @notice T-GAS-PLAN, cold: DONE at the formula gasLimit first in the transaction; NEED ≥ 1.3 × the cold minimum.
    function test_T_GAS_PLAN__coldDoneAtTheFormulaLimitAndNeedCoversTheColdMinimum() public {
        (, uint256 needPlan) = hub.needs();
        uint256 snap = vm.snapshotState();
        bytes memory d = abi.encodeCall(IReagentHub.rcAllocate, (RC, address(c), X3.vault, planE));
        assertTrue(_planDone(_deliver(d, _entry(_gasLimit(needPlan)))), "DONE at the formula gasLimit, cold");
        vm.revertToState(snap);
        bytes memory pd = abi.encodeCall(ICovenant.rcAllocate, (X3.vault, planE));
        Need memory n = _search(address(hub), address(c), pd, _planDone);
        console2.log("rcAllocate cold minimum entry", n.entry, "NEED", needPlan);
        assertGe(needPlan, n.entry * 13 / 10, "NEED >= 1.3 x the cold minimum");
        _freshCount(address(hub), address(c), pd, n); // last
        if (_chain() == 1301) _record("rcAllocate", n);
    }
}

/// @notice T-GAS-BUDGET, cold (F-010 H2-01): the Covenant's rulesNonce is read in setUp, so the search is the body's
///         first state-touching step; `emitState` at 4 holdings and 4 Bases.
contract GasNeedColdBudgetTest is GasNeedBase {
    uint64 internal rn;

    function setUp() public override {
        super.setUp();
        rn = c.rulesNonce();
    }

    function test_T_GAS_BUDGET__coldAnswersWithStateAndNeedCoversTheColdMinimum() public {
        bytes memory d = abi.encodeCall(IReagentHub.rcBudget, (RC, address(c), 4, 2e18, 1, rn));
        Need memory n = _search(PROXY, address(hub), d, _budgetAnswered);
        console2.log("rcBudget cold minimum entry", n.entry, "NEED", NEED_BUDGET);
        assertGe(NEED_BUDGET, n.entry * 13 / 10, "NEED >= 1.3 x the cold minimum");
        uint256 snap = vm.snapshotState();
        assertTrue(_budgetAnswered(_deliver(d, _entry(_gasLimit(NEED_BUDGET)))), "answered at the formula gasLimit");
        vm.revertToState(snap);
        _freshCount(PROXY, address(hub), d, n);
        if (_chain() == 1301) _record("rcBudget", n);
    }
}

/// @notice The cold rows at chain id 11155111 (the Hub selects its Sepolia NEEDs): a cancun-priced floor check
///         beside the binding method-(a) twins (`sepgas.py`; F-010 H2-02).
contract GasNeedColdExitSepoliaTest is GasNeedColdExitTest {
    function _chain() internal pure override returns (uint256) {
        return 11155111;
    }
}

contract GasNeedColdPlanSepoliaTest is GasNeedColdPlanTest {
    function _chain() internal pure override returns (uint256) {
        return 11155111;
    }
}
