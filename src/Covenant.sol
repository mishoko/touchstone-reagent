// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITouchstoneHook} from "touchstone/interfaces/ITouchstoneHook.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {Obs} from "touchstone/types/Obs.sol";
import {IReagentHub, NoteKind, Outcome, Rulebook, Base} from "./interfaces/IReagent.sol";
import {VaultRead} from "./libraries/VaultRead.sol";
import {CovenantBase} from "./CovenantBase.sol";
import {CovenantExt} from "./CovenantExt.sol";

/// @title Covenant
/// @notice A depositor's standing orders on one chain (spec §3.2, §5.4). It holds the depositor's Touchstone shares
///         and tokens; tokens leave only to the owner or into a vault on this chain (I-OWN). Every Covenant is an
///         EIP-1167 clone of one implementation of this contract at a CREATE2 address with salt = owner, so it has one
///         address on both chains (s2 LF-1). The owner's and agent's administration lives in `CovenantExt`, reached
///         by delegatecall for an explicit list of selectors.
contract Covenant is CovenantBase {
    using SafeERC20 for IERC20;

    /// @notice The extension (same storage layout; `CovenantBase`). Chain-independent: deployed through 0x4e59.
    address public immutable EXT;

    constructor(address ext) {
        // [MU-084] an extension without code would make every admin call a silent no-op (D2-07)
        if (ext.code.length == 0) revert NotDelegated();
        EXT = ext;
        owner = address(0xdead); // the implementation itself is never usable
    }

    /// @notice Called once by the factory on a fresh clone, in the transaction that creates it.
    function initialize(address owner_, IReagentHub hub) external {
        // [MU-082] once only; the clone's address is the factory's CREATE2, so only the factory reaches a fresh one
        if (owner != address(0)) revert Initialized();
        owner = owner_;
        HUB = hub;
        FACTORY = msg.sender;
        _rules.k = 1; // PB-14 defaults: B7 k = 1, B3 on, B4 50%, B6 6,000 bps; no budget until set
        _rules.b3 = true;
        _rules.b4FloorBps = 5_000;
        _rules.maxShareBps = 6_000;
        hub.note(NoteKind.CREATED, abi.encode(owner_));
    }

    /// @notice The owner's and agent's administration (setRules, tighten, setAgent, setAllowed, setPlan, unpause,
    ///         sweep, flush) runs in the extension on this clone's storage. Any other selector reverts.
    fallback() external {
        bytes4 s = msg.sig;
        // [MU-083] only the listed admin entry points reach the extension (never `note_`)
        if (
            s != CovenantExt.setRules.selector && s != CovenantExt.tighten.selector && s != CovenantExt.setAgent.selector
                && s != CovenantExt.setAllowed.selector && s != CovenantExt.setPlan.selector
                && s != CovenantExt.unpause.selector && s != CovenantExt.sweep.selector && s != CovenantExt.flush.selector
                && s != CovenantExt.vaultBase.selector
        ) revert NotDelegated();
        _delegate(msg.data);
    }

    modifier onlyOwner() {
        // [MU-020] the owner's functions
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyHub() {
        _checkHub();
        _;
    }

    /// @dev Virtual only so that a test harness can remove the defence (A-COV-AUTH's positive control).
    function _checkHub() internal view virtual {
        // [MU-022] only this chain's Hub relays RC callbacks (A-COV-AUTH)
        if (msg.sender != address(HUB) || address(HUB) == address(0)) revert NotHub();
    }

    // ================================================================== owner

    function allocate(address vault, uint256 shares, uint256 max0, uint256 max1) external onlyOwner {
        _allocate(vault, shares, max0, max1, 0);
    }

    /// @notice Always available (I-LEAVE): no Reagent rule is consulted; Touchstone's own `withdraw` decides.
    function leave(address vault, uint256 shares, uint256 min0, uint256 min1) external onlyOwner {
        uint256 l = ledger[vault];
        uint256 bal = IERC20(vault).balanceOf(address(this));
        uint256 cap = _leaveCap(l, bal);
        uint256 s = shares < cap ? shares : cap;
        IVaultEntries(vault).withdraw(s, min0, min1, owner);
        _book(vault, s, false);
        _note(C_NORMAL);
    }

    // ================================================================== agent

    function agentAllocate(address vault, uint256 shares, uint256 max0, uint256 max1) external {
        // [MU-021] the agent's allocations
        if (msg.sender != agent || agent == address(0)) revert NotAgent();
        _allocate(vault, shares, max0, max1, 1);
    }

    // ================================================================== Hub (RC callbacks); never revert after auth

    /// @notice The patient exit (spec §3.5, §5.4): validity is decided here, at delivery, from current state.
    function rcExit(address vault, uint64 minSeq, uint32 breachCount) external onlyHub {
        uint32 id = HUB.vaultId(vault);
        (,,, uint64 hubSeq) = HUB.conduct(id);
        // [MU-027] the snapshot the RC acted on is not applied here yet
        if (hubSeq < minSeq) return _exitNote(vault, id, Outcome.EARLY, breachCount, 0, Outcome.EARLY_NOT_APPLIED, hubSeq);
        if (_obs(vault).pendingBreaches > 0) {
            // [MU-028] one event-triggered processBreach (a revert is caught, r1 D1-10); all checks below see its result
            try IVaultEntries(vault).processBreach() {} catch {}
        }
        // [MU-029] the exit pause predicate (latched counts; a pending breach alone never counts, r12 D12-01)
        if (!_exitPaused(id)) return _exitNote(vault, id, Outcome.STALE, breachCount, 0, 0, hubSeq);
        // [MU-030] the vault check (PB-2): no local breach or gone since the baseline -> nothing (B2 skips it)
        if (!_rules.b2 && !_vaultTriggered(vault)) return _exitNote(vault, id, Outcome.STALE, breachCount, 0, 0, hubSeq);
        if (_obs(vault).pendingBreaches > 0) {
            return _exitNote(vault, id, Outcome.EARLY, breachCount, 0, Outcome.EARLY_PENDING, hubSeq);
        }
        uint256 end = VaultRead.dripEnd(vault);
        // [MU-031] the floor no key can move: the drip as read now (C-04)
        if (block.number < end) {
            return _exitNote(vault, id, Outcome.EARLY, breachCount, end - block.number, Outcome.EARLY_DRIP, hubSeq);
        }
        try this.exitWithdraw(vault) returns (uint256 a0, uint256 a1) {
            _exitNote(vault, id, Outcome.DONE, breachCount, a0, a1, hubSeq);
        } catch (bytes memory err) {
            _exitNote(vault, id, Outcome.FAILED, breachCount, uint256(uint32(_sel(err))), 0, hubSeq);
        }
    }

    /// @notice Self-call only: the withdrawal of an exit, in kind to the owner, priced against `tryRef`.
    function exitWithdraw(address vault) external returns (uint256 a0, uint256 a1) {
        // [MU-090] self-call only: an outsider would bypass I-STALE and the drip floor
        if (msg.sender != address(this)) revert Self();
        uint256 l = ledger[vault];
        uint256 bal = IERC20(vault).balanceOf(address(this));
        uint256 s = l < bal ? l : bal;
        if (s == 0) return (0, 0); // a zero ledger answers DONE(0, 0) (r12 m-4)
        (bool ok, int24 tick) = ITouchstoneHook(VaultRead.hook(vault)).tryRef();
        if (!ok) revert RefStale();
        uint160 sqrtRef = VaultRead.sqrtAt(tick);
        (uint256 f0, uint256 f1) = VaultRead.proRataAt(vault, s, sqrtRef);
        uint256 fairValue = VaultRead.value(f0, f1, sqrtRef);
        // [MU-032] in kind to the owner only (I-OWN)
        (a0, a1) = IVaultEntries(vault).withdraw(s, 0, 0, owner);
        // [MU-033] min-outs as value at the reference within TRYREF_TOL (s2 LF-3; A-EXIT-SANDWICH)
        if (VaultRead.value(a0, a1, sqrtRef) * BPS < fairValue * (BPS - TRYREF_TOL_BPS)) revert PriceTolerance();
        _book(vault, s, false);
    }

    /// @notice A standing-plan deposit on the vault's `EpochRecorded` (spec §3.7, A7b).
    function rcAllocate(address vault, uint32 vaultEpoch) external onlyHub {
        uint128 amount = plan[vault];
        uint8 reason = Outcome.SKIP_OTHER;
        uint32 cur = VaultRead.epoch(vault);
        // [MU-034] `EpochRecorded(e)` names the epoch that just closed: deposit iff e < the vault's current epoch and
        // no plan deposit was made in that current epoch; at most one per vault epoch, no catch-up (A-PLAN-REPLAY,
        // s2 D2-03)
        if (amount != 0 && _planDue(vaultEpoch, cur, lastPlanEpoch[vault])) {
            lastPlanEpoch[vault] = cur;
            try this.planDeposit(vault, amount) {
                return _planNote(vault, vaultEpoch, Outcome.DONE, 0);
            } catch (bytes memory err) {
                reason = _skipReason(_sel(err));
            }
        }
        _planNote(vault, vaultEpoch, Outcome.SKIPPED, reason);
    }

    /// @notice Self-call only: the plan's deposit of `amount` token1 of value, under the agent's guards.
    function planDeposit(address vault, uint128 amount) external {
        // [MU-091] self-call only: an outsider would bypass the plan's epoch gate
        if (msg.sender != address(this)) revert Self();
        (bool ok, int24 tick) = ITouchstoneHook(VaultRead.hook(vault)).tryRef();
        if (!ok) revert RefStale();
        uint160 sqrtRef = VaultRead.sqrtAt(tick);
        (uint256 f0, uint256 f1) = VaultRead.proRataAt(vault, 1e18, sqrtRef);
        uint256 per = VaultRead.value(f0, f1, sqrtRef); // value of 1e18 shares at the reference
        if (per == 0) revert RefStale();
        _allocate(vault, uint256(amount) * 1e18 / per, type(uint256).max, type(uint256).max, 2);
    }

    /// @notice The unlimited STATE answering an `rcBudget` (r21 m-3).
    function emitState() external onlyHub {
        _note(C_ANSWER);
    }

    // ================================================================== views (read by the Hub, r8 m-2)

    function rules() external view returns (Rulebook memory) {
        return _rules;
    }

    function exposure(uint32 id) external view returns (uint128) {
        return _exposure[id];
    }

    function baseline(uint32 id) external view returns (uint32 breaches, uint32 gone) {
        return (_baseline[id][0], _baseline[id][1]);
    }

    // ================================================================== allocation (PA-1: the local guard)

    /// @param who 0 owner, 1 agent, 2 plan
    function _allocate(address vault, uint256 shares, uint256 max0, uint256 max1, uint8 who) internal {
        uint32 id = _idOf(vault);
        // [MU-035] an unbound vault is refused on every path (r1 D1-06, A-IDSPOOF)
        if (id == 0) revert Unbound();
        // [MU-036] the vault's id must be in the Rulebook's ids (r23 D23-01)
        if (!_inIds(_rules.ids, id)) revert NotInIds();
        // [MU-037] no fifth vault with a non-zero ledger (r24 D24-03)
        if (ledger[vault] == 0 && _held.length >= MAX_HOLDINGS) revert FifthVault();
        // [MU-038] the vault itself is NORMAL
        if (VaultRead.mode(vault) != 0) revert ModeNotNormal();
        _localGuard(id);
        // [MU-039] the Hub mirror (the cross-chain record, once delivered)
        if (HUB.paused(address(this), id)) revert HubPaused();
        VaultBase storage vb = _vb[vault];
        if (who != 0) {
            // [MU-041] agent and plan: not where an exit is armed (a breach since the baseline; before any baseline,
            // any latched breach in the vault's history: s2 LF-10, D2-06)
            if (_obs(vault).breachSeq > vb.baseSeq) revert Armed();
            // [MU-042] agent and plan: allowlisted vaults only
            if (!allowed[vault]) revert NotAllowed();
        }
        // the baseline is taken at the first allocation, after the agent's guard; a holding opening retakes the exit's
        _snapshot(vault, false);
        if (ledger[vault] == 0) _rebaseExit(vault);
        if (vb.bond0 == 0) vb.bond0 = uint128(VaultRead.bondWithReserve(vault));
        // [MU-040] B4: the bond floor against the bond at the first allocation
        if (_rules.b4FloorBps != 0 && _bondNow(vault) * BPS < uint256(vb.bond0) * _rules.b4FloorBps) {
            revert BondFloor();
        }
        uint256 cost = _deposit(vault, shares, max0, max1, who != 0);
        if (who != 0) {
            Spend storage sp = _spend[vault];
            uint32 ep = VaultRead.epoch(vault);
            if (sp.epoch != ep) (sp.epoch, sp.spent) = (ep, 0);
            // [MU-045] the per-epoch cap for agent and plan
            if (uint256(sp.spent) + cost > _rules.agentCapPerEpoch) revert AgentCap();
            sp.spent += uint128(cost);
        }
        (uint128 b,,) = HUB.budget(address(this), id);
        uint256 e = uint256(_exposure[id]) + cost;
        // [MU-046] B6: E + x <= B (allowed at equality; PB-3)
        if (_rules.maxShareBps != 0 && e > b) revert OverBudget();
        _exposure[id] = uint128(e);
        _cost[vault] += uint128(cost);
        bool added = _book(vault, shares, true);
        _note(added ? C_HOLD_ADD : C_NORMAL);
    }

    /// @dev The deposit, valued at the reference (rounded up); for the agent and the plan, the cost within
    ///      TRYREF_TOL of the shares' value at the reference.
    function _deposit(address vault, uint256 shares, uint256 max0, uint256 max1, bool bounded)
        internal
        returns (uint256 cost)
    {
        (bool ok, int24 tick) = ITouchstoneHook(VaultRead.hook(vault)).tryRef();
        // [MU-043] exposure must be valued at the reference
        if (!ok) revert RefStale();
        uint160 sqrtRef = VaultRead.sqrtAt(tick);
        uint256 fairValue;
        if (bounded) {
            (uint256 f0, uint256 f1) = VaultRead.proRataAt(vault, shares, sqrtRef);
            fairValue = VaultRead.value(f0, f1, sqrtRef);
        }
        (IERC20 t0, IERC20 t1) = VaultRead.tokens(vault);
        t0.forceApprove(vault, max0);
        t1.forceApprove(vault, max1);
        (uint256 a0, uint256 a1) = IVaultEntries(vault).deposit(shares, max0, max1, address(this));
        t0.forceApprove(vault, 0);
        t1.forceApprove(vault, 0);
        cost = VaultRead.valueUp(a0, a1, sqrtRef);
        // [MU-044] agent and plan max-ins as value at the reference within TRYREF_TOL (s2 LF-3; A-DEPOSIT-SANDWICH)
        if (bounded && cost * BPS > fairValue * (BPS + TRYREF_TOL_BPS)) revert PriceTolerance();
    }

    /// @notice The local guard over every vault bound to `id` on this chain (spec §3.2; T-GUARD-*).
    function _localGuard(uint32 id) internal view {
        address[] memory vs = HUB.idVaults(id);
        uint256 sum;
        for (uint256 i; i < vs.length; ++i) {
            address w = vs[i];
            // [MU-047] a pending breach on any sibling refuses (T-GUARD-PEND)
            if (_obs(w).pendingBreaches > 0) revert Pending();
            VaultBase memory b = _vb[w];
            uint32 n = VaultRead.breaches(w);
            sum += n > b.base19 ? n - b.base19 : 0;
            // [MU-048] B3: a sibling gone beyond its baseline
            if (_rules.b3 && VaultRead.mode(w) == 2 && !b.baseGone) revert Gone();
        }
        // [MU-049] B7 locally: the id's slot-19 breaches since the baseline (T-GUARD-B7, T-GUARD-SIBLING)
        if (sum >= _rules.k) revert RecordPaused();
    }

    /// @notice The exit pause predicate (spec §3.5): the Hub mirror, or latched counts against the per-vault
    ///         baseline, or (B3) a sibling gone beyond its baseline. A pending breach alone does not count.
    function _exitPaused(uint32 id) internal view virtual returns (bool) {
        if (HUB.paused(address(this), id)) return true;
        address[] memory vs = HUB.idVaults(id);
        uint256 sum;
        for (uint256 i; i < vs.length; ++i) {
            VaultBase memory b = _vb[vs[i]];
            // [MU-098] a vault with no baseline of this Covenant's is counted by the Hub mirror only (s2 F1-08)
            if (!b.set) continue;
            uint32 seq = _obs(vs[i]).breachSeq;
            sum += seq > b.baseSeq ? seq - b.baseSeq : 0;
            // [MU-096] B3: gone beyond the baseline only (a vault gone at the unpause no longer pauses)
            if (_rules.b3 && VaultRead.mode(vs[i]) == 2 && !b.baseGone) return true;
        }
        return sum >= _rules.k;
    }

    /// @notice A local breach or gone event on the vault since this Covenant's baseline for it (PB-2).
    function _vaultTriggered(address vault) internal view virtual returns (bool) {
        VaultBase memory b = _vb[vault];
        // [MU-097] gone since the baseline, not before it
        return _obs(vault).breachSeq > b.baseSeq || (VaultRead.mode(vault) == 2 && !b.baseGone);
    }

    /// @dev Books `s` shares in or out; exposure leaves pro rata, rounded down (E stays conservative-high, r1 D1-14).
    ///      Returns whether a new holding was added.
    function _book(address vault, uint256 s, bool add) internal returns (bool added) {
        uint128 l = ledger[vault];
        if (add) {
            added = l == 0 && s > 0;
            if (added) _held.push(vault);
            ledger[vault] = l + uint128(s);
            return added;
        }
        if (l == 0 || s == 0) return false;
        uint32 id = HUB.vaultId(vault);
        // [MU-089] exposure leaves from this vault's own cost basis, pro rata, rounded down (s2 F1-01)
        uint128 cv = _cost[vault];
        uint128 cut = uint128(uint256(cv) * (s < l ? s : l) / l);
        _cost[vault] = cv - cut;
        uint128 e = _exposure[id];
        _exposure[id] = e - (cut < e ? cut : e);
        uint128 nl = s >= l ? 0 : l - uint128(s);
        ledger[vault] = nl;
        if (nl == 0) _removeHeld(vault);
    }

    /// @dev The plan's epoch gate: the epoch that closed is behind the current one, and no plan deposit was made in
    ///      the current epoch (s2 D2-03). Virtual only for the positive control (A-PLAN-REPLAY).
    function _planDue(uint32 e, uint32 cur, uint32 last) internal pure virtual returns (bool) {
        return e < cur && cur > last;
    }

    /// @dev The current bond B4 counts (slot 17 only, D5-01). Virtual only for the positive control.
    function _bondNow(address vault) internal view virtual returns (uint256) {
        return VaultRead.bond(vault);
    }

    /// @dev `leave` withdraws at most the ledger and never more than held (PB-9).
    function _leaveCap(uint256 l, uint256 bal) internal pure virtual returns (uint256) {
        // [MU-023] the ledger, never more than held (A-DONATE: donated shares never break `leave`)
        return l < bal ? l : bal;
    }

    /// @dev The curator id of a vault is the Hub's write-once binding, never a caller's word (A-IDSPOOF). Virtual
    ///      only so that a test harness can remove the defence (the positive control); production never overrides it.
    function _idOf(address vault) internal view virtual returns (uint32) {
        return HUB.vaultId(vault);
    }

    // ================================================================== notes

    function _note(uint8 cls) internal {
        // an internal call into the extension: bubbles a revert (e.g. TooSoon), returns normally otherwise
        (bool ok, bytes memory r) = EXT.delegatecall(abi.encodeCall(CovenantExt.note_, (cls)));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    function _exitNote(address vault, uint32 id, uint8 outcome, uint32 breachCount, uint256 a, uint256 b, uint64 hubSeq)
        internal
    {
        (uint128 bud, uint64 bn,) = HUB.budget(address(this), id);
        Base memory base = Base(id, _baseline[id][0], _baseline[id][1], bud, bn, _exposure[id]);
        VaultBase memory vb = _vb[vault];
        HUB.note(NoteKind.EXIT, abi.encode(vault, outcome, breachCount, a, b, base, vb.baseSeq, vb.baseGone, hubSeq));
    }

    function _planNote(address vault, uint32 epoch, uint8 outcome, uint8 reason) internal {
        HUB.note(NoteKind.PLAN, abi.encode(vault, epoch, outcome, reason));
    }

    // ================================================================== helpers

    /// @dev The fallback's forward: returns or reverts with the extension's data, ending this call.
    function _delegate(bytes memory data) internal {
        (bool ok, bytes memory r) = EXT.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        assembly ("memory-safe") {
            return(add(r, 32), mload(r))
        }
    }

    function _skipReason(bytes4 s) internal pure returns (uint8) {
        if (s == HubPaused.selector || s == RecordPaused.selector || s == Gone.selector || s == ModeNotNormal.selector) {
            return Outcome.SKIP_PAUSED;
        }
        // [MU-095] each error maps to its PLAN reason (spec §5.3)
        if (s == OverBudget.selector || s == AgentCap.selector) return Outcome.SKIP_B6;
        if (s == Armed.selector || s == Pending.selector) return Outcome.SKIP_ARMED;
        if (s == RefStale.selector) return Outcome.SKIP_REF_STALE;
        if (s == PriceTolerance.selector || s == VaultRead.SLIPPAGE) return Outcome.SKIP_SLIPPAGE;
        if (s == VaultRead.MARKOUT_PENDING) return Outcome.SKIP_MARKOUT;
        if (s == VaultRead.NAV_CAP) return Outcome.SKIP_NAVCAP;
        if (s == NotInIds.selector) return Outcome.SKIP_NOT_IN_IDS;
        if (s == FifthVault.selector) return Outcome.SKIP_FIFTH_VAULT;
        return Outcome.SKIP_OTHER;
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(err, 32))
            }
        }
    }

    function _removeHeld(address x) internal {
        for (uint256 i; i < _held.length; ++i) {
            if (_held[i] == x) {
                _held[i] = _held[_held.length - 1];
                _held.pop();
                return;
            }
        }
    }
}
