// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Reactive Network (Omni) interfaces, written clean-room from the documented interface (PA-10;
///         `internal/research/reactive-omni-api.md` §1–§3). No code is copied from reactive-lib-omni (its pragma is
///         ^0.8.29; ours is 0.8.26).

/// @dev An origin log as delivered to `react()` (`opCode` = the topic count; unused topics are 0).
struct LogRecord {
    uint256 chainId;
    address emitter;
    uint256 topic0;
    uint256 topic1;
    uint256 topic2;
    uint256 topic3;
    bytes data;
    uint256 blockNumber;
    uint256 opCode;
    uint256 blockHash;
    uint256 txHash;
    uint256 logIndex;
}

/// @dev `requestCallbackV_1_0`'s configuration; the network overwrites the payload's first argument with the
///      requesting RC's address before delivery.
struct CallbackV1 {
    uint256 chainId;
    address recipient;
    uint64 gasLimit;
    bytes payload;
}

/// @dev The Lasna system contract `0x8888…8888` (subscriptions, callbacks, payment).
interface IRnkSystem {
    function subscribe(uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external;
    function unsubscribe(uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external;
    function requestCallbackV_1_0(CallbackV1 calldata cfg) external;
    function depositTo(address who) external payable;
    function debt(address who) external view returns (uint256);
    function reserves(address who) external view returns (uint256);
}

interface IReactive {
    function react(LogRecord calldata log) external;
}
