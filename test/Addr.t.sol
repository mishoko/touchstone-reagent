// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {CovenantFactory} from "../src/CovenantFactory.sol";

/// @notice T-ADDR (spec §3.1, §5.2, §5.4; r26 D26-02, r27 D27-02, r28 m-3, s2 LF-1): through the real CREATE2 deployer
///         `0x4e59…956C`, the extension, the Covenant implementation, the factory, the Hub its constructor deploys
///         and every Covenant have identical addresses on both chain ids; the cross-links hold; sizes are within the
///         22,000 B runtime rule and EIP-3860's 49,152 B initcode limit.
contract AddrTest is Test {
    address internal constant DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = keccak256("touchstone-reagent/v1");
    address internal RC = makeAddr("rc");
    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");

    struct Set {
        address ext;
        address impl;
        address factory;
        address hub;
        address covenant;
        address proxy;
    }

    function _create2(bytes memory initcode) internal returns (address a) {
        (bool ok, bytes memory ret) = DEPLOYER.call(abi.encodePacked(SALT, initcode));
        require(ok && ret.length == 20, "CREATE2 deployer failed");
        a = address(bytes20(ret));
    }

    function _deployOn(uint256 chainId) internal returns (Set memory s) {
        vm.chainId(chainId);
        assertGt(DEPLOYER.code.length, 0, "the deterministic deployer exists");
        s.ext = _create2(type(CovenantExt).creationCode);
        s.impl = _create2(abi.encodePacked(type(Covenant).creationCode, abi.encode(s.ext)));
        bytes memory fcode = abi.encodePacked(type(CovenantFactory).creationCode, abi.encode(RC, admin, s.impl));
        assertLe(fcode.length, 49_152, "EIP-3860: the factory's initcode");
        s.factory = _create2(fcode);
        CovenantFactory f = CovenantFactory(s.factory);
        s.hub = f.HUB();
        vm.prank(admin);
        f.allow(owner, true);
        vm.prank(owner);
        s.covenant = f.create();
        s.proxy = ReagentHub(payable(s.hub)).PROXY();
        // cross-links (r26 D26-02, r27 D27-02)
        assertEq(ReagentHub(payable(s.hub)).FACTORY(), s.factory, "hub.FACTORY() == factory");
        assertEq(f.HUB(), s.hub, "factory.HUB() == hub");
        assertEq(f.ADMIN(), admin, "factory.ADMIN() == admin");
        assertEq(f.IMPL(), s.impl);
        assertEq(Covenant(payable(s.impl)).EXT(), s.ext);
        assertEq(ReagentHub(payable(s.hub)).RC(), RC);
        // sizes (the 22,000 B runtime rule)
        assertLe(s.ext.code.length, 22_000, "CovenantExt runtime");
        assertLe(s.impl.code.length, 22_000, "Covenant runtime");
        assertLe(s.factory.code.length, 22_000, "CovenantFactory runtime");
        assertLe(s.hub.code.length, 22_000, "ReagentHub runtime");
    }

    function test_T_ADDR__sameAddressesOnBothChainIds() public {
        uint256 snap = vm.snapshotState();
        Set memory a = _deployOn(1301);
        vm.revertToState(snap);
        Set memory b = _deployOn(11155111);
        assertEq(a.ext, b.ext, "extension");
        assertEq(a.impl, b.impl, "implementation");
        assertEq(a.factory, b.factory, "factory");
        assertEq(a.hub, b.hub, "hub");
        assertEq(a.covenant, b.covenant, "a Covenant");
        assertEq(a.proxy, 0x775c9B990ADe401060B78D0e98684eEf8d2466C1, "1301 proxy from the chain id");
        assertEq(b.proxy, 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4, "11155111 proxy from the chain id");
    }

    /// @notice An implementation whose extension has no code is refused (every admin call would be a no-op, D2-07).
    function test_T_ADDR__anImplementationWithoutAnExtensionIsRefused() public {
        vm.expectRevert();
        new Covenant(address(0x1234));
    }

    /// @notice The Hub refuses any other chain at construction (same initcode, table by chain id).
    function test_T_ADDR__anyOtherChainRefusesTheHub() public {
        vm.chainId(84532);
        address ext = _create2(type(CovenantExt).creationCode);
        address impl = _create2(abi.encodePacked(type(Covenant).creationCode, abi.encode(ext)));
        (bool ok,) = DEPLOYER.call(
            abi.encodePacked(SALT, type(CovenantFactory).creationCode, abi.encode(RC, admin, impl))
        );
        assertFalse(ok, "the factory's constructor reverts (the Hub's chain table)");
    }

    /// @notice The local build reproduces the LIVE addresses recorded by script in `audits/deployments-*.json` (with the
    ///         live RC and admin): any change to a deployed contract's source, even a comment (the metadata hash), moves
    ///         them, so the deployed contracts' source is frozen (s3: caught a comment edit before it shipped).
    function test_T_ADDR__localBuildReproducesTheLiveAddresses() public {
        RC = 0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9;
        admin = 0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213;
        string[2] memory files = ["./audits/deployments-1301.json", "./audits/deployments-11155111.json"];
        uint256[2] memory ids = [uint256(1301), uint256(11155111)];
        for (uint256 i; i < 2; ++i) {
            string memory j = vm.readFile(files[i]);
            uint256 snap = vm.snapshotState();
            Set memory s = _deployOn(ids[i]);
            vm.revertToState(snap);
            assertEq(s.ext, vm.parseJsonAddress(j, ".steps.reagent.reads.addresses.ext"), "CovenantExt as deployed");
            assertEq(s.impl, vm.parseJsonAddress(j, ".steps.reagent.reads.addresses.impl"), "Covenant impl as deployed");
            assertEq(s.factory, vm.parseJsonAddress(j, ".steps.reagent.reads.addresses.factory"), "CovenantFactory as deployed");
            assertEq(s.hub, vm.parseJsonAddress(j, ".steps.reagent.reads.addresses.hub"), "ReagentHub as deployed");
        }
    }
}
