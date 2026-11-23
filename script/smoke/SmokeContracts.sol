// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRnkSystem, Log, SmokePayer} from "./SmokeBases.sol";

/// @notice Origin emitter (deployed on 1301 and 11155111). Anyone may ping; G1 only.
contract SmokePing {
    /// topic0 = keccak256("Ping(uint256,uint256,uint256)")
    event Ping(uint256 indexed nonce, uint256 originTs, uint256 originBlock);

    function ping(uint256 nonce) external {
        emit Ping(nonce, block.timestamp, block.number);
    }
}

/// @notice The G1 reactive contract on Lasna. Every Ping from either origin fans out
/// one callback to each destination, so two pings cover all four paths
/// (1301->1301, 1301->11155111, 11155111->1301, 11155111->11155111).
contract SmokeRC is SmokePayer {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant PING_T0 = uint256(keccak256("Ping(uint256,uint256,uint256)"));

    uint256 internal immutable CHAIN_A;
    uint256 internal immutable CHAIN_B;
    address internal immutable PING_A;
    address internal immutable PING_B;
    address internal immutable RECV_A;
    address internal immutable RECV_B;
    uint64 public immutable GAS_LIMIT;

    event Reacted(uint256 indexed originChain, uint256 indexed nonce, uint256 originTxHash, uint256 reactTs);

    constructor(
        uint256 chainA,
        address pingA,
        address recvA,
        uint256 chainB,
        address pingB,
        address recvB,
        uint64 gasLimit
    ) payable SmokePayer(SYSTEM) {
        (CHAIN_A, PING_A, RECV_A, CHAIN_B, PING_B, RECV_B, GAS_LIMIT) =
            (chainA, pingA, recvA, chainB, pingB, recvB, gasLimit);
        IRnkSystem(SYSTEM).subscribe(chainA, pingA, PING_T0, IGNORE, IGNORE, IGNORE);
        IRnkSystem(SYSTEM).subscribe(chainB, pingB, PING_T0, IGNORE, IGNORE, IGNORE);
    }

    function react(Log calldata log) external {
        if (msg.sender != SYSTEM) revert NotVendor(msg.sender);
        if (log.topic0 != PING_T0) return;
        if (!((log.chainId == CHAIN_A && log.emitter == PING_A) || (log.chainId == CHAIN_B && log.emitter == PING_B))) {
            return;
        }
        (uint256 originTs, uint256 originBlock) = abi.decode(log.data, (uint256, uint256));
        // First word is address(0): the network overwrites it with this RC's address.
        bytes memory payload = abi.encodeWithSelector(
            SmokeReceiver.onSmoke.selector,
            address(0),
            log.chainId,
            log.topic1,
            originBlock,
            originTs,
            log.txHash,
            block.timestamp,
            GAS_LIMIT
        );
        _send(CHAIN_A, RECV_A, payload);
        _send(CHAIN_B, RECV_B, payload);
        emit Reacted(log.chainId, log.topic1, log.txHash, block.timestamp);
    }

    function _send(uint256 chainId, address recipient, bytes memory payload) internal {
        IRnkSystem(SYSTEM).requestCallbackV_1_0(
            IRnkSystem.CallbackV1({chainId: chainId, recipient: recipient, gasLimit: GAS_LIMIT, payload: payload})
        );
    }
}

/// @notice Destination receiver (1301 and 11155111). Logs gasleft(), on entry, to measure the proxy overhead.
contract SmokeReceiver is SmokePayer {
    address public immutable RC;

    error BadSender(address caller);
    error BadRc(address rc);

    event Smoke(
        uint256 indexed originChain,
        uint256 indexed nonce,
        uint256 gasAtEntry,
        uint256 gasLimitAsked,
        uint256 originBlock,
        uint256 originTs,
        uint256 originTxHash,
        uint256 reactTs,
        uint256 destTs
    );

    constructor(address proxy, address rc) SmokePayer(proxy) {
        RC = rc;
    }

    function onSmoke(
        address rc,
        uint256 originChain,
        uint256 nonce,
        uint256 originBlock,
        uint256 originTs,
        uint256 originTxHash,
        uint256 reactTs,
        uint64 gasLimitAsked
    ) external {
        uint256 g = gasleft();
        if (msg.sender != VENDOR) revert BadSender(msg.sender);
        if (rc != RC) revert BadRc(rc);
        emit Smoke(originChain, nonce, g, gasLimitAsked, originBlock, originTs, originTxHash, reactTs, block.timestamp);
    }
}
