// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcExt} from "../../src/RcExt.sol";
import {RcB6} from "../../src/RcB6.sol";

/// @notice R-GAS's item probe (F-012): an `RcExt` that reports, from inside a reaction, the gas of every optional
///         item it runs (each pair evaluation, each optional B6 step) and the start and end of the Cron tick's
///         cursor and sweep phases. Events, not storage: a log costs ~2.4k and touches no slot, so the probe never
///         warms what it measures (it only makes the reaction slightly dearer: the conservative side).
///         `SKIP` (a slot no layout uses) emulates the gas guard firing before a reaction's first optional item:
///         the entry stays listed by its write-ahead and nothing optional runs (spec §5.5 "Deferred work"). The
///         R-GAS cells use it only to BUILD guard-cut states (a lower owed and unsent, a stale lowers-list head),
///         never inside a measured reaction.
contract RcExtGasProbe is RcExt {
    bytes32 internal constant SKIP = keccak256("reagent.rc.probe.skip");

    event ProbeItem(uint8 indexed kind, bytes4 sel, uint256 gasAt, uint256 used, bool ok);
    event ProbePhase(uint8 indexed phase, uint256 gasAt);

    uint8 internal constant K_EVAL = 1;
    uint8 internal constant K_B6 = 2;

    constructor(address b6_) RcExt(b6_) {}

    /// @notice The build's GAS_GUARD (read by the R-GAS cells; never hard-coded, v13 r1 V1-06).
    function guard() external pure returns (uint256) {
        return GAS_GUARD;
    }

    /// @notice The build's CURSOR_FLOOR (read by the R-GAS cells; never hard-coded, rc-fix r3 C3-04).
    function cursorFloor() external pure returns (uint256) {
        return CURSOR_FLOOR;
    }

    function _skipping() internal view returns (bool s) {
        bytes32 k = SKIP;
        assembly ("memory-safe") {
            s := sload(k)
        }
    }

    function _serveEntry(uint256 c, address cov, Budget memory bud) internal override {
        if (_skipping()) return; // the guard fired before the first optional item: the entry stays listed
        super._serveEntry(c, cov, bud);
    }

    function _b6Opt(bytes memory data) internal override returns (bool ok, bytes memory r) {
        uint256 g = gasleft();
        (ok, r) = super._b6Opt(data);
        uint256 used = g - gasleft();
        bytes4 s;
        assembly ("memory-safe") {
            s := mload(add(data, 32))
        }
        emit ProbeItem(K_B6, s, g, used, ok);
    }

    function _evalPair(uint256 c, address cov, address vault, Budget memory bud) internal override returns (bool sent) {
        uint256 g = gasleft();
        sent = super._evalPair(c, cov, vault, bud);
        uint256 used = g - gasleft();
        emit ProbeItem(K_EVAL, sent ? bytes4(uint32(1)) : bytes4(0), g, used, true);
    }

    function _cursor(Budget memory bud, uint256 max) internal override {
        emit ProbePhase(1, gasleft());
        super._cursor(bud, max);
        emit ProbePhase(2, gasleft());
    }

    function _sweepStep(Budget memory bud, uint256 max) internal override {
        emit ProbePhase(3, gasleft());
        super._sweepStep(bud, max);
        emit ProbePhase(4, gasleft());
    }
}


/// @notice V2-07's B6 probe: when `BURN` (a slot no layout uses) is set, the next optional B6 step that evaluates a
///         sends lowers or runs steps 1b–3 consumes ALL the gas it was given and reverts out of gas, as a step under-sized against its guard would
///         (only OPTIONAL paths: `_sendLowers` (b6Lowers, b6Floor) and `_serveB6` (b6Rest); the mandatory `b6State`
///         never burns);
///         the flag clears itself only through the revert (one burnt step per set). The caller must still complete
///         (it kept `TAIL`), so the reaction never reverts.
contract RcB6BurnProbe is RcB6 {
    bytes32 internal constant BURN = keccak256("reagent.rc.probe.burn");

    function _burning() internal view returns (bool b) {
        bytes32 k = BURN;
        assembly ("memory-safe") {
            b := sload(k)
        }
    }

    function _burn() internal view {
        if (!_burning()) return;
        while (true) {}
    }

    function _sendLowers(address cov, Bud memory bud, uint256 max) internal override returns (uint256, bool) {
        _burn();
        return super._sendLowers(cov, bud, max);
    }

    function _wakeB6(uint256 c, address cov, uint32 id) internal override returns (bool, bool) {
        _burn();
        return super._wakeB6(c, cov, id);
    }

    function _serveB6(address cov, Bud memory bud) internal override returns (bool) {
        _burn();
        return super._serveB6(cov, bud);
    }
}
