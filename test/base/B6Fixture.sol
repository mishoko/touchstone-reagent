// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcFixture} from "./RcFixture.sol";
import {ICovenant, IReagentHub, Rulebook} from "../../src/interfaces/IReagent.sol";

/// @notice The B6 fixture (spec §5.5 B6 reconcile; §9.2 R-BUDGET, R-B6SCHED, R-COUNTERS; §9.3 A-B6LAG, A-OWNER-RACE;
///         §4 I-CAP, I-B6SUM): curator 1 with one vault per chain, alice's Covenant on both chains listing id 1, the
///         PB-14 defaults (cap 60 mWETH, so 30 per chain by default; MIN_MOVE 3), every check read from both Hubs.
abstract contract B6Fixture is RcFixture {
    address alice = makeAddr("alice");
    V xa;
    V xb;
    ICovenant ca;
    ICovenant cb;
    uint256 constant CAP = 60e18;

    function _b6SetUp() internal {
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

    function _cov(uint256 c) internal view returns (ICovenant) {
        return c == CA ? ca : cb;
    }

    function _vaultOn(uint256 c) internal view returns (V memory) {
        return c == CA ? xa : xb;
    }

    /// @dev The Hub's effective budget of alice's Covenant for id 1 on chain c (read under c's chain id).
    function _B(uint256 c) internal returns (uint256 b) {
        uint256 p = cur;
        _on(c);
        (b,,) = ch[c].hub.budget(address(_cov(c)), 1);
        _on(p);
    }

    function _E(uint256 c) internal returns (uint256 e) {
        uint256 p = cur;
        _on(c);
        e = _cov(c).exposure(1);
        _on(p);
    }

    /// @notice Allocates on chain c until E(id 1) reaches about `target` (from below, by the measured cost per share).
    function _allocTo(uint256 c, uint256 target) internal {
        uint256 e0 = _E(c);
        if (e0 >= target) return;
        V memory v = _vaultOn(c);
        _on(c);
        _keepAlive(v, 2);
        if (!_allocShares(c, v, 1e21)) return; // at the edge already
        uint256 e1 = _E(c);
        uint256 per = (e1 - e0) * 1e18 / 1e21; // cost per 1e18 shares
        if (e1 < target && per > 0) {
            uint256 sh = (target - e1) * 1e18 / per;
            sh = sh * 99 / 100;
            if (sh > 0) {
                _elapse(301); // past NOTE_INTERVAL: this allocation's STATE is emitted, not coalesced (PB-10)
                _on(c);
                _keepAlive(v, 2);
                _allocShares(c, v, sh);
            }
        }
    }

    /// @dev Allocates `sh` shares on chain c, halving on a refusal (B6 at the edge, rounding of the cost estimate).
    function _allocShares(uint256 c, V memory v, uint256 sh) internal returns (bool ok) {
        _on(c);
        for (uint256 k; k < 6 && !ok && sh > 0; ++k) {
            vm.prank(alice);
            (ok,) = address(_cov(c)).call(abi.encodeCall(ICovenant.allocate, (v.vault, sh, type(uint256).max, type(uint256).max)));
            sh /= 2;
        }
        if (ok) assertLe(_E(c), _B(c), "I-B6SUM: E <= B after an allocation");
    }

    /// @notice I-B6SUM first clause and I-CAP (c)'s visible half: on each chain E ≤ B.
    function _assertEleB() internal {
        assertLe(_E(CA), _B(CA), "I-B6SUM: E <= B on 1301");
        assertLe(_E(CB), _B(CB), "I-B6SUM: E <= B on 11155111");
    }

    /// @notice I-CAP (b) at quiescence: Σ B ≤ max(cap, Σ E).
    function _assertCapAtRest() internal {
        uint256 sb = _B(CA) + _B(CB);
        uint256 se = _E(CA) + _E(CB);
        uint256 cap = _capNow();
        assertLe(sb, cap > se ? cap : se, "I-CAP (b): sum B <= max(cap, sum E) at quiescence");
    }

    /// @dev The current cap: the minimum over the chains of maxShareBps · budget / 1e4 (spec §4, r22 m-2).
    function _capNow() internal returns (uint256 cap) {
        cap = type(uint256).max;
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c);
            Rulebook memory r = _cov(c).rules();
            uint256 x = uint256(r.maxShareBps) * r.budget / 10_000;
            if (x < cap) cap = x;
        }
    }

    /// @notice The number of `rcBudget` requests the RC made to chain c.
    function _budgetSends(uint256 c) internal view returns (uint256 n) {
        return _deliveredCount(c, IReagentHub.rcBudget.selector, 0);
    }
}
