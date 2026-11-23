// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A depositor's rules on one chain (spec §3.3, §5.4). Amounts are in token1 units of the vaults (the same
///         token on both Reagent chains, so exposure adds up across chains for B6).
struct Rulebook {
    uint8 k; // B7: pause at `breaches - baseline >= k`, 1..3
    bool b3; // B3: pause when a vault of the id is gone (EXITED or retired)
    uint16 b4FloorBps; // B4: refuse below this share of the bond at first allocation; 0 = off
    uint16 maxShareBps; // B6: cap = maxShareBps * budget / 1e4; 0 = off
    uint128 budget; // B6 owner budget (token1)
    bool b2; // B2 contagion exit (opt-in)
    uint16 b5MaxBurnBps; // B5: cut in s2 (PA-16 cut order); must be 0
    uint128 agentCapPerEpoch; // token1 per vault epoch for agent and plan, <= budget / 10 (PB-14)
    uint32[4] ids; // the curator ids this Covenant may allocate to on this chain (0 = empty slot)
}

/// @notice Note kinds (spec §5.3).
library NoteKind {
    uint8 internal constant STATE = 1;
    uint8 internal constant EXIT = 2;
    uint8 internal constant PLAN = 3;
    uint8 internal constant CREATED = 4;
}

/// @notice EXIT and PLAN outcomes (spec §5.3).
library Outcome {
    uint8 internal constant DONE = 1;
    uint8 internal constant EARLY = 2; // EXIT: a = blocksLeft, b = reason (EARLY_*)
    uint8 internal constant STALE = 3;
    uint8 internal constant FAILED = 4; // EXIT: a = error selector
    uint8 internal constant SKIPPED = 2; // PLAN: reason (SKIP_*)
    uint8 internal constant DEFERRED = 5;
    uint8 internal constant RELAY_FAILED = 6;

    uint8 internal constant EARLY_DRIP = 0;
    uint8 internal constant EARLY_NOT_APPLIED = 1;
    uint8 internal constant EARLY_PENDING = 2;

    uint8 internal constant SKIP_PAUSED = 1;
    uint8 internal constant SKIP_B6 = 2;
    uint8 internal constant SKIP_ARMED = 3;
    uint8 internal constant SKIP_REF_STALE = 4;
    uint8 internal constant SKIP_SLIPPAGE = 5;
    uint8 internal constant SKIP_MARKOUT = 6;
    uint8 internal constant SKIP_NAVCAP = 7;
    uint8 internal constant SKIP_OTHER = 8;
    uint8 internal constant SKIP_NOT_IN_IDS = 9;
    uint8 internal constant SKIP_FIFTH_VAULT = 10;
}

/// @notice Holding and baseline records carried by STATE and EXIT notes (spec §5.3).
struct Holding {
    address vault;
    uint32 id;
    uint128 shares;
    uint128 exposure;
    uint128 budget;
    uint64 budgetNonce;
    uint32 baseSeq;
    bool baseGone;
}

struct Base {
    uint32 id;
    uint32 breaches;
    uint32 gone;
    uint128 budget;
    uint64 budgetNonce;
    uint128 exposure;
}

interface IReagentHub {
    function rcConduct(address rc, uint32 id, uint32 breaches, uint32 gone, uint32 actions, uint64 seq) external;
    function rcBudget(address rc, address covenant, uint32 id, uint128 budget, uint64 budgetNonce, uint64 rulesNonce)
        external;
    function rcExit(address rc, address covenant, address vault, uint64 minSeq, uint32 breachCount) external;
    function rcAllocate(address rc, address covenant, address vault, uint32 vaultEpoch) external;
    function rcVault(address rc, address vault, uint32 id) external;

    function note(uint8 kind, bytes calldata data) external;
    function syncRules(uint128 maxB, uint32[4] calldata ids) external;
    function FACTORY() external view returns (address);
    function RC() external view returns (address);
    function PROXY() external view returns (address);
    function pay(uint256 amount) external;
    function sweep() external;

    function conduct(uint32 id) external view returns (uint32 breaches, uint32 gone, uint32 actions, uint64 seq);
    function budget(address covenant, uint32 id) external view returns (uint128 b, uint64 budgetNonce, uint64 rulesNonce);
    function paused(address covenant, uint32 id) external view returns (bool);
    function vaultId(address vault) external view returns (uint32);
    function idVaults(uint32 id) external view returns (address[] memory);

    event Applied(uint32 indexed id, uint64 seq);
    event BudgetApplied(address indexed covenant, uint32 indexed id, uint128 budget, uint64 budgetNonce, uint64 rulesNonce);
    event Note(address indexed owner, address indexed covenant, uint8 indexed kind, bytes data);
    event Stale(uint8 what, uint64 nonce);
    event VaultBound(address indexed vault, uint32 indexed id);
}

interface ICovenant {
    function allocate(address vault, uint256 shares, uint256 max0, uint256 max1) external;
    function leave(address vault, uint256 shares, uint256 min0, uint256 min1) external;
    function setRules(Rulebook calldata r) external;
    function setAgent(address agent) external;
    function setAllowed(address vault, bool ok) external;
    function setPlan(address vault, uint128 perEpochToken1) external;
    function unpause(uint32 id) external;
    function flush() external;
    function tighten(Rulebook calldata r) external;
    function agentAllocate(address vault, uint256 shares, uint256 max0, uint256 max1) external;
    function rcExit(address vault, uint64 minSeq, uint32 breachCount) external;
    function rcAllocate(address vault, uint32 vaultEpoch) external;

    function rulesNonce() external view returns (uint64);
    function exposure(uint32 id) external view returns (uint128);
    function rules() external view returns (Rulebook memory);
    function baseline(uint32 id) external view returns (uint32 breaches, uint32 gone);
    function vaultBase(address vault) external view returns (uint32 baseSeq, bool baseGone);
    function owner() external view returns (address);
    function emitState() external;
    function sweep(address token, uint256 amount) external;
    function agent() external view returns (address);
    function ledger(address vault) external view returns (uint128);
    function notePending() external view returns (bool);
    function noteNonce() external view returns (uint64);
    function allowed(address vault) external view returns (bool);
    function plan(address vault) external view returns (uint128);
    function lastPlanEpoch(address vault) external view returns (uint32);
}

interface ICovenantFactory {
    function create() external returns (address covenant);
    function isCovenant(address c) external view returns (bool);
    function HUB() external view returns (address);
    function ADMIN() external view returns (address);
    function allow(address owner, bool ok) external;
    function predict(address owner) external view returns (address);
    function IMPL() external view returns (address);
}
