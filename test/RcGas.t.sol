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

    function setUp() public {
        _setUpRc();
    }

    function _newExt() internal override returns (address) {
        return address(new RcExtProbe());
    }

    function _logPolicy(LogRecord memory l) internal view override returns (Act) {
        if (dropStates && l.topic0 == T_NOTE_ && l.topic3 == 1 && address(uint160(l.topic2)) == dropFor) return Act.DROP;
        return Act.DELIVER;
    }

    function _lastStateGas() internal view returns (uint256 used, uint256 forward, bool ok) {
        for (uint256 i = reactGas.length; i > 0; --i) {
            GasRow memory r = reactGas[i - 1];
            if (r.topic0 == T_NOTE_ && r.topic3 == 1) return (r.used, r.forward, r.ok);
        }
    }

    /// @notice A Covenant's first STATE at the bounds: 4 holdings, 4 budgeted ids, 4 plans, 4 late arms.
    function test_R_GAS__firstStateAtTheBoundsWithFourPlans() public {
        V[4] memory vs;
        for (uint32 i; i < 4; ++i) {
            vs[i] = _registeredVault(CA, i + 1);
            _on(CA);
            _age(vs[i], 100);
        }
        (ICovenant ca,) = _covenantBoth(alice, admin);
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
        forwardOverride = vm.envOr("RGAS_FORWARD", uint256(0));
        _on(CA);
        vm.store(address(rc), MARK, bytes32(0));
        vm.prank(alice);
        ca.flush();
        coolNext = true; // the measured STATE runs cold, as its own transaction does live
        _elapse(5);
        (uint256 used, uint256 forward, bool ok) = _lastStateGas();
        uint256 mark = uint256(vm.load(address(rc), MARK));
        uint256 mandatory = forward - mark;
        console2.log("first STATE gas", used, "forward", forward);
        console2.log("mandatory part", mandatory);
        assertLe(mandatory, 700_000, "the mandatory part within PB-8 (s3 rc r2 D2-03)");
        assertTrue(ok, "never reverts at the live forward");
        if (forwardOverride == 0) assertLe(used, forward, "within the live forward");
        assertEq(reactReverts, 0);
    }
}
