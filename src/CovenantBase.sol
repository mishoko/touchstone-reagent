// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ITouchstoneHook} from "touchstone/interfaces/ITouchstoneHook.sol";
import {Obs} from "touchstone/types/Obs.sol";
import {IReagentHub, Rulebook} from "./interfaces/IReagent.sol";
import {VaultRead} from "./libraries/VaultRead.sol";

/// @notice The storage, parameters and errors shared by `Covenant` (the core every clone runs) and `CovenantExt`
///         (its owner/agent administration and STATE notes, reached by delegatecall). One layout for both: this
///         contract declares every state variable, and neither child declares any (spec §5.4, s2 LF-1).
abstract contract CovenantBase {
    // ------------------------------------------------------------------ parameters (spec §6)

    uint256 internal constant NOTE_INTERVAL = 300;
    uint256 internal constant TRYREF_TOL_BPS = 50;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_HOLDINGS = 4;

    // STATE note classes (spec §5.2 rate rules, applied here: s2 LF-2)
    uint8 internal constant C_NORMAL = 0;
    uint8 internal constant C_RULE_OWNER = 1;
    uint8 internal constant C_RULE_AGENT = 2;
    uint8 internal constant C_HOLD_ADD = 3;
    uint8 internal constant C_ANSWER = 4;
    uint8 internal constant C_FLUSH = 5;

    // ------------------------------------------------------------------ state (the clone's storage)

    struct VaultBase {
        bool set; // baselines taken (first allocation or unpause)
        uint32 baseSeq; // hook breachSeq at the baseline (the exit vault check, I-STALE)
        uint32 base19; // slot-19 breaches at the baseline (the allocate guard's B7 sum)
        bool baseGone; // EXITED/retired at the baseline
        uint128 bond0; // the bond at this Covenant's first allocation (B4)
    }

    struct Window {
        uint40 start;
        uint8 n;
    }

    struct Spend {
        uint32 epoch;
        uint128 spent;
    }

    IReagentHub public HUB;
    address public FACTORY;
    address public owner;
    address public agent;
    Rulebook internal _rules;
    uint64 public rulesNonce;
    uint64 public noteNonce;

    mapping(address => uint128) public ledger; // shares booked by this Covenant (PB-9)
    address[] internal _held; // vaults with a non-zero ledger, <= 4
    mapping(uint32 => uint128) internal _exposure; // E_c(id), token1 at tryRef, at cost: Σ of the id's vaults' _cost
    mapping(address => uint128) internal _cost; // each vault's own cost basis (s2 F1-01: leaving one vault cuts only its own)
    mapping(uint32 => uint32[2]) internal _baseline; // (breaches, gone) of the Hub mirror at unpause
    mapping(address => VaultBase) internal _vb;
    mapping(address => bool) public allowed;
    mapping(address => uint128) public plan;
    mapping(address => uint32) public lastPlanEpoch;
    address[] internal _plans;
    mapping(address => Spend) internal _spend; // agent + plan spend per vault epoch

    uint40 internal _lastNote;
    bool public notePending;
    Window internal _ownerWin;
    Window internal _agentWin;
    Window internal _holdWin;

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error NotAgent();
    error NotHub();
    error NotFactory();
    error Initialized();
    error Unbound();
    error NotInIds();
    error FifthVault();
    error ModeNotNormal();
    error RecordPaused();
    error Pending();
    error Gone();
    error BondFloor();
    error HubPaused();
    error OverBudget();
    error Armed();
    error NotAllowed();
    error AgentCap();
    error RefStale();
    error PriceTolerance();
    error BadRules();
    error NoChange();
    error Looser();
    error TooSoon();
    error PendingBreach();
    error TooManyPlans();
    error Self();
    error NotDelegated();

    // ------------------------------------------------------------------ shared helpers

    function _obs(address vault) internal view returns (Obs memory) {
        return ITouchstoneHook(VaultRead.hook(vault)).obs();
    }

    function _inIds(uint32[4] memory a, uint32 id) internal pure returns (bool) {
        return id != 0 && (a[0] == id || a[1] == id || a[2] == id || a[3] == id);
    }

    /// @dev The per-vault baseline: taken at the first allocation, and again (forced) by `unpause`.
    function _snapshot(address vault, bool force) internal {
        VaultBase storage b = _vb[vault];
        if (b.set && !force) return;
        b.set = true;
        b.baseSeq = _obs(vault).breachSeq;
        b.base19 = VaultRead.breaches(vault);
        b.baseGone = VaultRead.mode(vault) == 2;
    }

    /// @dev A holding opening (ledger 0 → > 0): the exit's vault baseline is retaken, so a breach from before this
    ///      deposit never arms its exit (spec §3.3 B7, r7 m-5; s2 F1-02). `base19` (the allocate guard's B7 sum) stays.
    function _rebaseExit(address vault) internal virtual {
        VaultBase storage b = _vb[vault];
        // [MU-088] the exit baseline at every holding's opening
        b.baseSeq = _obs(vault).breachSeq;
        b.baseGone = VaultRead.mode(vault) == 2;
    }
}
