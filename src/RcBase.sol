// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRnkSystem, CallbackV1} from "./interfaces/IReactive.sol";
import {Kind} from "./interfaces/IReagentRC.sol";

/// @notice The storage, parameters, events and errors shared by `ReagentRC` (the reaction dispatch, registry,
///         conduct record and callbacks) and `RcExt` (STATE ingestion, the exit scheduler, B6 reconcile, Cron),
///         which the RC reaches only by an internal `delegatecall` (spec §3.2, s3 rc r2 D2-05). One layout for both:
///         this contract declares every state variable (checked by `script/deploy/layout.py`).
abstract contract RcBase {
    // ------------------------------------------------------------------ Reactive (research §1–§3, [M])

    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant CA = 1301;
    uint256 internal constant CB = 11155111;
    uint256 internal constant LASNA = 5318007;

    // ------------------------------------------------------------------ topic0s (spec §5.1, §5.2)

    uint256 internal constant T_LATCH = 0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346;
    uint256 internal constant T_PROCESSED = 0xf37492039a7f836f6b471f6a2c580a9743a545b9d3f3d4b1e3a47108e67ea59c;
    uint256 internal constant T_MODE = 0x73f069d8a008c9e2fe78e308751100d873455f99593c7d60eff545e91a90ab04;
    uint256 internal constant T_RETIRED = 0xfe4758e6ccdb65cb7d78b678b554dc5319e940c6ee582e94811b7d48fbb506c5;
    uint256 internal constant T_EPOCH = 0x52ac8c0ec192dc514cc63f10118a6ba589667d3548a5ffcb0886465085529050;
    uint256 internal constant T_ACTION = 0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba;
    uint256 internal constant T_DEPLOYED = 0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2;
    uint256 internal constant T_CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    uint256 internal constant T_APPLIED = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;
    uint256 internal constant T_BUDGET = 0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823;

    // ------------------------------------------------------------------ parameters (spec §6)

    uint256 internal constant ACTION_BUDGET = 8;
    uint256 internal constant MAX_PER_CHAIN = 4; // bundlers (so vaults) per id per chain
    uint256 internal constant MAX_COV = 16; // Covenants tracked per vault
    uint256 internal constant TICK_MS = 113_000; // one Cron100 tick [M]
    uint64 internal constant MAX_CALLBACK_GAS = 10_000_000;
    uint256 internal constant RESERVE = 40_000;
    uint256 internal constant F_1301 = 177_200;
    uint256 internal constant F_11155111 = 243_300;

    // NEED[chain][kind] (spec §5.6; s3 LF-S3-1 method (a) for 11155111). Exit and plan equal the Hubs' `needs()`
    // exactly (s3 rc r6 D6-03). Named so that `script/deploy/gasneed.py` and `rc.py` read them from source.
    uint256 internal constant NEED_CONDUCT_1301 = 35_000;
    uint256 internal constant NEED_VAULT_1301 = 91_000;
    uint256 internal constant NEED_BUDGET_1301 = 345_000;
    uint256 internal constant NEED_EXIT_1301 = 832_000;
    uint256 internal constant NEED_PLAN_1301 = 1_198_000;
    uint256 internal constant NEED_CONDUCT_11155111 = 150_000;
    uint256 internal constant NEED_VAULT_11155111 = 437_000;
    uint256 internal constant NEED_BUDGET_11155111 = 500_000;
    uint256 internal constant NEED_EXIT_11155111 = 2_220_000;
    uint256 internal constant NEED_PLAN_11155111 = 2_310_000;

    // per-chain time: block time (ms), the tier's forfeit drip (blocks) and EPOCH_TICKS (spec §3.5, §6)
    uint256 internal constant BT_1301_MS = 1_000;
    uint256 internal constant BT_11155111_MS = 13_200;
    uint256 internal constant DRIP_1301 = 3_600; // DEMO FORFEIT_DRIP_BLOCKS
    uint256 internal constant DRIP_11155111 = 120; // TEST FORFEIT_DRIP_BLOCKS
    uint32 internal constant EPOCH_TICKS_1301 = 32;
    uint32 internal constant EPOCH_TICKS_11155111 = 15;

    // ------------------------------------------------------------------ storage (the RC's; RcExt runs on it)

    struct Curator {
        bool exists;
        uint8 nbA; // bundlers on 1301
        uint8 nbB; // bundlers on 11155111
        uint8 nvA; // vaults bound on 1301
        uint8 nvB;
    }

    struct VaultRec {
        uint32 id; // 0 = not a registered vault
        address hook;
        uint32 maxSeq; // max latched breachSeq seen (PB-1)
        bool gone; // EXITED or retired
        uint8 nCov; // Covenants ever appended (append-once, ≤ 16)
    }

    struct VaultRec2 {
        uint32 actions;
        uint8 actionsThisEpoch;
        bool actionSub; // the Action subscription is live
        uint32 dripEndTick;
    }

    struct Conduct {
        uint32 breaches;
        uint32 gone;
        uint32 actions;
        uint32 seq;
    }

    struct SeqRec {
        uint32 seqOut; // last snapshot sent to this chain
        uint32 seqApplied; // max Applied seen from this chain
        uint32 seqTotals; // last sent snapshot that changed breaches or gone
        uint32 hubLogCount; // callback results seen (spec §3.5)
        uint16 parkedCount;
        uint16 b6ParkedCount;
        uint32 lastResendBlock; // the PB-7 rate key, shared by resends and probes (s3 rc r5 D5-06)
    }

    mapping(uint256 => address) internal _hub;
    mapping(uint256 => address) internal _factory;
    mapping(uint256 => mapping(uint8 => uint64)) internal _gas;
    mapping(uint32 => Curator) internal _curator;
    mapping(uint256 => mapping(address => uint32)) internal _bundlerId;
    mapping(uint32 => mapping(uint256 => address[4])) internal _idVaults;
    mapping(uint256 => mapping(address => VaultRec)) internal _vault;
    mapping(uint256 => mapping(address => VaultRec2)) internal _vault2;
    mapping(uint256 => mapping(address => address)) internal _hookVault;
    mapping(uint256 => mapping(address => mapping(uint256 => address))) internal _covAt;
    mapping(uint32 => Conduct) internal _conductOf;
    mapping(uint256 => mapping(uint32 => SeqRec)) internal _seq;

    // the level-triggered Cron gate (spec §5.5 "Deferred work")
    uint256 internal _pendingPairs;
    uint256 internal _sweeps; // (b6Active is the work list's length, `_workLen`: one counter, one writer)
    bool internal _cronOn;

    // ------------------------------------------------------------------ Covenants (STATE, spec §5.3, §5.5)

    /// @dev Per (chain, covenant), two slots. Nonces are kept at 32 bits (a Covenant's rule changes and notes).
    struct CovRec {
        uint128 cap; // maxShareBps · budget / 1e4 (B6 on)
        uint32[4] ids; // the Rulebook's ids on this chain
        uint8 k;
        bool b3;
        bool b2;
        bool b6On;
        uint32 rulesNonce;
        uint32 noteNonce; // 0 = no STATE yet
        uint8 nHold;
        uint8 nPlan;
        bool workListed; // on the work list (spec §5.5 "Deferred work")
        uint32 workPos;
        uint32 unsettledR; // a BudgetApplied's r above the stored rulesNonce, until a STATE brings it
    }

    struct Hold {
        address vault;
        uint32 baseSeq;
        bool baseGone;
    }

    struct Plan {
        address vault;
        uint96 amount;
    }

    /// @dev B6 per (covenant, id, chain), slot 1: the view from STATE and BudgetApplied, and the Covenant's per-id
    ///      unpause baseline on that chain. Budgets and exposure saturate at uint96 (≈ 7.9e28 token1 units).
    struct B6a {
        uint96 appliedB;
        uint96 E;
        uint32 baseBreaches;
        uint32 baseGone;
    }

    /// @dev The exit scheduler's pair state (spec §3.5), one slot.
    struct Pair {
        uint32 nextTick;
        uint32 waitSince;
        uint32 waitSeq;
        uint32 parkedLogCount; // 0 = not parked
        uint8 tries;
        uint8 defers;
        uint8 drips;
        uint8 seenSeq; // the vault's maxSeq when the counters were last reset (lazy reset on a new latch)
        uint32 suspB; // suspension: (breaches, gone, rulesNonce) at suspension
        uint8 suspG;
        uint32 suspR;
        bool pending;
        bool listed; // appended to the vault's covenants[] (append-once)
        bool suspended;
    }

    mapping(uint256 => mapping(address => CovRec)) internal _cov;
    mapping(uint256 => mapping(address => mapping(uint256 => Hold))) internal _hold;
    mapping(uint256 => mapping(address => mapping(uint256 => Plan))) internal _plan;
    mapping(address => mapping(uint32 => mapping(uint256 => B6a))) internal _b6a;
    mapping(uint256 => mapping(address => mapping(address => Pair))) internal _pair;

    // the work list of (chain, covenant) entries (spec §5.5 "Deferred work"), and the rotating Cron pointers
    mapping(uint256 => uint256) internal _workList; // position → chain << 160 | covenant
    uint256 internal _workLen;
    uint256 internal _workPtr;
    // the global vault list walked by the cursor (spec §3.5), and the cursor
    mapping(uint256 => uint256) internal _vaultList; // position → chain << 160 | vault
    uint256 internal _nVaults;
    uint256 internal _cursorV;
    uint256 internal _cursorC;
    // the dirty ids being swept (spec §3.5)
    mapping(uint32 => uint32) internal _sweepPos; // the next pair index in the id's sweep (1-based; 0 = not dirty)
    mapping(uint256 => uint32) internal _dirty; // position → id
    uint256 internal _nDirty;

    // ------------------------------------------------------------------ events and errors

    event GasSet(uint256 indexed chain, uint8 indexed kind, uint64 previous, uint64 limit);
    event VaultRegistered(uint256 indexed chain, address indexed vault, uint32 indexed id, address hook);
    event Untracked(uint256 chain, address covenant);
    event ExitAbandoned(uint256 chain, address covenant, address vault);
    event ExitParked(uint256 chain, address covenant, address vault);

    error NotSystem();
    error NotOwner();
    error BadChain();
    error BadKind();
    error BadGas();
    error Exists();
    error Unknown();
    error Full();
    error NoFactory();
    error NotDelegated();
    error ShortBalance();
    error PayFailed();

    // ------------------------------------------------------------------ shared helpers

    function _isChain(uint256 c) internal pure returns (bool) {
        return c == CA || c == CB;
    }

    /// @dev NEED[chain][kind] (spec §5.6).
    function _need(uint256 c, uint8 k) internal pure returns (uint256) {
        if (c == CA) {
            return k == Kind.CONDUCT ? NEED_CONDUCT_1301 : k == Kind.VAULT ? NEED_VAULT_1301 : k == Kind.BUDGET
                ? NEED_BUDGET_1301
                : k == Kind.EXIT ? NEED_EXIT_1301 : NEED_PLAN_1301;
        }
        return k == Kind.CONDUCT ? NEED_CONDUCT_11155111 : k == Kind.VAULT ? NEED_VAULT_11155111 : k == Kind.BUDGET
            ? NEED_BUDGET_11155111
            : k == Kind.EXIT ? NEED_EXIT_11155111 : NEED_PLAN_11155111;
    }

    /// @dev gasLimit(chain, NEED) = ceil(1.1 · (NEED·64/63 + RESERVE) · 64/63) + F[chain] (spec §5.6, PB-4).
    function _formula(uint256 c, uint8 k) internal pure returns (uint64) {
        uint256 num = 11 * 64 * (64 * _need(c, k) + 63 * RESERVE);
        uint256 den = 10 * 63 * 63;
        return uint64((num + den - 1) / den + (c == CA ? F_1301 : F_11155111));
    }

    /// @dev Now in Cron100 ticks, from `block.number` (Lasna) only, in every reaction (spec §3.5, r16 m-1).
    function _now() internal view returns (uint32) {
        return uint32(block.number / 100);
    }

    /// @dev Origin-chain blocks → ticks, with the +1 margin (spec §6).
    function _ticks(uint256 c, uint256 blocks) internal pure returns (uint32) {
        uint256 ms = blocks * (c == CA ? BT_1301_MS : BT_11155111_MS);
        return uint32((ms + TICK_MS - 1) / TICK_MS + 1);
    }

    function _dripTicks(uint256 c) internal pure returns (uint32) {
        return _ticks(c, c == CA ? DRIP_1301 : DRIP_11155111);
    }

    function _send(uint256 c, uint8 kind, bytes memory payload) internal {
        IRnkSystem(SYSTEM).requestCallbackV_1_0(CallbackV1(c, _hub[c], _gas[c][kind], payload));
    }

    function _sub(uint256 c, address e, uint256 t0, uint256 t1) internal {
        IRnkSystem(SYSTEM).subscribe(c, e, t0, t1, IGNORE, IGNORE);
    }

    function _unsub(uint256 c, address e, uint256 t0, uint256 t1) internal {
        IRnkSystem(SYSTEM).unsubscribe(c, e, t0, t1, IGNORE, IGNORE);
    }
}
