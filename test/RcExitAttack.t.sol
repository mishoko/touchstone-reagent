// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcFixture} from "./base/RcFixture.sol";
import {RcExt} from "../src/RcExt.sol";
import {ICovenant, IReagentHub, NoteKind} from "../src/interfaces/IReagent.sol";
import {LogRecord, IReactive} from "../src/interfaces/IReactive.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice A-CRON-PIN's positive control: no park.
contract RcExtNoPark is RcExt {
    constructor(address b6_) RcExt(b6_) {}

    function _parkTicks(uint256) internal pure override returns (uint32) {
        return type(uint32).max / 2;
    }
}

/// @notice A-EXIT-DENY's positive control: the per-epoch counting removed (a retry on the next tick).
contract RcExtNoEpoch is RcExt {
    constructor(address b6_) RcExt(b6_) {}

    function _retryTicks(uint256) internal pure override returns (uint32) {
        return 1;
    }
}

/// @notice §9.3 A-CRON-PIN, A-EXIT-DENY, A-NOTE-FORGE (spec §3.5, §7), each with its positive control.
contract RcExitAttackTest is RcFixture {
    uint256 constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    address alice = makeAddr("alice");
    V xa;
    V xb;
    ICovenant ca;
    ICovenant cb;
    uint8 variant; // 0 real, 1 no park, 2 no per-epoch counting
    uint256 failuresSeen;

    /// @dev EXIT notes with outcome FAILED (4) emitted so far.
    function _exitFailures() internal view returns (uint256 n) {
        for (uint256 i; i < originHist.length; ++i) {
            if (originHist[i].topic0 != T_NOTE || originHist[i].topic3 != 2) continue;
            bytes memory d = abi.decode(originHist[i].data, (bytes));
            (, uint8 o) = abi.decode(d, (address, uint8));
            if (o == 4) ++n;
        }
    }

    function setUp() public {}

    function _newExt() internal override returns (address) {
        if (variant == 1) return address(new RcExtNoPark(_newB6()));
        if (variant == 2) return address(new RcExtNoEpoch(_newB6()));
        return super._newExt();
    }

    function _base(uint8 v) internal {
        variant = v;
        _setUpRc();
        xa = _registeredVault(CA, 1);
        xb = _registeredVault(CB, 1);
        (ca, cb) = _covenantBoth(alice, admin);
        _setRulesOn(CA, ca, _rulesFor(1, 0));
        _setRulesOn(CB, cb, _rulesFor(1, 0));
        _elapse(30);
        _on(CA);
        _age(xa, 400);
        _allocOn(CA, ca, xa.vault, SH);
        _elapse(30);
    }

    function _breachA() internal {
        _on(CA);
        _latch(xa, 1);
        _process(xa);
        _backInRange(xa);
        _elapse(30);
    }

    function _sends(uint256 c, bytes4 s) internal view returns (uint256) {
        return _deliveredCount(c, s, 0);
    }

    function _cron() internal returns (bool on) {
        uint256 p = _lasna();
        (,,, on) = rc.counters();
        _leave(p);
    }

    // ================================================================== A-CRON-PIN

    function _pinRun() internal returns (uint256 sends, bool cronAfter, uint32 parked) {
        hubInDebt[CA] = true; // in debt BEFORE the breach: no callback to chain A ever lands
        uint256 s0 = _sends(CA, IReagentHub.rcExit.selector);
        _breachA();
        _elapse(260 * 113); // > the drip and 6 · EPOCH_TICKS(1301) = 192 ticks
        // the spec's "≤ 7 sends" bounds the EXITS (1.2M-gas callbacks); the waiting pair's snapshot is resent at the
        // PB-7 rate (§3.5; rc-fix r1 C1-03), at most one per 1,000 Lasna blocks (≈ 10 ticks), asserted apart
        uint256 resends = _sends(CA, IReagentHub.rcConduct.selector);
        sends = _sends(CA, IReagentHub.rcExit.selector) + resends - s0;
        uint256 exits = _sends(CA, IReagentHub.rcExit.selector);
        assertLe(exits, 7, "at most 7 exit sends before the park");
        sends = exits;
        cronAfter = _cron();
        uint256 p = _lasna();
        (,, parked,,,) = rc.pairOf(CA, address(ca), xa.vault);
        _leave(p);
    }

    /// @notice A-CRON-PIN: an exit whose Hub is in debt from before the breach (no answer ever comes) parks after
    ///         6 · EPOCH_TICKS with ≤ 7 sends, and Cron goes off.
    function test_A_CRON_PIN__aHubInDebtBeforeTheBreachParksAndCronGoesOff() public {
        _base(0);
        (uint256 sends, bool cronAfter, uint32 parked) = _pinRun();
        assertGt(parked, 0, "parked");
        assertLe(sends, 7, "at most 7 sends before the park");
        assertFalse(cronAfter, "the attack loses: Cron is not pinned");
    }

    /// @notice A-CRON-PIN/PC: without the park, Cron stays subscribed.
    function test_A_CRON_PIN__PC_withoutTheParkCronStaysOn() public {
        _base(vm.envOr("PC_UNMUTATED", false) ? 0 : 1);
        (,, uint32 parked) = _pinRun();
        assertEq(parked, 0);
        assertTrue(_cron(), "the control wins: Cron pinned");
    }

    // ================================================================== A-EXIT-DENY

    /// @dev Every exit withdrawal fails (as a sandwicher failing the min-outs would make it); the drip has ended.
    function _denyRun(uint256 ticks) internal returns (bool suspended, uint8 tries) {
        _breachA();
        vm.mockCallRevert(xa.vault, abi.encodeWithSelector(IVaultEntries.withdraw.selector), "sandwiched");
        _on(CA);
        _keepAlive(xa, 3_600 + 200); // the DEMO drip
        _elapse(ticks * 113);
        failuresSeen = _exitFailures();
        uint256 p = _lasna();
        (,,,, suspended, tries) = rc.pairOf(CA, address(ca), xa.vault);
        _leave(p);
        vm.clearMockedCalls();
    }

    /// @notice A-EXIT-DENY: min-outs failed on every tick of one epoch: at most one try per EPOCH_TICKS, so the exit
    ///         is not abandoned within one epoch (three failures need three epochs).
    function test_A_EXIT_DENY__failuresWithinOneEpochCountOnce() public {
        _base(0);
        (bool suspended, uint8 tries) = _denyRun(30); // < EPOCH_TICKS(1301) = 32
        assertGt(failuresSeen, 0, "non-vacuous: exits were sent and failed");
        assertFalse(suspended, "the attack loses: not abandoned within one epoch");
        assertLe(tries, 1, "one try per epoch");
    }

    /// @notice A-EXIT-DENY/PC: with the per-epoch counting removed the same attack abandons the exit in one epoch.
    function test_A_EXIT_DENY__PC_perTickRetriesAbandonTheExit() public {
        _base(vm.envOr("PC_UNMUTATED", false) ? 0 : 2);
        (bool suspended,) = _denyRun(30);
        assertTrue(suspended, "the control wins: abandoned within one epoch");
    }

    // ================================================================== A-NOTE-FORGE

    /// @dev A forged EXIT note (outcome DONE) for alice's pair, from `emitter`.
    function _forgeDone(address emitter) internal {
        // the EXIT tuple: (vault, outcome, breachCount, a, b, Base (6 words, static), baseSeq, baseGone, hubSeq)
        bytes memory d = abi.encode(xa.vault, uint8(1), uint32(1), uint256(0), uint256(0), uint32(1), uint32(0), uint32(0), uint128(0),
            uint64(0), uint128(0), uint32(0), false, uint64(0));
        LogRecord memory l;
        l.chainId = CA;
        l.emitter = emitter;
        l.topic0 = T_NOTE;
        l.topic1 = uint256(uint160(alice));
        l.topic2 = uint256(uint160(address(ca)));
        l.topic3 = NoteKind.EXIT;
        l.data = abi.encode(d);
        l.blockNumber = vm.getBlockNumber();
        l.opCode = 4;
        uint256 p = _lasna();
        vm.prank(SYSTEM);
        (bool ok,) = address(rc).call(abi.encodeCall(IReactive.react, (l)));
        assertTrue(ok, "react never reverts for a log");
        _leave(p);
    }

    function _forgeRun(address emitter) internal returns (uint256 ledgerAfter) {
        _breachA();
        _forgeDone(emitter); // the forger claims the exit is done, to disarm it
        _on(CA);
        _keepAlive(xa, 3_600 + 2_000);
        _on(CA);
        ledgerAfter = ca.ledger(xa.vault);
    }

    /// @notice A-NOTE-FORGE: a forged EXIT DONE note from a non-Hub emitter changes nothing; the exit runs.
    function test_A_NOTE_FORGE__aForgedNoteCannotDisarmTheExit() public {
        _base(0);
        assertEq(_forgeRun(makeAddr("forger")), 0, "the attack loses: the patient exit ran");
    }

    /// @notice A-NOTE-FORGE/PC: the same note accepted as the Hub's (the emitter check removed) disarms the exit.
    function test_A_NOTE_FORGE__PC_acceptedAsTheHubsTheNoteDisarms() public {
        _base(0);
        address em = vm.envOr("PC_UNMUTATED", false) ? makeAddr("forger") : address(ch[CA].hub);
        assertGt(_forgeRun(em), 0, "the control wins: no exit");
    }
}
