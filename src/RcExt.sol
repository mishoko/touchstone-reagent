// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LogRecord, IRnkSystem} from "./interfaces/IReactive.sol";
import {IReagentHub, Rulebook, Holding, Base} from "./interfaces/IReagent.sol";
import {Kind} from "./interfaces/IReagentRC.sol";
import {RcBase} from "./RcBase.sol";

/// @title RcExt
/// @notice The RC's STATE ingestion, exit scheduler, B6 reconcile and Cron tick (spec §3.5, §5.5). It runs only by
///         an internal `delegatecall` from `ReagentRC` (its own storage is never used): every entry refuses a direct
///         call and re-checks that the reaction came from the system contract (preserved by `delegatecall`;
///         s3 rc r2 D2-05, r3 D3-09).
contract RcExt is RcBase {
    address internal immutable SELF;

    uint256 internal constant SENDS_PER_REACTION = 4;
    uint256 internal constant GAS_GUARD = 150_000;
    uint256 internal constant SCAN_PER_TICK = 24;
    uint256 internal constant CURSOR_FLOOR = 8;
    uint256 internal constant EXITS_PER_TICK = 8;
    uint256 internal constant RECONCILE_PER_TICK = 8;
    uint256 internal constant RESEND_BLOCKS = 1_000;

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
    }

    constructor() {
        SELF = address(this);
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
            else if (kind == 3) _onPlanNote(c, d);
        } else if (l.topic0 == T_BUDGET) {
            _onBudgetApplied(c, l);
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
    function cron() external delegated {
        Budget memory bud = Budget(type(uint256).max, EXITS_PER_TICK, SCAN_PER_TICK);
        // (1) exactly CURSOR_FLOOR cursor evaluations and their due exits
        _cursor(bud, CURSOR_FLOOR);
        // (2) the lowers floor: in B6 (spec §5.5); (3) one dirty-id item
        _sweepStep(bud, 1);
        // (4)/(5) work entries, then further dirty items and cursor evaluations
        for (uint256 i; i < RECONCILE_PER_TICK && _workLen > 0 && gasleft() >= GAS_GUARD; ++i) {
            _serveNextEntry(bud);
            _sweepStep(bud, 1);
        }
        _sweepStep(bud, SCAN_PER_TICK);
        _cursor(bud, SCAN_PER_TICK);
        if (_pendingPairs + _workLen + _sweeps == 0) {
            _cronOn = false;
            IRnkSystem(SYSTEM).unsubscribe(LASNA, CRON, T_CRON100, IGNORE, IGNORE, IGNORE);
        }
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
        for (uint256 i; i < b.length && i < 8; ++i) {
            B6a storage x = _b6a[cov][b[i].id][c];
            (x.baseBreaches, x.baseGone) = (b[i].breaches, b[i].gone);
            _recordBudget(c, cov, b[i].id, b[i].budget, b[i].budgetNonce, b[i].exposure);
        }
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
        // write ahead (spec §5.5 "Deferred work"), then serve this entry within the reaction's optional budget
        _listEntry(c, cov);
        Budget memory bud = Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK);
        _serveEntry(c, cov, bud);
    }

    /// @dev Records a chain's (budget, exposure) for a (covenant, id) under the nonce gate (spec §5.5, r4 D4-02).
    function _recordBudget(uint256 c, address cov, uint32 id, uint128 budget, uint64 nonce, uint128 exposure)
        internal
        virtual
    {
        B6a storage x = _b6a[cov][id][c];
        (x.appliedB, x.E) = (_sat(budget), _sat(exposure));
        nonce;
    }

    // ================================================================== the exit scheduler (spec §3.5)

    /// @dev One evaluation of pair (c, cov, vault), in the order: suspension clear → unpark → release the wait →
    ///      not applied yet (wait) → send if due → park check (spec §3.5, r16 D16-02). Returns whether it sent.
    function _evalPair(uint256 c, address cov, address vault, Budget memory bud) internal returns (bool sent) {
        if (bud.evals == 0) return false;
        bud.evals -= 1;
        Pair storage p = _pair[c][cov][vault];
        VaultRec storage v = _vault[c][vault];
        uint32 id = v.id;
        (bool held, uint32 baseSeq, bool baseGone) = _holding(c, cov, vault);
        if (!held || id == 0) {
            _clearPair(c, cov, vault);
            return false;
        }
        uint32 now_ = _now();
        Conduct storage t = _conductOf[id];
        CovRec storage k = _cov[c][cov];
        // a new latch on the vault resets tries, defers and drips (lazily)
        if (v.maxSeq > p.seenSeq) (p.seenSeq, p.tries, p.defers, p.drips) = (uint8(v.maxSeq), 0, 0, 0);
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
            _resend(c, id, bud);
        }
        // [MU-236] at most one send per pair per EPOCH_TICKS (plus the drip re-targets)
        if (p.waitSeq == 0 && now_ >= p.nextTick && bud.sends > 0 && bud.exits > 0 && gasleft() >= GAS_GUARD) {
            _send(c, Kind.EXIT, abi.encodeCall(IReagentHub.rcExit, (address(0), cov, vault, uint64(q.seqTotals), t.breaches)));
            bud.sends -= 1;
            bud.exits -= 1;
            uint32 nt = now_ + _epochTicks(c);
            if (nt > p.nextTick) p.nextTick = nt;
            if (p.waitSince == 0) p.waitSince = now_;
            sent = true;
        }
        // [MU-237] park after 6·EPOCH_TICKS without progress (A-CRON-PIN)
        if (p.waitSince != 0 && now_ > p.waitSince + 6 * _epochTicks(c)) {
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
        uint32 et = _epochTicks(c);
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
            (x.baseBreaches, x.baseGone) = (base.breaches, base.gone);
            _setHoldBase(c, cov, vault, baseSeq, baseGone);
            if (_armable(c, cov, vault, id, baseSeq, baseGone)) _suspend(c, cov, vault, p, id);
            p.waitSince = 0;
        }
        _listEntry(c, cov);
        Budget memory bud = Budget(SENDS_PER_REACTION, EXITS_PER_TICK, SCAN_PER_TICK);
        _serveEntry(c, cov, bud);
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

    function _onPlanNote(uint256 c, bytes memory d) internal {
        (address vault,,,) = abi.decode(d, (address, uint32, uint8, uint8));
        uint32 id = _vault[c][vault].id;
        if (id != 0) _resultSeen(c, id);
    }

    /// @dev A callback result (an EXIT or PLAN note, a BudgetApplied): it proves delivery to this chain's Hub.
    function _resultSeen(uint256 c, uint32 id) internal {
        SeqRec storage q = _seq[c][id];
        q.hubLogCount += 1;
        if (q.parkedCount > 0 || q.b6ParkedCount > 0) _markDirty(id);
    }

    function _onBudgetApplied(uint256 c, LogRecord calldata l) internal virtual {
        _resultSeen(c, uint32(l.topic2));
    }

    // ================================================================== resends (PB-7)

    /// @dev A fresh-seq snapshot to a lagging chain, at most once per (chain, id) per 1,000 Lasna blocks (s3 rc r1
    ///      D1-07, r4 D4-01, r5 D5-06); a rate-limited resend keeps nothing listed.
    function _resend(uint256 c, uint32 id, Budget memory bud) internal {
        SeqRec storage q = _seq[c][id];
        uint32 bn = uint32(block.number);
        // [MU-241] the PB-7 rate (R-RESEND)
        if (q.lastResendBlock != 0 && bn < q.lastResendBlock + RESEND_BLOCKS) return;
        if (bud.sends == 0 || gasleft() < GAS_GUARD) return;
        bud.sends -= 1;
        q.lastResendBlock = bn;
        Conduct storage t = _conductOf[id];
        uint32 s = t.seq + 1;
        t.seq = s;
        q.seqOut = s;
        _send(c, Kind.CONDUCT, abi.encodeCall(IReagentHub.rcConduct, (address(0), id, t.breaches, t.gone, t.actions, uint64(s))));
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

    /// @dev Serves a Covenant's entry: its pair evaluations (and their exits and resends), then B6; the entry is
    ///      unlisted when nothing remains sendable now.
    function _serveEntry(uint256 c, address cov, Budget memory bud) internal virtual {
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
        if (!_serveB6(c, cov, bud)) left = true;
        if (!left) _unlistEntry(c, cov);
    }

    /// @dev B6 reconcile for a Covenant (spec §5.5 steps 0–3). Returns whether nothing remains to send.
    function _serveB6(uint256, address, Budget memory) internal virtual returns (bool) {
        return true;
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
    function _cursor(Budget memory bud, uint256 max) internal {
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

    function _markDirty(uint32 id) internal {
        if (_sweepPos[id] != 0) {
            _sweepPos[id] = 1; // a re-mark restarts the walk from the first pair (≤ 2 laps after the last mark)
            return;
        }
        _sweepPos[id] = 1;
        _dirty[_nDirty] = id;
        _nDirty += 1;
        _sweeps += 1;
    }

    /// @dev Up to `max` evaluations from the dirty ids' sweeps: each id walks its vaults' Covenants on both chains.
    function _sweepStep(Budget memory bud, uint256 max) internal {
        while (max > 0 && _nDirty > 0 && bud.evals > 0 && gasleft() >= GAS_GUARD) {
            uint32 id = _dirty[0];
            uint32 pos = _sweepPos[id]; // 1-based over (chain, vault slot, covenant)
            (bool found, uint256 c, address v, address cov) = _pairAt(id, pos - 1);
            if (!found) {
                _endSweep(id);
                continue;
            }
            _sweepPos[id] = pos + 1;
            _evalPair(c, cov, v, bud);
            --max;
        }
    }

    function _endSweep(uint32 id) internal {
        _sweepPos[id] = 0;
        uint256 last = _nDirty - 1;
        for (uint256 i; i < last; ++i) {
            _dirty[i] = _dirty[i + 1];
        }
        delete _dirty[last];
        _nDirty = last;
        _sweeps -= 1;
    }

    /// @dev The i-th (chain, vault, covenant) of an id (vaults on 1301 first), skipping empty slots.
    function _pairAt(uint32 id, uint256 i) internal view returns (bool, uint256, address, address) {
        for (uint256 ci; ci < 2; ++ci) {
            uint256 c = ci == 0 ? CA : CB;
            for (uint256 j; j < MAX_PER_CHAIN; ++j) {
                address v = _idVaults[id][c][j];
                if (v == address(0)) break;
                uint256 n = _vault[c][v].nCov;
                if (i < n) return (true, c, v, _covAt[c][v][i]);
                i -= n;
            }
        }
        return (false, 0, address(0), address(0));
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

    function _inIds(uint32[4] storage ids, uint32 id) internal view returns (bool) {
        return id != 0 && (ids[0] == id || ids[1] == id || ids[2] == id || ids[3] == id);
    }

    function _epochTicks(uint256 c) internal pure returns (uint32) {
        return c == CA ? EPOCH_TICKS_1301 : EPOCH_TICKS_11155111;
    }

    function _sat(uint128 x) internal pure returns (uint96) {
        return x > type(uint96).max ? type(uint96).max : uint96(x);
    }
}
