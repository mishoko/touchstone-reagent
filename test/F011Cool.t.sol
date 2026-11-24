// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

contract F011Target {
    uint256 public x;

    function put(uint256 v) external returns (uint256) {
        x = v;
        return 42;
    }
}

contract F011Caller {
    uint256 public x;
    address public immutable T;

    constructor(address t) {
        T = t;
    }

    function viaDelegate(uint256 v) external returns (bool ok, uint256 ret, uint256 len) {
        bytes memory r;
        (ok, r) = T.delegatecall(abi.encodeCall(F011Target.put, (v)));
        len = r.length;
        if (r.length == 32) ret = abi.decode(r, (uint256));
    }
}

/// @notice F-011's root cause (s4): `vm.cool` on a code-only account that a contract reaches by `delegatecall`,
///         under this forge (1.5.0). Pins what forge does, so the R harness never cools the extension again.
contract F011CoolTest is Test {
    F011Target t;
    F011Caller c;

    function setUp() public {
        t = new F011Target();
        c = new F011Caller(address(t));
    }

    function test_F011__coolingTheDelegateTarget() public {
        (bool ok, uint256 ret, uint256 len) = c.viaDelegate(7);
        assertTrue(ok);
        assertEq(ret, 42);
        assertEq(c.x(), 7);
        uint256 codeBefore = address(t).code.length;
        vm.cool(address(t));
        uint256 codeAfter = address(t).code.length;
        (ok, ret, len) = c.viaDelegate(9);
        emit log_named_uint("code before", codeBefore);
        emit log_named_uint("code after cool", codeAfter);
        emit log_named_uint("ok", ok ? 1 : 0);
        emit log_named_uint("ret", ret);
        emit log_named_uint("retlen", len);
        emit log_named_uint("x after", c.x());
    }

    function test_F011__coolingTheDelegateTargetBeforeItsFirstLoadInTheTest() public {
        vm.cool(address(t)); // the target was deployed in setUp and is not yet loaded in this test's transaction
        uint256 codeAfter = address(t).code.length;
        (bool ok, uint256 ret, uint256 len) = c.viaDelegate(9);
        emit log_named_uint("code after cool", codeAfter);
        emit log_named_uint("ok", ok ? 1 : 0);
        emit log_named_uint("ret", ret);
        emit log_named_uint("retlen", len);
        emit log_named_uint("x after", c.x());
    }

    function test_F011__coolingTheDelegateTargetBeforeItsFirstLoadNoCodeRead() public {
        vm.cool(address(t));
        (bool ok, uint256 ret, uint256 len) = c.viaDelegate(9);
        emit log_named_uint("ok", ok ? 1 : 0);
        emit log_named_uint("ret", ret);
        emit log_named_uint("retlen", len);
        emit log_named_uint("x after", c.x());
    }

    function test_F011__coolingTheCallerOnly() public {
        c.viaDelegate(7);
        vm.cool(address(c));
        (bool ok, uint256 ret,) = c.viaDelegate(9);
        emit log_named_uint("ok", ok ? 1 : 0);
        emit log_named_uint("ret", ret);
        emit log_named_uint("x after", c.x());
    }
}

/// @notice The root cause: cooling, in setUp, an account created in setUp and only ever reached by `delegatecall`
///         (which never touches the code account) leaves it un-touched at setUp's commit, so the test sees no code.
contract F011CoolInSetUpTest is Test {
    F011Target t;
    F011Caller c;

    function setUp() public {
        t = new F011Target();
        c = new F011Caller(address(t));
        vm.cool(address(t));
        c.viaDelegate(1); // delegatecall: does not re-touch t
    }

    function test_F011__aCodeAccountCooledInSetUpIsLostAtCommit() public {
        assertEq(address(t).code.length, 0, "forge 1.5.0: the cooled, untouched code account was not committed");
        (bool ok,, uint256 len) = c.viaDelegate(9);
        assertTrue(ok, "a delegatecall to an address without code succeeds");
        assertEq(len, 0, "and returns nothing: a silent no-op");
        assertEq(c.x(), 1, "so the write never happens");
    }
}

/// @notice Control: the same, with a CALL to the target after the cool (a CALL touches it again) → committed.
contract F011CoolInSetUpControlTest is Test {
    F011Target t;
    F011Caller c;

    function setUp() public {
        t = new F011Target();
        c = new F011Caller(address(t));
        vm.cool(address(t));
        t.put(5); // CALL touches t
    }

    function test_F011__PC_aCallAfterTheCoolKeepsTheCode() public view {
        assertGt(address(t).code.length, 0);
    }
}

contract F011Slot {
    uint256 public x;

    function set(uint256 v) external {
        x = v;
    }
}

/// @notice What a cooled re-write costs (for honest R-GAS numbers): live, a reaction is its own transaction, so a
///         slot written by an earlier reaction has original = present (a non-zero → non-zero write: 2,900 + 2,100).
contract F011SlotTest is Test {
    F011Slot s;

    function setUp() public {
        s = new F011Slot();
    }

    function test_F011__cooledRewriteCost() public {
        s.set(1);
        vm.cool(address(s));
        uint256 g = gasleft();
        s.set(2);
        uint256 used = g - gasleft();
        emit log_named_uint("cooled rewrite of a slot written earlier in this test", used);
        F011Slot s2 = new F011Slot();
        s2.set(1);
        // reference: a cold slot whose committed value is non-zero is not constructible in one test; print the
        // fresh-slot write too
        vm.cool(address(s2));
        g = gasleft();
        s2.set(0);
        emit log_named_uint("cooled clear of a slot set earlier in this test", g - gasleft());
    }
}

/// @notice The honest method: state built in setUp, the measured call FIRST in the test body (a new transaction:
///         every account and slot cold, original = committed). A non-zero → non-zero write: 2,600 + 2,900 + 2,100.
contract F011BoundaryTest is Test {
    F011Slot s;

    function setUp() public {
        s = new F011Slot();
        s.set(1);
    }

    function test_F011__firstCallAfterSetUpIsCold() public {
        uint256 g = gasleft();
        s.set(2);
        uint256 used = g - gasleft();
        emit log_named_uint("rewrite, first in the test", used);
        assertGt(used, 7_500, "cold account + cold slot + clean write");
    }
}
