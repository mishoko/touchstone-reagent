// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {ReagentHub} from "../src/ReagentHub.sol";

/// @notice A-GAS63's positive control: the Hub's gas pre-check removed.
contract HubNoPrecheck is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _shortGas(uint256) internal pure override returns (bool) {
        return false;
    }
}

interface ICuratedExt {
    function EXTENSION() external view returns (address);
}

/// @notice A "Covenant" that burns every unit of gas it is given in `rcExit` (the burn-all cell, D3-03).
contract Burner {
    address public owner;

    constructor(address o) {
        owner = o;
    }

    function rcExit(address, uint64, uint32) external pure {
        while (true) {}
    }
}
import {ICovenant, IReagentHub, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice Fork-style measurement of every callback's entry gas at a constructed worst-case state (spec §5.6,
///         s2 D1-06): a fresh id, a fresh vault, a fresh (Covenant, id), 4 bound vaults scanned, 4 holdings and 4
///         `Base`s in the STATE, a vault epoch boundary, a pending breach for `rcExit`'s processBreach branch, and
///         an owner receiving each token for the first time. 1301 needs are the minimum entry gas (binary search);
///         the 11155111 estimate is method (b): that + Δslot · fresh slots + Δcreate · creations, counted from the
///         state diff of the same call. Results go to `output/gas-need-measured.json`.
contract GasNeedTest is ReagentEnv {
    // measured s2 on 11155111 vs 1301 (`eth_estimateGas`; spec §6)
    uint256 internal constant SLOT_SEP = 110_980;
    uint256 internal constant SLOT_1301 = 22_274;
    uint256 internal constant CREATE_SEP = 210_421;
    uint256 internal constant CREATE_1301 = 53_799;

    ICovenant internal c;
    address internal owner2 = makeAddr("freshOwner");
    V internal X3;
    V internal X4;
    V internal Z;
    V internal W;
    uint256 internal constant SH = 1e23;

    struct Need {
        uint256 entry; // minimum entry gas on the F layer (1301-like pricing)
        uint256 fresh; // zero → non-zero slots written
        uint256 creates; // accounts created
    }

    function _chain() internal pure virtual returns (uint256) {
        return 1301;
    }

    function setUp() public virtual {
        _setUpReagent(_chain());
        _setUpVaults();
        X3 = _deployVault();
        X4 = _deployVault();
        Z = _deployVault();
        W = _deployVault();
        _bind(X3.vault, IDX);
        _bind(X4.vault, IDX); // id X has 4 bound vaults on this chain: the guards scan all of them
        _bind(Z.vault, 3);
        _bind(W.vault, 4);
        V[] memory all = new V[](7);
        (all[0], all[1], all[2], all[3], all[4], all[5], all[6]) = (X, X2, Y, X3, X4, Z, W);
        _keepAliveAll(all, 2 * tier.EPOCH);
        // the Covenant of a fresh owner (first receipt of each token on exit), 4 ids and 4 holdings
        c = _covenant(owner2);
        Rulebook memory r = _rules(IDX, IDY);
        r.ids = [IDX, IDY, uint32(3), uint32(4)];
        r.budget = 100e18;
        r.agentCapPerEpoch = 10e18;
        _setRules(c, r);
        _alloc(c, X.vault, SH);
        _alloc(c, Y.vault, SH);
        _alloc(c, Z.vault, SH);
        _alloc(c, W.vault, SH);
        vm.startPrank(owner2);
        c.setAllowed(X.vault, true);
        c.setPlan(X.vault, 0.1e18);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the search

    /// @dev The minimum gas at which `target.call(data)` from `from` succeeds by `ok(logs)`, within 1,000 gas.
    function _search(address from, address target, bytes memory data, function(Vm.Log[] memory) view returns (bool) ok)
        internal
        returns (Need memory n)
    {
        uint256 lo = 20_000;
        uint256 hi = 30_000_000;
        uint256 snap = vm.snapshotState();
        require(_try(from, target, data, hi, ok), "fails even at the top");
        vm.revertToState(snap);
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            bool good = _try(from, target, data, mid, ok);
            vm.revertToState(snap);
            if (good) hi = mid;
            else lo = mid;
        }
        n.entry = hi;
    }

    /// @dev Fresh slots and creations of one call, from forge's state diff. Run only after a test's measurements: a
    ///      state-diff recording leaves later calls in the same test cheaper (s2: measured), so it never precedes one.
    function _freshCount(address from, address target, bytes memory data, Need memory n) internal {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(from);
        (bool ok,) = target.call{gas: 30_000_000}(data);
        require(ok, "freshCount: the call failed");
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        vm.revertToState(snap);
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].kind == VmSafe.AccountAccessKind.Create) ++n.creates;
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                VmSafe.StorageAccess memory st = acc[i].storageAccesses[j];
                if (st.isWrite && !st.reverted && st.previousValue == bytes32(0) && st.newValue != bytes32(0)) ++n.fresh;
            }
        }
    }

    /// @dev Records one kind's measurement to `output/gas-need-<kind>.json` (merged into `audits/gas-need.json` by
    ///      `script/deploy/gasneed.py`).
    function _record(string memory kind, Need memory n) internal {
        // a mutated run never overwrites the measurements (tools review m-6)
        if (bytes(vm.envOr("TS_MUTATION_RUN", string(""))).length != 0) return;
        string memory row = _put(kind, kind, n);
        vm.writeJson(row, string.concat("./output/gas-need-", kind, ".json"));
    }

    function _try(address from, address target, bytes memory data, uint256 gas_, function(Vm.Log[] memory) view returns (bool) ok)
        internal
        returns (bool)
    {
        _coolAll(); // a callback arrives in its own transaction: every account and slot cold (EIP-2929)
        vm.recordLogs();
        vm.prank(from);
        (bool s,) = target.call{gas: gas_}(data);
        return s && ok(vm.getRecordedLogs());
    }

    function _coolAll() internal {
        address[8] memory fixed_ = [address(hub), address(c), address(impl), address(ext), address(factory),
            address(token0), address(token1), address(manager)];
        for (uint256 i; i < fixed_.length; ++i) {
            vm.cool(fixed_[i]);
        }
        V[7] memory vs = [X, X2, Y, X3, X4, Z, W];
        for (uint256 i; i < vs.length; ++i) {
            vm.cool(vs[i].vault);
            vm.cool(vs[i].hook);
            vm.cool(address(vs[i].ref));
            vm.cool(address(vs[i].bundler));
            vm.cool(ICuratedExt(vs[i].vault).EXTENSION());
        }
        vm.cool(owner2);
        vm.cool(alice);
    }

    // ------------------------------------------------------------------ success predicates

    function _applied(Vm.Log[] memory l) internal view returns (bool) {
        return _count(l, APPLIED_TOPIC) == 1;
    }

    function _vaultBound(Vm.Log[] memory l) internal view returns (bool) {
        return _count(l, keccak256("VaultBound(address,uint32)")) == 1;
    }

    function _budgetAnswered(Vm.Log[] memory l) internal view returns (bool) {
        return _count(l, BUDGET_TOPIC) == 1 && _countNotes(l, NoteKind.STATE) == 1;
    }

    function _exitEarly(Vm.Log[] memory l) internal view returns (bool) {
        (bytes memory d, bool f) = _lastNote(l, address(c), NoteKind.EXIT);
        if (!f) return false;
        (uint8 o,,) = _exitOutcome(d);
        return o == Outcome.EARLY;
    }

    function _exitDone(Vm.Log[] memory l) internal view returns (bool) {
        (bytes memory d, bool f) = _lastNote(l, address(c), NoteKind.EXIT);
        if (!f) return false;
        (uint8 o,,) = _exitOutcome(d);
        return o == Outcome.DONE;
    }

    function _planDone(Vm.Log[] memory l) internal view returns (bool) {
        (bytes memory d, bool f) = _lastNote(l, address(c), NoteKind.PLAN);
        if (!f) return false;
        (,, uint8 o,) = abi.decode(d, (address, uint32, uint8, uint8));
        return o == Outcome.DONE;
    }

    // ------------------------------------------------------------------ worst-case states

    function _toEpochBoundary(V memory v) internal {
        uint256 e = tier.EPOCH;
        uint256 next = (vm.getBlockNumber() / e + 1) * e;
        _keepAlive(v, next - vm.getBlockNumber() + 1); // the next vault entry rolls the epoch
    }

    // ================================================================== T-GAS-*, A-GAS63 (spec §5.6, 1301 pricing)

    uint256 internal constant F_1301 = 177_200;
    uint256 internal constant RESERVE = 40_000;
    // the RC-side NEEDs (the RC holds them in s3; spec §5.6 table): ×1.3 of the measured worst case, rounded up
    uint256 internal constant NEED_CONDUCT = 35_000;
    uint256 internal constant NEED_BUDGET = 345_000;
    uint256 internal constant NEED_VAULT = 91_000;

    /// @dev gasLimit(chain, NEED) = ceil(1.1 · (NEED·64/63 + RESERVE) · 64/63) + F (spec §5.6, PB-4).
    function _gasLimit(uint256 need) internal pure returns (uint256) {
        uint256 num = 11 * 64 * (64 * need + 63 * RESERVE);
        uint256 den = 10 * 63 * 63;
        return (num + den - 1) / den + F_1301;
    }

    /// @dev The entry gas a delivery at `gasLimit` brings (G1: (63/64)·(gasLimit − F)).
    function _entry(uint256 gasLimit) internal pure returns (uint256) {
        return (gasLimit - F_1301) * 63 / 64;
    }

    function _deliver(bytes memory data, uint256 entry) internal returns (Vm.Log[] memory) {
        _coolAll();
        vm.recordLogs();
        vm.prank(PROXY);
        (bool ok,) = address(hub).call{gas: entry}(data);
        ok;
        return vm.getRecordedLogs();
    }

    function _exitWorstState() internal {
        IVaultEntries(X.vault).poke();
        _latch(X, 1);
        _conduct(IDX, 1, 0);
        _process(X);
        _backInRange(X);
        _keepAlive(X, tier.FORFEIT_DRIP_BLOCKS + 60);
        _toEpochBoundary(X);
    }

    /// @notice T-GAS-CONDUCT: NEED ≥ 1.3 × the measured need at a fresh id; at the formula gasLimit it applies; at
    ///         1,000 gas under the measured need it does not.
    function test_T_GAS_CONDUCT__appliesAtTheFormulaLimit() public {
        bytes memory d = abi.encodeCall(IReagentHub.rcConduct, (RC, 9, 1, 0, 0, 1));
        Need memory n = _search(PROXY, address(hub), d, _applied); // first: every probe cold
        assertGe(NEED_CONDUCT, n.entry * 13 / 10, "NEED >= 1.3 x measured");
        uint256 snap = vm.snapshotState();
        assertTrue(_applied(_deliver(d, _entry(_gasLimit(NEED_CONDUCT)))), "applies at the formula gasLimit");
        vm.revertToState(snap); // count fresh slots on the pre-delivery state
        _freshCount(PROXY, address(hub), d, n);
        _record("rcConduct", n);
    }

    /// @notice T-GAS-VAULT: the same for `rcVault` at a fresh vault and id (3 fresh slots).
    function test_T_GAS_VAULT__bindsAtTheFormulaLimit() public {
        bytes memory d = abi.encodeCall(IReagentHub.rcVault, (RC, address(0xF00D), 11));
        Need memory n = _search(PROXY, address(hub), d, _vaultBound);
        assertGe(NEED_VAULT, n.entry * 13 / 10);
        uint256 snap = vm.snapshotState();
        assertTrue(_vaultBound(_deliver(d, _entry(_gasLimit(NEED_VAULT)))));
        vm.revertToState(snap); // count fresh slots on the pre-delivery state
        _freshCount(PROXY, address(hub), d, n);
        assertEq(n.fresh, 3, "vaultId, the idVaults length and element");
        _record("rcVault", n);
    }

    /// @notice T-GAS-BUDGET: the same for `rcBudget` at a fresh (Covenant, id) with `emitState` at 4 holdings and
    ///         4 Bases; below the need the STATE is lost (the answer alone is not success).
    function test_T_GAS_BUDGET__answersWithStateAtTheFormulaLimit() public {
        bytes memory d = abi.encodeCall(IReagentHub.rcBudget, (RC, address(c), 4, 2e18, 1, c.rulesNonce()));
        Need memory n = _search(PROXY, address(hub), d, _budgetAnswered);
        assertGe(NEED_BUDGET, n.entry * 13 / 10);
        uint256 snap = vm.snapshotState();
        assertTrue(_budgetAnswered(_deliver(d, _entry(_gasLimit(NEED_BUDGET)))));
        vm.revertToState(snap); // count fresh slots on the pre-delivery state
        _freshCount(PROXY, address(hub), d, n);
        _record("rcBudget", n);
    }

    /// @notice T-GAS-BUDGET (s2 F1-06, r2 m-4): a real out-of-gas inside `emitState` (4 holdings, 4 Bases) is
    ///         answered `Stale(6)` with the budget applied, not silence.
    function test_T_GAS_BUDGET__anOutOfGasStateAnswersStale6() public {
        bytes memory d = abi.encodeCall(IReagentHub.rcBudget, (RC, address(c), 4, 2e18, 1, c.rulesNonce()));
        bool seen;
        for (uint256 g = 120_000; g < NEED_BUDGET && !seen; g += 5_000) {
            uint256 snap = vm.snapshotState();
            Vm.Log[] memory l = _deliver(d, g);
            if (_count(l, BUDGET_TOPIC) == 1 && _count(l, STALE_TOPIC) == 1 && _countNotes(l, NoteKind.STATE) == 0) {
                seen = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(seen, "some delivery under NEED answers Stale(6)");
    }

    /// @notice T-GAS-EXIT: at the worst-case state the Hub's NEED covers 1.3 × the Covenant's measured need on both
    ///         exit branches; at the formula gasLimit the exit is DONE; a raised gasLimit also reaches the Covenant;
    ///         1% under the pre-check threshold → DEFERRED; a Covenant burning all forwarded gas still yields
    ///         RELAY_FAILED from the Hub's reserve.
    function test_T_GAS_EXIT__doneAtTheFormulaLimitDeferredBelowBurnAllRelayFailed() public {
        (uint256 needExit,) = hub.needs();
        _exitWorstState();
        bytes memory cd = abi.encodeCall(ICovenant.rcExit, (X.vault, seq, 1));
        Need memory n = _search(address(hub), address(c), cd, _exitDone);
        assertGe(needExit, n.entry * 13 / 10, "NEED >= 1.3 x measured (withdraw branch)");
        bytes memory d = abi.encodeCall(IReagentHub.rcExit, (RC, address(c), X.vault, seq, 1));
        uint256 snap = vm.snapshotState();
        assertTrue(_exitDone(_deliver(d, _entry(_gasLimit(needExit)))), "DONE at the formula gasLimit");
        vm.revertToState(snap);
        assertTrue(_exitDone(_deliver(d, _entry(_gasLimit(needExit)) * 2)), "a raised limit reaches the Covenant");
        vm.revertToState(snap);
        uint256 threshold = needExit * 64 / 63 + RESERVE;
        (bytes memory note, bool f) = _lastNote(_deliver(d, threshold * 99 / 100), address(c), NoteKind.EXIT);
        assertTrue(f);
        (uint8 o,,) = _exitOutcome(note);
        assertEq(o, Outcome.DEFERRED, "1% under the pre-check: DEFERRED, no try burnt");
        vm.revertToState(snap);
        // burn-all: a Covenant of this factory that burns every forwarded unit
        Burner b = new Burner(alice);
        vm.store(address(factory), keccak256(abi.encode(address(b), uint256(0))), bytes32(uint256(1)));
        assertTrue(factory.isCovenant(address(b)));
        bytes memory bd = abi.encodeCall(IReagentHub.rcExit, (RC, address(b), X.vault, seq, 1));
        (note, f) = _lastNote(_deliver(bd, _entry(_gasLimit(needExit))), address(b), NoteKind.EXIT);
        assertTrue(f, "the Hub's reserve pays for the answer");
        (o,,) = _exitOutcome(note);
        assertEq(o, Outcome.RELAY_FAILED);
        vm.revertToState(snap);
        _freshCount(address(hub), address(c), cd, n); // last: a state diff makes later calls cheaper
        _record("rcExit", n);
    }

    /// @notice T-GAS-PLAN: at the worst case (a fresh holding) the Hub's NEED covers 1.3 × the measured need and the
    ///         plan is DONE at the formula gasLimit; an empty revert inside the deposit → Skipped(8) and the epoch
    ///         consumed; a starved relay (no pre-check) → RELAY_FAILED and `lastPlanEpoch` unchanged.
    function test_T_GAS_PLAN__doneAtTheFormulaLimitEmptyRevertAndStarvedRelay() public {
        (, uint256 needPlan) = hub.needs();
        vm.prank(owner2);
        c.leave(Z.vault, type(uint256).max, 0, 0);
        vm.startPrank(owner2);
        c.setAllowed(X3.vault, true);
        c.setPlan(X3.vault, 0.1e18);
        vm.stopPrank();
        _toEpochBoundary(X3);
        IVaultEntries(X3.vault).poke();
        uint32 cur = uint32(_ld(X3.vault, 8) >> 40);
        bytes memory pd = abi.encodeCall(ICovenant.rcAllocate, (X3.vault, cur - 1));
        Need memory n = _search(address(hub), address(c), pd, _planDone);
        assertGe(needPlan, n.entry * 13 / 10, "NEED >= 1.3 x measured (fresh holding)");
        bytes memory d = abi.encodeCall(IReagentHub.rcAllocate, (RC, address(c), X3.vault, cur - 1));
        uint256 snap = vm.snapshotState();
        assertTrue(_planDone(_deliver(d, _entry(_gasLimit(needPlan)))), "DONE at the formula gasLimit");
        vm.revertToState(snap);
        {
            (bytes memory dn, bool df) =
                _lastNote(_deliver(d, (needPlan * 64 / 63 + RESERVE) * 99 / 100), address(c), NoteKind.PLAN);
            assertTrue(df);
            (,, uint8 od,) = abi.decode(dn, (address, uint32, uint8, uint8));
            assertEq(od, Outcome.DEFERRED, "1% under the plan pre-check: DEFERRED");
            vm.revertToState(snap);
        }
        vm.mockCallRevert(X3.vault, abi.encodeWithSelector(IVaultEntries.deposit.selector), "");
        (bytes memory note, bool f) = _lastNote(_deliver(d, _entry(_gasLimit(needPlan))), address(c), NoteKind.PLAN);
        assertTrue(f);
        (,, uint8 o, uint8 why) = abi.decode(note, (address, uint32, uint8, uint8));
        assertEq(o, Outcome.SKIPPED);
        assertEq(why, Outcome.SKIP_OTHER, "an empty revert: reason 8");
        assertEq(c.lastPlanEpoch(X3.vault), cur, "the attempt consumed the epoch");
        vm.clearMockedCalls();
        vm.revertToState(snap);
        vm.prank(address(factory));
        HubNoPrecheck np = new HubNoPrecheck(RC);
        vm.etch(address(hub), address(np).code);
        (note, f) = _lastNote(_deliver(d, 120_000), address(c), NoteKind.PLAN);
        assertTrue(f);
        (,, o,) = abi.decode(note, (address, uint32, uint8, uint8));
        assertEq(o, Outcome.RELAY_FAILED, "starved: the relay fails");
        assertEq(c.lastPlanEpoch(X3.vault), 0, "the epoch is not consumed");
        vm.revertToState(snap);
        _freshCount(address(hub), address(c), pd, n); // last
        _record("rcAllocate", n);
    }

    /// @notice A-GAS63: a delivery just under the pre-check threshold is DEFERRED; no try is burnt.
    function test_A_GAS63__aShortDeliveryIsDeferred() public {
        (uint256 needExit,) = hub.needs();
        _exitWorstState();
        bytes memory d = abi.encodeCall(IReagentHub.rcExit, (RC, address(c), X.vault, seq, 1));
        (bytes memory note,) = _lastNote(_deliver(d, needExit * 64 / 63 + RESERVE - 1), address(c), NoteKind.EXIT);
        (uint8 o,,) = _exitOutcome(note);
        assertEq(o, Outcome.DEFERRED);
        assertEq(c.ledger(X.vault), SH, "nothing happened");
    }

    function test_A_GAS63__PC_withoutThePrecheckATryIsBurnt() public {
        (uint256 needExit,) = hub.needs();
        _exitWorstState();
        vm.prank(address(factory));
        HubNoPrecheck np = new HubNoPrecheck(RC);
        vm.etch(address(hub), address(np).code);
        bytes memory d = abi.encodeCall(IReagentHub.rcExit, (RC, address(c), X.vault, seq, 1));
        (bytes memory note, bool f) = _lastNote(_deliver(d, 150_000), address(c), NoteKind.EXIT);
        assertTrue(f);
        (uint8 o,,) = _exitOutcome(note);
        assertEq(o, Outcome.RELAY_FAILED, "a try burnt");
        needExit;
    }

    function _put(string memory obj, string memory k, Need memory n) internal returns (string memory) {
        uint256 sep = n.entry + n.fresh * (SLOT_SEP - SLOT_1301) + n.creates * (CREATE_SEP - CREATE_1301);
        string memory o = k;
        vm.serializeUint(o, "entry_1301", n.entry);
        vm.serializeUint(o, "fresh_slots", n.fresh);
        vm.serializeUint(o, "creates", n.creates);
        vm.serializeUint(o, "need_1301_x1_3", n.entry * 13 / 10 + 1);
        vm.serializeUint(o, "entry_11155111_est", sep);
        string memory row = vm.serializeUint(o, "need_11155111_x1_3", sep * 13 / 10 + 1);
        return vm.serializeString(obj, k, row);
    }
}

/// @notice The same suite at chain id 11155111 (the Hub selects its Sepolia NEEDs), plus the method-(b) check: the
///         Hub's 11155111 NEEDs cover 1.3 × (the forge need + the Glamsterdam price of every fresh slot the path
///         writes) at the worst-case state (spec §5.6; the code-override `eth_simulateV1` twins are s3).
contract GasNeedSepoliaTest is GasNeedTest {
    function _chain() internal pure override returns (uint256) {
        return 11155111;
    }

    function test_T_GAS_EXIT__sepoliaNeedsCoverMethodB() public {
        (uint256 needExit, uint256 needPlan) = hub.needs();
        _exitWorstState();
        bytes memory cd = abi.encodeCall(ICovenant.rcExit, (X.vault, seq, 1));
        Need memory n = _search(address(hub), address(c), cd, _exitDone);
        _freshCount(address(hub), address(c), cd, n);
        uint256 est = n.entry + n.fresh * (SLOT_SEP - SLOT_1301) + n.creates * (CREATE_SEP - CREATE_1301);
        assertGe(needExit, est * 13 / 10, "11155111 exit NEED >= 1.3 x method (b)");
        assertGe(needPlan, needExit, "the plan's fresh holding needs more than the exit");
    }
}
