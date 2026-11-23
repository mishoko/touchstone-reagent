// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Covenant} from "../../src/Covenant.sol";
import {CovenantExt} from "../../src/CovenantExt.sol";
import {CovenantFactory} from "../../src/CovenantFactory.sol";
import {ReagentHub} from "../../src/ReagentHub.sol";

/// @notice The deterministic deployer (spec §3.1, §5.2, s2 LF-1): `CovenantExt`, the `Covenant` implementation and the
///         `CovenantFactory(RC, admin, impl)` (whose constructor deploys this chain's Hub) through the CREATE2 deployer
///         `0x4e59…956C` with one salt, so every address is the same on 1301 and 11155111 (T-ADDR, live).
///         Env: RC (the ReagentRC's Lasna address: CREATE(the dedicated RC deployer key, nonce 0), whose first Lasna
///         transaction must be the RC deploy), ADMIN (the demo allowlist admin).
contract ReagentDeploy is Script {
    bytes32 internal constant SALT = keccak256("touchstone-reagent/v1");

    function run() external {
        address rc = vm.envAddress("RC");
        address admin = vm.envAddress("ADMIN");
        vm.startBroadcast();
        CovenantExt ext = new CovenantExt{salt: SALT}();
        Covenant impl = new Covenant{salt: SALT}(address(ext));
        CovenantFactory f = new CovenantFactory{salt: SALT}(rc, admin, address(impl));
        vm.stopBroadcast();
        ReagentHub hub = ReagentHub(payable(f.HUB()));
        require(hub.FACTORY() == address(f) && hub.RC() == rc && f.ADMIN() == admin && f.IMPL() == address(impl));
        console2.log("CovenantExt", address(ext));
        console2.log("Covenant impl", address(impl));
        console2.log("CovenantFactory", address(f));
        console2.log("ReagentHub", address(hub));
        console2.log("PROXY", hub.PROXY());
    }
}
