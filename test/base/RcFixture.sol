// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcEnv} from "./RcEnv.sol";
import {CuratorBundler} from "touchstone/periphery/CuratorBundler.sol";
import {IReagentRC} from "../../src/interfaces/IReagentRC.sol";
import {ICovenant, Rulebook} from "../../src/interfaces/IReagent.sol";

/// @notice The R-layer fixture: the RC (deployed by artifact, so the suite compiles before the RC exists: test
///         first) on Lasna, then each chain's Reagent stack with that RC address, the Hubs and Touchstone factories
///         registered as live (one Hub address on both chains).
abstract contract RcFixture is RcEnv {
    IReagentRC internal rc;
    address internal rcExt;
    address internal rcOwner = makeAddr("rcOwner");
    address internal admin = makeAddr("admin");

    function _setUpRc() internal {
        _setUpTwoChains();
        uint256 p = _lasna();
        rcExt = _newExt();
        rc = IReagentRC(payable(deployCode("ReagentRC.sol:ReagentRC", abi.encode(rcOwner, rcExt))));
        coolList.push(rcExt);
        _leave(p);
        _deployReagent(address(rc), admin);
        p = _lasna();
        vm.startPrank(rcOwner);
        rc.addHub(CA, address(ch[CA].hub));
        rc.addHub(CB, address(ch[CA].hub)); // the live Hub has one address on both chains
        rc.addFactory(CA, address(ch[CA].ts));
        rc.addFactory(CB, address(ch[CB].ts));
        vm.stopPrank();
        _leave(p);
    }

    /// @dev The extension the RC is built with; a gas probe subclass may replace it (R-GAS).
    function _newExt() internal virtual returns (address) {
        return deployCode("RcExt.sol:RcExt");
    }

    /// @notice Registers curator `id` (if new) and a fresh bundler on `c`, then deploys its vault through it.
    function _registeredVault(uint256 c, uint32 id) internal returns (V memory v) {
        _on(c);
        CuratorBundler b = _newBundler();
        uint256 p = _lasna();
        vm.startPrank(rcOwner);
        if (!rc.curatorExists(id)) rc.addCurator(id);
        rc.addBundler(id, c, address(b));
        vm.stopPrank();
        _elapse(2); // the subscription takes effect before the deploy's origin (spec §12)
        _leave(p);
        _on(c);
        v = _deployVaultWith(b);
        _elapse(30); // the reaction (one Lasna block) and the rcVault delivery (3 s / 13.2 s)
    }

    function _ownerCall(bytes memory data) internal returns (bool ok, bytes memory ret) {
        uint256 p = _lasna();
        vm.prank(rcOwner);
        (ok, ret) = address(rc).call(data);
        _leave(p);
    }

    // ------------------------------------------------------------------ Covenants on both chains

    uint256 internal constant SH = 1e23;

    /// @notice PB-14 defaults with a 100 mWETH budget (cap 60, 30 per chain by default) over `ids`.
    function _rulesFor(uint32 a, uint32 b) internal pure returns (Rulebook memory r) {
        r.k = 1;
        r.b3 = true;
        r.b4FloorBps = 5_000;
        r.maxShareBps = 6_000;
        r.budget = 100e18;
        r.agentCapPerEpoch = 10e18;
        r.ids = [a, b, uint32(0), uint32(0)];
    }

    function _setRulesOn(uint256 c, ICovenant cv, Rulebook memory r) internal {
        _on(c);
        address o = cv.owner();
        vm.prank(o);
        cv.setRules(r);
    }

    function _allocOn(uint256 c, ICovenant cv, address vault, uint256 shares) internal {
        _on(c);
        address o = cv.owner();
        vm.prank(o);
        cv.allocate(vault, shares, type(uint256).max, type(uint256).max);
    }
}
