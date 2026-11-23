// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {CovenantFactory} from "../src/CovenantFactory.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {ICovenant, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";
import {MockRefPool} from "touchstone-test/utils/MockRefPool.sol";

/// @notice A-IDSPOOF's positive control: the id taken from a caller's word (here, always Y's) instead of the Hub's
///         binding.
contract CovenantCallerId is Covenant {
    constructor(address e) Covenant(e) {}

    function _idOf(address) internal pure override returns (uint32) {
        return 2;
    }
}

/// @notice A-AGENT-LOOSEN's positive control: the monotone check removed.
contract ExtNoMonotone is CovenantExt {
    function _looser(Rulebook calldata, Rulebook memory) internal pure override returns (bool) {
        return false;
    }
}

/// @notice The local guard inside every allocate path (spec §3.2, PA-1; C-01), on a real Touchstone.
contract GuardTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23; // ≈ 0.2 mWETH of shares at the seed price

    function setUp() public {
        _setUpReagent(1301);
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
        vm.prank(alice);
        c.setAgent(agentKey);
        vm.startPrank(alice);
        c.setAllowed(X.vault, true);
        c.setAllowed(X2.vault, true);
        c.setAllowed(Y.vault, true);
        vm.stopPrank();
    }

    function _agentAlloc(address vault, uint256 shares) internal {
        vm.prank(agentKey);
        c.agentAllocate(vault, shares, type(uint256).max, type(uint256).max);
    }

    function _expectOwner(address vault, bytes4 err) internal {
        vm.prank(alice);
        vm.expectRevert(err);
        c.allocate(vault, SH, type(uint256).max, type(uint256).max);
    }

    function _expectAgent(address vault, bytes4 err) internal {
        vm.prank(agentKey);
        vm.expectRevert(err);
        c.agentAllocate(vault, SH, type(uint256).max, type(uint256).max);
    }

    /// @notice The plan path: a plan on `vault`, then the RC's `rcAllocate` for the epoch that just closed.
    function _planSkip(address vault) internal returns (uint8 outcome, uint8 reason) {
        vm.prank(alice);
        c.setPlan(vault, 0.1e18);
        uint32 cur = _epochOf(vault);
        if (cur == 0) {
            V memory v = vault == X.vault ? X : vault == X2.vault ? X2 : Y;
            _keepAlive(v, tier.EPOCH);
            ICovenantPoke(vault).poke();
            cur = _epochOf(vault);
        }
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcAllocate{gas: 5_000_000}(RC, address(c), vault, cur - 1);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.PLAN);
        assertTrue(found, "a PLAN note");
        (,, outcome, reason) = abi.decode(d, (address, uint32, uint8, uint8));
    }

    function _epochOf(address vault) internal view returns (uint32) {
        return uint32(_ld(vault, 8) >> 40);
    }

    // ================================================================== T-COV-CREATE

    /// @notice T-COV-CREATE: CREATE2 address, owner = caller, the admin-only allowlist.
    function test_T_COV_CREATE__create2OwnerAndAdminAllowlist() public {
        address bob = makeAddr("bob");
        vm.prank(bob);
        vm.expectRevert(CovenantFactory.NotAllowed.selector);
        factory.create();
        vm.prank(bob);
        vm.expectRevert(CovenantFactory.NotAdmin.selector);
        factory.allow(bob, true); // an outsider cannot allowlist itself
        vm.prank(admin);
        factory.allow(bob, true);
        address predicted = factory.predict(bob);
        vm.prank(bob);
        address cb = factory.create();
        assertEq(cb, predicted, "CREATE2 at salt = owner");
        assertEq(ICovenant(cb).owner(), bob, "owner = caller");
        assertTrue(factory.isCovenant(cb));
        assertFalse(factory.isCovenant(address(impl)), "the implementation is not a Covenant");
        vm.prank(bob);
        vm.expectRevert(); // one Covenant per owner per factory (the CREATE2 address is taken)
        factory.create();
        // the implementation and a live clone cannot be re-initialised
        vm.expectRevert(CovenantBase.Initialized.selector);
        impl.initialize(bob, hub);
        vm.expectRevert(CovenantBase.Initialized.selector);
        Covenant(payable(cb)).initialize(makeAddr("thief"), hub);
    }

    // ================================================================== T-GUARD-MODE

    /// @notice T-GUARD-MODE: allocation refused in BREACHED and EXITED on all three paths; the NORMAL twin allowed.
    function test_T_GUARD_MODE__refusedOutsideNormalOnEveryPath() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3; // isolate the mode check from B7
        r.b3 = false;
        _setRules(c, r);
        _alloc(c, X.vault, SH); // NORMAL: allowed
        _agentAlloc(X2.vault, SH / 10); // NORMAL twin, agent: allowed
        _age(X, 2 * tier.EPOCH);
        _latch(X, 1);
        _process(X); // BREACHED
        assertEq(_mode(X), 1);
        _backInRange(X);
        _expectOwner(X.vault, CovenantBase.ModeNotNormal.selector);
        _expectAgent(X.vault, CovenantBase.ModeNotNormal.selector);
        (uint8 o, uint8 why) = _planSkip(X.vault);
        assertEq(o, Outcome.SKIPPED);
        assertEq(why, Outcome.SKIP_PAUSED, "plan: paused");
        // EXITED (retired): refused too
        vm.prank(curatorOwner);
        Y.bundler.retire();
        assertEq(_mode(Y), 2);
        _expectOwner(Y.vault, CovenantBase.ModeNotNormal.selector);
    }

    // ================================================================== T-GUARD-B7, T-GUARD-SIBLING, T-GUARD-PEND

    /// @notice T-GUARD-B7: refused at breaches − baseline ≥ k on the id's vaults, allowed below.
    function test_T_GUARD_B7__refusedAtKAllowedBelow() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 2;
        _setRules(c, r);
        _latch(X2, 1);
        _process(X2);
        _backInRange(X2);
        _alloc(c, X.vault, SH); // 1 < k = 2: allowed
        _keepAlive(X2, 30);
        _latch(X2, 1);
        _process(X2);
        _expectOwner(X.vault, CovenantBase.RecordPaused.selector); // 2 >= k
        _expectAgent(X.vault, CovenantBase.RecordPaused.selector);
    }

    /// @notice T-GUARD-SIBLING: a breach on one bound vault of an id refuses allocation to its sibling at once.
    function test_T_GUARD_SIBLING__aBreachOnOneVaultRefusesItsSibling() public {
        _alloc(c, X.vault, SH);
        _latch(X2, 1); // latched on the sibling, not yet processed
        _expectOwner(X.vault, CovenantBase.Pending.selector);
        _process(X2);
        _expectOwner(X.vault, CovenantBase.RecordPaused.selector); // k = 1
        _alloc(c, Y.vault, SH); // another curator: unaffected
    }

    /// @notice T-GUARD-PEND: refused while any bound vault of the id has a pending breach.
    function test_T_GUARD_PEND__refusedWhilePending() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        _setRules(c, r);
        _latch(X, 1);
        assertGt(_obs(X).pendingBreaches, 0);
        assertEq(_mode(X), 0, "still NORMAL: only the pending breach refuses");
        _expectOwner(X.vault, CovenantBase.Pending.selector);
        _expectAgent(X.vault, CovenantBase.Pending.selector);
    }

    // ================================================================== T-GUARD-B3

    /// @notice T-GUARD-B3: a sibling EXITED or retired refuses the id (B3 on); allowed with B3 off.
    function test_T_GUARD_B3__refusedAfterASiblingIsGone() public {
        vm.prank(curatorOwner);
        X2.bundler.retire();
        _expectOwner(X.vault, CovenantBase.Gone.selector);
        Rulebook memory r = _rules(IDX, IDY);
        r.b3 = false;
        _setRules(c, r);
        _alloc(c, X.vault, SH); // B3 off: allowed
    }

    // ================================================================== T-GUARD-B4

    /// @notice T-GUARD-B4: refused below the bond floor (50% of the bond at the first allocation), allowed at it.
    ///         The burn itself is Touchstone's charge path (FeeBank, tested upstream); slot 17 is set to the
    ///         post-burn bond here.
    function test_T_GUARD_B4__refusedBelowTheBondFloorAllowedAtIt() public {
        uint256 bond0 = _bondTotal(X); // as the Covenant reads it at its first allocation (before the prologue)
        _alloc(c, X.vault, SH);
        uint256 reserve = uint128(_ld(X.vault, 20));
        uint256 hi = _ld(X.vault, SLOT_BOND) >> 128 << 128;
        vm.store(X.vault, bytes32(uint256(SLOT_BOND)), bytes32(hi | ((bond0 + 1) / 2 - reserve)));
        _alloc(c, X.vault, SH); // exactly at the 50% floor (rounded up): allowed
        reserve = uint128(_ld(X.vault, 20));
        hi = _ld(X.vault, SLOT_BOND) >> 128 << 128;
        vm.store(X.vault, bytes32(uint256(SLOT_BOND)), bytes32(hi | ((bond0 + 1) / 2 - reserve - 1)));
        _expectOwner(X.vault, CovenantBase.BondFloor.selector);
    }

    /// @notice T-GUARD-B4 (D5-01): a DUE markout holds part of the bond in reserve and the deposit's prologue may
    ///         burn it; with bondShares < floor <= bondShares + reserve, the allocation is refused.
    function test_T_GUARD_B4__aDueReserveIsNotCountedAsBond() public {
        uint256 bond0 = _bondTotal(X);
        _alloc(c, X.vault, SH);
        _replace(X); // a curator action: part of the bond moves into reserve until its markout settles
        _keepAlive(X, 20); // the markout is due (unsettled: refreshRef does not settle)
        uint256 reserve = uint128(_ld(X.vault, 20));
        assertGt(reserve, 0, "a reserve is pending");
        uint256 floor = (bond0 + 1) / 2;
        uint256 hi = _ld(X.vault, SLOT_BOND) >> 128 << 128;
        vm.store(X.vault, bytes32(uint256(SLOT_BOND)), bytes32(hi | (floor - 1))); // bondShares < floor <= sum
        _expectOwner(X.vault, CovenantBase.BondFloor.selector);
    }

    function _bondTotal(V memory v) internal view returns (uint256) {
        return uint128(_ld(v.vault, SLOT_BOND)) + uint128(_ld(v.vault, 20));
    }

    // ================================================================== T-GUARD-HUB

    /// @notice T-GUARD-HUB: refused while the Hub mirror pauses the id; allowed after `unpause`.
    function test_T_GUARD_HUB__mirrorPausesUnpauseReopens() public {
        _conduct(IDX, 1, 0); // a breach on the other chain, delivered
        assertTrue(hub.paused(address(c), IDX));
        _expectOwner(X.vault, CovenantBase.HubPaused.selector);
        _expectAgent(X.vault, CovenantBase.HubPaused.selector);
        vm.prank(alice);
        c.unpause(IDX);
        assertFalse(hub.paused(address(c), IDX));
        _alloc(c, X.vault, SH);
    }

    // ================================================================== T-GUARD-B6

    /// @notice T-GUARD-B6: refused at E + x > B, allowed at equality; a token0-only cost counts too (D1-05).
    function test_T_GUARD_B6__refusedAboveBAllowedAtEquality() public {
        uint256 snap = vm.snapshotState();
        _alloc(c, X.vault, SH);
        uint128 x = c.exposure(IDX);
        vm.revertToState(snap);
        assertGt(x, 0);
        _budget(address(c), IDX, x, 1); // B = exactly x
        _alloc(c, X.vault, SH); // E + x = B: allowed
        assertEq(c.exposure(IDX), x);
        _expectOwner(X.vault, CovenantBase.OverBudget.selector); // E + x > B
    }

    // ================================================================== T-GUARD-ARMED

    /// @notice T-GUARD-ARMED: with a breach since the baseline, agent and plan are refused; the owner is allowed.
    ///         A fresh vault with a breach in its history refuses the agent until the owner allocates (LF-10).
    function test_T_GUARD_ARMED__agentAndPlanRefusedOwnerAllowed() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        r.b3 = false;
        _setRules(c, r);
        _alloc(c, Y.vault, SH); // the owner's first allocation sets Y's baseline
        _latch(Y, 1);
        _process(Y);
        _backInRange(Y);
        _replace(Y); // back to NORMAL, one breach since the baseline
        assertEq(_mode(Y), 0);
        _expectAgent(Y.vault, CovenantBase.Armed.selector);
        (uint8 o, uint8 why) = _planSkip(Y.vault);
        assertEq(o, Outcome.SKIPPED);
        assertEq(why, Outcome.SKIP_ARMED);
        _alloc(c, Y.vault, SH); // the owner: allowed
        // a fresh vault with history: the agent is refused, the owner allowed, then the agent may follow
        _latch(X, 1);
        _process(X);
        _backInRange(X);
        _replace(X);
        _expectAgent(X.vault, CovenantBase.Armed.selector);
        _alloc(c, X.vault, SH);
        _agentAlloc(X.vault, SH / 10);
    }

    /// @dev The curator re-places (BREACHED → NORMAL, Touchstone V:247-251).
    function _replace(V memory v) internal {
        _keepAlive(v, 60); // the live reference is a 600 s TWAP: let it come back within REF_BAND of spot
        vm.prank(curatorOwner);
        v.bundler.setPositions(-1000, 1000, PreSwap(false, false, 0), 0, type(uint256).max);
        _keepAlive(v, 20);
    }

    // ================================================================== T-GUARD-B5 (cut)

    /// @notice T-GUARD-B5: B5 is cut; a Rulebook carrying it is refused by `setRules` and by `tighten`.
    function test_T_GUARD_B5__aNonZeroB5IsRefused() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.b5MaxBurnBps = 100;
        vm.prank(alice);
        vm.expectRevert(CovenantBase.BadRules.selector);
        c.setRules(r);
        vm.prank(agentKey);
        vm.expectRevert(CovenantBase.BadRules.selector);
        c.tighten(r);
        assertEq(c.rules().b5MaxBurnBps, 0);
    }

    // ================================================================== T-GUARD-BIND

    /// @notice T-GUARD-BIND: unbound vaults and ids outside `ids` are refused on every path; a fifth vault and an
    ///         over-wide `ids` are refused; `leave` never needs a binding.
    function test_T_GUARD_BIND__unboundUnlistedFifthAndWideIdsRefused() public {
        V memory u = _deployVault(); // never bound
        _keepAlive(u, 30);
        vm.prank(alice);
        c.setAllowed(u.vault, true);
        _expectOwner(u.vault, CovenantBase.Unbound.selector);
        _expectAgent(u.vault, CovenantBase.Unbound.selector);
        // a vault of an id outside ids
        V memory z = _deployVault();
        _bind(z.vault, 3);
        _keepAlive(z, 30);
        _expectOwner(z.vault, CovenantBase.NotInIds.selector);
        // four holdings, then a fifth vault
        Rulebook memory r = _rules(IDX, IDY);
        r.ids = [IDX, IDY, uint32(3), uint32(0)];
        _setRules(c, r);
        V memory w = _deployVault();
        _bind(w.vault, IDY);
        V[] memory all = new V[](2);
        (all[0], all[1]) = (w, z);
        _keepAliveAll(all, 30);
        _alloc(c, X.vault, SH);
        _alloc(c, X2.vault, SH);
        _alloc(c, Y.vault, SH);
        _alloc(c, z.vault, SH);
        _expectOwner(w.vault, CovenantBase.FifthVault.selector);
        // ids' ∪ exposed ids > 4: refused
        r.ids = [uint32(4), uint32(5), uint32(0), uint32(0)];
        vm.prank(alice);
        vm.expectRevert(CovenantBase.BadRules.selector);
        c.setRules(r);
        // leave works without any binding check (the vault stays bound here; an unbound one cannot hold a ledger)
        vm.prank(alice);
        c.leave(z.vault, SH, 0, 0);
        assertEq(c.ledger(z.vault), 0);
    }

    // ================================================================== A-IDSPOOF

    /// @notice A-IDSPOOF: the agent cannot allocate into X's vault under another id to dodge X's pause.
    function test_A_IDSPOOF__aPausedCuratorsVaultIsRefusedWhateverTheId() public {
        _conduct(IDX, 1, 0); // X paused (other chain)
        _expectAgent(X.vault, CovenantBase.HubPaused.selector);
    }

    function test_A_IDSPOOF__PC_withACallerSuppliedIdThePausedVaultPasses() public {
        _conduct(IDX, 1, 0);
        // a factory whose Covenants take the vault's id from the caller's word (Y's), not the Hub's binding
        CovenantCallerId bad = new CovenantCallerId(address(ext));
        vm.etch(address(impl), address(bad).code);
        _agentAlloc(X.vault, SH / 10);
        assertGt(c.ledger(X.vault), 0, "the paused curator's vault was allocated into");
    }

    // ================================================================== A-COV-AUTH (the Covenant side)

    /// @notice A-COV-AUTH: an outsider can call none of the owner's or the agent's functions, cannot reach the
    ///         extension's internal note entry through the fallback, and the extension refuses direct calls.
    function test_A_COV_AUTH__outsidersCannotActAsOwnerOrAgent() public {
        address eve = makeAddr("eve");
        Rulebook memory r = _rules(IDX, IDY);
        vm.startPrank(eve);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.allocate(X.vault, SH, type(uint256).max, type(uint256).max);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.leave(X.vault, SH, 0, 0);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.setRules(r);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.setAgent(eve);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.sweep(address(token1), 1);
        vm.expectRevert(CovenantBase.NotOwner.selector);
        c.flush();
        vm.expectRevert(CovenantBase.NotAgent.selector);
        c.tighten(r);
        vm.expectRevert(CovenantBase.NotAgent.selector);
        c.agentAllocate(X.vault, SH, type(uint256).max, type(uint256).max);
        vm.expectRevert(CovenantBase.NotDelegated.selector);
        CovenantExt(address(c)).note_(4); // the unlimited answer class, never reachable from outside
        vm.expectRevert(CovenantBase.NotDelegated.selector);
        ext.setAgent(eve); // the extension on its own storage
        vm.stopPrank();
        assertEq(c.agent(), agentKey);
    }

    // ================================================================== T-AGENT-ALLOC

    /// @notice T-AGENT-ALLOC: allowlist, per-epoch cap, the reference bound, and no recipient choice.
    function test_T_AGENT_ALLOC__allowlistCapReferenceNoRecipient() public {
        vm.prank(alice);
        c.setAllowed(X.vault, false);
        _expectAgent(X.vault, CovenantBase.NotAllowed.selector);
        vm.prank(alice);
        c.setAllowed(X.vault, true);
        _agentAlloc(X.vault, SH); // ≈ 0.2 mWETH, under the 1 mWETH cap
        assertEq(c.ledger(X.vault), SH, "the shares are booked to the Covenant (no recipient argument exists)");
        vm.prank(agentKey);
        vm.expectRevert(CovenantBase.AgentCap.selector);
        c.agentAllocate(X.vault, SH * 5, type(uint256).max, type(uint256).max); // past the per-epoch cap
        // the next vault epoch resets the cap
        _keepAlive(X, tier.EPOCH);
        ICovenantPoke(X.vault).poke();
        _agentAlloc(X.vault, SH);
        // a stale reference refuses the agent (RefStale) — the reference reverts
        X.ref.setMode(MockRefPool.Mode.Revert);
        _expectAgent(X.vault, CovenantBase.RefStale.selector);
    }

    /// @notice T-AGENT-ALLOC (s2, the LF-3 direction): a deposit at a spot pushed away from the reference costs more
    ///         than the shares are worth at the reference; beyond TRYREF_TOL the agent's allocation is refused.
    function test_T_AGENT_ALLOC__aMovedSpotRefusesTheAgentsDeposit() public {
        _agentAlloc(X.vault, SH / 10); // allowed at the reference
        _swap(X, true, 6e17); // spot far below the range: the deposit would pay a token0-heavy composition
        vm.prank(agentKey);
        vm.expectRevert(CovenantBase.PriceTolerance.selector);
        c.agentAllocate(X.vault, SH / 10, type(uint256).max, type(uint256).max);
    }

    // ================================================================== T-TIGHTEN, A-AGENT-LOOSEN, I-TIGHT

    /// @notice T-TIGHTEN: each Rulebook field: a stricter value applies, a looser one reverts.
    function test_T_TIGHTEN__eachFieldStricterAppliesLooserReverts() public {
        Rulebook memory base = _rules(IDX, IDY);
        base.b3 = false;
        base.b4FloorBps = 4_000;
        base.k = 2;
        _setRules(c, base);
        Rulebook[8] memory stricter;
        Rulebook[8] memory looser;
        for (uint256 i; i < 8; ++i) {
            stricter[i] = _copy(base); // fresh structs: a plain assignment would alias one memory struct
            looser[i] = _copy(base);
        }
        stricter[0].k = 1;
        looser[0].k = 3;
        stricter[1].b3 = true;
        looser[1].b4FloorBps = 3_000; // (b3 cannot be looser than off)
        stricter[2].b4FloorBps = 5_000;
        looser[2].b4FloorBps = 0;
        stricter[3].maxShareBps = 5_000;
        looser[3].maxShareBps = 0; // off = +infinity
        stricter[4].budget = 9e18;
        stricter[4].agentCapPerEpoch = 0.9e18; // the cap stays within a tenth of the budget (PB-14)
        looser[4].budget = 11e18;
        stricter[5].b2 = true;
        looser[5].maxShareBps = 7_000;
        stricter[6].agentCapPerEpoch = 0.5e18;
        looser[6].agentCapPerEpoch = 1e18 + 1;
        looser[6].budget = 11e18;
        stricter[7].ids = [IDX, uint32(0), uint32(0), uint32(0)];
        looser[7].ids = [IDX, IDY, uint32(3), uint32(0)];
        for (uint256 i; i < 8; ++i) {
            uint256 snap = vm.snapshotState();
            vm.warp(vm.getBlockTimestamp() + 301);
            vm.prank(agentKey);
            c.tighten(stricter[i]);
            assertEq(keccak256(abi.encode(c.rules())), keccak256(abi.encode(stricter[i])), "stricter applies");
            vm.revertToState(snap);
            vm.prank(agentKey);
            vm.expectRevert(CovenantBase.Looser.selector);
            c.tighten(looser[i]);
        }
    }

    function _copy(Rulebook memory r) internal pure returns (Rulebook memory) {
        return abi.decode(abi.encode(r), (Rulebook));
    }

    /// @notice A-AGENT-LOOSEN: the agent cannot loosen a field (here: k 1 → 3 and the budget up).
    function test_A_AGENT_LOOSEN__theAgentCannotLoosen() public {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        r.budget = 20e18;
        vm.prank(agentKey);
        vm.expectRevert(CovenantBase.Looser.selector);
        c.tighten(r);
        assertEq(c.rules().k, 1);
    }

    function test_A_AGENT_LOOSEN__PC_withoutTheMonotoneCheckTheAgentLoosens() public {
        ExtNoMonotone bad = new ExtNoMonotone();
        Covenant badImpl = new Covenant(address(bad));
        vm.etch(address(impl), address(badImpl).code);
        Rulebook memory r = _rules(IDX, IDY);
        r.k = 3;
        r.budget = 20e18;
        vm.prank(agentKey);
        c.tighten(r);
        assertEq(c.rules().k, 3, "loosened");
    }
}

interface ICovenantPoke {
    function poke() external;
}
