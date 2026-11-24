// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TsEnv} from "./TsEnv.sol";
import {Tier} from "touchstone/types/Tier.sol";
import {Tiers} from "touchstone-script/Tiers.sol";
import {TouchstoneFactory} from "touchstone/TouchstoneFactory.sol";
import {ReagentHub} from "../../src/ReagentHub.sol";
import {Covenant} from "../../src/Covenant.sol";
import {CovenantExt} from "../../src/CovenantExt.sol";
import {CovenantFactory} from "../../src/CovenantFactory.sol";
import {ICovenant} from "../../src/interfaces/IReagent.sol";
import {LogRecord, CallbackV1, IReactive} from "../../src/interfaces/IReactive.sol";

/// @notice The Lasna system contract as the R layer needs it (spec §9 layers): like the live one, it records
///         subscriptions and callback requests as EVENTS, and it burns exactly the measured Lasna cost of each call
///         (s3 rc r3 D3-06: `subscribe` 9,932 cold / 5,432 warm; a request 12,887 at a 260-B payload + 8 per extra
///         byte; Lasna traces of the G1 RC). The harness rebuilds subscription history and the request queue from
///         these events. Etched at 0x8888…8888; it holds no storage, so its forge cost is only what it burns.
contract MockSystem {
    event Subscribed(address indexed rc, uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event Unsubscribed(address indexed rc, uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event Requested(address indexed rc, uint256 chainId, address recipient, uint64 gasLimit, bytes payload);
    event Deposited(address indexed who, uint256 amount);

    uint256 internal constant SUB_COLD = 9_932; // charged on every call: the conservative side (s3 rc r4 D4-07)
    uint256 internal constant REQ_260 = 12_887;

    function subscribe(uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        uint256 g0 = gasleft();
        require(block.chainid == 5318007, "MockSystem: subscribe off Lasna (test context)");
        emit Subscribed(msg.sender, c, e, t0, t1, t2, t3);
        _burnTo(g0, SUB_COLD);
    }

    function unsubscribe(uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        uint256 g0 = gasleft();
        require(block.chainid == 5318007, "MockSystem: unsubscribe off Lasna (test context)");
        emit Unsubscribed(msg.sender, c, e, t0, t1, t2, t3);
        _burnTo(g0, SUB_COLD);
    }

    function requestCallbackV_1_0(CallbackV1 calldata cfg) external {
        uint256 g0 = gasleft();
        require(block.chainid == 5318007, "MockSystem: request off Lasna (test context)");
        emit Requested(msg.sender, cfg.chainId, cfg.recipient, cfg.gasLimit, cfg.payload);
        uint256 extra = cfg.payload.length > 260 ? (cfg.payload.length - 260) * 8 : 0;
        _burnTo(g0, REQ_260 + extra);
    }

    function depositTo(address who) external payable {
        emit Deposited(who, msg.value);
    }

    /// @dev The calibration self-test's baseline: the same argument shapes, no work.
    function nopSub(uint256, address, uint256, uint256, uint256, uint256) external {}

    function nopReq(CallbackV1 calldata) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev The live system contract receives payments (`pay` from a reactive contract).
    receive() external payable {}

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    /// @dev Burns until `target` gas has been used since `g0` (the measured live cost of the call's execution).
    function _burnTo(uint256 g0, uint256 target) internal view {
        // + 200: the dispatch and decoding before `g0` differ slightly from the calibration baseline; never under
        while (g0 - gasleft() < target + 200) {}
    }
}

/// @notice A callback proxy's funding side (the Hub's `sweep` calls `depositTo`): etched at each chain's proxy.
contract MockProxy {
    mapping(address => uint256) public reserves;

    function depositTo(address who) external payable {
        reserves[who] += msg.value;
    }

    receive() external payable {}
}

/// @notice The R layer (spec §9 layers, as folded by s3 rc r1 D1-04/D1-05): one EVM, two origin chains and Lasna.
///         - Each chain has its own Reagent deployment (a plain `new` under `vm.chainId`), its own Touchstone
///           factory and tier (1301 DEMO at 1 s blocks, 11155111 TEST at 13.2 s blocks), and its own block clock;
///           all clocks follow one wall clock (ms), Lasna's at 1.13 s per block.
///         - Origin logs are captured by `vm.recordLogs` per chain context and become exact `LogRecord`s.
///         - A log reaches the RC only while a live subscription of the RC matches it (exact fields and
///           wildcards), once per matching subscription; Cron100 logs are synthesised only while subscribed.
///         - The chain-independent addresses (factory, Hub, Covenants: one address on both live chains) are
///           translated at this boundary only: the RC sees chain A's address for both chains.
///         - Callback delivery as the proxy does it: dropped under 100k gas; the payload's first argument
///           overwritten with the requesting RC; `63/64 · (gasLimit − F[chain])` entry gas; a revert is charged and
///           never retried; a Hub in debt receives nothing.
abstract contract RcEnv is TsEnv {
    uint256 internal constant CA = 1301;
    uint256 internal constant CB = 11155111;
    uint256 internal constant LASNA = 5318007;
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    struct ChainEnv {
        uint256 id;
        uint256 btMs; // block time
        uint256 bn0; // block number at wall 0
        uint256 F; // proxy overhead (spec §5.6)
        Tier tier;
        uint256 tierBt;
        TouchstoneFactory ts;
        CovenantFactory factory;
        ReagentHub hub;
        address proxy;
    }

    struct Inbox {
        LogRecord log;
        uint256 originBn; // the Lasna block at the log's origin (subscriptions are matched here, D3-07)
        uint256 arriveBn; // the Lasna block at which it reaches the RC
    }

    struct Sub {
        address rc;
        uint256 since; // the Lasna block of the subscribe
        uint256 until; // the Lasna block of the matching unsubscribe (0 = live)
        uint256 chainId;
        address emitter;
        uint256 t0;
        uint256 t1;
        uint256 t2;
        uint256 t3;
    }

    struct Req {
        address rc;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    struct Delivery {
        uint256 chainId;
        address recipient;
        bytes4 selector;
        uint64 gasLimit;
        uint8 outcome; // 1 delivered ok, 2 reverted (charged), 3 dropped < 100k, 4 Hub in debt, 5 dropped by policy
    }

    enum Act {
        DELIVER,
        DROP,
        HOLD,
        DUP
    }

    MockSystem internal sys;
    address internal rcAddr;
    mapping(uint256 => ChainEnv) internal ch;
    uint256 internal cur; // the current context: CA, CB or LASNA
    uint256 internal wallMs;
    uint256 internal ts0;
    uint256 internal lasnaBn0;
    uint256 internal lastCronBn; // the last Cron100 block processed
    uint256 internal lagBlocks = 1; // Lasna blocks between an origin log and its reaction (G1: the next block)
    mapping(uint256 => uint256) internal chainLag; // an extra per-chain lag (s3 rc r4 D4-05)
    mapping(uint256 => uint256) internal deliveryMs; // request → delivery on each chain (G1: 3 s / one 13.2 s block)

    struct Due {
        Req r;
        uint256 atMs; // the wall time of delivery
    }

    Due[] internal dueQ; // callback requests waiting for their delivery time (s3 rc r5 D5-07)
    Inbox[] internal heldLogs; // origin logs held back by `_logPolicy`
    LogRecord[] internal originHist; // every origin log ever emitted, in order (evidence for positive controls)
    bool internal noAutoPump; // set by a cell that wants time to pass with nothing reacting
    uint256 internal subLag; // Lasna blocks before a new subscription takes effect (s3 rc r2 D2-07)
    uint256 internal txSeq;

    mapping(address => address) internal toA; // chain-B chain-independent address → chain A's
    mapping(address => address) internal toB;

    Inbox[] internal inbox;
    Sub[] internal subsHist; // every subscription ever made, with its life (rebuilt from the mock's events)
    Req[] internal reqQ; // callback requests not yet delivered
    uint256 internal subscribeCalls;
    uint256 internal unsubscribeMisses; // a live unsubscribe matching nothing fails silently (research §1)
    Req[] internal held; // requests held back by a policy
    Delivery[] internal deliveries;
    Vm.Log[] internal lasnaLogs; // events emitted on Lasna (the RC's own)
    uint256 internal reactCalls;
    uint256 internal reactReverts;
    uint256 internal maxReactGas; // the largest gas a single react() used

    struct GasRow {
        uint256 topic0;
        uint256 topic3;
        uint256 used;
        uint256 forward;
        bool ok;
    }

    GasRow[] internal reactGas; // every reaction's gas, in order (R-GAS)
    uint256 internal forwardOverride; // a cell may set the forward (0 = the live HEAD-semantics forward)
    mapping(uint256 => bool) internal hubInDebt;
    bool internal rcInDebt;

    // ------------------------------------------------------------------ setup

    function _setUpTwoChains() internal {
        // one PoolManager, tokens and router (TsEnv), then a Touchstone factory per chain
        _setUpTouchstone(CA);
        ts0 = vm.getBlockTimestamp();
        lasnaBn0 = 9_100_000;
        lastCronBn = lasnaBn0 - (lasnaBn0 % 100);
        sys = new MockSystem();
        vm.etch(SYSTEM, address(sys).code);
        sys = MockSystem(payable(SYSTEM));
        (Tier memory ta, uint256 bta) = Tiers.demo();
        (Tier memory tb, uint256 btb) = Tiers.testing();
        ch[CA] = ChainEnv(CA, 1000, 30_000_000, 177_200, ta, bta, tsFactory, CovenantFactory(address(0)), ReagentHub(payable(address(0))), address(0));
        ch[CB] = ChainEnv(CB, 13_200, 9_000_000, 243_300, tb, btb, TouchstoneFactory(address(0)), CovenantFactory(address(0)), ReagentHub(payable(address(0))), address(0));
        cur = CA;
        deliveryMs[CA] = 3_000;
        deliveryMs[CB] = 13_200;
        _sync();
        ch[CB].ts = _onTs(CB);
        vm.recordLogs();
    }

    function _onTs(uint256 c) private returns (TouchstoneFactory f) {
        _on(c);
        f = new TouchstoneFactory(address(manager), keccak256(vaultCode), keccak256(extCode), keccak256(hookCode));
    }

    /// @notice A Reagent deployment per chain for the RC at `rc_` (the Hub's immutable): extension, implementation,
    ///         factory and Hub under each chain id; the mock proxy etched; chain B's factory and Hub translated.
    function _deployReagent(address rc_, address admin_) internal {
        rcAddr = rc_;
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c);
            CovenantExt e = new CovenantExt();
            Covenant im = new Covenant(address(e));
            CovenantFactory f = new CovenantFactory(rc_, admin_, address(im));
            ch[c].factory = f;
            ch[c].hub = ReagentHub(payable(f.HUB()));
            ch[c].proxy = ch[c].hub.PROXY();
            if (ch[c].proxy.code.length == 0) vm.etch(ch[c].proxy, address(new MockProxy()).code);
        }
        // only what the RC sees and what is one address live: the Hub (and each Covenant); never a Touchstone
        // factory, bundler, vault or hook (s3 rc r2 D2-06)
        _alias(address(ch[CA].hub), address(ch[CB].hub));
        _on(CA);
    }

    function _alias(address a, address b) internal {
        toA[b] = a;
        toB[a] = b;
    }

    /// @notice A Covenant for `owner` on both chains (same owner; the two clones translated to one address).
    function _covenantBoth(address owner, address admin_) internal returns (ICovenant a, ICovenant b) {
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c);
            vm.prank(admin_);
            ch[c].factory.allow(owner, true);
            vm.prank(owner);
            ICovenant cv = ICovenant(ch[c].factory.create());
            token0.mint(address(cv), 1e30);
            token1.mint(address(cv), 1e30);
            if (i == 0) a = cv;
            else b = cv;
        }
        _alias(address(a), address(b));
    }

    // ------------------------------------------------------------------ chain contexts and clocks

    /// @notice Switches the EVM to chain `c` (CA, CB or LASNA): logs recorded so far are flushed under the old
    ///         context, then chain id, block number and timestamp follow `c`'s clock.
    function _on(uint256 c) internal {
        _flush();
        cur = c;
        _sync();
    }

    function _sync() internal {
        vm.chainId(cur);
        vm.roll(_bn(cur));
        vm.warp(ts0 + wallMs / 1000);
        if (cur != LASNA) {
            tier = ch[cur].tier;
            blocktime = ch[cur].tierBt;
            if (address(ch[cur].ts) != address(0)) tsFactory = ch[cur].ts;
        }
    }

    function _bn(uint256 c) internal view returns (uint256) {
        if (c == LASNA) return lasnaBn0 + wallMs / 1130;
        return ch[c].bn0 + wallMs / ch[c].btMs;
    }

    function lasnaBlock() internal view returns (uint256) {
        return _bn(LASNA);
    }

    function tickNow() internal view returns (uint256) {
        return _bn(LASNA) / 100;
    }

    /// @dev `n` blocks of the current chain pass (TsEnv's helpers call this); all clocks follow the wall clock.
    function advance(uint256 n) internal override {
        uint256 bt = cur == LASNA ? 1130 : ch[cur].btMs;
        _advanceWall(n * bt);
    }

    /// @notice Wall time passes (no activity on any chain).
    /// @notice Enters Lasna's context (owner calls to the RC run there); `_leave(prev)` returns.
    function _lasna() internal returns (uint256 prev) {
        prev = cur;
        _on(LASNA);
    }

    function _leave(uint256 prev) internal {
        _on(prev);
    }

    function _elapse(uint256 secs) internal {
        _advanceWall(secs * 1000);
    }

    /// @notice Moves the wall clock by `ms`, stopping at every Lasna block where a Cron tick or a log arrival falls,
    ///         and running the pump THERE: every reaction and the callbacks it requests execute at that event's own
    ///         time, before later time passes (s3 rc r4 D4-05). Logs are stamped at emission (flushed first).
    function _advanceWall(uint256 ms) internal {
        _flush();
        uint256 target = wallMs + ms;
        while (!noAutoPump) {
            uint256 nextBn = lastCronBn + 100;
            (bool has,, uint256 at) = _earliest();
            if (has && at < nextBn) nextBn = at;
            uint256 nextMs = nextBn > lasnaBn0 ? (nextBn - lasnaBn0) * 1130 : 0;
            (bool hasDue, uint256 dueAt) = _nextDueMs();
            if (hasDue && dueAt < nextMs) nextMs = dueAt;
            if (nextMs > target) break;
            if (nextMs > wallMs) {
                wallMs = nextMs;
                _sync();
            }
            _pump();
        }
        wallMs = target;
        _sync();
        if (!noAutoPump) _pump();
    }

    // ------------------------------------------------------------------ logs → LogRecords

    function _flush() internal {
        Vm.Log[] memory ls = vm.getRecordedLogs();
        if (cur == LASNA) {
            for (uint256 i; i < ls.length; ++i) {
                Vm.Log memory l = ls[i];
                if (l.emitter == SYSTEM) _systemEvent(l);
                else lasnaLogs.push(l);
            }
            return;
        }
        uint256 originBn = _bn(LASNA);
        uint256 arrive = originBn + lagBlocks + chainLag[cur];
        for (uint256 i; i < ls.length; ++i) {
            Vm.Log memory l = ls[i];
            LogRecord memory r;
            r.chainId = cur;
            r.emitter = cur == CB && toA[l.emitter] != address(0) ? toA[l.emitter] : l.emitter;
            uint256[4] memory t;
            for (uint256 k; k < l.topics.length && k < 4; ++k) {
                t[k] = cur == CB ? _topicToA(uint256(l.topics[k])) : uint256(l.topics[k]);
            }
            (r.topic0, r.topic1, r.topic2, r.topic3) = (t[0], t[1], t[2], t[3]);
            r.data = l.data;
            r.blockNumber = _bn(cur);
            r.opCode = l.topics.length;
            r.txHash = uint256(keccak256(abi.encode("tx", ++txSeq)));
            r.logIndex = i;
            originHist.push(r);
            Act a = _logPolicy(r);
            if (a == Act.DROP) continue;
            if (a == Act.HOLD) {
                heldLogs.push(Inbox(r, originBn, arrive));
                continue;
            }
            inbox.push(Inbox(r, originBn, arrive));
            if (a == Act.DUP) inbox.push(Inbox(r, originBn, arrive));
        }
    }

    /// @dev The mock system's events become the subscription history and the request queue.
    function _systemEvent(Vm.Log memory l) internal {
        bytes32 t = l.topics[0];
        address rc_ = address(uint160(uint256(l.topics[1])));
        uint256 bn = vm.getBlockNumber();
        if (t == MockSystem.Subscribed.selector) {
            (uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) =
                abi.decode(l.data, (uint256, address, uint256, uint256, uint256, uint256));
            subsHist.push(Sub(rc_, bn, 0, c, e, t0, t1, t2, t3));
            ++subscribeCalls;
        } else if (t == MockSystem.Unsubscribed.selector) {
            (uint256 c, address e, uint256 t0, uint256 t1, uint256 t2, uint256 t3) =
                abi.decode(l.data, (uint256, address, uint256, uint256, uint256, uint256));
            for (uint256 i; i < subsHist.length; ++i) {
                Sub storage x = subsHist[i];
                if (x.until == 0 && x.rc == rc_ && x.chainId == c && x.emitter == e && x.t0 == t0 && x.t1 == t1 && x.t2 == t2 && x.t3 == t3) {
                    x.until = bn;
                    return;
                }
            }
            ++unsubscribeMisses;
        } else if (t == MockSystem.Requested.selector) {
            (uint256 c, address to, uint64 g, bytes memory p) = abi.decode(l.data, (uint256, address, uint64, bytes));
            reqQ.push(Req(rc_, c, to, g, p));
        }
    }

    function _topicToA(uint256 t) internal view returns (uint256) {
        if (t >> 160 != 0) return t;
        address a = toA[address(uint160(t))];
        return a == address(0) ? t : uint256(uint160(a));
    }

    // ------------------------------------------------------------------ subscriptions

    function _matches(Sub memory s, LogRecord memory l) internal pure returns (bool) {
        return (s.chainId == 0 || s.chainId == l.chainId) && (s.emitter == address(0) || s.emitter == l.emitter)
            && (s.t0 == IGNORE || s.t0 == l.topic0) && (s.t1 == IGNORE || s.t1 == l.topic1)
            && (s.t2 == IGNORE || s.t2 == l.topic2) && (s.t3 == IGNORE || s.t3 == l.topic3);
    }

    /// @dev Subscriptions of the RC matching `l` in effect at Lasna block `at`: begun strictly before it (plus the
    ///      activation lag) and not ended at or before it (s3 rc r3 D3-07).
    function _matchCount(LogRecord memory l, uint256 at) internal view returns (uint256 n) {
        for (uint256 i; i < subsHist.length; ++i) {
            Sub memory x = subsHist[i];
            if (x.rc == rcAddr && x.since + subLag < at && (x.until == 0 || x.until > at) && _matches(x, l)) ++n;
        }
    }

    function cronSubscribed() internal view returns (bool) {
        for (uint256 i; i < subsHist.length; ++i) {
            Sub memory x = subsHist[i];
            if (x.rc == rcAddr && x.until == 0 && _matches(x, _cronLog(0))) return true;
        }
        return false;
    }

    function _cronLog(uint256 bn) internal pure returns (LogRecord memory r) {
        r.chainId = LASNA;
        r.emitter = CRON;
        r.topic0 = CRON100;
        r.topic1 = bn;
        r.blockNumber = bn;
        r.opCode = 2;
    }

    // ------------------------------------------------------------------ the pump

    /// @notice Runs Lasna up to now: origin logs and Cron100 ticks in Lasna block order, each log once per matching
    ///         subscription; after each reaction, its callback requests are delivered (or held by `_policy`). Loops
    ///         until no new log or request appears (bounded).
    function _pump() internal {
        for (uint256 round; round < 64; ++round) {
            _flush();
            uint256 nowBn = _bn(LASNA);
            bool any;
            // inbox entries and Cron ticks, earliest first
            while (true) {
                uint256 nextCron = lastCronBn + 100;
                (bool has, uint256 idx, uint256 at) = _earliest();
                if (has && at <= nowBn && (at <= nextCron || nextCron > nowBn)) {
                    LogRecord memory l = inbox[idx].log;
                    uint256 origin = inbox[idx].originBn;
                    _removeInbox(idx);
                    if (!rcInDebt) {
                        uint256 n = _matchCount(l, origin);
                        for (uint256 k; k < n; ++k) {
                            _react(l, at);
                        }
                    }
                    any = true;
                } else if (nextCron <= nowBn) {
                    lastCronBn = nextCron;
                    LogRecord memory cl = _cronLog(nextCron);
                    if (!rcInDebt) {
                        uint256 n = _matchCount(cl, nextCron);
                        for (uint256 k; k < n; ++k) {
                            _react(cl, nextCron);
                        }
                    }
                } else {
                    break;
                }
                _deliverAll();
                _flush();
            }
            if (_deliverDue()) any = true;
            _flush();
            if (!any && reqQ.length == 0) return;
        }
        // F-010 H1-02: the bound never truncates work silently (a test asserting "nothing happened" must not pass
        // on a cut pump)
        revert("RcEnv: the pump did not settle within 64 rounds");
    }

    function _earliest() internal view returns (bool has, uint256 idx, uint256 at) {
        at = type(uint256).max;
        for (uint256 i; i < inbox.length; ++i) {
            if (inbox[i].arriveBn < at) (has, idx, at) = (true, i, inbox[i].arriveBn);
        }
    }

    function _removeInbox(uint256 i) internal {
        for (uint256 j = i; j + 1 < inbox.length; ++j) {
            inbox[j] = inbox[j + 1];
        }
        inbox.pop();
    }

    /// @notice One reaction, as the system contract runs it: from SYSTEM, at Lasna block `bn`, with the gas the
    ///         live system would forward (HEAD semantics, s3 rc r1 D1-11); a revert is recorded (charged, lost).
    function _react(LogRecord memory l, uint256 bn) internal {
        uint256 saveCur = cur;
        _on(LASNA);
        vm.roll(bn);
        bytes memory cd = abi.encodeCall(IReactive.react, (l));
        uint256 g = forwardOverride != 0 ? forwardOverride : reactGasFor(cd);
        ++reactCalls;
        // Every live reaction is its own transaction (accounts and slots cold). The harness never cools: under forge
        // 1.5.0 `vm.cool` cools an account but not its slots, and it un-touches the account, so a code account cooled
        // in setUp and reached only by `delegatecall` (RcExt) is dropped at setUp's commit (F-011, root-caused s4,
        // `test/F011Cool.t.sol`). An R-GAS cell builds its state in setUp and measures its reaction FIRST in the test
        // body, a new transaction (`_firstReactionSince`).
        vm.prank(SYSTEM);
        uint256 g0 = gasleft();
        (bool ok,) = rcAddr.call{gas: g}(cd);
        uint256 used = g0 - gasleft();
        if (used > maxReactGas) maxReactGas = used;
        if (!ok) ++reactReverts;
        reactGas.push(GasRow(l.topic0, l.topic3, used, g, ok));
        _on(saveCur);
    }

    /// @notice The gas the live system forwards to `react` for this calldata under HEAD semantics: the 900k tx cap,
    ///         less intrinsic and calldata gas, the trigger's own work and `_extraGas` (100k), then 63/64.
    function reactGasFor(bytes memory cd) internal pure returns (uint256) {
        uint256 c = 4 * 21; // the trigger's selector and RC word, roughly
        for (uint256 i; i < cd.length; ++i) {
            c += cd[i] == 0 ? 4 : 16;
        }
        return (900_000 - 21_000 - c - 15_000 - 100_000) * 63 / 64;
    }

    // ------------------------------------------------------------------ callback delivery

    /// @dev Scheduler tests override this to drop, hold or duplicate origin logs (R-B6SCHED; s3 rc r4 D4-05).
    function _logPolicy(LogRecord memory) internal virtual returns (Act) {
        return Act.DELIVER;
    }

    /// @notice Releases the held origin logs: they arrive now (late), in order; their origin stays the original one.
    function _releaseHeldLogs() internal {
        _flush(); // logs emitted before the release keep their own time
        uint256 nowBn = _bn(LASNA);
        for (uint256 i; i < heldLogs.length; ++i) {
            Inbox memory x = heldLogs[i];
            x.arriveBn = nowBn;
            inbox.push(x);
        }
        delete heldLogs;
    }

    /// @dev Scheduler tests override this to drop or hold requests (R-B6SCHED, R-EXIT-SCHED).
    function _policy(Req memory) internal virtual returns (Act) {
        return Act.DELIVER;
    }

    function _deliverAll() internal {
        _flush();
        Req[] memory rs = reqQ;
        delete reqQ;
        for (uint256 i; i < rs.length; ++i) {
            Act a = _policy(rs[i]);
            uint256 at = wallMs + deliveryMs[rs[i].chainId];
            if (a == Act.DELIVER) dueQ.push(Due(rs[i], at));
            else if (a == Act.HOLD) held.push(rs[i]);
            else if (a == Act.DUP) {
                dueQ.push(Due(rs[i], at));
                dueQ.push(Due(rs[i], at));
            } else {
                deliveries.push(Delivery(rs[i].chainId, rs[i].recipient, _sel(rs[i].payload), rs[i].gasLimit, 5));
            }
        }
    }

    /// @dev Delivers every queued request whose time has come, in order (the clock is already at or past it).
    function _deliverDue() internal returns (bool any) {
        uint256 i;
        while (i < dueQ.length) {
            if (dueQ[i].atMs <= wallMs) {
                Req memory r = dueQ[i].r;
                for (uint256 j = i; j + 1 < dueQ.length; ++j) {
                    dueQ[j] = dueQ[j + 1];
                }
                dueQ.pop();
                _deliver(r);
                any = true;
            } else {
                ++i;
            }
        }
    }

    function _nextDueMs() internal view returns (bool has, uint256 at) {
        at = type(uint256).max;
        for (uint256 i; i < dueQ.length; ++i) {
            if (dueQ[i].atMs < at) (has, at) = (true, dueQ[i].atMs);
        }
    }

    /// @notice Releases every held request (in order), as a late delivery.
    function _releaseHeld() internal {
        Req[] memory rs = held;
        delete held;
        for (uint256 i; i < rs.length; ++i) {
            _deliver(rs[i]);
        }
    }

    function _deliver(Req memory r) internal {
        bytes4 s = _sel(r.payload);
        if (r.gasLimit < 100_000) {
            deliveries.push(Delivery(r.chainId, r.recipient, s, r.gasLimit, 3));
            return;
        }
        if (r.chainId != CA && r.chainId != CB) {
            deliveries.push(Delivery(r.chainId, r.recipient, s, r.gasLimit, 5));
            return;
        }
        if (hubInDebt[r.chainId]) {
            deliveries.push(Delivery(r.chainId, r.recipient, s, r.gasLimit, 4));
            return;
        }
        uint256 saveCur = cur;
        _on(r.chainId);
        address to = r.recipient;
        if (r.chainId == CB) {
            // F-010 H1-01 (spec §9 layers: a missing mapping fails loudly): the RC addresses chain B by chain A's
            // address for the Hub and each Covenant; any other recipient is refused
            require(toB[r.recipient] != address(0), "RcEnv: no chain-B alias for this recipient");
            to = toB[r.recipient];
        }
        bytes memory p = _inject(r.payload, r.rc, r.chainId);
        uint256 g = r.gasLimit > ch[r.chainId].F ? (r.gasLimit - ch[r.chainId].F) * 63 / 64 : 0;
        vm.prank(ch[r.chainId].proxy);
        (bool ok,) = to.call{gas: g}(p);
        deliveries.push(Delivery(r.chainId, r.recipient, s, r.gasLimit, ok ? 1 : 2));
        _on(saveCur);
    }

    /// @dev The network's first-argument injection, and chain B's translation of chain-independent addresses in
    ///      the arguments (a covenant argument from the RC is chain A's address).
    function _inject(bytes memory p, address rc_, uint256 c) internal view returns (bytes memory q) {
        q = bytes.concat(p);
        if (q.length >= 36) {
            bytes32 w = bytes32(uint256(uint160(rc_)));
            assembly ("memory-safe") {
                mstore(add(q, 36), w)
            }
        }
        if (c != CB) return q;
        for (uint256 off = 36; off + 32 <= q.length; off += 32) {
            uint256 w;
            assembly ("memory-safe") {
                w := mload(add(add(q, 32), off))
            }
            if (w >> 160 == 0 && w != 0 && toB[address(uint160(w))] != address(0)) {
                uint256 nw = uint256(uint160(toB[address(uint160(w))]));
                assembly ("memory-safe") {
                    mstore(add(add(q, 32), off), nw)
                }
            }
        }
    }

    function _sel(bytes memory p) internal pure returns (bytes4 s) {
        if (p.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(p, 32))
            }
        }
    }

    // ------------------------------------------------------------------ queries

    function _deliveredCount(uint256 c, bytes4 s, uint8 outcome) internal view returns (uint256 n) {
        for (uint256 i; i < deliveries.length; ++i) {
            Delivery memory d = deliveries[i];
            if ((c == 0 || d.chainId == c) && (s == bytes4(0) || d.selector == s) && (outcome == 0 || d.outcome == outcome)) ++n;
        }
    }

    /// @notice R-GAS's cold measurement (F-011): the row of the first reaction after `mark` (= `reactGas.length` read at
    ///         the start of the test body), which must have topic0 `t0` and topic3 `t3`: only the body's first reaction
    ///         runs with every account and slot cold, as a live reaction does.
    function _firstReactionSince(uint256 mark, uint256 t0, uint256 t3) internal view returns (GasRow memory r) {
        require(reactGas.length > mark, "R-GAS: no reaction in the body");
        r = reactGas[mark];
        require(r.topic0 == t0 && r.topic3 == t3, "R-GAS: the measured reaction is not the body's first (not cold)");
    }

    function _lasnaEventCount(bytes32 topic0) internal view returns (uint256 n) {
        for (uint256 i; i < lasnaLogs.length; ++i) {
            if (lasnaLogs[i].emitter == rcAddr && lasnaLogs[i].topics.length > 0 && lasnaLogs[i].topics[0] == topic0) ++n;
        }
    }
}
