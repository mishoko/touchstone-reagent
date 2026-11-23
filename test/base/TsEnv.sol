// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Extsload} from "@uniswap/v4-core/src/Extsload.sol";
import {TouchstoneFactory} from "touchstone/TouchstoneFactory.sol";
import {TouchstoneHook} from "touchstone/TouchstoneHook.sol";
import {HookArgs, SeedParams} from "touchstone/interfaces/ITouchstoneFactory.sol";
import {ITouchstoneHook} from "touchstone/interfaces/ITouchstoneHook.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {TouchstoneVault} from "touchstone/TouchstoneVault.sol";
import {TouchstoneVaultExtension} from "touchstone/TouchstoneVaultExtension.sol";
import {CuratorBundler, DeployArgs} from "touchstone/periphery/CuratorBundler.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";
import {Obs} from "touchstone/types/Obs.sol";
import {Tier} from "touchstone/types/Tier.sol";
import {HookMining} from "touchstone-script/Mine.s.sol";
import {Tiers} from "touchstone-script/Tiers.sol";
import {MockRefPool} from "touchstone-test/utils/MockRefPool.sol";
import {MockToken} from "touchstone-test/utils/Stubs.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice The F layer (spec §9): a REAL Touchstone (the pinned submodule's factory, production vault, extension and
///         hook, `CuratorBundler.deployAndPlace`) on a local PoolManager, TEST tier, with one scripted v3-style
///         reference per vault so that a breach can be driven on one vault and not its sibling. The chain id is set
///         before anything is deployed, because the Hub resolves its proxy from `block.chainid` (r27 m-4).
///         Token orientation as on both live chains: token0 = mUSDC (6 dp), token1 = mWETH (18 dp, the B6 unit).
abstract contract TsEnv is Test {
    struct V {
        CuratorBundler bundler;
        address vault;
        address hook;
        MockRefPool ref;
    }

    uint32 internal constant SLOT_LADDER = 19; // breaches u32 @0, mode u8 @4
    uint32 internal constant SLOT_BOND = 17; // bondShares u128 @0, forfeitPool u128 @16
    uint32 internal constant SLOT_DRIP = 18; // forfeitTotal u128 @0, forfeitStart u40 @16, dripBlocks u40 @21

    PoolManager internal manager;
    TouchstoneFactory internal tsFactory;
    MockToken internal token0; // mUSDC
    MockToken internal token1; // mWETH
    Tier internal tier;
    uint256 internal blocktime;
    address internal curatorOwner = makeAddr("curatorOwner");
    bytes internal vaultCode;
    bytes internal extCode;
    bytes internal hookCode;
    PoolSwapTest internal swapRouter;

    function _setUpTouchstone(uint256 chainId) internal {
        vm.chainId(chainId);
        (Tier memory t, uint256 bt) = Tiers.testing();
        tier = t;
        blocktime = bt;
        vm.roll(100_000);
        vm.warp(100_000 * bt);
        manager = new PoolManager(address(this));
        MockToken a = new MockToken("mUSDC", 6);
        MockToken b = new MockToken("mWETH", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        vaultCode = type(TouchstoneVault).creationCode;
        extCode = type(TouchstoneVaultExtension).creationCode;
        hookCode = type(TouchstoneHook).creationCode;
        tsFactory = new TouchstoneFactory(address(manager), keccak256(vaultCode), keccak256(extCode), keccak256(hookCode));
        swapRouter = new PoolSwapTest(manager);
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    /// @notice A swap in the vault's own v4 pool: it moves spot away from the reference (a sandwich's first leg).
    function _swap(V memory v, bool zeroForOne, uint256 amountIn) internal {
        PoolKey memory key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(v.hook));
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice A fresh vault through a new bundler (one bundler deploys one vault), placed on [-1000, 1000) around a
    ///         reference at tick 0 with two hours of history.
    function _deployVault() internal returns (V memory v) {
        v.ref = new MockRefPool(address(token0), address(token1), 500, uint32(block.timestamp - 2 hours), 0);
        Tier memory t = tier;
        t.REF_POOL = address(v.ref);
        t.REF_SQRT_PRICE = TickMath.getSqrtPriceAtTick(0);
        v.bundler = new CuratorBundler(curatorOwner, tsFactory);
        bytes32 saltV = bytes32(uint256(1));
        HookArgs memory args = HookArgs({
            poolManager: address(manager),
            vault: HookMining.vaultAddress(address(tsFactory), address(v.bundler), saltV, vaultCode),
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 500,
            tickSpacing: 10,
            seedSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            tier: t
        });
        (bytes32 saltH,) = HookMining.mine(address(tsFactory), address(v.bundler), hookCode, args, 0);
        SeedParams memory seed = SeedParams({a0: 1e18, a1: 1e18, curator: address(v.bundler), wit0: 1e9, wit1: 1e9});
        token0.mint(address(v.bundler), 2e18);
        token1.mint(address(v.bundler), 2e18);
        vm.prank(curatorOwner);
        (v.vault, v.hook) = v.bundler.deployAndPlace(
            DeployArgs(vaultCode, extCode, hookCode, args, saltV, saltH, seed), -1000, 1000, PreSwap(false, false, 0), type(uint256).max
        );
    }

    // ------------------------------------------------------------------ clock and conduct

    function advance(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
        vm.warp(vm.getBlockTimestamp() + n * blocktime);
    }

    /// @notice Keeps the hook's clock observed for `blocks` (one open `refreshRef` per 10 blocks), as vault activity would.
    function _keepAlive(V memory v, uint256 blocks) internal {
        for (uint256 i; i < blocks; i += 10) {
            advance(10);
            ITouchstoneHook(v.hook).refreshRef();
        }
    }

    /// @notice In range for `blocks`, then a vault checkpoint (the open `poke`): base pay accrues to the curator, so a
    ///         later breach has unvested pay to forfeit and starts a drip.
    function _age(V memory v, uint256 blocks) internal {
        _keepAlive(v, blocks);
        IVaultEntries(v.vault).poke();
    }

    function _forfeitPool(V memory v) internal view returns (uint128) {
        return uint128(_ld(v.vault, SLOT_BOND) >> 128);
    }

    function _keepAliveAll(V[] memory vs, uint256 blocks) internal {
        for (uint256 i; i < blocks; i += 10) {
            advance(10);
            for (uint256 j; j < vs.length; ++j) {
                ITouchstoneHook(vs[j].hook).refreshRef();
            }
        }
    }

    /// @notice Moves the reference far out of the range and keeps the clock observed until `n` more breaches latch.
    function _latch(V memory v, uint32 n) internal {
        v.ref.setTick(50_000);
        uint32 target = _obs(v).breachSeq + n;
        for (uint256 i; _obs(v).breachSeq < target; ++i) {
            require(i < 1000, "TsEnv: no breach");
            _keepAlive(v, 10);
        }
    }

    function _backInRange(V memory v) internal {
        v.ref.setTick(0);
    }

    function _obs(V memory v) internal view returns (Obs memory) {
        return ITouchstoneHook(v.hook).obs();
    }

    function _process(V memory v) internal {
        IVaultEntries(v.vault).processBreach();
    }

    // ------------------------------------------------------------------ slot reads (spec §5.4 decodes the same)

    function _ld(address vault, uint256 slot) internal view returns (uint256) {
        return uint256(Extsload(vault).extsload(bytes32(slot)));
    }

    function _mode(V memory v) internal view returns (uint8) {
        return uint8(_ld(v.vault, SLOT_LADDER) >> 32);
    }

    function _breaches(V memory v) internal view returns (uint32) {
        return uint32(_ld(v.vault, SLOT_LADDER));
    }

    function _bond(V memory v) internal view returns (uint128) {
        return uint128(_ld(v.vault, SLOT_BOND));
    }

    function _dripEnd(V memory v) internal view returns (uint256) {
        uint256 w = _ld(v.vault, SLOT_DRIP);
        return uint256(uint40(w >> 128)) + uint256(uint40(w >> 168));
    }
}
