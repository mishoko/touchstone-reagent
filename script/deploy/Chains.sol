// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Tier} from "touchstone/types/Tier.sol";
import {Tiers} from "touchstone-script/Tiers.sol";
import {Addresses} from "touchstone-script/Addresses.sol";

/// @notice The two Reagent origin chains (spec §3.1): Unichain Sepolia runs Touchstone's DEMO tier, Ethereum Sepolia
///         its TEST tier (12 s grid; the measured 13.2 s block time is gate G2's question, OQ-14).
library Chains {
    // Ethereum Sepolia (11155111). Sources: https://docs.uniswap.org/contracts/v4/deployments (PoolManager) and
    // https://docs.uniswap.org/contracts/v3/reference/deployments/ethereum-deployments (Sepolia v3 factory).
    // Checked live in s2: code present, v3 `feeAmountTickSpacing(500) = 10`.
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant SEPOLIA_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;

    /// @dev The reference pool's minimum cardinality is the tier's `MIN_CARD` (read from `tier()`, never duplicated:
    ///      tools review m-7).
    struct C {
        address poolManager;
        address v3Factory;
        uint256 blocktime;
        bool demo;
    }

    function get(uint256 chainId) internal pure returns (C memory c) {
        if (chainId == 1301) {
            return C(Addresses.UNICHAIN_SEPOLIA_POOL_MANAGER, Addresses.UNICHAIN_SEPOLIA_V3_FACTORY, 1, true);
        }
        if (chainId == 11155111) return C(SEPOLIA_POOL_MANAGER, SEPOLIA_V3_FACTORY, 12, false);
        revert("Chains: not a Reagent chain");
    }

    function tier(uint256 chainId) internal pure returns (Tier memory t, uint256 blocktime) {
        if (chainId == 1301) return Tiers.demo();
        if (chainId == 11155111) return Tiers.testing();
        revert("Chains: not a Reagent chain");
    }
}
