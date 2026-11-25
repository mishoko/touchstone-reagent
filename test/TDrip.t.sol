// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {ICovenant, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice T-DRIP (spec §9.1, C-12) on the TEST tier (11155111): a patient exit keeps the value the burned forfeit adds
///         to the holder's shares; an exit at the breach block does not. A twin holder deposits the same shares as
///         the Covenant and withdraws at the breach block (the immediate payout); the Covenant waits out the drip and
///         exits through the Hub (the patient payout). Both are valued at the reference (tick 0: raw token0 = raw
///         token1). Truth: patient − immediate = the holder's share of the burned forfeit = SH/Sd × B × (value per
///         share at the breach), B the shares the drip burned and Sd the supply after it.
contract TDripTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23;
    address internal twin = makeAddr("twin");

    function setUp() public {
        _setUpReagent(11155111);
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
        V[] memory all = new V[](3);
        (all[0], all[1], all[2]) = (X, X2, Y);
        _keepAliveAll(all, 2 * tier.EPOCH); // pay accrues, so a breach forfeits and starts a drip
        _alloc(c, X.vault, SH);
        token0.mint(twin, 1e30);
        token1.mint(twin, 1e30);
        vm.startPrank(twin);
        token0.approve(X.vault, type(uint256).max);
        token1.approve(X.vault, type(uint256).max);
        IVaultEntries(X.vault).deposit(SH, type(uint256).max, type(uint256).max, twin);
        vm.stopPrank();
    }

    function _supply() internal view returns (uint256) {
        return IERC20(X.vault).totalSupply();
    }

    /// @dev The breach latched and processed: the forfeit is set aside and its drip starts here.
    function _breachNow() internal {
        IVaultEntries(X.vault).poke();
        _latch(X, 1);
        _process(X);
        assertGt(_dripEnd(X), vm.getBlockNumber(), "a drip is running");
    }

    function _bal(address who) internal view returns (uint256, uint256) {
        return (token0.balanceOf(who), token1.balanceOf(who));
    }

    function test_T_DRIP__patientMinusImmediateIsTheHoldersShareOfTheBurnedForfeit() public {
        _breachNow();
        // the immediate payout: the twin's same shares, withdrawn at the breach block
        vm.prank(twin);
        (uint256 i0, uint256 i1) = IVaultEntries(X.vault).withdraw(SH, 0, 0, twin);
        uint256 immediate = i0 + i1;
        uint256 s1 = _supply();
        // the patient exit: the Hub mirror paused, the reference back, the drip waited out, then one rcExit
        (uint32 b, uint32 g,, uint64 s) = hub.conduct(IDX);
        _conduct(IDX, b + 1, g);
        _backInRange(X);
        _keepAlive(X, _dripEnd(X) - vm.getBlockNumber() + 10);
        (uint256 a0, uint256 a1) = _bal(alice);
        vm.recordLogs();
        _exit(address(c), X.vault, s + 1);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(found, "an EXIT note");
        (uint8 o,,) = _exitOutcome(d);
        assertEq(o, Outcome.DONE, "the patient exit ran after the drip");
        (uint256 p0, uint256 p1) = _bal(alice);
        uint256 patient = (p0 - a0) + (p1 - a1);
        // the supply the drip left (the exit's own prologue applies the burn, then the withdrawal removes SH)
        uint256 sd = _supply() + SH;
        assertLt(sd, s1, "the drip burned forfeit shares");
        uint256 burned = s1 - sd;
        uint256 expected = immediate * burned / sd; // SH/Sd × B × (immediate / SH)
        assertGt(patient, immediate, "the patient exit is worth more");
        assertApproxEqRel(patient - immediate, expected, 1e12, "patient - immediate = the holder's share of the burn");
        emit log_named_uint("immediate (token1 at the reference)", immediate);
        emit log_named_uint("patient", patient);
        emit log_named_uint("burned shares", burned);
    }

    /// @notice The control: the same holder leaving at the breach block (I-LEAVE, always available) gets the twin's
    ///         immediate payout and none of the forfeit: the gain above comes from the wait alone.
    function test_T_DRIP__PC_anExitAtTheBreachBlockGetsNoneOfTheForfeit() public {
        _breachNow();
        vm.prank(twin);
        (uint256 i0, uint256 i1) = IVaultEntries(X.vault).withdraw(SH, 0, 0, twin);
        (uint256 a0, uint256 a1) = _bal(alice);
        vm.prank(alice);
        c.leave(X.vault, SH, 0, 0);
        (uint256 p0, uint256 p1) = _bal(alice);
        uint256 atBreach = (p0 - a0) + (p1 - a1);
        assertApproxEqAbs(atBreach, i0 + i1, 2, "an exit at the breach block gets the immediate payout, no forfeit");
    }
}
