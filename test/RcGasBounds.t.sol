// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {ICovenant, Rulebook} from "../src/interfaces/IReagent.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";

/// @notice R-GAS at the bounds (spec §9.2; F-012): reactions whose size grows with the bounds, each measured as the
///         test body's FIRST reaction (cold, F-011) at the live forward.
abstract contract RcBoundsBase is RcFixture {
    uint256 internal constant T_LATCH_ = 0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346;
    uint256 internal constant T_APPLIED_ = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;

    address[] internal holdFrom; // origin emitters whose logs are held (released in the body)
    bool internal holdApplied; // hold every 1301 `Applied`

    function _logPolicy(LogRecord memory l) internal virtual override returns (Act) {
        if (holdApplied && l.chainId == CA && l.topic0 == T_APPLIED_) return Act.HOLD;
        for (uint256 i; i < holdFrom.length; ++i) {
            if (l.emitter == holdFrom[i]) return Act.HOLD;
        }
        return Act.DELIVER;
    }

    function _owner(uint256 i) internal returns (address) {
        return makeAddr(string(abi.encode("bounds-owner", i)));
    }

    function _rules(bool b2) internal pure returns (Rulebook memory r) {
        r.k = 1;
        r.b3 = true;
        r.b2 = b2;
        r.b4FloorBps = 5_000;
        r.maxShareBps = 6_000;
        r.budget = 100e18;
        r.agentCapPerEpoch = 10e18;
        r.ids = [uint32(1), 0, 0, 0];
    }

    function _breachNow(V memory v, uint256 c) internal {
        _on(c);
        _latch(v, 1);
        _process(v);
        _backInRange(v);
    }

    /// @dev The row of the body's first reaction (it must be `topic0`): cold, as a live reaction (F-011).
    function _first(uint256 mark, uint256 topic0) internal view returns (GasRow memory r) {
        require(reactGas.length > mark, "R-GAS: no reaction in the body");
        r = reactGas[mark];
        require(r.topic0 == topic0, "R-GAS: the measured reaction is not the body's first (not cold)");
    }
}

/// @notice A breach at the bounds: curator 1 with 4 vaults on each chain (8), 16 Covenants holding all 4 of their
///         chain's vaults on both chains (128 pairs), B2 on; 7 vaults breached in setUp, the 8th latch measured. Then
///         every exit leaves within the bound, with no reaction reverting.
contract RcGasBreachAtTheBoundsTest is RcBoundsBase {
    V[4] va;
    V[4] vb;
    ICovenant[16] ca;
    ICovenant[16] cb;

    function setUp() public {
        _setUpRc();
        for (uint256 i; i < 4; ++i) {
            va[i] = _registeredVault(CA, 1);
            vb[i] = _registeredVault(CB, 1);
        }
        for (uint256 i; i < 4; ++i) {
            _on(CA);
            _age(va[i], 400);
            _on(CB);
            _age(vb[i], 40);
        }
        for (uint256 j; j < 16; ++j) {
            (ca[j], cb[j]) = _covenantBoth(_owner(j), admin);
            _setRulesOn(CA, ca[j], _rules(true));
            _setRulesOn(CB, cb[j], _rules(true));
            for (uint256 i; i < 4; ++i) {
                _on(CA);
                _keepAlive(va[i], 2);
                _allocOn(CA, ca[j], va[i].vault, SH / 100);
                _on(CB);
                _allocOn(CB, cb[j], vb[i].vault, SH / 100);
            }
            _elapse(301); // past NOTE_INTERVAL: each Covenant's next holdings are reported at once
        }
        _elapse(60);
        // 7 of the 8 vaults breach in setUp; the 8th's logs are held and released in the body
        for (uint256 i; i < 4; ++i) {
            _breachNow(va[i], CA);
        }
        for (uint256 i; i < 3; ++i) {
            _breachNow(vb[i], CB);
        }
        _elapse(30);
        holdFrom.push(vb[3].hook);
        holdFrom.push(vb[3].vault);
        _breachNow(vb[3], CB);
        _elapse(30);
    }

    function test_R_GAS__aBreachAtTheBoundsThenEveryExitLeaves() public {
        uint256 mark = reactGas.length;
        delete holdFrom;
        _releaseHeldLogs();
        _elapse(5);
        GasRow memory row = _first(mark, T_LATCH_);
        console2.log("8th latch at the bounds: used", row.used, "forward", row.forward);
        assertTrue(row.ok, "the latch never reverts");
        assertLe(row.used, 700_000, "within PB-8");
        // every exit leaves: the drips (1301 33 ticks, 11155111 15 ticks) then <= ceil(128/8) ticks of sends, plus the
        // answers; generous: 200 ticks, while churn-free (no B6 work)
        _elapse(200 * 113);
        uint256 left;
        for (uint256 j; j < 16; ++j) {
            for (uint256 i; i < 4; ++i) {
                _on(CA);
                if (ca[j].ledger(va[i].vault) != 0) ++left;
                _on(CB);
                if (cb[j].ledger(vb[i].vault) != 0) ++left;
            }
        }
        console2.log("pairs still holding", left, "max react gas", maxReactGas);
        assertEq(left, 0, "every one of the 128 pairs exited");
        assertEq(reactReverts, 0, "no reaction reverted");
    }
}

/// @notice An `Applied` at the bounds with 64 waiting pairs (16 Covenants × 4 vaults on 1301, every pair waiting on a
///         snapshot whose `Applied` is held): a small constant, no evaluation, no send (r13 D13-01, R-NOLOOP).
contract RcGasAppliedWaitingTest is RcBoundsBase {
    V[4] va;
    ICovenant[16] ca;

    function setUp() public {
        _setUpRc();
        for (uint256 i; i < 4; ++i) {
            va[i] = _registeredVault(CA, 1);
        }
        for (uint256 i; i < 4; ++i) {
            _on(CA);
            _age(va[i], 400);
        }
        for (uint256 j; j < 16; ++j) {
            (ca[j],) = _covenantBoth(_owner(j), admin);
            _setRulesOn(CA, ca[j], _rules(false));
            for (uint256 i; i < 4; ++i) {
                _on(CA);
                _keepAlive(va[i], 2);
                _allocOn(CA, ca[j], va[i].vault, SH / 100);
            }
            _elapse(301);
        }
        _elapse(60);
        holdApplied = true;
        for (uint256 i; i < 4; ++i) {
            _breachNow(va[i], CA);
        }
        _elapse(20 * 113); // the sweeps evaluate all 64 pairs: each waits (seqApplied < seqTotals), no exit sent
        uint256 p = _lasna();
        uint256 waiting;
        for (uint256 j; j < 16; ++j) {
            for (uint256 i; i < 4; ++i) {
                (, uint32 ws,,,,) = rc.pairOf(CA, address(ca[j]), va[i].vault);
                if (ws != 0) ++waiting;
            }
        }
        _leave(p);
        require(waiting == 64, "setUp: 64 waiting pairs");
        holdApplied = false;
    }

    function test_R_GAS__anAppliedWithSixtyFourWaitingPairsIsASmallConstant() public {
        uint256 mark = reactGas.length;
        uint256 req0 = _deliveredCount(0, bytes4(0), 0);
        _releaseHeldLogs();
        _elapse(2);
        GasRow memory row = _first(mark, T_APPLIED_);
        console2.log("Applied with 64 waiting pairs: used", row.used);
        assertTrue(row.ok);
        assertLe(row.used, 60_000, "a small constant: no evaluation (the wait releases lazily)");
        assertEq(_deliveredCount(0, bytes4(0), 0), req0, "no callback from an Applied (R-NOLOOP)");
    }
}
