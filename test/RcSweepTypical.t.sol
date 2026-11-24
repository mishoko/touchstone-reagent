// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {ICovenant} from "../src/interfaces/IReagent.sol";

/// @notice C-10's "a few ticks for a typical curator" (spec §3.5, §12): a curator with 2 vaults on
///         1301 and 8 Covenants (4 per vault) breaches one vault; at the live Cron forward the sweep that finds the
///         affected positions (≤ 2 laps) ends within a few ticks and Cron is released.
contract RcSweepTypicalTest is RcFixture {
    uint32 internal constant ID = 7;
    V a;
    V b;
    ICovenant[8] cv;

    function setUp() public {
        _setUpRc();
        a = _registeredVault(CA, ID);
        b = _registeredVault(CA, ID);
        _on(CA);
        _age(a, 400);
        _on(CA);
        _age(b, 400);
        for (uint256 i; i < 8; ++i) {
            (ICovenant x,) = _covenantBoth(makeAddr(string(abi.encode("typical", i))), admin);
            cv[i] = x;
            _setRulesOn(CA, x, _rulesFor(ID, 0));
            V memory v = i < 4 ? a : b;
            _on(CA);
            _keepAlive(v, 2);
            _allocOn(CA, x, v.vault, SH / 100);
        }
        _elapse(30);
    }

    function _sweepOn() internal returns (bool on) {
        uint256 p = _lasna();
        (,,, on) = rc.sweepOf(ID);
        _leave(p);
    }

    function test_C10__aTypicalCuratorsSweepEndsInAFewTicks() public {
        cronWithheld = true; // the latch helper advances ~48 ticks of chain time: no tick serves the sweep meanwhile
        _on(CA);
        _latch(a, 1); // the breach: marks the id dirty (a sweep over its 8 pairs, ≤ 2 laps)
        _elapse(5); // the latch log reaches the RC (Cron still withheld)
        assertTrue(_sweepOn(), "non-vacuous: the breach started a sweep");
        uint256 t0 = tickNow();
        cronWithheld = false;
        for (uint256 i; i < 30 && _sweepOn(); ++i) {
            _elapse(113);
        }
        uint256 ticks = tickNow() - t0;
        console2.log("typical curator (2 vaults, 8 positions): sweep ended after ticks", ticks);
        assertFalse(_sweepOn(), "the sweep ended");
        assertLe(ticks, 3, "a few ticks (C-10)");
    }
}

/// @notice v13 r4 V4-01 (MU-283): a vault the cursor dropped while it had no Covenant re-joins the cursor at its first
///         Covenant (its pairs are found by the cursor again).
contract RcCursorRelistTest is RcFixture {
    function _listed(uint256 c, address vault) internal returns (bool found, uint256 n) {
        uint256 p = _lasna();
        n = uint256(vm.load(address(rc), bytes32(uint256(24)))); // `_nVaults` (RcGasCaps `_cursorTo`)
        uint256 want = (c << 160) | uint160(vault);
        for (uint256 i; i < n; ++i) {
            if (uint256(vm.load(address(rc), keccak256(abi.encode(i, uint256(23))))) == want) found = true;
        }
        _leave(p);
    }

    function test_R_GAS__aDroppedEmptyVaultRejoinsTheCursorAtItsFirstCovenant() public {
        _setUpRc();
        V memory a = _registeredVault(CA, 7);
        V memory b = _registeredVault(CA, 8);
        (bool l0,) = _listed(CA, a.vault);
        assertTrue(l0, "listed at registration");
        // b gets a Covenant (keeps Cron busy with a pending pair is not needed: a STATE subscribes it while work is owed)
        (ICovenant x,) = _covenantBoth(makeAddr("relist"), admin);
        _setRulesOn(CA, x, _rulesFor(8, 7));
        _on(CA);
        _age(b, 400);
        _on(CA);
        _keepAlive(b, 2);
        _allocOn(CA, x, b.vault, SH / 100);
        _on(CA);
        _latch(b, 1); // Cron runs while id 8 is swept: the cursor floors meet `a`, still empty
        _elapse(20 * 113);
        (bool l1,) = _listed(CA, a.vault);
        assertFalse(l1, "non-vacuous: the cursor dropped the empty vault");
        _on(CA);
        _age(a, 400);
        _on(CA);
        _keepAlive(a, 2);
        _allocOn(CA, x, a.vault, SH / 100); // its first Covenant
        _elapse(30);
        (bool l2,) = _listed(CA, a.vault);
        assertTrue(l2, "re-listed at its first Covenant");
    }
}
