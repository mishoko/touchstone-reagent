// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {ICovenant, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";

/// @notice A-B6-CLAWBACK's first positive control: the clamp at exposure removed (a lower goes below spent E).
contract HubNoClamp is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _lowered(uint128, uint128 newB, uint128) internal pure override returns (uint128) {
        return newB;
    }
}

/// @notice A-B6-CLAWBACK's second positive control: `max(newB, E)` applied as a raise (above the current B).
contract HubMaxAsRaise is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _lowered(uint128, uint128 newB, uint128 e) internal pure override returns (uint128) {
        return newB > e ? newB : e;
    }
}

/// @notice A-TIGHTEN-RESPLIT's positive control: `max` instead of `min` in the local re-split.
contract HubSyncMax is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _syncLower(uint128 b, uint128 maxB) internal pure override returns (uint128) {
        return b > maxB ? b : maxB;
    }
}

/// @notice T-HUB-BUDGET's re-entry control: the `listed` bit ignored (a re-added id resurrects the default).
contract HubIgnoreListed is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _wasListed(Bud storage) internal pure override returns (bool) {
        return false;
    }
}

/// @notice A-COV-AUTH's positive control: a Covenant that takes `rcExit` from anyone.
contract CovenantAnyCaller is Covenant {
    constructor(address e) Covenant(e) {}

    function _checkHub() internal view override {}
}

/// @notice B6 on one chain (spec §5.2 rcBudget/syncRules, PB-3; I-CAP (c), I-B6SUM first clause), on a real Touchstone.
///         The RC's side (raises at rest, safety lowers) is R-B6SCHED in s3; here each RC message is delivered by hand.
contract BudgetTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23;
    uint64 internal nonce;

    function setUp() public {
        _setUpReagent(1301);
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY)); // cap = 6e18, B = 3e18 per id by default
        vm.startPrank(alice);
        c.setAgent(agentKey);
        c.setAllowed(X.vault, true);
        vm.stopPrank();
    }

    function _b(uint32 id) internal view returns (uint128 b) {
        (b,,) = hub.budget(address(c), id);
    }

    function _rcBudget(uint32 id, uint128 b) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        _budget(address(c), id, b, ++nonce);
        logs = vm.getRecordedLogs();
    }

    function _swapHub(address code) internal {
        vm.etch(address(hub), code.code);
    }

    function _deployAsFactory(bytes memory code) internal returns (address a) {
        vm.prank(address(factory));
        assembly {
            a := create(0, add(code, 32), mload(code))
        }
    }

    // ================================================================== T-HUB-BUDGET

    /// @notice T-HUB-BUDGET: a first-listed id reads cap/2; a lower is clamped at spent exposure; a raise applies; an
    ///         id outside `ids` is answered at the unchanged B with the nonce consumed and a STATE; a rulesNonce
    ///         mismatch is answered the same way (r21 D21-02); a non-factory Covenant is Stale(2); none reverts.
    function test_T_HUB_BUDGET__defaultsClampAnswersAndGates() public {
        assertEq(_b(IDX), 3e18, "first listing: cap/2");
        _alloc(c, X.vault, SH);
        uint128 e = c.exposure(IDX);
        _rcBudget(IDX, 1); // a lower below E
        assertEq(_b(IDX), e, "clamped at spent exposure");
        _rcBudget(IDX, 4e18); // a raise
        assertEq(_b(IDX), 4e18);
        // an id outside ids: answered at the unchanged (derived) B, nonce consumed, STATE emitted
        Vm.Log[] memory logs = _rcBudget(7, 1e18);
        assertEq(_count(logs, BUDGET_TOPIC), 1, "answered");
        assertEq(_countNotes(logs, NoteKind.STATE), 1, "the unlimited STATE");
        (, uint64 n7,) = hub.budget(address(c), 7);
        assertEq(n7, nonce, "nonce consumed");
        // a rules mismatch with a fresh nonce: BudgetApplied at the unchanged B and the current r, one STATE
        uint64 r = c.rulesNonce();
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcBudget(RC, address(c), IDX, 1e18, ++nonce, r + 7);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, BUDGET_TOPIC), 1);
        assertEq(_countNotes(logs, NoteKind.STATE), 1);
        assertEq(_b(IDX), 4e18, "unchanged");
        (, uint64 nx,) = hub.budget(address(c), IDX);
        assertEq(nx, nonce, "consumed");
        // a non-factory address: Stale(2), no Covenant read
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcBudget(RC, address(0xBAD), IDX, 1, ++nonce, 0);
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1);
    }

    /// @notice T-HUB-BUDGET (r24 D24-01, r25 D25-02, r26 D26-01): remove an id, leave to E = 0, re-add → B = 0
    ///         (the derived value is written at re-entry; the default never comes back).
    function test_T_HUB_BUDGET__removeLeaveReaddReadsZero() public {
        _alloc(c, X.vault, SH);
        _setRules(c, _rules(IDY, 0)); // X's id removed (its exposure stays reported)
        assertEq(_b(IDX), c.exposure(IDX), "outside ids: derived min(B, E)");
        vm.prank(alice);
        c.leave(X.vault, type(uint256).max, 0, 0);
        assertEq(_b(IDX), 0, "E = 0: derived 0");
        vm.warp(vm.getBlockTimestamp() + 301);
        _setRules(c, _rules(IDX, IDY)); // re-added
        assertEq(_b(IDX), 0, "re-adding never raises: 0, not cap/2");
    }

    function test_T_HUB_BUDGET__PC_ignoringTheListedBitResurrectsTheDefault() public {
        _alloc(c, X.vault, SH);
        _setRules(c, _rules(IDY, 0));
        vm.prank(alice);
        c.leave(X.vault, type(uint256).max, 0, 0);
        _swapHub(_deployAsFactory(abi.encodePacked(type(HubIgnoreListed).creationCode, abi.encode(RC))));
        vm.warp(vm.getBlockTimestamp() + 301);
        _setRules(c, _rules(IDX, IDY));
        assertEq(_b(IDX), 3e18, "the re-entry got cap/2 back");
    }

    // ================================================================== A-B6-CLAWBACK, I-B6SUM (first clause)

    /// @notice A-B6-CLAWBACK (1): a lower below spent exposure is clamped at E, so the other chain's raise to
    ///         cap − B_A keeps Σ E ≤ cap.
    function test_A_B6_CLAWBACK__aLowerNeverGoesBelowSpentExposure() public {
        _alloc(c, X.vault, SH * 5);
        uint128 e = c.exposure(IDX);
        _rcBudget(IDX, e / 2);
        assertGe(_b(IDX), e, "I-B6SUM: E <= B on this chain");
        uint256 otherRaise = 6e18 - _b(IDX); // what the RC may then give the other chain
        assertLe(uint256(e) + otherRaise, 6e18, "sum E <= cap");
    }

    function test_A_B6_CLAWBACK__PC_withoutTheClampSumExceedsTheCap() public {
        _alloc(c, X.vault, SH * 5);
        uint128 e = c.exposure(IDX);
        _swapHub(_deployAsFactory(abi.encodePacked(type(HubNoClamp).creationCode, abi.encode(RC))));
        _rcBudget(IDX, e / 2);
        assertLt(_b(IDX), e, "B below spent exposure");
        uint256 otherRaise = 6e18 - _b(IDX);
        assertGt(uint256(e) + otherRaise, 6e18, "sum E > cap once the other chain spends its raise");
    }

    /// @notice A-B6-CLAWBACK (2): a tighten below E, an RC lower, a `leave`, then an agent allocation: the agent
    ///         stays within the tightened cap.
    function test_A_B6_CLAWBACK__afterATightenTheAgentStaysWithinTheCap() public {
        _alloc(c, X.vault, SH * 5);
        uint128 e = c.exposure(IDX);
        Rulebook memory r = _rules(IDX, IDY);
        r.budget = uint128(uint256(e) * 2 * 10_000 / 6_000 / 2); // cap'/2 = E/2
        r.agentCapPerEpoch = r.budget / 10;
        vm.prank(agentKey);
        c.tighten(r);
        uint128 half = _b(IDX);
        assertLt(half, e, "the local re-split may go below E");
        _rcBudget(IDX, half);
        vm.prank(alice);
        c.leave(X.vault, SH * 4, 0, 0); // E falls to E/5
        uint256 room = uint256(_b(IDX)) - c.exposure(IDX);
        vm.prank(agentKey);
        vm.expectRevert(); // any allocation worth more than the room is refused (B6 or the agent cap)
        c.agentAllocate(X.vault, SH * 5, type(uint256).max, type(uint256).max);
        assertLe(c.exposure(IDX), _b(IDX), "E <= B");
        room;
    }

    function test_A_B6_CLAWBACK__PC_maxAsARaiseLetsTheAgentPastTheTightenedCap() public {
        _alloc(c, X.vault, SH * 5);
        uint128 e = c.exposure(IDX);
        Rulebook memory r = _rules(IDX, IDY);
        r.budget = uint128(uint256(e) * 2 * 10_000 / 6_000 / 2);
        r.agentCapPerEpoch = r.budget / 10;
        vm.prank(agentKey);
        c.tighten(r);
        uint128 half = _b(IDX);
        _swapHub(_deployAsFactory(abi.encodePacked(type(HubMaxAsRaise).creationCode, abi.encode(RC))));
        _rcBudget(IDX, half); // "lower" to the tightened half: max(newB, E) raises B to E
        assertGt(_b(IDX), half, "B raised above the tightened cap/2");
    }

    // ================================================================== A-TIGHTEN-RESPLIT

    /// @notice A-TIGHTEN-RESPLIT: with skewed budgets (this chain raised to 5 of a 6 cap), a tighten to cap' = 2
    ///         lowers this chain's B to min(B, cap'/2) at once; with the RC's lower of the other chain delivered,
    ///         Σ B ≤ max(cap', Σ E).
    function test_A_TIGHTEN_RESPLIT__aTightenLowersThisChainAtOnce() public {
        _rcBudget(IDX, 5e18); // skewed: this chain 5, the other 1
        uint128 otherB = 1e18;
        Rulebook memory r = _rules(IDX, IDY);
        r.budget = uint128(uint256(2e18) * 10_000 / 6_000); // cap' ≈ 2e18
        r.agentCapPerEpoch = r.budget / 10;
        vm.prank(agentKey);
        c.tighten(r);
        uint256 capP = uint256(r.maxShareBps) * r.budget / 10_000;
        assertLe(_b(IDX), capP / 2, "min(B, cap'/2) on this chain");
        uint256 otherAfter = otherB < capP - _b(IDX) ? otherB : capP - _b(IDX); // the RC's lower on the other chain
        assertLe(uint256(_b(IDX)) + otherAfter, capP, "sum B <= cap' at quiescence");
    }

    function test_A_TIGHTEN_RESPLIT__PC_maxInsteadOfMinKeepsTheSumAboveTheCap() public {
        _rcBudget(IDX, 5e18);
        _swapHub(_deployAsFactory(abi.encodePacked(type(HubSyncMax).creationCode, abi.encode(RC))));
        Rulebook memory r = _rules(IDX, IDY);
        r.budget = uint128(uint256(2e18) * 10_000 / 6_000);
        r.agentCapPerEpoch = r.budget / 10;
        vm.prank(agentKey);
        c.tighten(r);
        uint256 capP = uint256(r.maxShareBps) * r.budget / 10_000;
        assertGt(_b(IDX), capP, "this chain alone keeps more than cap'");
    }

    // ================================================================== A-COV-AUTH

    /// @notice A-COV-AUTH: a direct `rcExit`/`rcAllocate`/`emitState` on a Covenant reverts; a Hub relaying to a
    ///         non-factory "Covenant" is Stale(3) with no call.
    function test_A_COV_AUTH__onlyItsHubReachesTheCallbacks() public {
        _alloc(c, X.vault, SH);
        _latch(X, 1);
        _process(X);
        _conduct(IDX, 1, 0);
        _backInRange(X);
        _keepAlive(X, tier.FORFEIT_DRIP_BLOCKS + 60);
        address eve = makeAddr("eve");
        vm.startPrank(eve);
        vm.expectRevert(CovenantBase.NotHub.selector);
        c.rcExit(X.vault, 0, 0);
        vm.expectRevert(CovenantBase.NotHub.selector);
        c.rcAllocate(X.vault, 0);
        vm.expectRevert(CovenantBase.NotHub.selector);
        c.emitState();
        vm.stopPrank();
        assertEq(c.ledger(X.vault), SH, "nothing withdrawn");
        vm.recordLogs();
        _exit(address(new FakeCovenant()), X.vault, 0);
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1, "a non-factory Covenant is never called");
    }

    function test_A_COV_AUTH__PC_withoutTheHubCheckAnyoneTriggersTheExit() public {
        _alloc(c, X.vault, SH);
        _latch(X, 1);
        _process(X);
        _conduct(IDX, 1, 0);
        _backInRange(X);
        _keepAlive(X, tier.FORFEIT_DRIP_BLOCKS + 60);
        vm.etch(address(impl), address(new CovenantAnyCaller(address(ext))).code);
        vm.prank(makeAddr("eve"));
        c.rcExit(X.vault, 0, 0);
        assertEq(c.ledger(X.vault), 0, "an outsider triggered the withdrawal");
    }
}

contract FakeCovenant {
    function rcExit(address, uint64, uint32) external pure {
        revert("must never be called");
    }
}
