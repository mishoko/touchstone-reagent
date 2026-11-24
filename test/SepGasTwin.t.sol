// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {GasNeedTest, HubNoPrecheck} from "./GasNeed.t.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {Covenant} from "../src/Covenant.sol";
import {CovenantExt} from "../src/CovenantExt.sol";
import {CovenantFactory} from "../src/CovenantFactory.sol";
import {ICovenant, IReagentHub} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice Etched at the proxy address in the `eth_simulateV1` twins: calls `target` with exactly `g` gas, so the
///         Hub sees `msg.sender == PROXY` and the entry gas a delivery at a chosen gasLimit would bring.
contract GasForwarder {
    fallback() external payable {
        (address t, uint256 g, bytes memory p) = abi.decode(msg.data, (address, uint256, bytes));
        (bool ok,) = t.call{gas: g}(p);
        ok;
    }
}

/// @notice A-SEPGAS63's and T-SEPGAS-EXIT/PLAN's positive control: the Hub with the forge (1301) NEEDs on
///         11155111, i.e. the pre-check sized without the Glamsterdam price of fresh slots (spec §5.6, D4-06).
contract HubForgeNeed is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    /// @dev Keyed by kind through `needs()` (never by value, which changes; s3 rc r5 D5-05).
    function _shortGas(uint256 need) internal view override returns (bool) {
        (uint256 e, uint256 p) = needs();
        uint256 forge_ = need == e ? 880_000 : need == p ? 1_290_000 : need; // the 1301 NEEDs (RcBase NEED_*_1301; s4 LF-S4-1)
        return gasleft() < forge_ * 64 / 63 + 40_000;
    }
}

/// @notice The 11155111 gas twins' state source (spec §5.6 method (a), §9.1 T-SEPGAS-*): the T-GAS worst-case state
///         of each kind is built at chain id 11155111 with the LIVE deterministic addresses (RC 0xFbcD…, admin =
///         the deployer EOA, so the Hub is 0x5887… with the deployed runtime), then dumped for
///         `script/deploy/sepgas.py`, which replays the callback by `eth_simulateV1` on Sepolia with the dumped
///         accounts as state overrides (Glamsterdam pricing). Runs only with SEPGAS_DUMP=1.
contract SepGasTwinDump is GasNeedTest {
    address internal constant D4E59 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant SALT = keccak256("touchstone-reagent/v1");

    function _chain() internal pure override returns (uint256) {
        return 11155111;
    }

    function setUp() public override {
        if (bytes(vm.envOr("SEPGAS_DUMP", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    function _setUpReagent(uint256 chainId) internal override {
        RC = 0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9;
        admin = 0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213;
        _setUpTouchstone(chainId);
        ext = CovenantExt(_create2(type(CovenantExt).creationCode));
        impl = Covenant(payable(_create2(abi.encodePacked(type(Covenant).creationCode, abi.encode(address(ext))))));
        factory = CovenantFactory(
            _create2(abi.encodePacked(type(CovenantFactory).creationCode, abi.encode(RC, admin, address(impl))))
        );
        hub = ReagentHub(payable(factory.HUB()));
        PROXY = hub.PROXY();
        require(
            address(hub) == vm.parseJsonAddress(vm.readFile("./audits/deployments-11155111.json"), ".steps.reagent.reads.addresses.hub"),
            "not the live Hub address"
        );
    }

    function _create2(bytes memory initcode) internal returns (address a) {
        (bool ok, bytes memory ret) = D4E59.call(abi.encodePacked(SALT, initcode));
        require(ok && ret.length == 20, "CREATE2 deployer failed");
        a = address(bytes20(ret));
    }

    /// @dev Writes `output/sepgas-<kind>.json`: the call, the block, and every account the call touches with its
    ///      code, balance and the PRE-call value of each storage slot it accesses (first access in the state diff),
    ///      which is exactly the state the replay needs (any other slot is never read on the same path).
    function _dump(string memory kind, bytes memory data, bytes memory pcCode) internal {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(PROXY);
        (bool ok,) = address(hub).call{gas: 30_000_000}(data);
        require(ok, "dump: the reference call failed");
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        vm.revertToState(snap);
        // distinct accounts (callees, accessed accounts and storage owners)
        address[] memory as_ = new address[](acc.length * 2 + 64);
        uint256 n;
        for (uint256 i; i < acc.length; ++i) {
            n = _addOnce(as_, n, acc[i].account);
            for (uint256 k; k < acc[i].storageAccesses.length; ++k) {
                n = _addOnce(as_, n, acc[i].storageAccesses[k].account);
            }
        }
        string memory root = string.concat(kind, ".accounts");
        string memory accounts;
        for (uint256 a; a < n; ++a) {
            accounts = _account(root, as_[a], acc);
        }
        string memory o = kind;
        vm.serializeString(o, "kind", kind);
        vm.serializeAddress(o, "hub", address(hub));
        vm.serializeAddress(o, "proxy", PROXY);
        vm.serializeBytes(o, "data", data);
        vm.serializeBytes(o, "pcCode", pcCode);
        vm.serializeBytes(o, "npCode", _noPrecheckHubCode());
        vm.serializeUint(o, "blockNumber", vm.getBlockNumber());
        vm.serializeUint(o, "timestamp", vm.getBlockTimestamp());
        string memory j = vm.serializeString(o, "accounts", accounts);
        vm.writeJson(j, string.concat("./output/sepgas-", kind, ".json"));
    }

    function _addOnce(address[] memory as_, uint256 n, address x) internal pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (as_[i] == x) return n;
        }
        as_[n] = x;
        return n + 1;
    }

    /// @dev One account's code, balance and accessed slots' pre-call values, serialised under `root`.
    function _account(string memory root, address a, VmSafe.AccountAccess[] memory acc) internal returns (string memory) {
        bytes32[] memory slots = new bytes32[](512);
        bytes32[] memory vals = new bytes32[](512);
        uint256 m;
        for (uint256 i; i < acc.length; ++i) {
            for (uint256 k; k < acc[i].storageAccesses.length; ++k) {
                VmSafe.StorageAccess memory st = acc[i].storageAccesses[k];
                if (st.account != a) continue;
                bool seen;
                for (uint256 q; q < m; ++q) {
                    if (slots[q] == st.slot) seen = true;
                }
                if (!seen) {
                    slots[m] = st.slot;
                    vals[m++] = st.previousValue;
                }
            }
        }
        assembly ("memory-safe") {
            mstore(slots, m)
            mstore(vals, m)
        }
        string memory key = string.concat(root, ".", vm.toString(a));
        vm.serializeBytes(key, "code", a.code);
        vm.serializeUint(key, "balance", a.balance);
        vm.serializeBytes32(key, "slots", slots);
        string memory obj = vm.serializeBytes32(key, "values", vals);
        return vm.serializeString(root, vm.toString(a), obj);
    }

    /// @dev The Hub without its pre-check (forwards everything above RESERVE): measures the Covenant's own need.
    function _noPrecheckHubCode() internal returns (bytes memory) {
        uint256 snap = vm.snapshotState();
        vm.prank(address(factory));
        HubNoPrecheck h = new HubNoPrecheck(RC);
        bytes memory code = address(h).code;
        vm.revertToState(snap);
        return code;
    }

    function _forgeNeedHubCode() internal returns (bytes memory) {
        vm.prank(address(factory));
        HubForgeNeed h = new HubForgeNeed(RC);
        return address(h).code;
    }

    function test_SEPGAS_DUMP__conduct() public {
        _dump("rcConduct", abi.encodeCall(IReagentHub.rcConduct, (RC, 9, 1, 0, 0, 1)), "");
    }

    function test_SEPGAS_DUMP__vault() public {
        _dump("rcVault", abi.encodeCall(IReagentHub.rcVault, (RC, address(0xF00D), 11)), "");
    }

    function test_SEPGAS_DUMP__budget() public {
        _dump("rcBudget", abi.encodeCall(IReagentHub.rcBudget, (RC, address(c), 4, 2e18, 1, c.rulesNonce())), "");
    }

    function test_SEPGAS_DUMP__exit() public {
        _exitWorstState();
        bytes memory pc = _forgeNeedHubCode();
        _dump("rcExit", abi.encodeCall(IReagentHub.rcExit, (RC, address(c), X.vault, seq, 1)), pc);
    }

    function test_SEPGAS_DUMP__plan() public {
        vm.prank(owner2);
        c.leave(Z.vault, type(uint256).max, 0, 0);
        vm.startPrank(owner2);
        c.setAllowed(X3.vault, true);
        c.setPlan(X3.vault, 0.1e18);
        vm.stopPrank();
        _toEpochBoundary(X3);
        IVaultEntries(X3.vault).poke();
        uint32 cur = uint32(_ld(X3.vault, 8) >> 40);
        bytes memory pc = _forgeNeedHubCode();
        _dump("rcAllocate", abi.encodeCall(IReagentHub.rcAllocate, (RC, address(c), X3.vault, cur - 1)), pc);
    }
}
