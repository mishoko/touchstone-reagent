// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TsEnv} from "./base/TsEnv.sol";

interface ICurated {
    function curator() external view returns (address);
}

/// @notice The Touchstone facts Reagent reads (spec §5.1, §5.4; touchstone-surface §1, §3), on a real deployment.
contract TouchstoneSurfaceTest is TsEnv {
    bytes32 internal constant DEPLOYED = 0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2;
    bytes32 internal constant MODE_CHANGED = 0x73f069d8a008c9e2fe78e308751100d873455f99593c7d60eff545e91a90ab04;
    bytes32 internal constant BREACH_PROCESSED = 0xf37492039a7f836f6b471f6a2c580a9743a545b9d3f3d4b1e3a47108e67ea59c;
    bytes32 internal constant BREACH_LATCHED = 0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346;
    bytes32 internal constant ACTION = 0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba;

    function setUp() public {
        _setUpTouchstone(1301);
    }

    /// @notice T-DEPLOYED: a vault deployed through a bundler emits `Deployed` with topic1 = the bundler, and the
    ///         vault's curator is that bundler (the RC's curator identity, PB-5).
    function test_T_DEPLOYED__topic1IsTheBundlerAndTheCurator() public {
        vm.recordLogs();
        V memory v = _deployVault();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(tsFactory) && logs[i].topics[0] == DEPLOYED) {
                ++n;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(v.bundler), "topic1 = bundler");
                (address vault,, address hook) = abi.decode(_head(logs[i].data, 96), (address, address, address));
                assertEq(vault, v.vault, "vault");
                assertEq(hook, v.hook, "hook");
            }
        }
        assertEq(n, 1, "one Deployed");
        assertEq(ICurated(v.vault).curator(), address(v.bundler), "curator = bundler");
        // a second vault of another bundler has its own topic1 (one bundler, one vault)
        V memory w = _deployVault();
        assertTrue(address(w.bundler) != address(v.bundler));
        assertEq(ICurated(w.vault).curator(), address(w.bundler));
    }

    /// @notice T-SLOTS: slots 17/18/19 decode the bond, the drip and (breaches, mode) in NORMAL, BREACHED, EXITED and
    ///         after `retire`, against independent truth: the seed's bond (1e24 - 1e15 shares) less every
    ///         `Action.burnedBond` of the first placement, every `ModeChanged`, and the drip each `BreachProcessed`
    ///         starts (forfeitStart = its block, dripBlocks = FORFEIT_DRIP_BLOCKS).
    function test_T_SLOTS__bondDripAndLadderDecodeInEveryMode() public {
        vm.recordLogs();
        V memory v = _deployVault();
        Vm.Log[] memory dl = vm.getRecordedLogs();
        uint256 burned;
        for (uint256 i; i < dl.length; ++i) {
            if (dl[i].emitter == v.vault && dl[i].topics[0] == ACTION) {
                (,,,, uint256 bb) = abi.decode(dl[i].data, (uint8, uint256, uint160, uint256, uint256));
                burned += bb;
            }
        }
        // while the placement's markout is pending, part of the bond sits in reserveBond (slot 20 @0)
        uint256 reserveBond = uint128(_ld(v.vault, 20));
        assertEq(_bond(v) + reserveBond, 1e24 - 1e15 - burned, "bond + reserve = the seed's bond less the burn");
        assertEq(_mode(v), 0, "NORMAL");
        assertEq(_breaches(v), 0);
        _assertNoDrip(v);

        for (uint32 k = 1; k <= 3; ++k) {
            _age(v, 2 * tier.EPOCH); // unvested pay to forfeit
            _latch(v, 1);
            assertEq(_obs(v).pendingBreaches, 1, "latched, pending");
            assertEq(_breaches(v), k - 1, "slot 19 counts processed breaches only");
            vm.recordLogs();
            _process(v);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            (uint8 to, bool seen) = _modeTo(logs, v.vault);
            assertEq(_breaches(v), k, "breaches");
            uint8 want = k < 3 ? 1 : 2;
            assertEq(_mode(v), want, "mode");
            if (seen) assertEq(to, want, "ModeChanged.to = slot mode");
            uint256 w = _ld(v.vault, SLOT_DRIP);
            assertGt(uint128(w), 0, "a forfeit");
            assertEq(uint40(w >> 128), vm.getBlockNumber(), "forfeitStart = the processing block");
            assertEq(uint40(w >> 168), tier.FORFEIT_DRIP_BLOCKS, "dripBlocks");
            assertEq(_dripEnd(v), vm.getBlockNumber() + tier.FORFEIT_DRIP_BLOCKS, "drip end");
            _backInRange(v);
            _keepAlive(v, 30);
        }
        assertEq(_obs(v).breachSeq, 3, "latched seq = processed count here");
    }

    function test_T_SLOTS__retiredDecodes() public {
        V memory v = _deployVault();
        vm.recordLogs();
        vm.prank(curatorOwner);
        v.bundler.retire();
        (uint8 to, bool seen) = _modeTo(vm.getRecordedLogs(), v.vault);
        assertTrue(seen, "ModeChanged on retire");
        assertEq(_mode(v), to, "slot mode = ModeChanged.to");
        assertEq(_mode(v), 2, "retired is EXITED");
        _assertNoDrip(v); // nothing unvested: retire forfeits nothing and starts no drip
    }

    function _assertNoDrip(V memory v) internal view {
        uint256 w = _ld(v.vault, SLOT_DRIP);
        assertEq(uint128(w), 0, "forfeitTotal");
        assertEq(uint40(w >> 128), 0, "forfeitStart");
        assertEq(uint40(w >> 168), tier.FORFEIT_DRIP_BLOCKS, "dripBlocks is configured at seed");
        assertEq(uint40(w >> 208), 4 * tier.EPOCH, "releaseDelay = 4 EPOCH");
    }

    function _modeTo(Vm.Log[] memory logs, address vault) internal pure returns (uint8 to, bool seen) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == vault && logs[i].topics[0] == MODE_CHANGED) {
                (, to) = abi.decode(logs[i].data, (uint8, uint8));
                seen = true;
            }
        }
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory r) {
        r = new bytes(n);
        for (uint256 i; i < n; ++i) {
            r[i] = b[i];
        }
    }
}
