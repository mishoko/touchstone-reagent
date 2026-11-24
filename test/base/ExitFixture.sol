// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcFixture} from "./RcFixture.sol";
import {ICovenant, IReagentHub} from "../../src/interfaces/IReagent.sol";

/// @notice The exit fixture (spec §3.5): curator 1 with X_A (1301) and X_B (11155111), alice's Covenant on both
///         chains listing id 1 (PB-14 defaults) and holding SH of X_A.
abstract contract ExitFixture is RcFixture {
    uint256 constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    address alice = makeAddr("alice");
    V xa;
    V xb;
    ICovenant ca;
    ICovenant cb;

    function _exitBase() internal {
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
        _allocOn(CA, ca, xa.vault, SH);
        _elapse(30);
    }

    function _breach(V memory v, uint256 c) internal {
        _on(c);
        _latch(v, 1);
        _process(v);
        _backInRange(v);
        _elapse(30);
    }

    function _sends(uint256 c, bytes4 s) internal view returns (uint256) {
        return _deliveredCount(c, s, 0);
    }

    function _counters() internal returns (uint256 pp, uint256 work, uint256 sw, bool on) {
        uint256 p = _lasna();
        (pp, work, sw, on) = rc.counters();
        _leave(p);
    }

    function _pair(uint256 c, address cov, address v)
        internal
        returns (uint32 nextTick, uint32 waitSeq, uint32 parked, bool pending, bool suspended, uint8 tries)
    {
        uint256 p = _lasna();
        (nextTick, waitSeq, parked, pending, suspended, tries) = rc.pairOf(c, cov, v);
        _leave(p);
    }

    /// @dev EXIT notes with `outcome` emitted so far (0 = any).
    function _exitNotes(uint8 outcome) internal view returns (uint256 n) {
        for (uint256 i; i < originHist.length; ++i) {
            if (originHist[i].topic0 != T_NOTE || originHist[i].topic3 != 2) continue;
            bytes memory d = abi.decode(originHist[i].data, (bytes));
            (, uint8 o) = abi.decode(d, (address, uint8));
            if (outcome == 0 || o == outcome) ++n;
        }
    }

    /// @dev The Lasna requests of a selector made by the RC so far (the mock system's record).
    function _requests(bytes4 s) internal view returns (uint256 n) {
        return _deliveredCount(0, s, 0);
    }
}
