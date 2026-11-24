// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcFixture} from "./base/RcFixture.sol";
import {console2} from "forge-std/console2.sol";
import {ICovenant, IReagentHub} from "../src/interfaces/IReagent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The patient exit end to end on the R layer (spec §3.4, §3.5; §9.2 R-E2E).
contract RcExitTest is RcFixture {
    address alice = makeAddr("alice");
    V xa; // curator 1 on 1301
    V xb; // curator 1 on 11155111
    ICovenant ca;
    ICovenant cb;

    function setUp() public {
        _setUpRc();
        xa = _registeredVault(CA, 1);
        xb = _registeredVault(CB, 1);
        (ca, cb) = _covenantBoth(alice, admin);
        _setRulesOn(CA, ca, _rulesFor(1, 0));
        _setRulesOn(CB, cb, _rulesFor(1, 0));
        _elapse(30);
        _on(CA);
        _age(xa, 400);
        _on(CB);
        _age(xb, 40);
    }

    /// @notice R-E2E: a breach on chain A reaches both Hubs, pauses the curator on chain B, and the RC delivers the
    ///         patient exit on A after the drip: the shares leave in kind to the owner.
    function test_R_E2E__breachOnAPausesBAndExitsOnAAfterTheDrip() public {
        _allocOn(CA, ca, xa.vault, SH);
        _elapse(30);
        assertEq(ca.ledger(xa.vault), SH);
        _on(CA);
        _latch(xa, 1);
        _process(xa); // the forfeit's drip starts
        _backInRange(xa);
        _elapse(30);
        // the pause reached chain B
        _on(CB);
        assertTrue(ch[CB].hub.paused(address(cb), 1), "paused on B once Reactive delivered");
        vm.prank(alice);
        vm.expectRevert();
        cb.allocate(xb.vault, SH, type(uint256).max, type(uint256).max);
        // the exit waits for the drip, then lands in kind to alice
        uint256 a0 = IERC20(address(token0)).balanceOf(alice);
        uint256 a1 = IERC20(address(token1)).balanceOf(alice);
        _on(CA);
        _keepAlive(xa, 3_600 + 2_000); // the DEMO drip (3,600 blocks) and the scheduler's ticks
        _logExitOutcomes();
        (uint256 pp0, uint256 ba0, uint256 sw0, bool on0) = rc.counters();
        console2.log("pending", pp0, "b6Active", ba0);
        console2.log("sweeps", sw0, "cronOn", on0);
        console2.log("reactCalls", reactCalls, "reverts", reactReverts);
        assertEq(ca.ledger(xa.vault), 0, "exited");
        assertGt(IERC20(address(token0)).balanceOf(alice) + IERC20(address(token1)).balanceOf(alice), a0 + a1, "in kind to the owner");
        assertGt(_deliveredCount(CA, IReagentHub.rcExit.selector, 1), 0);
        assertEq(reactReverts, 0, "no reaction reverted");
        _logExitOutcomes();
        (uint256 pp, uint256 ba, uint256 sw, bool on) = rc.counters();
        console2.log("pending", pp, "b6Active", ba);
        console2.log("sweeps", sw, "cronOn", on);
        console2.log("reactCalls", reactCalls);
    }

    function _logExitOutcomes() internal view {
        bytes32 note = keccak256("Note(address,address,uint8,bytes)");
        for (uint256 i; i < originHist.length; ++i) {
            if (originHist[i].topic0 != uint256(note) || originHist[i].topic3 != 2) continue;
            bytes memory d = abi.decode(originHist[i].data, (bytes));
            (, uint8 o,, uint256 a, uint256 b) = abi.decode(d, (address, uint8, uint32, uint256, uint256));
            console2.log("EXIT outcome", o, a, b);
        }
    }
}
