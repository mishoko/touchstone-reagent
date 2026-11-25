// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReagentHub} from "../src/ReagentHub.sol";

/// @notice R-DEPLOY (spec §9.2, a script row): the live deploy, as `script/deploy/rc.py` recorded it, is the reserved
///         address and the reviewed build, and both live Hubs name it. The live sends and their on-chain assertions
///         are rc.py's (status, code = simulated runtime = pin, OWNER, EXT); this cell pins the RECORD they wrote, so a
///         later hand edit or a re-recorded step that contradicts the deploy fails `forge test` (s7, F-015).
contract RDeployRecordTest is Test {
    address internal constant RESERVED = 0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9;
    address internal constant RC_DEPLOYER = 0x67941b1eA81913B45a6eE1d9B2e1aFfa98b2aea1;
    address internal constant OWNER = 0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213;

    function _j(string memory f) internal view returns (string memory) {
        return vm.readFile(string.concat("./audits/", f));
    }

    function test_R_DEPLOY__theRecordedDeployIsTheReservedAddressAndThePinnedBuild() public view {
        string memory l = _j("deployments-5318007.json");
        string memory pin = _j("rc-build.json");
        // the reserved address is CREATE(RC deployer, nonce 0) (F-007)
        assertEq(vm.computeCreateAddress(RC_DEPLOYER, 0), RESERVED, "CREATE(RC deployer, 0) is the reserved address");
        assertEq(vm.parseJsonAddress(l, ".steps.rc.address"), RESERVED, "the RC landed at the reserved address");
        assertEq(vm.parseJsonAddress(l, ".steps.rc.from"), RC_DEPLOYER, "sent by the RC deployer");
        assertEq(vm.parseJsonString(l, ".steps.rc.status"), "ok", "status 1");
        assertTrue(vm.parseJsonBool(l, ".steps.rc.asserted"), "rc.py's on-chain assertions ran");
        assertEq(vm.parseJsonAddress(l, ".steps.rc.owner"), OWNER, "OWNER is the owner key, not the RC deployer");
        assertEq(vm.parseJsonAddress(l, ".steps.rc.ext"), vm.parseJsonAddress(l, ".steps.rcext.address"), "EXT = RcExt");
        assertEq(vm.parseJsonAddress(l, ".steps.rc.b6"), vm.parseJsonAddress(l, ".steps.rcb6.address"), "B6 = RcB6");
        // the extension modules' live runtimes are the reviewed-build pin (immutables masked)
        assertEq(
            vm.parseJsonString(l, ".steps.rcext.runtimeMaskedSha"),
            vm.parseJsonString(pin, ".modules.RcExt.runtimeMaskedSha"),
            "RcExt live = pin"
        );
        assertEq(
            vm.parseJsonString(l, ".steps.rcb6.runtimeMaskedSha"),
            vm.parseJsonString(pin, ".modules.RcB6.runtimeMaskedSha"),
            "RcB6 live = pin"
        );
    }

    function test_R_DEPLOY__bothLiveHubsNameTheRcAndTheRecordedNeeds() public {
        string memory g = _j("gas-need.json");
        string[2] memory files = ["deployments-1301.json", "deployments-11155111.json"];
        uint256[2] memory ids = [uint256(1301), uint256(11155111)];
        for (uint256 i; i < 2; ++i) {
            string memory d = _j(files[i]);
            assertEq(vm.parseJsonAddress(d, ".steps.reagent.reads['ReagentHub.RC()']"), RESERVED, "the live Hub names the RC");
            assertEq(
                vm.parseJsonAddress(d, ".steps.reagent.reads['ReagentHub.FACTORY()']"),
                vm.parseJsonAddress(d, ".steps.reagent.reads.addresses.factory"),
                "the Hub's factory is the recorded one"
            );
            // the Hub's exit and plan NEEDs (in its code, selected by chain id) equal the recorded gas-need rows
            vm.chainId(ids[i]);
            (uint256 e, uint256 p) = new ReagentHub(RESERVED).needs();
            string memory c = vm.toString(ids[i]);
            assertEq(e, vm.parseJsonUint(g, string.concat(".kinds.rcExit.chains['", c, "'].need")), "exit NEED");
            assertEq(p, vm.parseJsonUint(g, string.concat(".kinds.rcAllocate.chains['", c, "'].need")), "plan NEED");
        }
    }
}
