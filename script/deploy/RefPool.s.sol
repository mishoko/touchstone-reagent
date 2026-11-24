// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {DemoToken, IV3Factory, IV3Pool, RefDriver} from "touchstone-script/demo/DemoKit.sol";
import {Chains} from "./Chains.sol";
import {Tier} from "touchstone/types/Tier.sol";

/// @notice Step 0b on either Reagent chain (ported from Touchstone's `script/demo/DemoRef.s.sol`, spec OQ-2): the mock
///         tokens (mUSDC, 6 decimals, as token0 and mWETH, 18 decimals, as token1: Touchstone's orientation, so the
///         tiers' token1-denominated BOND_MIN applies), the mock-token v3 reference pool through the chain's canonical
///         v3 factory, its observation cardinality raised to the tier's MIN_CARD in chunks of 250, and full-range
///         liquidity through a `RefDriver`. The warm-up (`script/deploy/warmup.sh`) follows before `TsDeploy.s.sol`.
///         Both Reagent chains use the same token1 unit (mWETH) so that exposure adds up across chains (B6).
///         Run: `forge script script/deploy/RefPool.s.sol --rpc-url <rpc> --private-key $DEPLOYER_PK --broadcast --slow`
contract RefPool is Script {
    uint24 internal constant FEE = 500;
    /// @dev ETH at 3,000 USDC in raw units (as Touchstone's demo): tick ~196,256, on the 10-tick grid.
    int24 internal constant START_TICK = 196_250;
    int24 internal constant FULL_LO = -887_270;
    int24 internal constant FULL_HI = 887_270;
    uint128 internal constant DEPTH_L = 5.5e16;

    function run() external {
        Chains.C memory c = Chains.get(block.chainid);
        (Tier memory tier_,) = Chains.tier(block.chainid);
        uint16 minCard = tier_.MIN_CARD;
        vm.startBroadcast();
        address me = msg.sender;
        uint64 n = vm.getNonce(me);
        bool usdcFirst = vm.computeCreateAddress(me, n) < vm.computeCreateAddress(me, n + 1);
        DemoToken usdc;
        DemoToken weth;
        if (usdcFirst) {
            usdc = new DemoToken("Reagent Demo USDC", "mUSDC", 6);
            weth = new DemoToken("Reagent Demo WETH", "mWETH", 18);
        } else {
            weth = new DemoToken("Reagent Demo WETH", "mWETH", 18);
            usdc = new DemoToken("Reagent Demo USDC", "mUSDC", 6);
        }
        require(address(usdc) < address(weth), "order");

        IV3Pool pool = IV3Pool(IV3Factory(c.v3Factory).createPool(address(usdc), address(weth), FEE));
        pool.initialize(TickMath.getSqrtPriceAtTick(START_TICK));
        // in chunks of 250 (a per-transaction gas cap on 1301), ending exactly at MIN_CARD (s2: 400 is not a
        // multiple of 250; the first 11155111 run stopped at 250 and the hook refused the pool, BadRef)
        for (uint16 k = 250; k < minCard; k += 250) {
            pool.increaseObservationCardinalityNext(k);
        }
        pool.increaseObservationCardinalityNext(minCard);
        RefDriver driver = new RefDriver(me, pool);
        usdc.mint(address(driver), 10_000_000e6);
        weth.mint(address(driver), 5_000e18);
        driver.addLiquidity(FULL_LO, FULL_HI, DEPTH_L);
        // the deployer's own balance funds vault seeds, the curator and the demo depositor later
        usdc.mint(me, 1_000_000e6);
        weth.mint(me, 1_000e18);
        vm.stopBroadcast();

        console2.log("mUSDC (token0)", address(usdc));
        console2.log("mWETH (token1)", address(weth));
        console2.log("v3 reference pool", address(pool));
        console2.log("RefDriver", address(driver));
    }
}
