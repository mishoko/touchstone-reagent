// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRnkSystem, Log, SmokePayer} from "../smoke/SmokeBases.sol";

/// @notice L-SPOOF (spec §9.5, OQ-18, PB-12): a THIRD-PARTY reactive contract on Lasna, deployed from the owner key
///         (never the RC deployer, F-007), that requests ONE `rcConduct` callback to the 1301 ReagentHub. The network
///         injects this contract's address as the first argument, so the Hub's `callback(rc)` check (rc == RC) must
///         reject it; the live run records the rejection and what the callback proxy charged the Hub.
///         Trigger: a 1-unit mUSDC transfer from the owner to 0x…dEaD on 1301 (a topic pair no one else emits).
///         One shot: after its single request it unsubscribes (exact six arguments), so it never pays again.
///         The payload names curator id 99 (never registered) and seq 1, so even a broken check could change
///         no real curator's record.
contract SpoofRC is SmokePayer {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant TRANSFER_T0 = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant CHAIN = 1301;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint64 internal constant GAS_LIMIT = 261_631; // the RC's own rcConduct gasLimit on 1301 (spec §5.6)
    uint32 internal constant ID = 99;

    address public immutable TOKEN; // mUSDC on 1301
    address public immutable FROM; // the owner
    address public immutable HUB; // the 1301 ReagentHub
    bool public sent;

    event Spoofed(uint256 originTxHash, address hub, uint32 id, uint64 seq);

    constructor(address token, address from, address hub) payable SmokePayer(SYSTEM) {
        (TOKEN, FROM, HUB) = (token, from, hub);
        IRnkSystem(SYSTEM).subscribe(CHAIN, token, TRANSFER_T0, uint256(uint160(from)), uint256(uint160(DEAD)), IGNORE);
    }

    function react(Log calldata log) external {
        if (msg.sender != SYSTEM) revert NotVendor(msg.sender);
        if (sent || log.chainId != CHAIN || log.emitter != TOKEN || log.topic0 != TRANSFER_T0) return;
        if (log.topic1 != uint256(uint160(FROM)) || log.topic2 != uint256(uint160(DEAD))) return;
        sent = true;
        // First word address(0): the network overwrites it with THIS contract's address (not the Reagent RC).
        bytes memory payload = abi.encodeWithSignature(
            "rcConduct(address,uint32,uint32,uint32,uint32,uint64)", address(0), ID, uint32(0), uint32(0), uint32(0), uint64(1)
        );
        IRnkSystem(SYSTEM).requestCallbackV_1_0(
            IRnkSystem.CallbackV1({chainId: CHAIN, recipient: HUB, gasLimit: GAS_LIMIT, payload: payload})
        );
        IRnkSystem(SYSTEM).unsubscribe(CHAIN, TOKEN, TRANSFER_T0, uint256(uint160(FROM)), uint256(uint160(DEAD)), IGNORE);
        emit Spoofed(log.txHash, HUB, ID, 1);
    }
}
