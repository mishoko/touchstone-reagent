// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Extsload} from "@uniswap/v4-core/src/Extsload.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface IVaultViews {
    function HOOK() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IHookRef {
    function REF_POOL() external view returns (address);
}

interface IRefTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Reads of a Touchstone vault through `extsload`, at the slots of its committed storage snapshot
///         (`lib/touchstone/test/storage/TouchstoneVault.txt`; T-SLOTS pins them), and valuation at the reference.
library VaultRead {
    // Touchstone errors a plan maps to a SKIPPED reason (spec §5.3)
    bytes4 internal constant SLIPPAGE = bytes4(keccak256("Slippage()"));
    bytes4 internal constant MARKOUT_PENDING = bytes4(keccak256("MarkoutPending()"));
    bytes4 internal constant NAV_CAP = bytes4(keccak256("NavCap()"));

    uint256 internal constant Q96 = 1 << 96;

    function _ld(address vault, uint256 slot) private view returns (uint256) {
        return uint256(Extsload(vault).extsload(bytes32(slot)));
    }

    function hook(address vault) internal view returns (address) {
        return IVaultViews(vault).HOOK();
    }

    function tokens(address vault) internal view returns (IERC20, IERC20) {
        IRefTokens r = IRefTokens(IHookRef(hook(vault)).REF_POOL());
        return (IERC20(r.token0()), IERC20(r.token1()));
    }

    /// @dev slot 19: breaches u32 @0, mode u8 @4
    function breaches(address vault) internal view returns (uint32) {
        return uint32(_ld(vault, 19));
    }

    function mode(address vault) internal view returns (uint8) {
        return uint8(_ld(vault, 19) >> 32);
    }

    /// @dev The bond a deposit can count on: slot 17 bondShares u128 @0 only. A pending markout holds part of the bond
    ///      in slot 20 (reserveBond) and its settlement, run by the deposit's own prologue, may burn it, so the reserve
    ///      is never counted as current bond (s2 D5-01: the lower bound).
    function bond(address vault) internal view returns (uint256) {
        // [MU-087] slot 17 only: never the reserve a due markout may burn (s2 D5-01)
        return uint128(_ld(vault, 17));
    }

    /// @dev The B4 baseline at the first allocation: bondShares plus reserveBond (the upper bound, so the floor is
    ///      never below what the curator had bonded then).
    function bondWithReserve(address vault) internal view returns (uint256) {
        return uint256(uint128(_ld(vault, 17))) + uint128(_ld(vault, 20));
    }

    /// @dev slot 18: forfeitStart u40 @16, dripBlocks u40 @21; the drip's end as read now (no drip → 0)
    function dripEnd(address vault) internal view returns (uint256) {
        uint256 w = _ld(vault, 18);
        uint256 start = uint40(w >> 128);
        if (start == 0) return 0;
        return start + uint40(w >> 168);
    }

    /// @dev slot 8: epoch u32 @5
    function epoch(address vault) internal view returns (uint32) {
        return uint32(_ld(vault, 8) >> 40);
    }

    function sqrtAt(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    /// @notice The composition `s` shares are worth pro rata (idle plus the liquidity's amounts at `sqrtP`).
    function proRataAt(address vault, uint256 s, uint160 sqrtP) internal view returns (uint256 f0, uint256 f1) {
        uint256 S = IVaultViews(vault).totalSupply();
        if (S == 0 || s == 0) return (0, 0);
        uint256 a = _ld(vault, 5);
        uint256 b = _ld(vault, 6);
        f0 = FullMath.mulDiv(uint128(a), s, S);
        f1 = FullMath.mulDiv(uint128(a >> 128), s, S);
        uint128 l = uint128(FullMath.mulDiv(uint128(b), s, S));
        if (l == 0) return (f0, f1);
        uint160 sa = TickMath.getSqrtPriceAtTick(int24(uint24(b >> 128)));
        uint160 sb = TickMath.getSqrtPriceAtTick(int24(uint24(b >> 152)));
        if (sqrtP <= sa) {
            f0 += SqrtPriceMath.getAmount0Delta(sa, sb, l, false);
        } else if (sqrtP >= sb) {
            f1 += SqrtPriceMath.getAmount1Delta(sa, sb, l, false);
        } else {
            f0 += SqrtPriceMath.getAmount0Delta(sqrtP, sb, l, false);
            f1 += SqrtPriceMath.getAmount1Delta(sa, sqrtP, l, false);
        }
    }

    /// @notice token1 value of (a0, a1) at `sqrtP`, rounded down.
    function value(uint256 a0, uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        return a1 + FullMath.mulDiv(FullMath.mulDiv(a0, sqrtP, Q96), sqrtP, Q96);
    }

    /// @notice token1 value of (a0, a1) at `sqrtP`, rounded up (exposure is booked conservative-high, r1 D1-14).
    function valueUp(uint256 a0, uint256 a1, uint160 sqrtP) internal pure returns (uint256) {
        return a1 + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(a0, sqrtP, Q96), sqrtP, Q96);
    }
}
