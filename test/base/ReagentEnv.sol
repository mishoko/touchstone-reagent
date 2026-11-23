// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TsEnv} from "./TsEnv.sol";
import {ReagentHub} from "../../src/ReagentHub.sol";
import {Covenant} from "../../src/Covenant.sol";
import {CovenantExt} from "../../src/CovenantExt.sol";
import {CovenantFactory} from "../../src/CovenantFactory.sol";
import {ICovenant, Rulebook, NoteKind, Holding, Base} from "../../src/interfaces/IReagent.sol";

/// @notice Reagent on a real Touchstone (the F layer, spec §9): the extension, the Covenant implementation and the
///         factory (whose constructor deploys the Hub) at the chosen chain id, so the Hub resolves its real proxy
///         address. Callbacks are delivered by pranking that proxy with the RC as the first word (the network's
///         injection), at a chosen entry gas where the test is about gas.
abstract contract ReagentEnv is TsEnv {
    bytes32 internal constant NOTE_TOPIC = keccak256("Note(address,address,uint8,bytes)");
    bytes32 internal constant APPLIED_TOPIC = keccak256("Applied(uint32,uint64)");
    bytes32 internal constant BUDGET_TOPIC = keccak256("BudgetApplied(address,uint32,uint128,uint64,uint64)");
    bytes32 internal constant STALE_TOPIC = keccak256("Stale(uint8,uint64)");

    address internal RC = makeAddr("rc");
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal agentKey = makeAddr("agent");
    address internal PROXY;

    CovenantExt internal ext;
    Covenant internal impl;
    CovenantFactory internal factory;
    ReagentHub internal hub;

    V internal X; // curator id 1, vault X1
    V internal X2; // curator id 1, a sibling vault on this chain
    V internal Y; // curator id 2
    uint32 internal constant IDX = 1;
    uint32 internal constant IDY = 2;

    uint64 internal seq; // the RC's conduct seq in tests

    function _setUpReagent(uint256 chainId) internal {
        _setUpTouchstone(chainId);
        ext = new CovenantExt();
        impl = new Covenant(address(ext));
        factory = new CovenantFactory(RC, admin, address(impl));
        hub = ReagentHub(payable(factory.HUB()));
        PROXY = hub.PROXY();
    }

    /// @notice Three vaults (two of curator X, one of Y), bound by RC callbacks, past their first markout.
    function _setUpVaults() internal {
        X = _deployVault();
        X2 = _deployVault();
        Y = _deployVault();
        _bind(X.vault, IDX);
        _bind(X2.vault, IDX);
        _bind(Y.vault, IDY);
        V[] memory all = new V[](3);
        (all[0], all[1], all[2]) = (X, X2, Y);
        _keepAliveAll(all, 30); // the placement's markout settles on the next entry
    }

    // ------------------------------------------------------------------ RC callbacks (as the proxy delivers them)

    function _bind(address vault, uint32 id) internal {
        vm.prank(PROXY);
        hub.rcVault(RC, vault, id);
    }

    function _conduct(uint32 id, uint32 breaches, uint32 gone) internal {
        vm.prank(PROXY);
        hub.rcConduct(RC, id, breaches, gone, 0, ++seq);
    }

    function _budget(address c, uint32 id, uint128 b, uint64 nonce) internal {
        uint64 r = ICovenant(c).rulesNonce(); // read before the prank (a call in the arguments would consume it)
        vm.prank(PROXY);
        hub.rcBudget(RC, c, id, b, nonce, r);
    }

    function _exit(address c, address vault, uint64 minSeq) internal {
        vm.prank(PROXY);
        hub.rcExit{gas: 5_000_000}(RC, c, vault, minSeq, 0);
    }

    // ------------------------------------------------------------------ Covenants

    function _covenant(address owner) internal returns (ICovenant c) {
        vm.prank(admin);
        factory.allow(owner, true);
        vm.prank(owner);
        c = ICovenant(factory.create());
        token0.mint(address(c), 1e30);
        token1.mint(address(c), 1e30);
    }

    /// @notice PB-14 defaults with a 10 mWETH budget (cap 6 mWETH, 3 per chain by default), the agent cap at a tenth.
    function _rules(uint32 a, uint32 b) internal pure returns (Rulebook memory r) {
        r.k = 1;
        r.b3 = true;
        r.b4FloorBps = 5_000;
        r.maxShareBps = 6_000;
        r.budget = 10e18;
        r.agentCapPerEpoch = 1e18;
        r.ids = [a, b, uint32(0), uint32(0)];
    }

    function _setRules(ICovenant c, Rulebook memory r) internal {
        vm.prank(c.owner());
        c.setRules(r);
    }

    /// @notice An owner allocation of `shares` (no slippage bound).
    function _alloc(ICovenant c, address vault, uint256 shares) internal {
        vm.prank(c.owner());
        c.allocate(vault, shares, type(uint256).max, type(uint256).max);
    }

    // ------------------------------------------------------------------ log decoding

    /// @notice The last Note of `kind` for `c` in `logs`; found = false if none.
    function _lastNote(Vm.Log[] memory logs, address c, uint8 kind) internal view returns (bytes memory data, bool found) {
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (
                l.emitter == address(hub) && l.topics[0] == NOTE_TOPIC && address(uint160(uint256(l.topics[2]))) == c
                    && uint8(uint256(l.topics[3])) == kind
            ) return (abi.decode(l.data, (bytes)), true);
        }
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(hub) && logs[i].topics[0] == topic) ++n;
        }
    }

    function _countNotes(Vm.Log[] memory logs, uint8 kind) internal view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hub) && logs[i].topics[0] == NOTE_TOPIC
                    && uint8(uint256(logs[i].topics[3])) == kind
            ) ++n;
        }
    }

    /// @notice (outcome, a, b) of an EXIT note.
    function _exitOutcome(bytes memory data) internal pure returns (uint8 outcome, uint256 a, uint256 b) {
        (, outcome,, a, b) = abi.decode(data, (address, uint8, uint32, uint256, uint256));
    }
}
