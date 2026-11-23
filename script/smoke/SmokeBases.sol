// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// G1 smoke loop: clean-room minimal Reactive Omni bases.
// Written from the documented interface only; no code is copied from reactive-lib-omni.
// Throwaway: the production bases are written test-first in s2/s3.

/// @dev The Reactive system contract's documented interface (Omni).
interface IRnkSystem {
    struct CallbackV1 {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    function subscribe(uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external;
    function unsubscribe(uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external;
    function requestCallbackV_1_0(CallbackV1 memory cfg) external;
    function depositTo(address who) external payable;
    function debt(address who) external view returns (uint256);
    function reserves(address who) external view returns (uint256);
}

/// @dev A destination callback proxy's funding interface.
interface IRnkProxy {
    function depositTo(address who) external payable;
    function debt(address who) external view returns (uint256);
    function reserves(address who) external view returns (uint256);
}

/// @dev The origin log as delivered to react().
struct Log {
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

/// @dev Shared payer logic: the vendor (system contract or proxy) may pull a debt.
abstract contract SmokePayer {
    error NotVendor(address caller);
    error Short(uint256 have, uint256 want);

    address internal immutable VENDOR;

    constructor(address vendor) {
        VENDOR = vendor;
    }

    receive() external payable virtual {}

    /// @notice Called by the vendor to settle a debt from this contract's balance.
    function pay(uint256 amount) external {
        if (msg.sender != VENDOR) revert NotVendor(msg.sender);
        if (address(this).balance < amount) revert Short(address(this).balance, amount);
        (bool ok,) = VENDOR.call{value: amount}("");
        require(ok, "pay");
    }
}
