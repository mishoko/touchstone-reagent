// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TouchstoneFactory} from "touchstone/TouchstoneFactory.sol";
import {TouchstoneHook} from "touchstone/TouchstoneHook.sol";
import {HookArgs, SeedParams} from "touchstone/interfaces/ITouchstoneFactory.sol";
import {IUniswapV3PoolOracle} from "touchstone/interfaces/IUniswapV3PoolOracle.sol";
import {TouchstoneVault} from "touchstone/TouchstoneVault.sol";
import {TouchstoneVaultExtension} from "touchstone/TouchstoneVaultExtension.sol";
import {CuratorBundler, DeployArgs} from "touchstone/periphery/CuratorBundler.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";
import {Tier} from "touchstone/types/Tier.sol";
import {HookMining} from "touchstone-script/Mine.s.sol";
import {Tiers} from "touchstone-script/Tiers.sol";
import {DemoToken} from "touchstone-script/demo/DemoKit.sol";
import {Chains} from "./Chains.sol";

interface IV3Slot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @notice A fresh Touchstone vault on a Reagent chain (ported from Touchstone's `script/demo/DeployDemo.s.sol`; R-02:
///         never the hookathon vault): the factory against the chain's canonical v4 PoolManager (or an existing one,
///         `FACTORY`), a new `CuratorBundler` (the curator; one bundler deploys one vault), the hook salt mined for
///         that bundler, and `deployAndPlace` in one transaction. DEMO tier on 1301, TEST tier on 11155111.
///         Env: REF_POOL (from `RefPool.s.sol`, warmed up); optional FACTORY (0 or unset = deploy a new one);
///         optional DEPLOY_VAULT=0 to deploy only the factory and a bundler (a bundler the RC registers before it
///         deploys, spec §12).
///         Run: `REF_POOL=<pool> forge script script/deploy/TsDeploy.s.sol --rpc-url <rpc> --private-key $DEPLOYER_PK
///         --broadcast --slow --gas-estimate-multiplier 115` (1301's per-transaction cap is 2^24).
contract TsDeploy is Script {
    uint24 internal constant FEE = 500;
    int24 internal constant SPACING = 10;
    uint256 internal constant SEED1 = 2e18;

    error History();
    error NotDemoToken();
    error Decimals();
    error Cardinality(uint16 have, uint16 want);

    function run() external {
        address refPool = vm.envAddress("REF_POOL");
        address existing = vm.envOr("FACTORY", address(0));
        bool deployVault = vm.envOr("DEPLOY_VAULT", true);
        Chains.C memory c = Chains.get(block.chainid);
        (Tier memory t, uint256 blocktime) = Chains.tier(block.chainid);
        t.REF_POOL = refPool;
        int24 refTick = _twap(refPool, t.REF_WINDOW);
        uint32[] memory ago = new uint32[](2);
        ago[0] = t.GRID_SEC + t.REF_WINDOW;
        try IUniswapV3PoolOracle(refPool).observe(ago) {} catch {
            revert History();
        }
        uint160 seedSqrt = TickMath.getSqrtPriceAtTick(refTick);
        t.REF_SQRT_PRICE = seedSqrt;
        Tiers.check(t, blocktime);

        IUniswapV3PoolOracle r = IUniswapV3PoolOracle(refPool);
        IERC20 t0 = IERC20(r.token0());
        IERC20 t1 = IERC20(r.token1());
        if (DemoToken(address(t0)).minter() != msg.sender || DemoToken(address(t1)).minter() != msg.sender) revert NotDemoToken();
        // token0 = mUSDC (6 dp), token1 = mWETH (18 dp, the B6 unit) on both chains (spec §3.1; tools review m-7)
        if (DemoToken(address(t0)).decimals() != 6 || DemoToken(address(t1)).decimals() != 18) revert Decimals();
        // the reference holds enough history slots before the hook sees it (TRAPS s2: BadRef at 250 < 400)
        (,,, uint16 card,,,) = IV3Slot0(refPool).slot0();
        if (card < t.MIN_CARD) revert Cardinality(card, t.MIN_CARD);

        vm.startBroadcast();
        address me = msg.sender;
        bytes memory vaultCode = type(TouchstoneVault).creationCode;
        bytes memory extCode = type(TouchstoneVaultExtension).creationCode;
        bytes memory hookCode = type(TouchstoneHook).creationCode;
        TouchstoneFactory factory = existing != address(0)
            ? TouchstoneFactory(existing)
            : new TouchstoneFactory(c.poolManager, keccak256(vaultCode), keccak256(extCode), keccak256(hookCode));
        CuratorBundler bundler = new CuratorBundler(me, factory);
        console2.log("factory", address(factory));
        console2.log("bundler (curator)", address(bundler));
        if (!deployVault) {
            vm.stopBroadcast();
            return;
        }
        bytes32 saltV = bytes32(uint256(1));
        HookArgs memory args = HookArgs({
            poolManager: c.poolManager,
            vault: HookMining.vaultAddress(address(factory), address(bundler), saltV, vaultCode),
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: FEE,
            tickSpacing: SPACING,
            seedSqrtPriceX96: seedSqrt,
            tier: t
        });
        (bytes32 saltH,) = HookMining.mine(address(factory), address(bundler), hookCode, args, 0);

        int24 cc = refTick / SPACING * SPACING;
        if (refTick < 0 && refTick % SPACING != 0) cc -= SPACING;
        int24 lo = cc - t.W_TICKS / 2;
        int24 hi = cc + t.W_TICKS / 2;
        uint160 sa = TickMath.getSqrtPriceAtTick(lo);
        uint160 sb = TickMath.getSqrtPriceAtTick(hi);
        uint128 l = LiquidityAmounts.getLiquidityForAmount1(sa, seedSqrt, SEED1);
        uint256 a0 = SqrtPriceMath.getAmount0Delta(seedSqrt, sb, l, true);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(sa, seedSqrt, l, true);
        SeedParams memory seed =
            SeedParams({a0: a0 * 101 / 100 + 1, a1: a1 * 101 / 100 + 1, curator: address(bundler), wit0: 1e6, wit1: 1e12});
        t0.transfer(address(bundler), seed.a0 + seed.wit0);
        t1.transfer(address(bundler), seed.a1 + seed.wit1);
        (address v, address h) = bundler.deployAndPlace(
            DeployArgs(vaultCode, extCode, hookCode, args, saltV, saltH, seed), lo, hi, PreSwap(false, false, 0), type(uint256).max
        );
        vm.stopBroadcast();

        console2.log("vault", v);
        console2.log("hook", h);
        console2.log("m_perBlock", uint256(t.m_perBlock));
        console2.log("reference tick", int256(refTick));
        console2.log("range lo", int256(lo));
        console2.log("range hi", int256(hi));
    }

    function _twap(address pool, uint32 window) internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        (int56[] memory cum,) = IUniswapV3PoolOracle(pool).observe(ago);
        int56 d = cum[1] - cum[0];
        int24 tick = int24(d / int56(uint56(window)));
        if (d < 0 && d % int56(uint56(window)) != 0) --tick;
        return tick;
    }
}
