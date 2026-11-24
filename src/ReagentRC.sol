// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LogRecord, IRnkSystem} from "./interfaces/IReactive.sol";
import {IReagentHub} from "./interfaces/IReagent.sol";
import {Kind} from "./interfaces/IReagentRC.sol";
import {RcBase} from "./RcBase.sol";
import {RcExt} from "./RcExt.sol";

/// @title ReagentRC
/// @notice The reactive contract on Lasna (spec §3.2, §5.5): it keeps each curator's conduct record across its vaults
///         on both chains and pushes it to both Hubs; it binds a registered bundler's new vault from `react()`. The
///         STATE ingestion, the exit scheduler, B6 reconcile and the Cron tick run in `RcExt` (internal
///         `delegatecall` only; no public forward, s3 rc r2 D2-05). `react` returns early on any log it does not
///         handle and reverts only for a wrong caller (PB-21).
contract ReagentRC is RcBase {
    address public immutable OWNER;
    address public immutable EXT;

    constructor(address owner_, address ext_) {
        // [MU-200] an extension without code would make every delegated reaction a silent no-op (D2-07 class)
        if (ext_.code.length == 0) revert NotDelegated();
        OWNER = owner_;
        EXT = ext_;
        for (uint8 k; k < 5; ++k) {
            _gas[CA][k] = _formula(CA, k);
            _gas[CB][k] = _formula(CB, k);
        }
    }

    modifier onlyOwner() {
        // [MU-201] the registry and the gas table are the owner's (spec §7 trust roots)
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    // ================================================================== registry (spec §3.2, R-REG)

    function addCurator(uint32 id) external onlyOwner {
        // [MU-202] ids start at 1 (r2 m-4); once
        if (id == 0 || _curator[id].exists) revert Exists();
        _curator[id].exists = true;
        emit CuratorAdded(id);
    }

    function addFactory(uint256 c, address f) external onlyOwner {
        // [MU-203] only the two chains, write-once
        if (!_isChain(c)) revert BadChain();
        if (_factory[c] != address(0) || f == address(0)) revert Exists();
        _factory[c] = f;
        emit FactoryAdded(c, f);
    }

    /// @notice Registers a chain's Hub (one address on both live chains) and subscribes its three topics.
    function addHub(uint256 c, address h) external onlyOwner {
        if (!_isChain(c)) revert BadChain();
        if (_hub[c] != address(0) || h == address(0)) revert Exists();
        _hub[c] = h;
        _sub(c, h, T_NOTE, IGNORE);
        _sub(c, h, T_APPLIED, IGNORE);
        _sub(c, h, T_BUDGET, IGNORE);
        emit HubAdded(c, h);
    }

    /// @notice A bundler of curator `id` on chain `c`: its vault is bound and watched when its `Deployed` arrives
    ///         (PA-8, PB-5). It must be registered before it deploys (spec §12).
    function addBundler(uint32 id, uint256 c, address b) external onlyOwner {
        if (!_isChain(c)) revert BadChain();
        Curator storage k = _curator[id];
        if (!k.exists) revert Unknown();
        // [MU-204] the chain's factory first: the subscription names it (s3 rc r1 D1-10)
        if (_factory[c] == address(0)) revert NoFactory();
        if (b == address(0) || _bundlerId[c][b] != 0) revert Exists();
        uint8 n = c == CA ? k.nbA : k.nbB;
        // [MU-205] at most 4 bundlers per id per chain (PB-8)
        if (n >= MAX_PER_CHAIN) revert Full();
        if (c == CA) k.nbA = n + 1;
        else k.nbB = n + 1;
        _bundlerId[c][b] = id;
        _sub(c, _factory[c], T_DEPLOYED, uint256(uint160(b)));
        emit BundlerAdded(id, c, b);
    }

    /// @notice A kind's callback gas limit, within [the formula value, MAX] (spec §5.6, s3 rc r1 D1-08).
    function setGas(uint256 c, uint8 kind, uint64 limit) external onlyOwner {
        if (!_isChain(c)) revert BadChain();
        if (kind > Kind.PLAN) revert BadKind();
        // [MU-206] never below the formula (no callback starves) and never above MAX (every kind deliverable)
        if (limit < _formula(c, kind) || limit > MAX_CALLBACK_GAS) revert BadGas();
        emit GasSet(c, kind, _gas[c][kind], limit);
        _gas[c][kind] = limit;
    }

    // ================================================================== payer (spec §3.2, R-PAYER)

    /// @notice The system contract pulls a debt from this balance (AbstractPayer semantics): exact, to SYSTEM only.
    function pay(uint256 amount) external {
        // [MU-207] only the system contract asks for payment
        if (msg.sender != SYSTEM) revert NotSystem();
        // exactly the amount, never a partial payment
        if (address(this).balance < amount) revert ShortBalance();
        (bool ok,) = SYSTEM.call{value: amount}("");
        if (!ok) revert PayFailed();
    }

    receive() external payable {}

    // ================================================================== react (spec §5.5)

    function react(LogRecord calldata l) external {
        // [MU-209] only the system contract delivers logs (PB-21: the only revert)
        if (msg.sender != SYSTEM) revert NotSystem();
        uint256 c = l.chainId;
        if (c == LASNA) {
            if (l.emitter == CRON && l.topic0 == T_CRON100 && _cronOn) {
                // the rotation phase from the Cron log's OWN block (each Cron event distinct; v13 r1 V1-01)
                _delegate(abi.encodeCall(RcExt.cron, ((l.blockNumber / 100) % 3))); // [MU-276]
            }
        } else if (_isChain(c)) {
            address e = l.emitter;
            // [MU-210] the (chain, registered Hub) filter (A-XCHAIN, A-NOTE-FORGE)
            if (e == _hub[c] && e != address(0)) {
                if (l.topic0 == T_APPLIED) _onApplied(c, l);
                else if (l.topic0 == T_NOTE || l.topic0 == T_BUDGET) _delegate(abi.encodeCall(RcExt.onHubLog, (l)));
            } else if (e == _factory[c] && e != address(0)) {
                if (l.topic0 == T_DEPLOYED) _onDeployed(c, l);
            } else if (_vault[c][e].id != 0) {
                _onVaultLog(c, e, l);
            } else {
                address v = _hookVault[c][e];
                if (v != address(0) && l.topic0 == T_LATCH) _onLatch(c, v, l);
            }
        }
        _cronGate();
    }

    /// @dev Runs `RcExt` code on this contract's storage (internal only; RcExt re-checks SYSTEM).
    function _delegate(bytes memory data) internal {
        (bool ok, bytes memory r) = EXT.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    // ------------------------------------------------------------------ dynamic registration (PA-8, R-DYN)

    function _onDeployed(uint256 c, LogRecord calldata l) internal {
        uint32 id = _bundlerId[c][address(uint160(l.topic1))];
        // [MU-211] only a registered bundler's vault (R-DYN-FOREIGN)
        if (id == 0 || l.data.length < 96) return;
        (address vault,, address hook) = abi.decode(l.data[0:96], (address, address, address));
        // [MU-212] a duplicated Deployed changes nothing (s3 rc r1 D1-10)
        if (_vault[c][vault].id != 0 || vault == address(0)) return;
        Curator storage k = _curator[id];
        uint8 n = c == CA ? k.nvA : k.nvB;
        if (n >= MAX_PER_CHAIN) return; // a fifth vault per id per chain is not bound (spec §5.5 Bounds)
        if (c == CA) k.nvA = n + 1;
        else k.nvB = n + 1;
        _vault[c][vault] = VaultRec(id, hook, 0, false, 0, false);
        _vault2[c][vault].actionSub = true;
        _hookVault[c][hook] = vault;
        _idVaults[id][c][n] = vault;
        uint256 nv = _nVaults;
        _vaultList[nv] = (c << 160) | uint160(vault);
        _nVaults = nv + 1;
        // [MU-284] a registration that takes a stale slot (left by a drop) leaves a new one at the high-water mark,
        // paid here, so a re-list never writes a fresh slot inside a STATE (rc-fix r4 C4-01)
        if (nv < _vaultHigh) {
            _vaultList[_vaultHigh] = (c << 160) | uint160(vault);
            _vaultHigh += 1;
        } else {
            _vaultHigh = nv + 1;
        }
        _sub(c, vault, T_PROCESSED, IGNORE);
        _sub(c, vault, T_MODE, IGNORE);
        _sub(c, vault, T_RETIRED, IGNORE);
        _sub(c, vault, T_EPOCH, IGNORE);
        _sub(c, vault, T_ACTION, IGNORE);
        _sub(c, hook, T_LATCH, IGNORE);
        _send(c, Kind.VAULT, abi.encodeCall(IReagentHub.rcVault, (address(0), vault, id)));
        emit VaultRegistered(c, vault, id, hook);
    }

    // ------------------------------------------------------------------ the conduct record (PB-1, R-BREACH, R-GONE)

    function _onLatch(uint256 c, address vault, LogRecord calldata l) internal {
        if (l.data.length < 32) return;
        uint32 s = uint32(uint256(bytes32(l.data[0:32])));
        VaultRec storage v = _vault[c][vault];
        // [MU-213] the record is the max latched seq per vault: a duplicate or reordered latch adds nothing (A-DELTA)
        if (s <= v.maxSeq) return;
        v.maxSeq = s;
        _rearmDrip(c, vault);
        _snapshot(v.id, true);
        _delegate(abi.encodeCall(RcExt.markDirty, (v.id)));
    }

    function _onVaultLog(uint256 c, address vault, LogRecord calldata l) internal {
        VaultRec storage v = _vault[c][vault];
        uint256 t = l.topic0;
        if (t == T_MODE) {
            if (l.data.length < 64) return;
            uint8 to = uint8(uint256(bytes32(l.data[32:64])));
            // [MU-214] EXITED is gone (B3)
            if (to == 2) _gone(v);
        } else if (t == T_RETIRED) {
            _gone(v);
        } else if (t == T_PROCESSED) {
            _rearmDrip(c, vault);
            _delegate(abi.encodeCall(RcExt.markDirty, (v.id)));
        } else if (t == T_ACTION) {
            _onAction(c, vault, v.id);
        } else if (t == T_EPOCH) {
            VaultRec2 storage w = _vault2[c][vault];
            w.actionsThisEpoch = 0;
            if (!w.actionSub) {
                w.actionSub = true;
                _sub(c, vault, T_ACTION, IGNORE);
            }
            _delegate(abi.encodeCall(RcExt.onEpoch, (c, vault, uint32(l.topic1))));
        }
    }

    function _gone(VaultRec storage v) internal {
        if (v.gone) return;
        v.gone = true;
        _snapshot(v.id, true);
        _delegate(abi.encodeCall(RcExt.markDirty, (v.id)));
    }

    /// @dev `Action`: refreshes the record, never arms an exit; ≤ ACTION_BUDGET snapshots per vault epoch, then the
    ///      exact six-argument unsubscribe until the next `EpochRecorded` (PB-6, R-ACTION).
    function _onAction(uint256 c, address vault, uint32 id) internal {
        VaultRec2 storage w = _vault2[c][vault];
        if (!w.actionSub) return;
        w.actions += 1;
        if (w.actionsThisEpoch >= ACTION_BUDGET) return;
        w.actionsThisEpoch += 1;
        _snapshot(id, false);
        // [MU-215] at the per-epoch budget, the exact six-argument unsubscribe (A-ACTION-SPAM)
        if (w.actionsThisEpoch == ACTION_BUDGET) {
            w.actionSub = false;
            _unsub(c, vault, T_ACTION, IGNORE);
        }
    }

    /// @dev A breach reaction re-targets the vault's drip end (an estimate, PA-5; ticks from block.number).
    function _rearmDrip(uint256 c, address vault) internal {
        VaultRec2 storage w = _vault2[c][vault];
        uint32 end = _now() + _dripTicks(c);
        if (end > w.dripEndTick) w.dripEndTick = end;
    }

    /// @notice A fresh snapshot of `id`'s record to both Hubs (`rcConduct`, seq-gated and monotone there).
    function _snapshot(uint32 id, bool totalsChanged) internal {
        Conduct storage k = _conductOf[id];
        uint32 b;
        uint32 g;
        uint32 a;
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            address[4] storage vs = _idVaults[id][c];
            for (uint256 j; j < MAX_PER_CHAIN; ++j) {
                address v = vs[j];
                if (v == address(0)) break;
                VaultRec storage r = _vault[c][v];
                b += r.maxSeq;
                if (r.gone) g += 1;
                a += _vault2[c][v].actions;
            }
        }
        uint32 s = k.seq + 1;
        (k.breaches, k.gone, k.actions, k.seq) = (b, g, a, s);
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            if (_hub[c] == address(0)) continue;
            SeqRec storage q = _seq[c][id];
            q.seqOut = s;
            if (totalsChanged) q.seqTotals = s;
            _send(c, Kind.CONDUCT, abi.encodeCall(IReagentHub.rcConduct, (address(0), id, b, g, a, uint64(s))));
        }
    }

    // ------------------------------------------------------------------ Hub results

    /// @dev `Applied(id, seq)`: records `seqApplied` (max) and the callback-result count; never a send (R-NOLOOP).
    function _onApplied(uint256 c, LogRecord calldata l) internal {
        if (l.data.length < 32) return;
        uint32 id = uint32(l.topic1);
        uint32 s = uint32(uint256(bytes32(l.data[0:32])));
        SeqRec storage q = _seq[c][id];
        if (s > q.seqApplied) q.seqApplied = s;
        q.hubLogCount += 1;
        if (q.parkedCount > 0 || q.b6ParkedCount > 0) _delegate(abi.encodeCall(RcExt.markDirty, (id)));
    }

    // ------------------------------------------------------------------ the Cron gate (spec §5.5 "Deferred work")

    function _cronGate() internal {
        // [MU-216] Cron only while there is deferred work (C-10)
        if (!_cronOn && _pendingPairs + _workLen + _sweeps > 0) {
            _cronOn = true;
            IRnkSystem(SYSTEM).subscribe(LASNA, CRON, T_CRON100, IGNORE, IGNORE, IGNORE);
        }
    }

    // ================================================================== views

    function gasLimit(uint256 c, uint8 kind) external view returns (uint64) {
        return _gas[c][kind];
    }

    function formulaGas(uint256 c, uint8 kind) external pure returns (uint64) {
        return _formula(c, kind);
    }

    function hubOf(uint256 c) external view returns (address) {
        return _hub[c];
    }

    function factoryOf(uint256 c) external view returns (address) {
        return _factory[c];
    }

    function curatorExists(uint32 id) external view returns (bool) {
        return _curator[id].exists;
    }

    function bundlerId(uint256 c, address b) external view returns (uint32) {
        return _bundlerId[c][b];
    }

    function vaultOf(uint256 c, address vault)
        external
        view
        returns (uint32 id, address hook, uint32 maxSeq, bool gone, uint32 actions)
    {
        VaultRec storage v = _vault[c][vault];
        return (v.id, v.hook, v.maxSeq, v.gone, _vault2[c][vault].actions);
    }

    function conduct(uint32 id) external view returns (uint32, uint32, uint32, uint32) {
        Conduct storage k = _conductOf[id];
        return (k.breaches, k.gone, k.actions, k.seq);
    }

    function seqOf(uint256 c, uint32 id) external view returns (uint32, uint32, uint32, uint32) {
        SeqRec storage q = _seq[c][id];
        return (q.seqOut, q.seqApplied, q.seqTotals, q.hubLogCount);
    }

    function counters() external view returns (uint256, uint256, uint256, bool) {
        return (_pendingPairs, _workLen, _sweeps, _cronOn);
    }

    /// @notice B6 per (covenant, id, chain) (spec §5.5): applied B, E, the highest unanswered B, the RC's last nonce,
    ///         the applied nonce, flags (1 unanswered, 2 raise, 4 Base reported, 8 overflowed park), the park mark.
    function b6Of(address cov, uint32 id, uint256 c)
        external
        view
        returns (uint96 appliedB, uint96 e, uint96 unB, uint32 nonce, uint32 appliedNonce, uint8 flags, uint32 parkLog)
    {
        B6a storage x = _b6a[cov][id][c];
        B6b storage b = _b6b[cov][id][c];
        return (x.appliedB, x.E, b.unB, b.nonce, x.appliedNonce, b.flags | x.flags, b.parkLog);
    }

    /// @notice The lowers list (head, tail, length), the work list's length and the b6Parked count of (chain, id).
    function lowersOf() external view returns (address head, address tail, uint256 count) {
        return (_lHead, _lTail, _lowersCount);
    }

    function lowersNext(address cov) external view returns (address next, address prev, bool listed) {
        return (_lNext[cov], _lPrev[cov].prev, _lPrev[cov].listed);
    }

    function parkedOf(uint256 c, uint32 id) external view returns (uint16 parkedCount, uint16 b6ParkedCount) {
        SeqRec storage q = _seq[c][id];
        return (q.parkedCount, q.b6ParkedCount);
    }

    /// @notice A dirty id's sweep (spec §3.5): the next index of its walk, the lap in progress, the lap it ends at.
    function sweepOf(uint32 id) external view returns (uint32 pos, uint32 lap, uint32 endLap, bool on) {
        Sweep storage w = _sweep[id];
        return (w.pos, w.lap, w.endLap, w.on);
    }

    function workAt(uint256 i) external view returns (uint256 chain, address cov) {
        uint256 e = _workList[i];
        return (e >> 160, address(uint160(e)));
    }

    function covOf(uint256 c, address cov)
        external
        view
        returns (uint128 cap, uint32 rulesNonce, uint32 noteNonce, uint32 unsettledR, bool workListed, uint8 nHold)
    {
        CovRec storage k = _cov[c][cov];
        return (k.cap, k.rulesNonce, k.noteNonce, k.unsettledR, k.workListed, k.nHold);
    }

    function pairOf(uint256 c, address cov, address vault)
        external
        view
        returns (uint32 nextTick, uint32 waitSeq, uint32 parkedLogCount, bool pending, bool suspended, uint8 tries)
    {
        Pair storage p = _pair[c][cov][vault];
        return (p.nextTick, p.waitSeq, p.parkedLogCount, p.pending, p.suspended, p.tries);
    }

    event CuratorAdded(uint32 indexed id);
    event BundlerAdded(uint32 indexed id, uint256 indexed chain, address bundler);
    event FactoryAdded(uint256 indexed chain, address factory);
    event HubAdded(uint256 indexed chain, address hub);
}
