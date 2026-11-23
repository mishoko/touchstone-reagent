// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoteKind, Rulebook, Holding, Base} from "./interfaces/IReagent.sol";
import {CovenantBase} from "./CovenantBase.sol";

/// @title CovenantExt
/// @notice The owner's and the agent's administration of a Covenant and its STATE notes (spec §5.2–§5.4). It runs
///         only by delegatecall from a Covenant clone (its own storage is never used): the Covenant's fallback
///         forwards the admin selectors here, and the Covenant's code calls `note_` directly. Direct calls revert.
contract CovenantExt is CovenantBase {
    using SafeERC20 for IERC20;

    address internal immutable SELF;

    constructor() {
        SELF = address(this);
    }

    modifier delegated() {
        // [MU-070] only through a Covenant's delegatecall, never on this contract's own storage
        if (address(this) == SELF) revert NotDelegated();
        _;
    }

    modifier onlyOwner() {
        // [MU-071] the owner's administration
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ================================================================== owner

    function setRules(Rulebook calldata r) external delegated onlyOwner {
        _validate(r);
        _setRules(r, C_RULE_OWNER);
    }

    function setAgent(address a) external delegated onlyOwner {
        // [MU-092] the Covenant itself is never its agent (its self-calls would pass the agent checks)
        if (a == address(this)) revert Self();
        agent = a;
    }

    function setAllowed(address vault, bool ok) external delegated onlyOwner {
        allowed[vault] = ok;
    }

    function setPlan(address vault, uint128 perEpochToken1) external delegated onlyOwner {
        // the RC packs a plan in one slot: (vault, uint96 amount) (s2 D2-04)
        if (perEpochToken1 > type(uint96).max) revert BadRules();
        if (plan[vault] == 0 && perEpochToken1 != 0) {
            if (_plans.length >= 4) revert TooManyPlans();
            _plans.push(vault);
        } else if (plan[vault] != 0 && perEpochToken1 == 0) {
            _remove(_plans, vault);
        }
        plan[vault] = perEpochToken1;
        _note(C_NORMAL);
    }

    /// @notice Records the Hub's current counts for `id` and every bound vault's local state as this Covenant's
    ///         baseline (spec §5.4). With a loosening `setRules`, the only way out of a pause.
    function unpause(uint32 id) external delegated {
        // [MU-086] only the owner leaves a pause; the agent never can (A-AGENT-STALE)
        if (!_mayUnpause()) revert NotOwner();
        address[] memory vs = HUB.idVaults(id);
        for (uint256 i; i < vs.length; ++i) {
            // [MU-072] no unpause over a pending breach (r7 m-4)
            if (_obs(vs[i]).pendingBreaches > 0) revert PendingBreach();
        }
        (uint32 b, uint32 g,,) = HUB.conduct(id);
        _baseline[id] = [b, g];
        for (uint256 i; i < vs.length; ++i) {
            _snapshot(vs[i], true);
        }
        _note(C_RULE_OWNER);
    }

    /// @notice Sends what this Covenant holds of `token` (idle tokens, e.g. a skipped plan's) to the owner (I-OWN).
    function sweep(address token, uint256 amount) external delegated onlyOwner {
        if (amount > _sweepable(token)) revert NotAllowed();
        // [MU-073] tokens leave only to the owner
        IERC20(token).safeTransfer(owner, amount);
    }

    /// @notice A fresh STATE of the current state, if the interval allows; otherwise `TooSoon` (r18 m-2, r20 D20-01).
    function flush() external delegated {
        // [MU-074] owner or agent
        if (msg.sender != owner && (msg.sender != agent || agent == address(0))) revert NotOwner();
        _note(C_FLUSH);
    }

    /// @notice A vault's exit baseline (spec §5.4 view; served from the extension to keep the core under 22,000 B).
    function vaultBase(address vault) external view delegated returns (uint32 baseSeq, bool baseGone) {
        VaultBase memory b = _vb[vault];
        return (b.baseSeq, b.baseGone);
    }

    // ================================================================== agent

    /// @notice Monotone-stricter only (I-TIGHT): never raises a budget, never loosens a field, never adds an id.
    function tighten(Rulebook calldata r) external delegated {
        // [MU-075] the agent's only rule power
        if (msg.sender != agent || agent == address(0)) revert NotAgent();
        _validate(r);
        // [MU-076] every field at least as strict (A-AGENT-LOOSEN)
        if (_looser(r, _rules)) revert Looser();
        _setRules(r, C_RULE_AGENT);
    }

    /// @dev Virtual only so that a test harness can remove the defence (the positive control).
    function _looser(Rulebook calldata r, Rulebook memory o) internal pure virtual returns (bool) {
        return r.k > o.k || (o.b3 && !r.b3) || r.b4FloorBps < o.b4FloorBps
            || _looserShare(o.maxShareBps, r.maxShareBps) || r.budget > o.budget || (o.b2 && !r.b2)
            || r.agentCapPerEpoch > o.agentCapPerEpoch || !_subset(r.ids, o.ids);
    }

    // ================================================================== notes (called by the Covenant's own code)

    /// @notice Not forwarded by the Covenant's fallback: reachable only from the Covenant's code.
    function note_(uint8 cls) external delegated {
        _note(cls);
    }

    // ================================================================== rules

    function _validate(Rulebook calldata r) internal view {
        // [MU-077] k in 1..3; the agent cap within a tenth of the budget (PB-14); B5 is cut (s2 LF-6)
        if (r.k == 0 || r.k > 3 || r.agentCapPerEpoch > r.budget / 10 || r.b5MaxBurnBps != 0) revert BadRules();
        if (r.b4FloorBps > BPS || r.maxShareBps > BPS) revert BadRules();
        // [MU-078] |ids' u {exposed ids}| <= 4 on this chain (r24 D24-03)
        uint32[8] memory set;
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            if (r.ids[i] != 0 && !_inArr(set, n, r.ids[i])) set[n++] = r.ids[i];
        }
        for (uint256 i; i < _held.length; ++i) {
            uint32 id = HUB.vaultId(_held[i]);
            if (_exposure[id] > 0 && !_inArr(set, n, id)) set[n++] = id;
        }
        if (n > 4) revert BadRules();
    }

    function _setRules(Rulebook calldata r, uint8 cls) internal {
        if (_same(r, _rules)) revert NoChange();
        _rules = r;
        ++rulesNonce;
        // store first, then sync the Hub's budget list and lower to the new cap/2 (r28 m-2)
        HUB.syncRules(_halfCap(r), r.ids);
        _note(cls);
    }

    function _halfCap(Rulebook calldata r) internal pure returns (uint128) {
        if (r.maxShareBps == 0) return type(uint128).max;
        return uint128(uint256(r.maxShareBps) * r.budget / BPS / 2);
    }

    // ================================================================== STATE notes (spec §5.2, §5.3)

    function _note(uint8 cls) internal {
        uint40 t = uint40(block.timestamp);
        if (cls == C_RULE_OWNER || cls == C_RULE_AGENT) {
            Window storage w = cls == C_RULE_OWNER ? _ownerWin : _agentWin;
            if (t >= w.start + NOTE_INTERVAL) (w.start, w.n) = (t, 0);
            // [MU-079] at most 2 rule changes per role per interval; a third reverts, never silent (r5 D5-02)
            if (w.n >= 2) revert TooSoon();
            ++w.n;
        } else if (cls == C_HOLD_ADD) {
            Window storage w = _holdWin;
            if (t >= w.start + NOTE_INTERVAL) (w.start, w.n) = (t, 0);
            // [MU-080] a new holding is reported at once, <= 4 per interval (r11 D11-04)
            if (w.n >= 4) return _limited(t);
            ++w.n;
        } else if (cls == C_FLUSH) {
            if (t < _lastNote + NOTE_INTERVAL) revert TooSoon();
        } else if (cls == C_NORMAL) {
            return _limited(t);
        }
        _emitState(t);
    }

    /// @dev What `sweep` may move: never booked shares, at most what is held beyond the ledger.
    function _sweepable(address token) internal view virtual returns (uint256) {
        // [MU-085] I-SHARES, s2 D2-05 (A-SWEEP-SHARES)
        return IERC20(token).balanceOf(address(this)) - ledger[token];
    }

    /// @dev Virtual only so that a test harness can remove a defence (the positive controls); never overridden.
    function _mayUnpause() internal view virtual returns (bool) {
        return msg.sender == owner;
    }

    function _limited(uint40 t) internal virtual {
        // [MU-081] one STATE per interval, the rest coalesced (PB-10); never a revert (A-NOTE-REVERT)
        if (t < _lastNote + NOTE_INTERVAL) {
            notePending = true;
            return;
        }
        _emitState(t);
    }

    function _emitState(uint40 t) internal {
        _lastNote = t;
        notePending = false;
        HUB.note(NoteKind.STATE, _statePayload());
    }

    function _statePayload() internal returns (bytes memory) {
        uint64 nn = ++noteNonce;
        Holding[] memory h = new Holding[](_held.length);
        for (uint256 i; i < _held.length; ++i) {
            address v = _held[i];
            uint32 id = HUB.vaultId(v);
            (uint128 b, uint64 bn,) = HUB.budget(address(this), id);
            VaultBase memory vb = _vb[v];
            h[i] = Holding(v, id, ledger[v], _exposure[id], b, bn, vb.baseSeq, vb.baseGone);
        }
        // a Base for every id in ids or with exposure on this chain (r25 D25-03)
        uint32[8] memory set;
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            uint32 id = _rules.ids[i];
            if (id != 0 && !_inArr(set, n, id)) set[n++] = id;
        }
        for (uint256 i; i < _held.length; ++i) {
            uint32 id = HUB.vaultId(_held[i]);
            if (_exposure[id] > 0 && !_inArr(set, n, id)) set[n++] = id;
        }
        Base[] memory bs = new Base[](n);
        for (uint256 i; i < n; ++i) {
            (uint128 b, uint64 bn,) = HUB.budget(address(this), set[i]);
            bs[i] = Base(set[i], _baseline[set[i]][0], _baseline[set[i]][1], b, bn, _exposure[set[i]]);
        }
        address[] memory pv = _plans;
        uint128[] memory pa = new uint128[](pv.length);
        for (uint256 i; i < pv.length; ++i) {
            pa[i] = plan[pv[i]];
        }
        return abi.encode(nn, rulesNonce, _rules, h, bs, pv, pa);
    }

    // ================================================================== helpers

    function _looserShare(uint16 o, uint16 n) internal pure returns (bool) {
        // 0 = off counts as +infinity
        if (o == 0) return false;
        return n == 0 || n > o;
    }

    function _subset(uint32[4] calldata a, uint32[4] memory b) internal pure returns (bool) {
        for (uint256 i; i < 4; ++i) {
            if (a[i] != 0 && !_inIds(b, a[i])) return false;
        }
        return true;
    }

    function _count(uint32[4] memory a) internal pure returns (uint256 n) {
        for (uint256 i; i < 4; ++i) {
            if (a[i] == 0) continue;
            bool dup;
            for (uint256 j; j < i; ++j) {
                if (a[j] == a[i]) dup = true;
            }
            if (!dup) ++n;
        }
    }

    function _inArr(uint32[8] memory a, uint256 n, uint32 id) internal pure returns (bool) {
        for (uint256 i; i < n; ++i) {
            if (a[i] == id) return true;
        }
        return false;
    }

    /// @dev Equal as rules: every scalar equal and `ids` equal as sets (a permutation is NoChange, r24 m-1).
    function _same(Rulebook calldata a, Rulebook memory b) internal pure returns (bool) {
        if (
            a.k != b.k || a.b3 != b.b3 || a.b4FloorBps != b.b4FloorBps || a.maxShareBps != b.maxShareBps
                || a.budget != b.budget || a.b2 != b.b2 || a.b5MaxBurnBps != b.b5MaxBurnBps
                || a.agentCapPerEpoch != b.agentCapPerEpoch
        ) return false;
        return _subset(a.ids, b.ids) && _count(a.ids) == _count(b.ids);
    }

    function _remove(address[] storage a, address x) internal {
        for (uint256 i; i < a.length; ++i) {
            if (a[i] == x) {
                a[i] = a[a.length - 1];
                a.pop();
                return;
            }
        }
    }
}
