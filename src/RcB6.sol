// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IReagentHub, Base} from "./interfaces/IReagent.sol";
import {Kind} from "./interfaces/IReagentRC.sol";
import {RcBase} from "./RcBase.sol";

/// @title RcB6
/// @notice The RC's B6 reconcile (spec §5.5 steps 0–3), `BudgetApplied` handling, B6 parks and probes and the lazy
///         per-Covenant lowers list. Like `RcExt` it runs only by an internal `delegatecall`, here from `RcExt`
///         (itself delegated from `ReagentRC.react`), on the RC's storage: every entry refuses a direct call and
///         re-checks that the reaction came from the system contract (s3 rc r2 D2-05, r3 D3-09). A third module
///         because `RcExt` with B6 exceeds the 22,000 B runtime rule (s4; §14).
contract RcB6 is RcBase {
    address internal immutable SELF;

    /// @dev The optional-send budget the caller passes in (spec §5.5 `SENDS_PER_REACTION`; unlimited in Cron).
    struct Bud {
        uint256 sends;
    }

    constructor() {
        SELF = address(this);
    }

    modifier delegated() {
        // [MU-260] only on the RC's storage, inside a reaction (as RcExt's MU-230)
        if (address(this) == SELF) revert NotDelegated();
        if (msg.sender != SYSTEM) revert NotSystem();
        _;
    }

    // ================================================================== entries (called by RcExt only)

    /// @notice A STATE's B6 part (mandatory): the Bases under the nonce gate, then its own unpark test, then the
    ///         lowers list's write-ahead (s3 rc r9 D9-02, r7 D7-01).
    function b6State(uint256 c, address cov, Base[] calldata b) external delegated {
        (uint32[8] memory u, uint256 un) = _b6Ids(cov);
        for (uint256 i; i < un; ++i) {
            if (!_baseIn(b, u[i])) _b6a[cov][u[i]][c].flags &= ~F_BASE; // a Base no longer reported
        }
        for (uint256 i; i < b.length && i < 8; ++i) {
            B6a storage x = _b6a[cov][b[i].id][c];
            (x.baseBreaches, x.baseGone) = (b[i].breaches, uint16(b[i].gone));
            _recordBudget(c, cov, b[i].id, b[i].budget, b[i].budgetNonce, b[i].exposure);
        }
        _unparkOwn(cov);
        if (_owesLower(cov)) _lowersAdd(cov);
    }

    /// @notice `BudgetApplied(covenant, id, budget, budgetNonce, rulesNonce)` (spec §5.5): under the nonce gate it
    ///         records the applied B and answers every send ≤ its nonce; an `r` above the stored rulesNonce marks
    ///         the chain rules-unsettled until a STATE brings it; then the lowers write-ahead.
    function b6Answer(uint256 c, address cov, uint32 id, uint128 nb, uint64 n, uint64 r) external delegated {
        B6b storage bb = _b6b[cov][id][c];
        B6a storage x = _b6a[cov][id][c];
        // [MU-246] the nonce gate on answers (A-REPLAY class; r4 D4-02); the applied B only from a strictly newer
        // nonce, so a same-nonce answer never overwrites a STATE emitted after it (s4 rc-fix r1 C1-07)
        if (n >= x.appliedNonce) {
            if (n > x.appliedNonce) (x.appliedNonce, x.appliedB) = (uint24(n), _sat(nb));
            // [MU-247] every send ≤ the answered nonce is answered
            if (bb.flags & F_UN != 0 && n >= bb.nonce) {
                bb.flags &= ~(F_UN | F_RAISE);
                (bb.unB, bb.resends, bb.runSince, bb.sentTick) = (0, 0, 0, 0);
            }
            CovRec storage k = _cov[c][cov];
            // [MU-248] a newer rulesNonce than the RC's: rules-unsettled until its STATE arrives (r1 D1-03)
            if (r > k.rulesNonce && r > k.unsettledR) k.unsettledR = uint32(r);
        }
        if (_owesLower(cov)) _lowersAdd(cov);
    }

    /// @notice The lowers write-ahead for a non-STATE reaction (an EXIT note): listed when a lower is owed.
    function b6WriteAhead(address cov) external delegated {
        if (_owesLower(cov)) _lowersAdd(cov);
    }

    /// @notice Step 1: up to `max` owed safety lowers of `cov`; unlinks it from the lowers list when none remains.
    function b6Lowers(address cov, uint256 sends, uint256 max) external delegated returns (uint256, bool owes) {
        Bud memory bud = Bud(sends);
        _sendLowers(cov, bud, max);
        owes = _owesLower(cov);
        if (!owes) {
            _lowersRemove(cov);
        } else if (_lHead == cov) {
            // [MU-269] a head that still owes after its sends goes to the tail (round-robin; rc-fix r1 C1-01)
            _lowersRemove(cov);
            _lowersAdd(cov);
        }
        return (bud.sends, owes);
    }

    /// @notice A STATE's probes (if `probes`), then steps 3, 1b and 2. Returns the sends left and whether anything
    ///         remains for the entry (an unanswered unparked message, or a move sendable now but not sent).
    function b6Rest(uint256 c, address cov, uint256 sends, bool probes) external delegated returns (uint256, bool left) {
        Bud memory bud = Bud(sends);
        if (probes) _probes(c, cov, bud);
        left = _serveB6(cov, bud);
        return (bud.sends, left);
    }

    /// @notice The sweep's b6Parked item (spec §5.5 step 3). Returns whether the swap-remove moved an element into
    ///         this slot and whether the swept chain's work entry must be listed (the lifecycle predicate).
    function b6Wake(uint256 c, address cov, uint32 id) external delegated returns (bool moved, bool list) {
        return _wakeB6(c, cov, id);
    }

    /// @notice Cron floor (2) (unlimited sends; each item under the guard).
    function b6Floor() external delegated {
        _lowersFloor(Bud(type(uint256).max));
    }

    /// @notice Pops the lowers list's stale heads and returns the owing head (0 = none).
    function b6Head() external delegated returns (address) {
        while (_lHead != address(0) && gasleft() >= GAS_GUARD && !_owesLower(_lHead)) {
            _lowersRemove(_lHead);
        }
        return _lHead;
    }

    function _resend(uint256 c, uint32 id, Bud memory bud) internal {
        if (bud.sends > 0 && _resendOnce(c, id)) bud.sends -= 1;
    }


    /// @dev The distinct ids of a Covenant's Rulebooks on both chains (≤ 8): the B6 reconcile's (covenant, id) set.
    function _b6Ids(address cov) internal view returns (uint32[8] memory u, uint256 n) {
        for (uint256 ci; ci < 2; ++ci) {
            uint32[4] storage ids = _cov[ci == 0 ? CA : CB][cov].ids;
            for (uint256 j; j < 4; ++j) {
                uint32 id = ids[j];
                if (id == 0) continue;
                bool dup;
                for (uint256 m; m < n; ++m) {
                    if (u[m] == id) dup = true;
                }
                if (!dup) u[n++] = id;
            }
        }
    }

    /// @dev capRC = the minimum over the reporting chains of the cap in each one's latest STATE (r22 m-2); B6 off
    ///      counts as no cap; no cap at all → MAX (no B6 work).
    function _capRC(address cov) internal view returns (uint256 cap) {
        cap = type(uint256).max;
        for (uint256 ci; ci < 2; ++ci) {
            CovRec storage k = _cov[ci == 0 ? CA : CB][cov];
            if (k.noteNonce != 0 && k.b6On && k.cap < cap) cap = k.cap;
        }
    }

    /// @dev committed(c) (spec §5.5 steps 0–1): an unreported chain counts capRC/2; a reported chain with no Base
    ///      for the id cap_c/2 (the Hub default); else max(applied B, E, the highest unanswered sent B).
    function _committed(uint256 c, address cov, uint32 id, uint256 capRC) internal view returns (uint256 m) {
        CovRec storage k = _cov[c][cov];
        // [MU-251] an unreported chain counts capRC/2 (step 0, r22 m-3)
        if (k.noteNonce == 0) return capRC / 2;
        B6b storage bb = _b6b[cov][id][c];
        B6a storage x = _b6a[cov][id][c];
        if (x.flags & F_BASE == 0) return (k.b6On ? k.cap : type(uint256).max) / 2;
        m = x.appliedB > x.E ? x.appliedB : x.E;
        // [MU-252] committed counts the unanswered sends (r1 D1-02: never "applied only")
        if (bb.flags & F_UN != 0 && bb.unB > m) m = bb.unB;
    }

    function _other(uint256 c) internal pure returns (uint256) {
        return c == CA ? CB : CA;
    }

    function _listing(uint256 c, address cov, uint32 id) internal view returns (bool) {
        CovRec storage k = _cov[c][cov];
        // [MU-253] only a chain whose latest STATE lists the id is ever messaged (step 0, r24 D24-02)
        return k.noteNonce != 0 && _inIds(k.ids, id);
    }

    /// @dev Step 1: whether chain c owes a safety lower for (cov, id), and its target max(E_c, capRC − committed
    ///      (other)). Not owed for a B6-parked (chain, id) (s3 rc r8 D8-02) or when an unanswered lower already
    ///      has a target ≤ it.
    function _lowerOwed(uint256 c, address cov, uint32 id, uint256 capRC) internal view virtual returns (bool, uint256 t) {
        bool need;
        (need, t) = _lowerNeed(c, cov, id, capRC);
        if (!need) return (false, 0);
        B6b storage bb = _b6b[cov][id][c];
        // [MU-268] an unanswered LOWER whose own target is ≤ t already covers it (its target, not the run's max)
        if (bb.flags & F_UN != 0 && bb.flags & F_RAISE == 0 && _lowB[cov][id][c] <= t) return (false, 0);
        return (true, t);
    }

    /// @dev Step 1's need and target for chain c, regardless of what is in flight: a re-send of an unanswered lower
    ///      carries this target (s4 rc-fix r1: re-sending through `_lowerOwed` degraded every re-sent lower into a
    ///      hold at the applied B, so a dropped lower was never re-delivered).
    function _lowerNeed(uint256 c, address cov, uint32 id, uint256 capRC) internal view returns (bool, uint256 t) {
        if (capRC == type(uint256).max || !_listing(c, cov, id)) return (false, 0);
        if (_b6b[cov][id][c].parkLog != 0) return (false, 0);
        uint256 o = _committed(_other(c), cov, id, capRC);
        // [MU-254] lowers only while Σ committed exceeds capRC
        if (_committed(c, cov, id, capRC) + o <= capRC) return (false, 0);
        B6a storage x = _b6a[cov][id][c];
        t = capRC > o ? capRC - o : 0;
        if (t < x.E) t = x.E;
        if (x.appliedB <= t) return (false, 0);
        return (true, t);
    }

    function _owesLower(address cov) internal view returns (bool) {
        uint256 cap = _capRC(cov);
        if (cap == type(uint256).max) return false;
        (uint32[8] memory u, uint256 n) = _b6Ids(cov);
        for (uint256 i; i < n; ++i) {
            for (uint256 ci; ci < 2; ++ci) {
                (bool owed,) = _lowerOwed(ci == 0 ? CA : CB, cov, u[i], cap);
                if (owed) return true;
            }
        }
        return false;
    }

    /// @dev Sends up to `max` owed safety lowers of a Covenant, each an item under the guard and the send budget.
    function _sendLowers(address cov, Bud memory bud, uint256 max) internal {
        uint256 cap = _capRC(cov);
        if (cap == type(uint256).max) return;
        (uint32[8] memory u, uint256 n) = _b6Ids(cov);
        for (uint256 i; i < n && max > 0; ++i) {
            for (uint256 ci; ci < 2 && max > 0; ++ci) {
                if (bud.sends == 0 || gasleft() < GAS_GUARD) return;
                uint256 c = ci == 0 ? CA : CB;
                (bool owed, uint256 t) = _lowerOwed(c, cov, u[i], cap);
                if (!owed) continue;
                _sendBudget(c, cov, u[i], t, false);
                bud.sends -= 1;
                --max;
            }
        }
    }

    /// @dev One `rcBudget` with a fresh nonce; the unanswered run's bookkeeping.
    function _sendBudget(uint256 c, address cov, uint32 id, uint256 target, bool raise) internal {
        B6b storage bb = _b6b[cov][id][c];
        uint32 an = _b6a[cov][id][c].appliedNonce;
        uint32 n = (bb.nonce > an ? bb.nonce : an) + 1;
        bb.nonce = n;
        uint96 t = target > type(uint96).max ? type(uint96).max : uint96(target);
        uint24 now_ = uint24(_now());
        if (bb.flags & F_UN == 0) {
            (bb.unB, bb.runSince, bb.resends) = (t, now_, 0);
        } else if (t > bb.unB) {
            bb.unB = t;
        }
        bb.flags = raise ? bb.flags | F_UN | F_RAISE : (bb.flags | F_UN) & ~F_RAISE;
        if (!raise) _lowB[cov][id][c] = t;
        bb.sentTick = now_;
        _send(c, Kind.BUDGET, abi.encodeCall(IReagentHub.rcBudget, (address(0), cov, id, uint128(t), uint64(n),
            uint64(_cov[c][cov].rulesNonce))));
    }

    /// @dev Steps 1b, 2 and 3 for every id of the Covenant (step 1 is `_sendLowers`). Returns whether anything
    ///      remains for the entry: an unanswered unparked message, or a move sendable now but not sent.
    function _serveB6(address cov, Bud memory bud) internal virtual returns (bool left) {
        uint256 cap = _capRC(cov);
        if (cap == type(uint256).max) return false;
        (uint32[8] memory u, uint256 n) = _b6Ids(cov);
        for (uint256 i; i < n; ++i) {
            for (uint256 ci; ci < 2; ++ci) {
                _resendB6(ci == 0 ? CA : CB, cov, u[i], cap, bud);
            }
            if (_restMove(cov, u[i], cap, bud)) left = true; // a move sendable now but held back
        }
        // the entry-lifecycle predicate, evaluated AFTER this entry's sends: any unanswered, unparked message keeps
        // it listed, including one this very pass sent (s3 rc r11 D11-02; s4 found the gap)
        for (uint256 i; i < n && !left; ++i) {
            for (uint256 ci; ci < 2; ++ci) {
                B6b storage bb = _b6b[cov][u[i]][ci == 0 ? CA : CB];
                // [MU-263] an unanswered, unparked message keeps the entry listed
                if (bb.flags & F_UN != 0 && bb.parkLog == 0) left = true;
            }
        }
    }

    /// @dev Step 3 for (c, cov, id): an unanswered, unparked message is re-sent after its back-off with a fresh
    ///      nonce; a raise stays a raise only if step 2's rest holds without it, else a hold at min(recomputed, B);
    ///      a lower parks after 6·EPOCH_TICKS, a raise after MOVE_RESENDS (spec §5.5 step 3). Returns whether the
    ///      message is still unanswered and unparked (it keeps the entry listed).
    function _resendB6(uint256 c, address cov, uint32 id, uint256 cap, Bud memory bud) internal returns (bool) {
        B6b storage bb = _b6b[cov][id][c];
        if (bb.flags & F_UN == 0 || bb.parkLog != 0) return false;
        uint32 now_ = _now();
        uint256 delay = MOVE_TICKS << (bb.resends > 8 ? 8 : bb.resends);
        uint256 et = _epochTicks(c);
        if (delay > et) delay = et; // at most one send per EPOCH_TICKS once the back-off reaches it (LF-S4-3)
        // [MU-255] the back-off
        if (bb.sentTick != 0 && now_ < bb.sentTick + delay) return true;
        bool raise = bb.flags & F_RAISE != 0;
        // [MU-256] park: a raise after MOVE_RESENDS, a lower after 6·EPOCH_TICKS (A-CRON-PIN)
        if (raise ? bb.resends >= MOVE_RESENDS : now_ > bb.runSince + 6 * et) {
            _parkB6(c, cov, id);
            return false;
        }
        if (bud.sends == 0 || gasleft() < GAS_GUARD) return true;
        uint256 o = _committed(_other(c), cov, id, cap);
        uint256 target;
        if (raise && _restIgnoring(c, cov, id, cap)) {
            target = cap > o ? cap - o : 0;
        } else {
            // [MU-270] a re-sent lower carries its recomputed target (never degraded to a hold by its own flight)
            (bool need, uint256 t) = _lowerNeed(c, cov, id, cap);
            uint256 ab = _b6a[cov][id][c].appliedB;
            target = need && t < ab ? t : ab;
            raise = false;
        }
        uint8 r = bb.resends;
        _sendBudget(c, cov, id, target, raise);
        bb.resends = r + 1;
        bud.sends -= 1;
        return true;
    }

    /// @dev Step 2's at-rest conditions for re-sending chain c's raise, ignoring that raise: the other chain has no
    ///      unanswered message, neither chain is rules-unsettled, both list the id, c is short and Σ < capRC.
    function _restIgnoring(uint256 c, address cov, uint32 id, uint256 cap) internal view returns (bool) {
        uint256 o = _other(c);
        if (!_listing(c, cov, id) || !_listing(o, cov, id)) return false;
        if (_b6b[cov][id][o].flags & F_UN != 0) return false;
        if (_cov[c][cov].unsettledR != 0 || _cov[o][cov].unsettledR != 0) return false;
        B6a storage x = _b6a[cov][id][c];
        uint256 mine = x.appliedB > x.E ? x.appliedB : x.E;
        uint256 h = x.appliedB > x.E ? x.appliedB - x.E : 0;
        return h < cap * 5 / 100 && mine + _committed(o, cov, id, cap) < cap;
    }

    /// @dev Steps 1b and 2, only at rest (both chains reported and listing the id, no unanswered message to either,
    ///      both rules settled): the rebalance lower with hysteresis, else one raise of a short chain. Returns true
    ///      if a move was sendable now but the budget or the guard held it.
    function _restMove(address cov, uint32 id, uint256 cap, Bud memory bud) internal virtual returns (bool) {
        // [MU-257] raises and rebalances only at rest (r3 D3-01, r5 D5-03)
        if (!_listing(CA, cov, id) || !_listing(CB, cov, id)) return false;
        B6b storage ba = _b6b[cov][id][CA];
        B6b storage bbB = _b6b[cov][id][CB];
        if ((ba.flags | bbB.flags) & F_UN != 0 || ba.parkLog != 0 || bbB.parkLog != 0) return false;
        if (_cov[CA][cov].unsettledR != 0 || _cov[CB][cov].unsettledR != 0) return false;
        uint256 mm = cap * 5 / 100; // MIN_MOVE
        B6a storage xa = _b6a[cov][id][CA];
        B6a storage xb = _b6a[cov][id][CB];
        uint256 ha = xa.appliedB > xa.E ? xa.appliedB - xa.E : 0;
        uint256 hb = xb.appliedB > xb.E ? xb.appliedB - xb.E : 0;
        uint256 c;
        uint256 target;
        bool raise;
        // [MU-258] step 1b: the donor keeps MIN_MOVE of its headroom (hysteresis, r6 D6-04)
        if (ha < mm && hb >= 2 * mm) {
            (c, target) = (CB, xb.appliedB - (hb - mm));
        } else if (hb < mm && ha >= 2 * mm) {
            (c, target) = (CA, xa.appliedB - (ha - mm));
        } else if (ha < mm || hb < mm) {
            c = ha < mm ? CA : CB;
            uint256 o = _committed(_other(c), cov, id, cap);
            uint256 mine = _committed(c, cov, id, cap);
            if (mine + o >= cap) return false;
            (target, raise) = (cap - o, true);
        } else {
            return false;
        }
        if (bud.sends == 0 || gasleft() < GAS_GUARD) return true;
        _sendBudget(c, cov, id, target, raise);
        bud.sends -= 1;
        return false;
    }

    /// @dev Parks (c, cov, id): no Cron for it, raises blocked; listed on b6Parked (≤ 16; an overflowed one is
    ///      uncounted and wakes on its own STATE; r19 m-3).
    function _parkB6(uint256 c, address cov, uint32 id) internal {
        B6b storage bb = _b6b[cov][id][c];
        SeqRec storage q = _seq[c][id];
        bb.parkLog = q.hubLogCount + 1;
        if (q.b6ParkedCount < 16) {
            _b6Parked[c][id][q.b6ParkedCount] = cov;
            _b6ParkIdx[cov][id][c] = uint8(q.b6ParkedCount + 1);
            q.b6ParkedCount += 1;
        } else {
            bb.flags |= F_OVER;
        }
    }

    /// @dev Unparks (c, cov, id): off its list, the back-off clock reset, resent at once (spec §5.5 step 3).
    function _unparkB6(uint256 c, address cov, uint32 id) internal returns (bool moved) {
        B6b storage bb = _b6b[cov][id][c];
        bb.parkLog = 0;
        if (bb.flags & F_OVER != 0) {
            bb.flags &= ~F_OVER;
        } else {
            SeqRec storage q = _seq[c][id];
            uint256 i = _b6ParkIdx[cov][id][c] - 1;
            uint256 last = q.b6ParkedCount - 1;
            if (i != last) {
                address m = _b6Parked[c][id][last];
                _b6Parked[c][id][i] = m;
                _b6ParkIdx[m][id][c] = uint8(i + 1);
                moved = true;
            }
            delete _b6Parked[c][id][last];
            delete _b6ParkIdx[cov][id][c];
            q.b6ParkedCount = uint16(last);
        }
        (bb.resends, bb.sentTick, bb.runSince) = (0, 0, uint24(_now()));
    }

    /// @dev The sweep's b6Parked item: unparks when a callback result arrived after the park; the caller lists the
    ///      Covenant's work entry (keyed by the swept chain) iff `list` (the lifecycle predicate), and the lowers
    ///      list is written here if a lower is owed (s3 rc r12 D12-02).
    function _wakeB6(uint256 c, address cov, uint32 id) internal returns (bool unparked, bool list) {
        B6b storage bb = _b6b[cov][id][c];
        // [MU-259] unpark only on a callback result after the park (r18 m-4)
        if (bb.parkLog == 0 || _seq[c][id].hubLogCount < bb.parkLog) return (false, false);
        unparked = bb.flags & F_OVER == 0; // a counted park leaves the walked list
        _unparkB6(c, cov, id);
        bool owes = _owesLower(cov);
        list = bb.flags & F_UN != 0 || owes;
        if (owes) _lowersAdd(cov);
    }

    /// @dev A STATE's own unpark test over the Covenant's parks on both chains (before its write-ahead, D9-02).
    function _unparkOwn(address cov) internal {
        (uint32[8] memory u, uint256 n) = _b6Ids(cov);
        for (uint256 i; i < n; ++i) {
            for (uint256 ci; ci < 2; ++ci) {
                uint256 c = ci == 0 ? CA : CB;
                B6b storage bb = _b6b[cov][u[i]][c];
                if (bb.parkLog != 0 && _seq[c][u[i]].hubLogCount >= bb.parkLog) {
                    bool counted = bb.flags & F_OVER == 0;
                    _unparkB6(c, cov, u[i]);
                    // a running sweep of the id walks a list that just shrank: one more lap (rc-fix r1 C1-02)
                    if (counted && _sweep[u[i]].on) _markDirty(u[i]);
                }
            }
        }
    }

    /// @dev A STATE's PB-7 resends (each id it holds on c, while seqApplied < seqOut) and probes (every (chain, id)
    ///      on which RC storage shows this Covenant with a parked pair or a B6 park; r18 D18-01, r19 D19-01); one
    ///      rate key per (chain, id) shared by both (D5-06).
    function _probes(uint256 c, address cov, Bud memory bud) internal {
        CovRec storage k = _cov[c][cov];
        for (uint256 i; i < k.nHold; ++i) {
            uint32 id = _vault[c][_hold[c][cov][i].vault].id;
            SeqRec storage q = _seq[c][id];
            if (id != 0 && q.seqApplied < q.seqOut) _resend(c, id, bud);
        }
        (uint32[8] memory u, uint256 n) = _b6Ids(cov);
        for (uint256 ci; ci < 2; ++ci) {
            uint256 cc = ci == 0 ? CA : CB;
            for (uint256 i; i < n; ++i) {
                if (_b6b[cov][u[i]][cc].parkLog != 0 || _parkedPairFor(cc, cov, u[i])) _resend(cc, u[i], bud);
            }
            CovRec storage kk = _cov[cc][cov];
            for (uint256 i; i < kk.nHold; ++i) {
                address v = _hold[cc][cov][i].vault;
                if (_pair[cc][cov][v].parkedLogCount != 0) _resend(cc, _vault[cc][v].id, bud);
            }
        }
    }

    function _parkedPairFor(uint256 c, address cov, uint32 id) internal view returns (bool) {
        CovRec storage k = _cov[c][cov];
        for (uint256 i; i < k.nHold; ++i) {
            address v = _hold[c][cov][i].vault;
            if (_vault[c][v].id == id && _pair[c][cov][v].parkedLogCount != 0) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ the lowers list (per Covenant, FIFO)

    function _lowersAdd(address cov) internal {
        LowerLink storage l = _lPrev[cov];
        if (l.listed) return;
        (l.listed, l.prev) = (true, _lTail);
        if (_lTail != address(0)) _lNext[_lTail] = cov;
        else _lHead = cov;
        _lTail = cov;
        _lowersCount += 1;
    }

    function _lowersRemove(address cov) internal {
        LowerLink storage l = _lPrev[cov];
        if (!l.listed) return;
        address p = l.prev;
        address nx = _lNext[cov];
        if (p != address(0)) _lNext[p] = nx;
        else _lHead = nx;
        if (nx != address(0)) _lPrev[nx].prev = p;
        else _lTail = p;
        delete _lPrev[cov];
        delete _lNext[cov];
        _lowersCount -= 1;
    }

    /// @dev Cron floor (2): pop ≤ STALE_POPS stale heads, then send ONE lower of an owing head and move it to the
    ///      tail if it still owes (s3 rc r8 D8-01, r10 D10-01).
    function _lowersFloor(Bud memory bud) internal {
        for (uint256 pops; pops < STALE_POPS && _lHead != address(0) && gasleft() >= GAS_GUARD; ++pops) {
            if (_owesLower(_lHead)) break;
            _lowersRemove(_lHead); // [MU-245] a stale head costs one pop (never a correctness fault)
        }
        address h = _lHead;
        if (h == address(0) || gasleft() < GAS_GUARD || !_owesLower(h)) return;
        _sendLowers(h, bud, 1);
        if (_owesLower(h)) {
            _lowersRemove(h);
            _lowersAdd(h);
        } else {
            _lowersRemove(h);
        }
    }


    /// @dev Records a chain's (budget, exposure) for a (covenant, id) under the nonce gate (spec §5.5, r4 D4-02).
    function _recordBudget(uint256 c, address cov, uint32 id, uint128 budget, uint64 nonce, uint128 exposure)
        internal
        virtual
    {
        // one slot per (covenant, id, chain) at a first STATE (spec §5.5 Bounds); the next nonce is above
        // appliedNonce, which is ≥ the Hub's n0 once a STATE is recorded
        B6a storage x = _b6a[cov][id][c];
        x.flags |= F_BASE;
        // [MU-244] the nonce gate on STATE: an older budget never overwrites a newer answer (r4 D4-02; LF-S4-2)
        if (nonce < x.appliedNonce) return;
        (x.appliedNonce, x.appliedB, x.E) = (uint24(nonce), _sat(budget), _sat(exposure));
    }




    function _baseIn(Base[] calldata b, uint32 id) internal pure returns (bool) {
        for (uint256 i; i < b.length; ++i) {
            if (b[i].id == id) return true;
        }
        return false;
    }
}
