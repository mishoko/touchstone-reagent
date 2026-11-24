// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LogRecord, IRnkSystem} from "./interfaces/IReactive.sol";
import {IReagentHub, Rulebook, Holding, Base} from "./interfaces/IReagent.sol";
import {Kind} from "./interfaces/IReagentRC.sol";
import {RcBase} from "./RcBase.sol";
import {RcB6} from "./RcB6.sol";

/// @title RcExt
/// @notice The RC's STATE ingestion, exit scheduler, B6 reconcile and Cron tick (spec §3.5, §5.5). It runs only by
///         an internal `delegatecall` from `ReagentRC` (its own storage is never used): every entry refuses a direct
///         call and re-checks that the reaction came from the system contract (preserved by `delegatecall`;
///         s3 rc r2 D2-05, r3 D3-09).
contract RcExt is RcBase {
    address internal immutable SELF;
    address public immutable B6; // the B6 module (immutable, like EXT: no upgrade path)

    uint256 internal constant SENDS_PER_REACTION = 4; // [MU-275] (spec §6)
    uint256 internal constant SCAN_PER_TICK = 24;
    uint256 internal constant CURSOR_FLOOR = 4; // [MU-279] floor (1) (v1.3: the reservation; v1.2: 8)
    uint256 internal constant EXITS_PER_TICK = 8;
    uint256 internal constant RECONCILE_PER_TICK = 8;

    uint8 internal constant EXIT_DONE = 1;
    uint8 internal constant EXIT_EARLY = 2;
    uint8 internal constant EXIT_STALE = 3;
    uint8 internal constant EXIT_FAILED = 4;
    uint8 internal constant EXIT_DEFERRED = 5;
    uint8 internal constant EXIT_RELAY_FAILED = 6;

    /// @dev The optional-work budget of the current reaction (sends left; Cron gets its own caps).
    struct Budget {
        uint256 sends;
        uint256 exits;
        uint256 evals;
        bool probes; // a STATE's reaction: PB-7 resends and probes for the Covenant's ids (spec §3.5)
        uint8 lowers; // step (a) for this Covenant: 0 serve it; 1 just served, nothing owed; 2 just served, still owes
        //              (the lowers-list head in Cron (4): one scan, v13 r2 V2-04; the result keeps the entry listed)
    }

    constructor(address b6_) {
        // [MU-261] a module without code would make every B6 step a silent no-op (D2-07 class, F-011)
        if (b6_.code.length == 0) revert NotDelegated();
        SELF = address(this);
        B6 = b6_;
    }

    /// @dev An OPTIONAL B6 step (spec §5.5 "Deferred work"): started only at gasleft ≥ GAS_GUARD, given all but
    ///      `TAIL` gas, and never bubbling: a step cut short reverts alone and stays owed on the listed work entry,
    ///      so no reaction spends its mandatory part, or reverts, on optional work (s3 rc r1 D1-01 class; s4).
    function _b6Opt(bytes memory data) internal virtual returns (bool ok, bytes memory r) {
        if (gasleft() < GAS_GUARD) return (false, r);
        // [MU-262] the tail kept back for the rest of the reaction (the entry bookkeeping and the Cron subscribe)
        (ok, r) = B6.delegatecall{gas: gasleft() - TAIL}(data);
    }

    /// @dev Runs `RcB6` code on the RC's storage (internal only; RcB6 re-checks SYSTEM).
    function _b6(bytes memory data) internal returns (bytes memory r) {
        bool ok;
        (ok, r) = B6.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    modifier delegated() {
        // [MU-230] only on the RC's storage, inside a reaction: never a direct call, never an outsider's
        if (address(this) == SELF) revert NotDelegated();
        if (msg.sender != SYSTEM) revert NotSystem();
        _;
    }

    // ================================================================== entries (called by ReagentRC.react only)

    /// @notice A Hub `Note` or `BudgetApplied` (STATE, EXIT and PLAN answers; B6 answers).
    function onHubLog(LogRecord calldata l) external delegated {
        uint256 c = l.chainId;
        if (l.topic0 == T_NOTE) {
            address cov = address(uint160(l.topic2));
            uint256 kind = l.topic3;
            bytes memory d = abi.decode(l.data, (bytes));
            if (kind == 1) _onState(c, cov, d);
            else if (kind == 2) _onExitNote(c, cov, d);
            else if (kind == 3) _onPlanNote(c, cov, d);
        } else if (l.topic0 == T_BUDGET) {
            address cov = address(uint160(l.topic1));
            uint32 id = uint32(l.topic2);
            _resultSeen(c, id);
            if (l.data.length >= 96) {
                (uint128 nb, uint64 n, uint64 r) = abi.decode(l.data, (uint128, uint64, uint64));
                _b6(abi.encodeCall(RcB6.b6Answer, (c, cov, id, nb, n, r)));
            }
            _listEntry(c, cov);
            _serveEntry(c, cov, Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK, false, 0));
        }
    }

    /// @notice The id's positions need evaluation (a latch, a gone event, `BreachProcessed`, a parked wake).
    function markDirty(uint32 id) external delegated {
        _markDirty(id);
    }

    /// @notice A vault's `EpochRecorded`: the due plan callbacks (A7b; structural, ≤ 16, one plan per (Covenant,
    ///         vault)). The RC skips a Covenant it sees paused or armed, or whose `ids` lack the vault's id
    ///         (R-PLAN); the Covenant re-checks everything at delivery.
    function onEpoch(uint256 c, address vault, uint32 e) external delegated {
        VaultRec storage v = _vault[c][vault];
        uint256 n = v.nCov;
        for (uint256 i; i < n; ++i) {
            address cov = _covAt[c][vault][i];
            CovRec storage k = _cov[c][cov];
            if (!_inIds(k.ids, v.id)) continue;
            uint96 amount = _planOf(c, cov, vault);
            if (amount == 0) continue;
            if (_paused(c, cov, v.id) || _pair[c][cov][vault].pending) continue;
            _send(c, Kind.PLAN, abi.encodeCall(IReagentHub.rcAllocate, (address(0), cov, vault, e)));
        }
    }

    /// @notice A Cron100 tick: the tick order of spec §5.5 "Deferred work", each item under the guard; then the gate.
    ///         `phase` = (the Cron log's own blockNumber / 100) mod 3 rotates which floor comes first (v1.3, s5 v13 r1
    ///         V1-01: a phase, never a time; "now" stays `block.number`).
    function cron(uint256 phase) external delegated {
        Budget memory bud = Budget(type(uint256).max, EXITS_PER_TICK, SCAN_PER_TICK, false, 0);
        // the three floors, the phase's class first (the reservation guarantees the first one; §5.5 "Deferred work")
        for (uint256 k; k < 3; ++k) {
            // [MU-272] the floors rotate with the Cron event's phase
            uint256 cls = (phase + k) % 3;
            if (cls == 0) {
                // (1) CURSOR_FLOOR cursor evaluations and their due exits
                _cursor(bud, CURSOR_FLOOR);
            } else if (cls == 1) {
                // (2) at most STALE_POPS stale heads, then one visit that pops or sends one lower (round-robin)
                _b6Opt(abi.encodeCall(RcB6.b6Floor, ()));
            } else {
                // (3) one sweep step (an item or a lap end)
                _sweepStep(bud, 1);
            }
        }
        // (4) the lowers-list head's remaining lowers and its entries, or the work list's rotation; (5) further
        // entries (lowers list first) and dirty items alternately, up to RECONCILE_PER_TICK entries
        for (uint256 i; i < RECONCILE_PER_TICK && gasleft() >= GAS_GUARD; ++i) {
            if (!_serveHeadOrRotation(bud)) break;
            if (i > 0) _sweepStep(bud, 1);
        }
        _sweepStep(bud, SCAN_PER_TICK);
        _cursor(bud, SCAN_PER_TICK);
        if (_pendingPairs + _workLen + _sweeps == 0) {
            _cronOn = false;
            IRnkSystem(SYSTEM).unsubscribe(LASNA, CRON, T_CRON100, IGNORE, IGNORE, IGNORE);
        }
    }

    /// @dev One work-entry item: the lowers list's head (stale heads popped) with its remaining lowers and its
    ///      entries; else the work list's rotation. Returns false when there was nothing to serve.
    function _serveHeadOrRotation(Budget memory bud) internal returns (bool) {
        (bool hok, bytes memory hr) = _b6Opt(abi.encodeCall(RcB6.b6Head, ()));
        address h = hok ? abi.decode(hr, (address)) : address(0);
        if (h != address(0)) {
            (bool ok, bytes memory r) = _b6Opt(abi.encodeCall(RcB6.b6Lowers, (h, bud.sends, type(uint256).max)));
            if (ok) {
                bool still;
                (bud.sends, still) = abi.decode(r, (uint256, bool));
                bud.lowers = still ? 2 : 1; // its entries skip step (a) and carry its result (one scan, V2-04)
            }
            if (_cov[CA][h].workListed) _serveEntry(CA, h, bud);
            if (_cov[CB][h].workListed) _serveEntry(CB, h, bud);
            bud.lowers = 0;
            return true;
        }
        if (_workLen == 0) return false;
        _serveNextEntry(bud);
        return true;
    }

    // ================================================================== STATE (spec §5.3, §5.5 `Note(STATE)`)

    function _onState(uint256 c, address cov, bytes memory d) internal {
        (uint64 nn, uint64 rn, Rulebook memory r, Holding[] memory h, Base[] memory b, address[] memory pv,
            uint128[] memory pa) = abi.decode(d, (uint64, uint64, Rulebook, Holding[], Base[], address[], uint128[]));
        CovRec storage k = _cov[c][cov];
        // [MU-231] a STATE older than the last one changes nothing (spec §5.5)
        if (nn <= k.noteNonce) return;
        bool first = k.noteNonce == 0;
        k.noteNonce = uint32(nn);
        // [MU-232] rules only from a STATE at or above the stored rulesNonce (the only source of cap and k, r3 D3-01)
        if (rn >= k.rulesNonce) {
            (k.rulesNonce, k.k, k.b3, k.b2, k.b6On, k.ids) = (uint32(rn), r.k, r.b3, r.b2, r.maxShareBps != 0, r.ids);
            k.cap = uint128(uint256(r.maxShareBps) * r.budget / 10_000);
            if (k.unsettledR != 0 && rn >= k.unsettledR) k.unsettledR = 0;
        }
        // B6 (mandatory): the Bases under the nonce gate, the own unpark test, the lowers write-ahead
        _b6(abi.encodeCall(RcB6.b6State, (c, cov, b)));
        // holdings: a dropped holding's pair stops being pending now (mandatory; one writer)
        uint256 oldN = k.nHold;
        for (uint256 i; i < oldN; ++i) {
            address v = _hold[c][cov][i].vault;
            if (!_heldIn(h, v)) _clearPair(c, cov, v);
        }
        uint256 n = h.length < 4 ? h.length : 4;
        for (uint256 i; i < n; ++i) {
            _hold[c][cov][i] = Hold(h[i].vault, h[i].baseSeq, h[i].baseGone);
            _appendCov(c, h[i].vault, cov);
        }
        for (uint256 i = n; i < oldN; ++i) {
            delete _hold[c][cov][i];
        }
        k.nHold = uint8(n);
        // [MU-243] plans are stored lazily, from the Covenant's second STATE on this chain (R-GAS selected the lazy
        // path: the first STATE at the bounds stays within PB-8; spec §5.5 Bounds, §12)
        uint256 np = first ? 0 : (pv.length < 4 ? pv.length : 4);
        for (uint256 i; i < np; ++i) {
            _plan[c][cov][i] = Plan(pv[i], uint96(pa[i]));
        }
        for (uint256 i = np; i < k.nPlan; ++i) {
            delete _plan[c][cov][i];
        }
        k.nPlan = uint8(np);
        // write ahead (spec §5.5 "Deferred work"; the lowers list in b6State), then serve within the optional budget
        _listEntry(c, cov);
        _serveEntry(c, cov, Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK, true, 0));
    }

    /// @dev The mandatory write-ahead: the work entry, and the lowers list when a lower is owed (D7-01).
    function _writeAhead(uint256 c, address cov) internal {
        _listEntry(c, cov);
        _b6(abi.encodeCall(RcB6.b6WriteAhead, (cov)));
    }

    // ================================================================== the exit scheduler (spec §3.5)

    /// @dev One evaluation of pair (c, cov, vault), in the order: suspension clear → unpark → release the wait →
    ///      not applied yet (wait) → send if due → park check (spec §3.5, r16 D16-02). Returns whether it sent.
    function _evalPair(uint256 c, address cov, address vault, Budget memory bud) internal virtual returns (bool sent) {
        if (bud.evals == 0) return false;
        bud.evals -= 1;
        Pair storage p = _pair[c][cov][vault];
        VaultRec storage v = _vault[c][vault];
        uint32 id = v.id;
        (bool held, uint32 baseSeq, bool baseGone) = _holding(c, cov, vault);
        // [MU-264] an Untracked (17th) Covenant gets no pair state at all (PB-8; s4 rc-fix r1 C1-04)
        if (!held || id == 0 || !p.listed) {
            _clearPair(c, cov, vault);
            return false;
        }
        uint32 now_ = _now();
        Conduct storage t = _conductOf[id];
        CovRec storage k = _cov[c][cov];
        // a new latch on the vault resets tries, defers and drips (lazily)
        uint8 seen = v.maxSeq > 255 ? 255 : uint8(v.maxSeq); // saturated on both sides (s4 rc-fix r1 C1-06)
        if (seen > p.seenSeq) (p.seenSeq, p.tries, p.defers, p.drips) = (seen, 0, 0, 0);
        // [MU-233] a suspension clears when the id's totals or the rules move past it
        if (p.suspended && (t.breaches > p.suspB || t.gone > p.suspG || k.rulesNonce > p.suspR)) {
            (p.suspended, p.tries, p.defers) = (false, 0, 0);
        }
        SeqRec storage q = _seq[c][id];
        if (p.parkedLogCount != 0) {
            // [MU-234] unpark on a callback result after the park (r18 m-4)
            if (q.hubLogCount < p.parkedLogCount) return false;
            p.parkedLogCount = 0;
            q.parkedCount -= 1;
            p.waitSince = now_;
        }
        if (p.suspended || !_armable(c, cov, vault, id, baseSeq, baseGone)) {
            _setPending(p, false);
            return false;
        }
        _setPending(p, true);
        uint32 drip = _vault2[c][vault].dripEndTick;
        if (drip > p.nextTick && !k.b2) p.nextTick = drip;
        // [MU-235] the wait releases lazily on the scan that finds the snapshot applied (r13 D13-01)
        if (p.waitSeq != 0 && q.seqApplied >= p.waitSeq) (p.waitSeq, p.waitSince) = (0, 0);
        // a chain that has not applied the latest totals: wait without sending (r18 D18-02)
        if (p.waitSeq == 0 && q.seqApplied < q.seqTotals) {
            p.waitSeq = q.seqTotals;
            if (p.waitSince == 0) p.waitSince = now_;
        }
        // [MU-265] while waiting, the snapshot is resent at the PB-7 rate on every evaluation, not once at the
        // wait's start (§3.5; s4 rc-fix r1 C1-03)
        if (p.waitSeq != 0) _resend(c, id, bud);
        // [MU-236] at most one send per pair per EPOCH_TICKS (plus the drip re-targets)
        // (no second gas gate here: the evaluation was admitted whole by its caller's guard, v13 r3 V3-01)
        // [MU-281]
        if (p.waitSeq == 0 && now_ >= p.nextTick && bud.sends > 0 && bud.exits > 0) {
            _send(c, Kind.EXIT, abi.encodeCall(IReagentHub.rcExit, (address(0), cov, vault, uint64(q.seqTotals), t.breaches)));
            bud.sends -= 1;
            bud.exits -= 1;
            uint32 nt = now_ + _retryTicks(c);
            if (nt > p.nextTick) p.nextTick = nt;
            if (p.waitSince == 0) p.waitSince = now_;
            sent = true;
        }
        // [MU-237] park after 6·EPOCH_TICKS without progress (A-CRON-PIN)
        if (p.waitSince != 0 && now_ > p.waitSince + _parkTicks(c)) {
            p.parkedLogCount = q.hubLogCount + 1;
            q.parkedCount += 1;
            _setPending(p, false);
            emit ExitParked(c, cov, vault);
        }
    }

    /// @dev Armable (spec §3.5): held with shares, the rules for the vault's id met on this chain (B7 against the
    ///      per-id baseline, B3 gone, B2 the id paused), and for B7/B3 the vault's own check (PB-2).
    function _armable(uint256 c, address cov, address vault, uint32 id, uint32 baseSeq, bool baseGone)
        internal
        view
        returns (bool)
    {
        if (!_paused(c, cov, id)) return false;
        if (_cov[c][cov].b2) return true; // B2 skips the vault check (disclosed)
        VaultRec storage v = _vault[c][vault];
        // [MU-238] the vault check: a breach or gone event on V since the Covenant's baseline for it (PB-2)
        return v.maxSeq > baseSeq || (v.gone && !baseGone);
    }

    function _paused(uint256 c, address cov, uint32 id) internal view returns (bool) {
        CovRec storage k = _cov[c][cov];
        if (k.noteNonce == 0 || k.k == 0) return false;
        Conduct storage t = _conductOf[id];
        B6a storage x = _b6a[cov][id][c];
        // [MU-239] B7 against the unpause baseline; B3 only when on
        return (t.breaches >= x.baseBreaches + k.k) || (k.b3 && t.gone > x.baseGone);
    }

    /// @dev The pending bit's one writer (r15 m-5, s3 rc r2 D2-04): `_pendingPairs` follows it exactly.
    function _setPending(Pair storage p, bool on) internal {
        if (p.pending == on) return;
        p.pending = on;
        if (on) _pendingPairs += 1;
        else _pendingPairs -= 1;
    }

    /// @dev A pair whose holding is gone: not pending, not parked (one writer for both counters).
    function _clearPair(uint256 c, address cov, address vault) internal {
        Pair storage p = _pair[c][cov][vault];
        _setPending(p, false);
        if (p.parkedLogCount != 0) {
            p.parkedLogCount = 0;
            _seq[c][_vault[c][vault].id].parkedCount -= 1;
        }
    }

    // ================================================================== answers (spec §3.5 "Answers")

    function _onExitNote(uint256 c, address cov, bytes memory d) internal {
        (address vault, uint8 outcome,, uint256 a, uint256 b, Base memory base, uint32 baseSeq, bool baseGone, uint64 hubSeq) =
            abi.decode(d, (address, uint8, uint32, uint256, uint256, Base, uint32, bool, uint64));
        uint32 id = _vault[c][vault].id;
        if (id == 0) return;
        _resultSeen(c, id);
        Pair storage p = _pair[c][cov][vault];
        SeqRec storage q = _seq[c][id];
        uint32 now_ = _now();
        uint32 et = _retryTicks(c);
        if (outcome == EXIT_DONE) {
            _dropHolding(c, cov, vault);
            p.waitSince = 0;
        } else if (outcome == EXIT_EARLY && b == 0) {
            // DRIP: re-target to the end read at delivery; ≤ 3 re-targets per latch (r12 D12-02)
            uint32 end = now_ + _ticks(c, a);
            if (p.drips < 3) (p.drips, p.nextTick) = (p.drips + 1, end);
            else if (end > p.nextTick) p.nextTick = end;
            p.waitSince = 0;
        } else if ((outcome == EXIT_EARLY && b == 1) || (outcome == EXIT_STALE && uint32(hubSeq) < q.seqTotals)) {
            // NOT_APPLIED or a lag UNMET: wait for the snapshot (r11 D11-01)
            (p.waitSeq, p.waitSince) = (q.seqTotals, now_);
        } else if (outcome == EXIT_EARLY || outcome == EXIT_DEFERRED) {
            // PENDING or DEFERRED: retry after an epoch; every fifth counts a try (PB-11)
            uint32 nt = now_ + et;
            if (nt > p.nextTick) p.nextTick = nt;
            p.defers += 1;
            if (p.defers % 5 == 0) _addTry(c, cov, vault, p);
            if (outcome == EXIT_DEFERRED) {
                if (p.waitSince == 0) p.waitSince = now_;
            } else {
                p.waitSince = 0;
            }
        } else if (outcome == EXIT_FAILED || outcome == EXIT_RELAY_FAILED) {
            uint32 nt = now_ + et;
            if (nt > p.nextTick) p.nextTick = nt;
            p.waitSince = 0;
            _addTry(c, cov, vault, p);
        } else if (outcome == EXIT_STALE) {
            // caught up: the destination has everything; take its baselines, then suspend if still armable (PB-2)
            B6a storage x = _b6a[cov][id][c];
            (x.baseBreaches, x.baseGone) = (base.breaches, uint16(base.gone));
            _setHoldBase(c, cov, vault, baseSeq, baseGone);
            if (_armable(c, cov, vault, id, baseSeq, baseGone)) _suspend(c, cov, vault, p, id);
            p.waitSince = 0;
        }
        _writeAhead(c, cov);
        _serveEntry(c, cov, Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK, false, 0));
    }

    /// @dev The retry window after a FAILED, RELAY_FAILED, PENDING or DEFERRED answer: one EPOCH_TICKS (PB-11).
    ///      Virtual only for A-EXIT-DENY's positive control.
    function _retryTicks(uint256 c) internal view virtual returns (uint32) {
        return _epochTicks(c);
    }

    /// @dev The park age: 6 · EPOCH_TICKS without progress (A-CRON-PIN). Virtual only for its positive control.
    function _parkTicks(uint256 c) internal view virtual returns (uint32) {
        return 6 * _epochTicks(c);
    }

    function _addTry(uint256 c, address cov, address vault, Pair storage p) internal {
        p.tries += 1;
        // [MU-240] the third try suspends (MAX_TRIES; A-EXIT-DENY)
        if (p.tries >= 3) _suspend(c, cov, vault, p, _vault[c][vault].id);
    }

    function _suspend(uint256 c, address cov, address vault, Pair storage p, uint32 id) internal {
        Conduct storage t = _conductOf[id];
        (p.suspended, p.suspB, p.suspG, p.suspR) = (true, t.breaches, uint8(t.gone), _cov[c][cov].rulesNonce);
        _setPending(p, false);
        emit ExitAbandoned(c, cov, vault);
    }

    /// @dev A PLAN answer: a callback result, then the Covenant's reconcile like an EXIT note (§5.5; rc-fix r1 C1-13).
    function _onPlanNote(uint256 c, address cov, bytes memory d) internal {
        (address vault,,,) = abi.decode(d, (address, uint32, uint8, uint8));
        uint32 id = _vault[c][vault].id;
        if (id == 0) return;
        _resultSeen(c, id);
        _writeAhead(c, cov);
        _serveEntry(c, cov, Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK, false, 0));
    }

    /// @dev A callback result (an EXIT or PLAN note, a BudgetApplied): it proves delivery to this chain's Hub.
    function _resultSeen(uint256 c, uint32 id) internal {
        SeqRec storage q = _seq[c][id];
        q.hubLogCount += 1;
        if (q.parkedCount > 0 || q.b6ParkedCount > 0) _markDirty(id);
    }

    // ================================================================== resends (PB-7)

    /// @dev A waiting pair's PB-7 resend, inside its evaluation (admitted whole by the caller's guard, V3-01).
    function _resend(uint256 c, uint32 id, Budget memory bud) internal {
        if (bud.sends > 0 && _resendOnce(c, id, 0)) bud.sends -= 1; // [MU-282] guard 0 (V3-01)
    }

    // ================================================================== work entries (spec §5.5 "Deferred work")

    /// @dev Write ahead: the (chain, covenant) entry is listed before any optional work (≤ 1 fresh slot).
    function _listEntry(uint256 c, address cov) internal {
        CovRec storage k = _cov[c][cov];
        if (k.workListed) return;
        k.workListed = true;
        k.workPos = uint32(_workLen);
        _workList[_workLen] = (c << 160) | uint160(cov);
        _workLen += 1;
    }

    function _unlistEntry(uint256 c, address cov) internal {
        CovRec storage k = _cov[c][cov];
        if (!k.workListed) return;
        uint256 pos = k.workPos;
        uint256 last = _workLen - 1;
        if (pos != last) {
            uint256 moved = _workList[last];
            _workList[pos] = moved;
            _cov[moved >> 160][address(uint160(moved))].workPos = uint32(pos);
        }
        delete _workList[last];
        _workLen = last;
        k.workListed = false;
        if (_workPtr >= _workLen) _workPtr = 0;
    }

    /// @dev Serves a Covenant's entry in the optional order of spec §5.5 "Deferred work": B6 safety lowers; pair
    ///      evaluations and their exits; PB-7 resends and probes; B6 re-sends and holds; raises and rebalances. The
    ///      entry is unlisted when nothing remains (the entry-lifecycle predicate).
    function _serveEntry(uint256 c, address cov, Budget memory bud) internal virtual {
        // (a) B6 safety lowers (both chains); skipped for the lowers-list head whose lowers Cron (4) just served (its
        // owed state is the lowers list's, which keeps it listed while it owes)
        bool owes = true; // a step cut short stays owed
        bool ok;
        bytes memory r;
        if (bud.lowers != 0) {
            owes = bud.lowers == 2;
        } else {
            (ok, r) = _b6Opt(abi.encodeCall(RcB6.b6Lowers, (cov, bud.sends, type(uint256).max)));
            if (ok) (bud.sends, owes) = abi.decode(r, (uint256, bool));
        }
        // (b) the Covenant's pairs on this chain
        bool left;
        CovRec storage k = _cov[c][cov];
        uint256 n = k.nHold;
        for (uint256 i; i < n; ++i) {
            if (gasleft() < GAS_GUARD || bud.evals == 0) {
                left = true;
                break;
            }
            address v = _hold[c][cov][i].vault;
            _evalPair(c, cov, v, bud);
            Pair storage p = _pair[c][cov][v];
            if (p.pending && p.waitSeq == 0 && _now() >= p.nextTick) left = true; // due but not sent: owed
        }
        // (c) PB-7 resends and probes (a STATE's reaction only; rate-limited ones keep nothing listed)
        // (d), (e) B6 re-sends and holds, then raises and rebalances
        bool b6left = true;
        (ok, r) = _b6Opt(abi.encodeCall(RcB6.b6Rest, (c, cov, bud.sends, bud.probes)));
        if (ok) (bud.sends, b6left) = abi.decode(r, (uint256, bool));
        if (b6left || owes) left = true;
        // [MU-249] the entry stays listed while anything remains (the lifecycle predicate, s3 rc r11 D11-02)
        if (!left) _unlistEntry(c, cov);
    }

    function _serveNextEntry(Budget memory bud) internal {
        if (_workLen == 0) return;
        if (_workPtr >= _workLen) _workPtr = 0;
        uint256 e = _workList[_workPtr];
        _workPtr += 1;
        _serveEntry(e >> 160, address(uint160(e)), bud);
    }

    // ================================================================== the cursor and the dirty sweeps (spec §3.5)

    /// @dev Up to `max` evaluations from the rotating cursor over (vault, covenant) pairs.
    function _cursor(Budget memory bud, uint256 max) internal virtual {
        uint256 nv = _nVaults;
        if (nv == 0) return;
        uint256 steps;
        uint256 guardSteps = nv * MAX_COV;
        while (max > 0 && bud.evals > 0 && gasleft() >= GAS_GUARD && steps < guardSteps) {
            ++steps;
            if (_cursorV >= nv) (_cursorV, _cursorC) = (0, 0);
            uint256 e = _vaultList[_cursorV];
            uint256 c = e >> 160;
            address v = address(uint160(e));
            uint256 nc = _vault[c][v].nCov;
            // [MU-280] a vault without Covenants leaves the cursor: one counted step, once per registration (the last
            // vault takes its place; the stale tail slot is kept for a cheap re-list) (v13 r4 V4-01)
            if (nc == 0) {
                _vaultList[_cursorV] = _vaultList[nv - 1];
                nv -= 1;
                _nVaults = nv;
                _vault[c][v].unlisted = true;
                _cursorC = 0;
                --max;
                if (nv == 0) return;
                continue;
            }
            if (_cursorC >= nc) {
                (_cursorV, _cursorC) = (_cursorV + 1, 0);
                continue;
            }
            address cov = _covAt[c][v][_cursorC];
            _cursorC += 1;
            _evalPair(c, cov, v, bud);
            --max;
        }
    }

    /// @dev Up to `max` items from the dirty ids' sweeps: each id walks its pairs on both chains, then its b6Parked
    ///      lists (a lap; s3 rc r19 m-4).
    function _sweepStep(Budget memory bud, uint256 max) internal virtual {
        while (max > 0 && _nDirty > 0 && bud.evals > 0 && gasleft() >= GAS_GUARD) {
            // [MU-266] round-robin over the dirty ids, one item each (s4 rc-fix r1 C1-10: no head-of-line)
            if (_dirtyPtr >= _nDirty) _dirtyPtr = 0;
            uint256 at = _dirtyPtr;
            uint32 id = _dirty[at];
            Sweep storage w = _sweep[id];
            (uint8 kind, uint256 c, address v, address cov) = _itemAt(id, w.pos);
            if (kind == 0) {
                w.lap += 1;
                if (w.lap >= w.endLap) {
                    _endSweep(at); // the next id moved into `at`
                } else {
                    w.pos = 0;
                    _dirtyPtr = at + 1; // a lap end is this id's step: the next step is the next id's (v13 r5 V5-01)
                }
                --max; // [MU-273] a lap end is the step's item (floor (3) is one item or one lap end; v13 r1 V1-09)
                continue;
            }
            w.pos += 1;
            _dirtyPtr = at + 1;
            if (kind == 1) {
                _evalPair(c, cov, v, bud);
            } else {
                bud.evals -= 1;
                // optional and non-bubbling like every B6 step in Cron: a cut wake keeps its place (rc-fix r1 C1-05)
                (bool ok, bytes memory r) = _b6Opt(abi.encodeCall(RcB6.b6Wake, (c, cov, id)));
                if (!ok) {
                    w.pos -= 1;
                    _dirtyPtr = at; // a cut wake keeps this id's turn (rc-fix r5 C5-01)
                    break;
                }
                (bool unparked, bool list) = abi.decode(r, (bool, bool));
                if (list) _listEntry(c, cov);
                // [MU-267] an unpark shrinks the walked list: step back so the next element is not skipped, whether
                // the swap-remove moved one here or the last element left (s4 rc-fix r1 C1-02)
                if (unparked) w.pos -= 1;
            }
            --max;
        }
    }

    function _endSweep(uint256 at) internal {
        delete _sweep[_dirty[at]];
        uint256 last = _nDirty - 1;
        for (uint256 i = at; i < last; ++i) {
            _dirty[i] = _dirty[i + 1];
        }
        delete _dirty[last];
        _nDirty = last;
        _sweeps -= 1;
    }

    /// @dev The i-th item of an id's lap: kind 1 a (chain, vault, covenant) pair (vaults on 1301 first), kind 2 an
    ///      element of b6Parked[chain][id] (1301 first), kind 0 the end of the lap.
    function _itemAt(uint32 id, uint256 i) internal view returns (uint8, uint256, address, address) {
        for (uint256 ci; ci < 2; ++ci) {
            uint256 c = ci == 0 ? CA : CB;
            for (uint256 j; j < MAX_PER_CHAIN; ++j) {
                address v = _idVaults[id][c][j];
                if (v == address(0)) break;
                uint256 n = _vault[c][v].nCov;
                if (i < n) return (1, c, v, _covAt[c][v][i]);
                i -= n;
            }
        }
        for (uint256 ci; ci < 2; ++ci) {
            uint256 c = ci == 0 ? CA : CB;
            uint256 n = _seq[c][id].b6ParkedCount;
            if (i < n) return (2, c, address(0), _b6Parked[c][id][i]);
            i -= n;
        }
        return (0, 0, address(0), address(0));
    }

    // ================================================================== helpers

    function _appendCov(uint256 c, address vault, address cov) internal {
        VaultRec storage v = _vault[c][vault];
        if (v.id == 0) return;
        Pair storage p = _pair[c][cov][vault];
        if (p.listed) return;
        // [MU-242] a 17th Covenant is untracked and gets no pair state (PB-8, s3 rc r1 D1-03)
        if (v.nCov >= MAX_COV) {
            emit Untracked(c, cov);
            return;
        }
        p.listed = true;
        // [MU-283] a vault the cursor dropped while empty re-joins it at its first Covenant; the write reuses the stale
        // slot the drop left above `_nVaults` (non-zero to non-zero: a STATE stays within PB-8; v13 r4 V4-01)
        if (v.nCov == 0 && v.unlisted) {
            _vaultList[_nVaults] = (c << 160) | uint160(vault);
            _nVaults += 1;
            v.unlisted = false;
        }
        _covAt[c][vault][v.nCov] = cov;
        v.nCov += 1;
    }

    function _holding(uint256 c, address cov, address vault) internal view returns (bool, uint32, bool) {
        uint256 n = _cov[c][cov].nHold;
        for (uint256 i; i < n; ++i) {
            Hold storage h = _hold[c][cov][i];
            if (h.vault == vault) return (true, h.baseSeq, h.baseGone);
        }
        return (false, 0, false);
    }

    function _setHoldBase(uint256 c, address cov, address vault, uint32 baseSeq, bool baseGone) internal {
        uint256 n = _cov[c][cov].nHold;
        for (uint256 i; i < n; ++i) {
            Hold storage h = _hold[c][cov][i];
            if (h.vault == vault) (h.baseSeq, h.baseGone) = (baseSeq, baseGone);
        }
    }

    /// @dev `ExitDone`: the pair's shares are 0, so the holding leaves the view (no longer armable).
    function _dropHolding(uint256 c, address cov, address vault) internal {
        CovRec storage k = _cov[c][cov];
        uint256 n = k.nHold;
        for (uint256 i; i < n; ++i) {
            if (_hold[c][cov][i].vault == vault) {
                _hold[c][cov][i] = _hold[c][cov][n - 1];
                delete _hold[c][cov][n - 1];
                k.nHold = uint8(n - 1);
                break;
            }
        }
        _clearPair(c, cov, vault);
    }

    function _heldIn(Holding[] memory h, address v) internal pure returns (bool) {
        for (uint256 i; i < h.length; ++i) {
            if (h[i].vault == v) return true;
        }
        return false;
    }

    function _planOf(uint256 c, address cov, address vault) internal view returns (uint96) {
        uint256 n = _cov[c][cov].nPlan;
        for (uint256 i; i < n; ++i) {
            Plan storage p = _plan[c][cov][i];
            if (p.vault == vault) return p.amount;
        }
        return 0;
    }

}
