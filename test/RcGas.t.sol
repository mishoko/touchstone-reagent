// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {ICovenant, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";
import {RcExt} from "../src/RcExt.sol";

/// @notice R-GAS's probe: records gasleft() where a reaction's optional work begins (the first serve of a work
///         entry), in an RC storage slot no layout uses, so a cell can split mandatory from optional gas.
contract RcExtProbe is RcExt {
    bytes32 internal constant MARK = keccak256("reagent.rc.gas.mark");

    constructor(address b6_) RcExt(b6_) {}

    function _serveEntry(uint256 c, address cov, Budget memory bud) internal override {
        bytes32 m = MARK;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            if iszero(sload(m)) { sstore(m, g) }
        }
        super._serveEntry(c, cov, bud);
    }
}

/// @notice R-GAS (spec §5.5 Bounds, §9.2): reactions at the bounds, cold, at the live forward.
contract RcGasTest is RcFixture {
    uint256 constant T_NOTE_ = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    address alice = makeAddr("alice");
    bool dropStates;
    address dropFor;

    bytes32 internal constant MARK = keccak256("reagent.rc.gas.mark");

    ICovenant ca;

    /// @dev The first-STATE cell's state, built here and committed: the test body is a new transaction in which the
    ///      measured STATE is the first reaction, every account and slot cold (F-011).
    function setUp() public virtual {
        _setUpRc();
        V[4] memory vs;
        for (uint32 i; i < 4; ++i) {
            vs[i] = _registeredVault(CA, i + 1);
            _on(CA);
            _age(vs[i], 100);
        }
        (ca,) = _covenantBoth(alice, admin);
        dropFor = address(ca);
        dropStates = true;
        Rulebook memory r = _rulesFor(1, 2);
        r.ids = [uint32(1), 2, 3, 4];
        _setRulesOn(CA, ca, r);
        for (uint256 i; i < 4; ++i) {
            _on(CA);
            _age(vs[i], 20);
            _allocOn(CA, ca, vs[i].vault, SH);
        }
        vm.startPrank(alice);
        for (uint256 i; i < 4; ++i) {
            ca.setPlan(vs[i].vault, 0.1e18);
        }
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            _on(CA);
            _latch(vs[i], 1); // every holding breached after the deposit: 4 late arms
        }
        _elapse(301);
        dropStates = false;
        (,,, bool cronOn) = rc.counters();
        require(!cronOn, "setUp: Cron must be off, so no tick precedes the measured STATE");
        _on(CA);
        vm.store(address(rc), MARK, bytes32(0));
    }

    function _newExt() internal override returns (address) {
        return address(new RcExtProbe(_newB6()));
    }

    function _logPolicy(LogRecord memory l) internal view override returns (Act) {
        if (dropStates && l.topic0 == T_NOTE_ && l.topic3 == 1 && address(uint160(l.topic2)) == dropFor) return Act.DROP;
        return Act.DELIVER;
    }

    /// @notice A Covenant's first STATE at the bounds: 4 holdings, 4 budgeted ids, 4 plans, 4 late arms.
    /// @dev The cursor list (`_vaultList` slot 23, `_nVaults` 24; see RcGasCaps `_cursorTo`): the listed count, and
    ///      whether the slots [n, n + k) hold non-zero (stale) entries.
    function _cursorSlots(uint256 k) internal returns (uint256 n, bool staleOk) {
        uint256 p = _lasna();
        n = uint256(vm.load(address(rc), bytes32(uint256(24))));
        staleOk = true;
        for (uint256 i = n; i < n + k; ++i) {
            if (vm.load(address(rc), keccak256(abi.encode(i, uint256(23)))) == bytes32(0)) staleOk = false;
        }
        _leave(p);
    }

    function test_R_GAS__firstStateAtTheBoundsWithFourPlans() public {
        (, bool stale) = _cursorSlots(4);
        assertTrue(stale, "non-vacuous: the 4 vaults were dropped (empty), so the STATE takes the re-list path");
        uint256 mark0 = reactGas.length;
        forwardOverride = vm.envOr("RGAS_FORWARD", uint256(0));
        vm.prank(alice);
        ca.flush();
        _elapse(5);
        GasRow memory row = _firstReactionSince(mark0, T_NOTE_, 1); // the body's first reaction: cold (F-011)
        (uint256 used, uint256 forward, bool ok) = (row.used, row.forward, row.ok);
        uint256 mark = uint256(vm.load(address(rc), MARK));
        uint256 mandatory = forward - mark;
        console2.log("first STATE gas", used, "forward", forward);
        console2.log("mandatory part", mandatory);
        assertLe(mandatory, 700_000, "the mandatory part within PB-8 (s3 rc r2 D2-03)");
        assertTrue(ok, "never reverts at the live forward");
        if (forwardOverride == 0) assertLe(used, forward, "within the live forward");
        assertEq(reactReverts, 0);
    }

    /// @notice R-GAS (s4, `_b6Opt`): the same first STATE at a forward just above its mandatory part + GAS_GUARD: the
    ///         optional B6 step starts and runs out of gas, which reverts that step alone; the reaction lands (its
    ///         records and the listed work entry), and the cut work leaves at the next Cron ticks.
    function test_R_GAS__anOptionalStepOutOfGasNeverRevertsTheReaction() public {
        uint256 mark0 = reactGas.length;
        forwardOverride = 600_701 + 150_000 + 25_000;
        vm.prank(alice);
        ca.flush();
        _elapse(5);
        GasRow memory row = _firstReactionSince(mark0, T_NOTE_, 1);
        assertTrue(row.ok, "the reaction lands");
        forwardOverride = 0;
        (, uint256 work,,) = rc.counters();
        assertGt(work, 0, "the work entry was written ahead");
        _elapse(10 * 113);
        assertEq(reactReverts, 0);
    }
}

/// @notice rc-fix r4 C4-01: the same first STATE after 4 permissionless registrations took the stale slots the drops
///         left (S = 0 without the high-water invariant): the re-lists still write non-zero slots, so the mandatory
///         part stays within PB-8 and the reaction lands at the live forward (PC MU-284: fresh slots, ≈ +93k).
contract RcGasFirstStateAfterRegistrationsTest is RcGasTest {
    function setUp() public override {
        super.setUp();
        (uint256 n0,) = _cursorSlots(0);
        for (uint32 i; i < 4; ++i) {
            _registeredVault(CA, 11 + i); // they land in the slots [n0, n0 + 4)
        }
        (uint256 n1, bool stale) = _cursorSlots(4);
        require(n1 == n0 + 4, "setUp: 4 registrations listed");
        require(stale, "setUp: the registrations left stale slots for the re-lists (C4-01)");
        (,,, bool cronOn) = rc.counters();
        require(!cronOn, "setUp: Cron off");
        _on(CA);
        vm.store(address(rc), MARK, bytes32(0));
    }
}
