// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICovenant, ICovenantFactory, IReagentHub, NoteKind, Outcome, Rulebook, Base} from "./interfaces/IReagent.sol";

interface IDepositTo {
    function depositTo(address recipient) external payable;
}

/// @title ReagentHub
/// @notice The per-chain, immutable, ownerless sole callback recipient (spec §3.2, §5.2). It holds the RC-only facts
///         (the curator conduct mirror and the vault bindings), the B6 chain budgets of every Covenant of its factory,
///         and no tokens; its ETH (if any) pays only its own fees, to the proxy (F-004). Every callback authenticates the proxy and the injected RC address first; after that it
///         never reverts: every outcome is an event (PA-3).
contract ReagentHub is IReagentHub {
    // ------------------------------------------------------------------ immutables

    address public immutable RC;
    address public immutable FACTORY;
    address public immutable PROXY;

    // ------------------------------------------------------------------ parameters (spec §5.6, §6)

    uint256 internal constant RESERVE = 40_000;
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ state

    struct Conduct {
        uint32 breaches;
        uint32 gone;
        uint32 actions;
        uint64 seq;
    }

    struct Bud {
        uint128 b; // stored budget; meaningful only when `written`
        uint64 budgetNonce; // the last consumed RC nonce
        uint64 rulesNonce; // the Covenant's rulesNonce when the last RC value was applied
        bool written; // b holds a value (else the effective value is the cap/2 default)
        bool listed; // the id has been in this Covenant's `ids` before (r26 D26-01)
    }

    mapping(uint32 => Conduct) internal _conduct;
    mapping(address => uint32) public vaultId;
    mapping(uint32 => address[]) internal _idVaults;
    mapping(address => mapping(uint32 => Bud)) internal _bud;
    mapping(address => uint32[4]) internal _ids; // the Hub's own copy of each Covenant's Rulebook `ids`

    // ------------------------------------------------------------------ errors

    error NotProxy();
    error NotRc();
    error NotCovenant();
    error UnknownChain(uint256 chainId);
    error ShortBalance();
    error PayFailed();

    constructor(address rc) {
        RC = rc;
        FACTORY = msg.sender;
        PROXY = _proxyFor(block.chainid);
    }

    /// @dev Same initcode on both chains (r1 D1-13): the proxy comes from the chain id, never an argument [M: G1].
    function _proxyFor(uint256 chainId) internal pure returns (address) {
        if (chainId == 1301) return 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
        if (chainId == 11155111) return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4;
        revert UnknownChain(chainId);
    }

    // ------------------------------------------------------------------ auth

    modifier callback(address rc) {
        _checkProxy();
        _checkRc(rc);
        _;
    }

    /// @dev The defences are internal virtual so that the positive controls (spec §9) can remove one at a time in a
    ///      test harness; production never overrides them.
    function _checkProxy() internal view virtual {
        // [MU-001] only the chain's callback proxy delivers (A-SPOOF-PROXY)
        if (msg.sender != PROXY) revert NotProxy();
    }

    function _checkRc(address rc) internal view virtual {
        // [MU-002] the first word, injected by the network, is our RC (A-SPOOF-RC, A-SPOOF-WORD)
        if (rc != RC) revert NotRc();
    }

    function _shortGas(uint256 need) internal view virtual returns (bool) {
        return gasleft() < need * 64 / 63 + RESERVE;
    }

    /// @dev The gas forwarded to the Covenant: everything above the reserve (NEED is a floor, D2-01).
    function _fwd(uint256) internal view virtual returns (uint256) {
        return gasleft() - RESERVE;
    }

    function _staleBudget(uint64 nonce, uint64 stored) internal pure virtual returns (bool) {
        return nonce <= stored;
    }

    function _lowered(uint128 b0, uint128 newB, uint128 e) internal pure virtual returns (uint128) {
        return newB >= b0 ? newB : _min(b0, _max(newB, e));
    }

    function _syncLower(uint128 b, uint128 maxB) internal pure virtual returns (uint128) {
        return b > maxB ? maxB : b;
    }

    function _wasListed(Bud storage s) internal view virtual returns (bool) {
        return s.listed;
    }

    function _isCovenant(address c) internal view virtual returns (bool) {
        return ICovenantFactory(FACTORY).isCovenant(c);
    }

    // ------------------------------------------------------------------ callbacks

    /// @inheritdoc IReagentHub
    function rcConduct(address rc, uint32 id, uint32 breaches, uint32 gone, uint32 actions, uint64 seq)
        external
        callback(rc)
    {
        Conduct storage c = _conduct[id];
        // [MU-003] seq-gated: an older or duplicate snapshot changes nothing (I-IDEM, A-LATEPAUSE)
        if (seq <= c.seq) {
            emit Stale(1, seq);
            return;
        }
        // [MU-004] a monotone merge: counts never fall (I-MONO)
        if (breaches > c.breaches) c.breaches = breaches;
        if (gone > c.gone) c.gone = gone;
        if (actions > c.actions) c.actions = actions;
        c.seq = seq;
        emit Applied(id, seq);
    }

    /// @inheritdoc IReagentHub
    function rcVault(address rc, address vault, uint32 id) external callback(rc) {
        // [MU-005] write-once binding (A-IDSPOOF)
        if (vaultId[vault] != 0 || id == 0) {
            emit Stale(4, 0);
            return;
        }
        address[] storage vs = _idVaults[id];
        if (vs.length >= 4) {
            emit Stale(5, 0);
            return;
        }
        vaultId[vault] = id;
        vs.push(vault);
        emit VaultBound(vault, id);
    }

    /// @inheritdoc IReagentHub
    function rcBudget(address rc, address covenant, uint32 id, uint128 newB, uint64 budgetNonce, uint64 rulesNonce_)
        external
        callback(rc)
    {
        // [MU-006] factory membership first, before any Covenant read (r20 m-4)
        if (!_isCovenant(covenant)) {
            emit Stale(2, budgetNonce);
            return;
        }
        Bud storage s = _bud[covenant][id];
        // [MU-007] the nonce gate (A-REPLAY)
        if (_staleBudget(budgetNonce, s.budgetNonce)) {
            emit Stale(2, budgetNonce);
            return;
        }
        ICovenant cov = ICovenant(covenant);
        uint64 r = cov.rulesNonce();
        uint128 b0 = _effective(covenant, id, cov);
        s.budgetNonce = budgetNonce;
        // [MU-008] a rules mismatch or an id outside `ids` is answered at the unchanged B (r2 D2-01, r21 D21-02, r23)
        if (rulesNonce_ != r || !_inIds(covenant, id)) {
            emit BudgetApplied(covenant, id, b0, budgetNonce, r);
        } else {
            uint128 e = cov.exposure(id);
            // [MU-009] a lower never rises above B and never cuts below spent exposure (A-B6-CLAWBACK)
            uint128 applied = _lowered(b0, newB, e);
            s.b = applied;
            s.written = true;
            s.rulesNonce = r;
            emit BudgetApplied(covenant, id, applied, budgetNonce, r);
        }
        // the unlimited STATE answering this callback (r21 m-3); never allowed to revert here, never silent (s2 F1-06)
        try cov.emitState() {}
        catch {
            emit Stale(6, budgetNonce);
        }
    }

    /// @inheritdoc IReagentHub
    function rcExit(address rc, address covenant, address vault, uint64 minSeq, uint32 breachCount)
        external
        callback(rc)
    {
        if (!_relayable(covenant, vault)) return;
        uint256 need = _need(true);
        // [MU-010] the gas pre-check: a short delivery defers and burns no try (A-GAS63)
        if (_shortGas(need)) {
            _relayNote(covenant, NoteKind.EXIT, vault, Outcome.DEFERRED);
            return;
        }
        // NEED is a floor, not a cap: everything above the Hub's own reserve is forwarded, so a raised gasLimit
        // reaches the Covenant (s2 D2-01)
        // [MU-093] forward everything above the reserve (NEED is a floor, D2-01)
        try ICovenant(covenant).rcExit{gas: _fwd(need)}(vault, minSeq, breachCount) {}
        catch {
            _relayNote(covenant, NoteKind.EXIT, vault, Outcome.RELAY_FAILED);
        }
    }

    /// @inheritdoc IReagentHub
    function rcAllocate(address rc, address covenant, address vault, uint32 vaultEpoch) external callback(rc) {
        if (!_relayable(covenant, vault)) return;
        uint256 need = _need(false);
        // [MU-011] the same pre-check for plan allocations (T-GAS-PLAN)
        if (_shortGas(need)) {
            _relayNote(covenant, NoteKind.PLAN, vault, Outcome.DEFERRED);
            return;
        }
        // [MU-094] the same for plans
        try ICovenant(covenant).rcAllocate{gas: _fwd(need)}(vault, vaultEpoch) {}
        catch {
            _relayNote(covenant, NoteKind.PLAN, vault, Outcome.RELAY_FAILED);
        }
    }

    function _relayable(address covenant, address vault) internal returns (bool) {
        // [MU-012] only deployed Covenants of this Hub's factory are relayed to, and only for bound vaults (r20 m-4)
        if (!_isCovenant(covenant) || vaultId[vault] == 0) {
            emit Stale(3, 0);
            return false;
        }
        return true;
    }

    /// @notice The entry gas the Covenant needs for an exit and a plan deposit (spec §5.6): ×1.3 of the measured
    ///         worst case (s2, `audits/gas-need.json`): 1301 by forge measurement; 11155111 by method (b) (+ the
    ///         Glamsterdam price of each fresh slot the path writes). A floor for the pre-check, never a cap (D2-01).
    function needs() public view returns (uint256 exit, uint256 plan) {
        // [MU-019] the per-chain table (selected by chain id, like PROXY, so T-ADDR holds)
        if (block.chainid == 11155111) return (2_220_000, 2_310_000);
        return (880_000, 1_290_000); // s4 LF-S4-1: ×1.3 of the cold minimum entry (F-011)
    }

    function _need(bool exit) internal view returns (uint256) {
        (uint256 e, uint256 p) = needs();
        return exit ? e : p;
    }

    function _relayNote(address covenant, uint8 kind, address vault, uint8 outcome) internal {
        bytes memory data = kind == NoteKind.EXIT
            ? abi.encode(vault, outcome, uint32(0), uint256(0), uint256(0), Base(0, 0, 0, 0, 0, 0), uint32(0), false, uint64(0))
            : abi.encode(vault, uint32(0), outcome, uint8(0));
        emit Note(_ownerOf(covenant), covenant, kind, data);
    }

    function _ownerOf(address covenant) internal view returns (address o) {
        try ICovenant(covenant).owner() returns (address a) {
            o = a;
        } catch {}
    }

    // ------------------------------------------------------------------ ETH for its own fees (F-004, spec §5.2)

    /// @notice Called by the callback proxy when this Hub's reserves are short: pays exactly `amount` to the proxy
    ///         (AbstractPayer semantics). Only the proxy may call it, and ETH goes only to the proxy (I-ETH).
    function pay(uint256 amount) external virtual {
        // [MU-017] only the proxy asks for payment (T-HUB-PAY (a))
        if (msg.sender != PROXY) revert NotProxy();
        // [MU-018] exactly the amount, never a partial payment (T-HUB-PAY (b), D1-02)
        if (address(this).balance < amount) revert ShortBalance();
        (bool ok,) = PROXY.call{value: amount}("");
        if (!ok) revert PayFailed();
    }

    /// @notice Anyone may move this Hub's whole balance into its own reserves at the proxy (`depositTo` settles a
    ///         debt first, then credits the rest). The runbook step after a direct transfer (D1-03).
    function sweep() public {
        uint256 b = address(this).balance;
        if (b != 0) IDepositTo(PROXY).depositTo{value: b}(address(this));
    }

    /// @notice The name Reactive's documentation uses for the same action.
    function coverDebt() external {
        sweep();
    }

    receive() external payable {}

    // ------------------------------------------------------------------ Covenant entry points

    modifier onlyCovenant() {
        // [MU-013] only Covenants of this Hub's factory note or sync, and only for themselves
        if (!_isCovenant(msg.sender)) revert NotCovenant();
        _;
    }

    /// @inheritdoc IReagentHub
    /// @dev The Covenant applies the STATE rate limit and its exemptions (it alone knows the role and the reason);
    ///      the Hub authenticates and emits.
    function note(uint8 kind, bytes calldata data) external onlyCovenant {
        emit Note(ICovenant(msg.sender).owner(), msg.sender, kind, data);
    }

    /// @inheritdoc IReagentHub
    function syncRules(uint128 maxB, uint32[4] calldata ids) external onlyCovenant {
        address c = msg.sender;
        ICovenant cov = ICovenant(c);
        uint32[4] memory old = _ids[c];
        // (1) entering ids: a re-entry stores its derived value as written; a first listing keeps the default
        for (uint256 i; i < 4; ++i) {
            uint32 id = ids[i];
            if (id == 0 || _has(old, id) || _seenBefore(ids, i)) continue;
            Bud storage s = _bud[c][id];
            if (_wasListed(s)) {
                // [MU-014] re-adding never raises: the derived min(B_stored, E) becomes the written value (r24, r25)
                uint128 e = cov.exposure(id);
                s.b = _min(_stored(c, id, s, cov), e);
                s.written = true;
            } else {
                s.listed = true;
            }
        }
        // (2) the new copy
        _ids[c] = ids;
        // (3) never raise: min(B, maxB) on every listed id, written only when it changes
        for (uint256 i; i < 4; ++i) {
            uint32 id = ids[i];
            if (id == 0 || _seenBefore(ids, i)) continue;
            Bud storage s = _bud[c][id];
            uint128 b = _stored(c, id, s, cov);
            // [MU-015] a local rule change only lowers (I-CAP (c))
            uint128 nb = _syncLower(b, maxB);
            if (nb != b) {
                s.b = nb;
                s.written = true;
            }
        }
    }

    // ------------------------------------------------------------------ views

    function conduct(uint32 id) external view returns (uint32, uint32, uint32, uint64) {
        Conduct memory c = _conduct[id];
        return (c.breaches, c.gone, c.actions, c.seq);
    }

    function idVaults(uint32 id) external view returns (address[] memory) {
        return _idVaults[id];
    }

    function hubIds(address covenant) external view returns (uint32[4] memory) {
        return _ids[covenant];
    }

    /// @inheritdoc IReagentHub
    function budget(address covenant, uint32 id) external view returns (uint128 b, uint64 budgetNonce, uint64 rulesNonce) {
        Bud memory s = _bud[covenant][id];
        return (_effective(covenant, id, ICovenant(covenant)), s.budgetNonce, s.rulesNonce);
    }

    /// @inheritdoc IReagentHub
    function paused(address covenant, uint32 id) external view returns (bool) {
        ICovenant cov = ICovenant(covenant);
        Rulebook memory r = cov.rules();
        (uint32 bb, uint32 bg) = _baseOf(cov, id);
        Conduct memory c = _conduct[id];
        // [MU-016] B7 against the unpause baseline; B3 only when on (r6 m-2)
        return (r.k != 0 && c.breaches >= bb && c.breaches - bb >= r.k) || (r.b3 && c.gone > bg);
    }

    /// @dev The Covenant's unpause baseline (A-LATEPAUSE). Virtual only for the positive control.
    function _baseOf(ICovenant cov, uint32 id) internal view virtual returns (uint32, uint32) {
        return cov.baseline(id);
    }

    // ------------------------------------------------------------------ budget arithmetic

    /// @dev The effective budget: the stored value or the cap/2 default inside `ids`; outside `ids`, the derived
    ///      min(stored-or-default, E), which takes precedence over the default (r25 D25-02, r28 m-1).
    function _effective(address c, uint32 id, ICovenant cov) internal view returns (uint128) {
        Bud storage s = _bud[c][id];
        uint128 b = _stored(c, id, s, cov);
        if (_inIds(c, id)) return b;
        uint128 e = cov.exposure(id);
        return _min(b, e);
    }

    function _stored(address, uint32, Bud storage s, ICovenant cov) internal view returns (uint128) {
        if (s.written) return s.b;
        Rulebook memory r = cov.rules();
        if (r.maxShareBps == 0) return type(uint128).max; // B6 off: no budget
        return uint128(uint256(r.maxShareBps) * r.budget / BPS / 2);
    }

    function _inIds(address c, uint32 id) internal view returns (bool) {
        if (id == 0) return false;
        uint32[4] storage a = _ids[c];
        return a[0] == id || a[1] == id || a[2] == id || a[3] == id;
    }

    function _has(uint32[4] memory a, uint32 id) internal pure returns (bool) {
        return a[0] == id || a[1] == id || a[2] == id || a[3] == id;
    }

    function _seenBefore(uint32[4] calldata a, uint256 i) internal pure returns (bool) {
        for (uint256 j; j < i; ++j) {
            if (a[j] == a[i]) return true;
        }
        return false;
    }

    function _min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    function _max(uint128 a, uint128 b) internal pure returns (uint128) {
        return a > b ? a : b;
    }
}
