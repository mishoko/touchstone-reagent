// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {VaultRead} from "../src/libraries/VaultRead.sol";
import {ICovenant, IReagentHub, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {MockRefPool} from "touchstone-test/utils/MockRefPool.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";

interface ISettle {
    function settle() external;
}

/// @notice F1-02's control: no exit rebase at a holding's opening (the r1 code).
contract CovenantNoRebase is Covenant {
    constructor(address e) Covenant(e) {}

    function _rebaseExit(address) internal override {}
}

/// @notice A-STALE (r12 D12-01) control: the exit pause predicate ignores k (any breach since the baseline pauses).
contract CovenantAnyBreach is Covenant {
    constructor(address e) Covenant(e) {}

    function _exitPaused(uint32 id) internal view override returns (bool) {
        address[] memory vs = HUB.idVaults(id);
        for (uint256 i; i < vs.length; ++i) {
            VaultBase memory b = _vb[vs[i]];
            if (_obs(vs[i]).breachSeq > b.baseSeq) return true;
        }
        return false;
    }
}

/// @notice A-STALE (r13 m-7) control: the B3 clause not seeing a vault gone by the exit's own processBreach.
contract CovenantNoB3 is Covenant {
    constructor(address e) Covenant(e) {}

    function _exitPaused(uint32 id) internal view override returns (bool) {
        if (HUB.paused(address(this), id)) return true;
        address[] memory vs = HUB.idVaults(id);
        uint256 sum;
        for (uint256 i; i < vs.length; ++i) {
            VaultBase memory b = _vb[vs[i]];
            if (!b.set) continue;
            uint32 seq = _obs(vs[i]).breachSeq;
            sum += seq > b.baseSeq ? seq - b.baseSeq : 0;
        }
        return sum >= _rules.k;
    }
}

/// @notice T-GUARD-B4's control: the pending reserve counted as current bond.
contract CovenantReserveIsBond is Covenant {
    constructor(address e) Covenant(e) {}

    function _bondNow(address vault) internal view override returns (uint256) {
        return VaultRead.bondWithReserve(vault);
    }
}

/// @notice T-GAS-EXIT's raised-limit control: the Hub forwards exactly NEED (the r1 `{gas: need}`).
contract HubForwardNeed is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _fwd(uint256 need) internal pure override returns (uint256) {
        return need;
    }
}

/// @notice A "Covenant" whose exit needs more than NEED (a padded path): it burns `pad` gas, then succeeds.
contract PaddedCovenant {
    address public owner;
    uint256 public immutable pad;
    uint256 public done;

    constructor(address o, uint256 p) {
        owner = o;
        pad = p;
    }

    function rcExit(address, uint64, uint32) external {
        uint256 g = gasleft();
        while (g - gasleft() < pad) {}
        done = 1;
    }
}

/// @notice F2-01 controls: the exit predicate without the per-vault "gone beyond the baseline" clause (MU-096).
contract CovenantGoneIgnoresBaseline is Covenant {
    constructor(address e) Covenant(e) {}

    function _exitPaused(uint32 id) internal view override returns (bool) {
        if (HUB.paused(address(this), id)) return true;
        address[] memory vs = HUB.idVaults(id);
        uint256 sum;
        for (uint256 i; i < vs.length; ++i) {
            VaultBase memory b = _vb[vs[i]];
            if (!b.set) continue;
            uint32 seq = _obs(vs[i]).breachSeq;
            sum += seq > b.baseSeq ? seq - b.baseSeq : 0;
            if (_rules.b3 && VaultRead.mode(vs[i]) == 2) return true;
        }
        return sum >= _rules.k;
    }
}

/// @notice F2-01 control: the vault check counting a gone state from before the baseline (MU-097).
contract CovenantTriggerIgnoresBaseline is Covenant {
    constructor(address e) Covenant(e) {}

    function _vaultTriggered(address vault) internal view override returns (bool) {
        return _obs(vault).breachSeq > _vb[vault].baseSeq || VaultRead.mode(vault) == 2;
    }
}

/// @notice F2-01 control: the exit predicate counting vaults with no baseline of this Covenant's (MU-098).
contract CovenantCountsUnbaselined is Covenant {
    constructor(address e) Covenant(e) {}

    function _exitPaused(uint32 id) internal view override returns (bool) {
        if (HUB.paused(address(this), id)) return true;
        address[] memory vs = HUB.idVaults(id);
        uint256 sum;
        for (uint256 i; i < vs.length; ++i) {
            VaultBase memory b = _vb[vs[i]];
            uint32 seq = _obs(vs[i]).breachSeq;
            sum += seq > b.baseSeq ? seq - b.baseSeq : 0;
            if (_rules.b3 && VaultRead.mode(vs[i]) == 2 && !b.baseGone) return true;
        }
        return sum >= _rules.k;
    }
}

/// @notice A "Covenant" whose plan deposit needs more than NEED (m-1).
contract PaddedPlanCovenant {
    address public owner;
    uint256 public immutable pad;
    uint256 public done;

    constructor(address o, uint256 p) {
        owner = o;
        pad = p;
    }

    function rcAllocate(address, uint32) external {
        uint256 g = gasleft();
        while (g - gasleft() < pad) {}
        done = 1;
    }
}

contract CellsTest is ReagentEnv {
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
        c.setAllowed(X2.vault, true);
        c.setAllowed(Y.vault, true);
        vm.stopPrank();
        V[] memory all = new V[](3);
        (all[0], all[1], all[2]) = (X, X2, Y);
        _keepAliveAll(all, 2 * tier.EPOCH);
    }

    function _swapIn(address code) internal {
        vm.etch(address(impl), code.code);
    }

    function _exitOutcomeOf(address vault) internal returns (uint8 o) {
        (,,, uint64 s) = hub.conduct(hub.vaultId(vault));
        vm.recordLogs();
        _exit(address(c), vault, s);
        (bytes memory d, bool f) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(f);
        (o,,) = _exitOutcome(d);
    }

    function _toEnd(V memory v) internal {
        uint256 end = _dripEnd(v);
        if (vm.getBlockNumber() < end) _keepAlive(v, end - vm.getBlockNumber() + 10);
    }

    function _replace(V memory v) internal {
        _keepAlive(v, 60);
        vm.prank(curatorOwner);
        v.bundler.setPositions(-1000, 1000, PreSwap(false, false, 0), 0, type(uint256).max);
        _keepAlive(v, 20);
    }

    function _breachProcessed(V memory v) internal {
        IVaultEntries(v.vault).poke();
        _latch(v, 1);
        _process(v);
        _backInRange(v);
        _keepAlive(v, 60);
    }

    // ================================================================== F1-01: per-vault cost basis (T-LEDGER)

    /// @notice T-LEDGER (s2 F1-01): leaving one vault of an id removes only that vault's cost from E(id).
    function test_T_LEDGER__leavingOneVaultCutsOnlyItsOwnCost() public {
        _alloc(c, X.vault, SH);
        uint128 ex = c.exposure(IDX);
        _alloc(c, X2.vault, SH);
        uint128 both = c.exposure(IDX);
        uint128 ex2 = both - ex;
        vm.prank(alice);
        c.leave(X.vault, type(uint256).max, 0, 0);
        assertEq(c.exposure(IDX), ex2, "E(id) = X2's own cost");
        vm.prank(alice);
        c.leave(X2.vault, SH / 2, 0, 0);
        assertApproxEqAbs(c.exposure(IDX), ex2 - ex2 / 2, 1, "a partial leave cuts its own cost pro rata");
        vm.prank(alice);
        c.leave(X2.vault, type(uint256).max, 0, 0);
        assertEq(c.exposure(IDX), 0);
    }

    // ================================================================== F1-02: exit rebase at a holding's opening (A-STALE)

    /// @notice A-STALE (s2 F1-02): a breach from before a deposit never arms that deposit's exit, even when the
    ///         vault's baseline was set earlier (an `unpause`, or a holding left and reopened).
    function test_A_STALE__aPreDepositBreachNeverArmsTheExit() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        vm.prank(alice);
        c.unpause(IDX); // baselines X2 before any allocation into it
        _breachProcessed(X2); // a breach on X2 before the deposit (1 < k)
        _replace(X2);
        _alloc(c, X2.vault, SH); // the deposit
        _alloc(c, X.vault, SH);
        _breachProcessed(X); // the id reaches k
        _conduct(IDX, 2, 0);
        _toEnd(X2);
        _toEnd(X);
        assertEq(_exitOutcomeOf(X2.vault), Outcome.STALE, "X2's breach predates its deposit");
        assertEq(_exitOutcomeOf(X.vault), Outcome.DONE, "X breached after its deposit: it exits");
    }

    function test_A_STALE__PC_withoutTheRebaseThePreDepositBreachWithdraws() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        vm.prank(alice);
        c.unpause(IDX);
        _breachProcessed(X2);
        _replace(X2);
        _swapIn(address(new CovenantNoRebase(address(ext))));
        _alloc(c, X2.vault, SH);
        _alloc(c, X.vault, SH);
        _breachProcessed(X);
        _conduct(IDX, 2, 0);
        _toEnd(X2);
        assertEq(_exitOutcomeOf(X2.vault), Outcome.DONE, "withdrawn on a pre-deposit breach");
    }

    /// @notice A-STALE (r7 D7-01): unpause → re-allocate → re-breach of the same vault → the pending exit runs.
    function test_A_STALE__unpauseReallocateRebreachRuns() public {
        _alloc(c, X.vault, SH);
        _breachProcessed(X);
        _conduct(IDX, 1, 0);
        _replace(X);
        vm.prank(alice);
        c.unpause(IDX);
        _alloc(c, X.vault, SH);
        _keepAlive(X, 2 * tier.EPOCH);
        _breachProcessed(X);
        _conduct(IDX, 2, 0);
        _toEnd(X);
        assertEq(_exitOutcomeOf(X.vault), Outcome.DONE);
    }

    /// @notice A-STALE (r12 D12-01): after unpause, at k = 2, a pending sub-k latch on V that the exit's own
    ///         `processBreach` processes (no new forfeit), with the old drip ended: nothing.
    function test_A_STALE__aPendingSubKLatchProcessedByTheExitDoesNothing() public {
        _subKSetup();
        assertEq(_exitOutcomeOf(X.vault), Outcome.STALE);
        assertEq(_obs(X).pendingBreaches, 0, "the exit processed it");
        assertEq(c.ledger(X.vault), SH);
    }

    function test_A_STALE__PC_aPredicateIgnoringKWithdraws() public {
        _subKSetup();
        _swapIn(address(new CovenantAnyBreach(address(ext))));
        uint8 o = _exitOutcomeOf(X.vault); // the exit's processBreach may forfeit new pay and restart the drip
        if (o == Outcome.EARLY) {
            _toEnd(X);
            o = _exitOutcomeOf(X.vault);
        }
        assertEq(o, Outcome.DONE, "a sub-k latch withdrew");
    }

    function _subKSetup() internal {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        _breachProcessed(X);
        _conduct(IDX, 1, 0);
        _replace(X);
        vm.prank(alice);
        c.unpause(IDX);
        _toEnd(X);
        _latch(X, 1); // pending, sub-k after the baseline
        _backInRange(X);
        _keepAlive(X, 60);
    }

    /// @notice A-STALE (r13 m-7): B3 on, k = 3; a third latch pending on V makes it EXITED when the exit processes
    ///         it: the exit must see the B3 pause it caused and run.
    function test_A_STALE__theB3PauseCausedByTheExitsProcessBreachRuns() public {
        _b3Setup();
        uint8 o = _exitOutcomeOf(X.vault);
        assertTrue(o != Outcome.STALE, "the B3 pause the exit's processBreach caused is seen");
        assertEq(_mode(X), 2, "EXITED");
        if (o == Outcome.EARLY) {
            _toEnd(X);
            o = _exitOutcomeOf(X.vault);
        }
        assertEq(o, Outcome.DONE, "gone by the exit's own processBreach: B3 exit");
    }

    function test_A_STALE__PC_aB3ClauseBlindToTheProcessedStateMissesTheExit() public {
        _b3Setup();
        _swapIn(address(new CovenantNoB3(address(ext))));
        assertEq(_exitOutcomeOf(X.vault), Outcome.STALE, "the legitimate exit is missed");
    }

    /// @dev k = 3 and the baseline after the first breach (`unpause`): B7 stays below k, so only B3 can pause.
    function _b3Setup() internal {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        for (uint256 k; k < 2; ++k) {
            _latch(X, 1);
            _process(X);
            _backInRange(X);
            _keepAlive(X, 30);
            if (k == 0) {
                vm.prank(alice);
                c.unpause(IDX); // baseline: one breach
            }
        }
        _toEnd(X);
        _latch(X, 1); // the third, pending: processing it makes X EXITED
        _backInRange(X);
        _keepAlive(X, 60);
    }

    // ================================================================== T-GUARD-B4 (D5-01, D6-01)

    function _dueReserve(uint256 bond0) internal returns (uint256 floor) {
        _replace(X); // a curator action: a reserve until its markout settles
        _keepAlive(X, 20); // due, unsettled
        floor = (bond0 + 1) / 2;
        uint256 hi = _ld(X.vault, SLOT_BOND) >> 128 << 128;
        vm.store(X.vault, bytes32(uint256(SLOT_BOND)), bytes32(hi | (floor - 1)));
    }

    function test_T_GUARD_B4__PC_theReserveCountedAsBondAllocatesBelowTheFloor() public {
        uint256 bond0 = uint128(_ld(X.vault, SLOT_BOND)) + uint128(_ld(X.vault, 20));
        _alloc(c, X.vault, SH);
        uint256 floor = _dueReserve(bond0);
        _swapIn(address(new CovenantReserveIsBond(address(ext))));
        uint128 l0 = c.ledger(X.vault);
        _alloc(c, X.vault, SH); // the optimistic read allocates where the real code refuses (the D5-01 cell)
        assertGt(c.ledger(X.vault), l0, "allocated with bondShares below the floor at the guard");
        floor;
    }

    function test_T_GUARD_B4__afterSettleTheDueReserveIsReleasedAndAllowed() public {
        uint256 bond0 = uint128(_ld(X.vault, SLOT_BOND)) + uint128(_ld(X.vault, 20));
        _alloc(c, X.vault, SH);
        uint256 floor = _dueReserve(bond0);
        ISettle(X.vault).settle(); // the open settlement releases (or burns) the reserve
        if (uint128(_ld(X.vault, SLOT_BOND)) >= floor) {
            _alloc(c, X.vault, SH); // released into the bond: allowed
        } else {
            vm.prank(alice);
            vm.expectRevert(CovenantBase.BondFloor.selector);
            c.allocate(X.vault, SH, type(uint256).max, type(uint256).max);
        }
    }

    // ================================================================== T-PLAN reasons and the gap roll

    function _plan(address vault, uint128 amount) internal {
        vm.prank(alice);
        c.setPlan(vault, amount);
    }

    function _planCall(address vault, uint32 e) internal returns (uint8 outcome, uint8 reason) {
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcAllocate{gas: 8_000_000}(RC, address(c), vault, e);
        (bytes memory d, bool f) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.PLAN);
        assertTrue(f);
        (,, outcome, reason) = abi.decode(d, (address, uint32, uint8, uint8));
    }

    function _roll(V memory v) internal returns (uint32 closed) {
        _keepAlive(v, tier.EPOCH);
        IVaultEntries(v.vault).poke();
        closed = uint32(_ld(v.vault, 8) >> 40) - 1;
    }

    /// @notice T-PLAN: every SKIPPED reason maps (2 B6, 4 stale ref, 5 slippage, 6 markout pending, 7 NavCap,
    ///         10 a fifth vault), and a gap roll (`EpochRecorded(old)`, `(old + 1)`) deposits once.
    function test_T_PLAN__everySkipReasonAndTheGapRoll() public {
        uint8 o;
        uint8 why;
        // 2: B6 (the plan's cost beyond B)
        _plan(X.vault, 0.5e18);
        _budget(address(c), IDX, 1, 1); // B lowered to E = 0 → clamped at 0
        (o, why) = _planCall(X.vault, _roll(X));
        assertEq(why, Outcome.SKIP_B6, "2");
        _budget(address(c), IDX, 3e18, 2);
        // 4: the reference cannot price the deposit
        X.ref.setMode(MockRefPool.Mode.Revert);
        (o, why) = _planCall(X.vault, _roll(X));
        assertEq(why, Outcome.SKIP_REF_STALE, "4");
        X.ref.setMode(MockRefPool.Mode.Ok);
        // 5: spot moved past TRYREF_TOL (the deposit would overpay at the reference)
        uint32 e5 = _roll(X);
        _swap(X, true, 6e17);
        (o, why) = _planCall(X.vault, e5);
        assertEq(why, Outcome.SKIP_SLIPPAGE, "5");
        _swap(X, false, 6e17);
        // 6: a curator action's markout pending
        uint32 e6 = _roll(X);
        _replaceNoWait(X);
        (o, why) = _planCall(X.vault, e6);
        assertEq(why, Outcome.SKIP_MARKOUT, "6");
        // the gap roll: two epochs pass with no entry; one poke emits EpochRecorded(old) and (old + 1)
        _keepAlive(X, 2 * tier.EPOCH + 30);
        vm.recordLogs();
        IVaultEntries(X.vault).poke();
        uint32 cur = uint32(_ld(X.vault, 8) >> 40);
        {
            Vm.Log[] memory pl = vm.getRecordedLogs();
            uint256 nOld;
            uint256 nGap;
            bytes32 er = 0x52ac8c0ec192dc514cc63f10118a6ba589667d3548a5ffcb0886465085529050;
            for (uint256 i; i < pl.length; ++i) {
                if (pl[i].emitter == X.vault && pl[i].topics[0] == er) {
                    uint32 e = uint32(uint256(pl[i].topics[1]));
                    if (e == cur - 2) ++nOld;
                    else if (e == cur - 1) ++nGap;
                    else fail();
                }
            }
            assertEq(nOld, 1, "the old epoch, once");
            assertEq(nGap, 1, "the gap record, once");
        }
        (uint8 o1,) = _planCall(X.vault, cur - 2);
        (uint8 o2,) = _planCall(X.vault, cur - 1);
        assertEq(o1, Outcome.DONE, "the first gap record deposits");
        assertEq(o2, Outcome.SKIPPED, "the second does not");
    }

    function _replaceNoWait(V memory v) internal {
        _keepAlive(v, 60);
        vm.prank(curatorOwner);
        v.bundler.setPositions(-1000, 1000, PreSwap(false, false, 0), 0, type(uint256).max);
    }

    /// @notice T-PLAN: reason 7 (Touchstone's NavCap) and reason 10 (a fifth vault).
    function test_T_PLAN__navCapAndAFifthVault() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.budget = 1e26;
        r.agentCapPerEpoch = 1e25;
        _setRules(c, r);
        _budget(address(c), IDX, type(uint128).max, 1);
        _plan(X.vault, 5_000e18); // far past 575 x the bond
        (, uint8 why) = _planCall(X.vault, _roll(X));
        assertEq(why, Outcome.SKIP_NAVCAP, "7");
        _plan(X.vault, 0);
        // 10: four holdings, then a plan into a fifth vault
        V memory z = _deployVault();
        V memory w = _deployVault();
        _bind(z.vault, 3);
        _bind(w.vault, IDX);
        V[] memory all = new V[](2);
        (all[0], all[1]) = (z, w);
        _keepAliveAll(all, 30);
        r.ids = [IDX, IDY, uint32(3), uint32(0)];
        vm.warp(vm.getBlockTimestamp() + 301);
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        _alloc(c, X2.vault, SH);
        _alloc(c, Y.vault, SH);
        _alloc(c, z.vault, SH);
        vm.prank(alice);
        c.setAllowed(w.vault, true);
        _plan(w.vault, 0.1e18);
        (, why) = _planCall(w.vault, _roll(w));
        assertEq(why, Outcome.SKIP_FIFTH_VAULT, "10");
    }

    // ================================================================== F1-03: NEED is a floor (T-GAS-EXIT)

    /// @notice T-GAS-EXIT (D2-01): a Covenant path that needs more than NEED succeeds when the RC raises the
    ///         gasLimit, because the Hub forwards everything above its reserve.
    function test_T_GAS_EXIT__aRaisedLimitReachesAPaddedCovenant() public {
        (uint256 needExit,) = hub.needs();
        PaddedCovenant p = new PaddedCovenant(alice, needExit + 200_000);
        vm.store(address(factory), keccak256(abi.encode(address(p), uint256(0))), bytes32(uint256(1)));
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcExit{gas: (needExit + 400_000) * 2}(RC, address(p), X.vault, 0, 0);
        assertEq(p.done(), 1, "the padded path ran");
        assertEq(_countNotes(vm.getRecordedLogs(), NoteKind.EXIT), 0, "no RELAY_FAILED");
    }

    function test_T_GAS_EXIT__PC_forwardingExactlyNeedStarvesThePaddedPath() public {
        (uint256 needExit,) = hub.needs();
        PaddedCovenant p = new PaddedCovenant(alice, needExit + 200_000);
        vm.store(address(factory), keccak256(abi.encode(address(p), uint256(0))), bytes32(uint256(1)));
        vm.prank(address(factory));
        HubForwardNeed h = new HubForwardNeed(RC);
        vm.etch(address(hub), address(h).code);
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcExit{gas: (needExit + 400_000) * 2}(RC, address(p), X.vault, 0, 0);
        assertEq(p.done(), 0);
        (bytes memory d, bool f) = _lastNote(vm.getRecordedLogs(), address(p), NoteKind.EXIT);
        assertTrue(f);
        (uint8 o,,) = _exitOutcome(d);
        assertEq(o, Outcome.RELAY_FAILED, "starved at NEED");
    }

    // ================================================================== F1-04: self-call guards (A-COV-AUTH)

    /// @notice A-COV-AUTH: the self-call entry points refuse every outsider (the owner included), and the
    ///         Covenant can never be its own agent.
    function test_A_COV_AUTH__selfCallEntriesRefuseOutsiders() public {
        _alloc(c, X.vault, SH);
        address[2] memory who = [makeAddr("eve"), alice];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(CovenantBase.Self.selector);
            Covenant(payable(address(c))).exitWithdraw(X.vault);
            vm.expectRevert(CovenantBase.Self.selector);
            Covenant(payable(address(c))).planDeposit(X.vault, 1e18);
            vm.stopPrank();
        }
        vm.prank(alice);
        vm.expectRevert(CovenantBase.Self.selector);
        c.setAgent(address(c));
        assertEq(c.ledger(X.vault), SH);
    }

    // ================================================================== F1-06: a starved emitState is not silent (T-GAS-BUDGET)

    /// @notice T-GAS-BUDGET (F1-06): an `rcBudget` whose STATE cannot be emitted answers `Stale(6)`.
    function test_T_GAS_BUDGET__aStarvedStateAnswerIsNotSilent() public {
        vm.mockCallRevert(address(c), abi.encodeWithSelector(ICovenant.emitState.selector), "");
        vm.recordLogs();
        _budget(address(c), IDX, 2e18, 1);
        Vm.Log[] memory l = vm.getRecordedLogs();
        assertEq(_count(l, BUDGET_TOPIC), 1);
        assertEq(_count(l, STALE_TOPIC), 1, "Stale(6)");
    }

    // ================================================================== F2-01: the baseline clauses of the exit (A-STALE)

    function _exitedBy3(V memory v) internal {
        for (uint256 k; k < 3; ++k) {
            _latch(v, 1);
            _process(v);
            _backInRange(v);
            _keepAlive(v, 30);
        }
        require(_mode(v) == 2, "EXITED");
    }

    function _siblingGoneAtBaseline() internal {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        _alloc(c, X2.vault, SH);
        _exitedBy3(X2);
        _conduct(IDX, 3, 1);
        vm.prank(alice);
        c.unpause(IDX); // the Hub baseline (3, 1); X2 gone at its baseline
        _breachProcessed(X);
        _conduct(IDX, 4, 1);
        _toEnd(X);
    }

    /// @notice A-STALE (s2 F2-01): a sibling already gone at the owner's unpause does not pause the id again.
    function test_A_STALE__aSiblingGoneAtTheBaselineDoesNotPause() public {
        _siblingGoneAtBaseline();
        assertEq(_exitOutcomeOf(X.vault), Outcome.STALE);
    }

    function test_A_STALE__PC_goneIgnoringTheBaselineWithdraws() public {
        _siblingGoneAtBaseline();
        _swapIn(address(new CovenantGoneIgnoresBaseline(address(ext))));
        assertEq(_exitOutcomeOf(X.vault), Outcome.DONE, "withdrawn while unpaused");
    }

    function _vGoneAtBaseline() internal {
        _alloc(c, X.vault, SH);
        _alloc(c, X2.vault, SH);
        _exitedBy3(X);
        _conduct(IDX, 3, 1);
        vm.prank(alice);
        c.unpause(IDX); // X gone at its baseline
        _breachProcessed(X2); // the sibling reaches k = 1 since the baseline
        _conduct(IDX, 4, 1);
        _toEnd(X);
    }

    /// @notice A-STALE (s2 F2-01): V gone at the baseline is not "a breach or gone event since the baseline".
    function test_A_STALE__aVaultGoneAtItsBaselineIsNotTriggered() public {
        _vGoneAtBaseline();
        assertEq(_exitOutcomeOf(X.vault), Outcome.STALE);
    }

    function test_A_STALE__PC_aTriggerIgnoringTheBaselineWithdraws() public {
        _vGoneAtBaseline();
        _swapIn(address(new CovenantTriggerIgnoresBaseline(address(ext))));
        assertEq(_exitOutcomeOf(X.vault), Outcome.DONE, "withdrawn on a gone state from before the baseline");
    }

    function _boundAfterUnpause() internal {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        V memory w = _deployVault(); // not yet bound
        _keepAlive(w, 2 * tier.EPOCH);
        _breachProcessed(w);
        _conduct(IDX, 1, 0); // the RC counted W's breach
        vm.prank(alice);
        c.unpause(IDX); // baseline (1, 0); W not bound, so no local baseline for it
        _bind(w.vault, IDX); // W's binding lands late
        _breachProcessed(X);
        _conduct(IDX, 2, 0); // 2 - 1 < k: not paused
        _toEnd(X);
    }

    /// @notice A-STALE (s2 F1-08, F2-01): a vault bound after the unpause, with an older breach, is counted by the
    ///         mirror only: one new breach on V at k = 2 does nothing.
    function test_A_STALE__aVaultBoundAfterTheUnpauseIsCountedByTheMirrorOnly() public {
        _boundAfterUnpause();
        assertEq(_exitOutcomeOf(X.vault), Outcome.STALE);
    }

    function test_A_STALE__PC_countingUnbaselinedVaultsWithdraws() public {
        _boundAfterUnpause();
        _swapIn(address(new CovenantCountsUnbaselined(address(ext))));
        assertEq(_exitOutcomeOf(X.vault), Outcome.DONE, "the late vault's old breach counted");
    }

    // ================================================================== m-1: the plan's forward is a floor too (T-GAS-PLAN)

    function test_T_GAS_PLAN__aRaisedLimitReachesAPaddedPlan() public {
        (, uint256 needPlan) = hub.needs();
        PaddedPlanCovenant p = new PaddedPlanCovenant(alice, needPlan + 200_000);
        vm.store(address(factory), keccak256(abi.encode(address(p), uint256(0))), bytes32(uint256(1)));
        vm.prank(PROXY);
        hub.rcAllocate{gas: (needPlan + 400_000) * 2}(RC, address(p), X.vault, 0);
        assertEq(p.done(), 1);
    }

    function test_T_GAS_PLAN__PC_forwardingExactlyNeedStarvesThePaddedPlan() public {
        (, uint256 needPlan) = hub.needs();
        PaddedPlanCovenant p = new PaddedPlanCovenant(alice, needPlan + 200_000);
        vm.store(address(factory), keccak256(abi.encode(address(p), uint256(0))), bytes32(uint256(1)));
        vm.prank(address(factory));
        HubForwardNeed h = new HubForwardNeed(RC);
        vm.etch(address(hub), address(h).code);
        vm.prank(PROXY);
        hub.rcAllocate{gas: (needPlan + 400_000) * 2}(RC, address(p), X.vault, 0);
        assertEq(p.done(), 0, "starved at NEED");
    }
}
