// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICovenantFactory, IReagentHub} from "./interfaces/IReagent.sol";
import {ReagentHub} from "./ReagentHub.sol";
import {Covenant} from "./Covenant.sol";

/// @title CovenantFactory
/// @notice Deployed through the CREATE2 deployer `0x4e59…956C` with chain-independent arguments `(RC, admin, impl)`,
///         where `impl` is the Covenant implementation, itself deployed through `0x4e59…956C` (with its extension).
///         The constructor deploys this chain's Hub (CREATE2, salt 0), so the factory, the Hub and every Covenant (an
///         EIP-1167 clone of `impl` at CREATE2, salt = owner) have the same address on both chains (spec §3.1, §5.2,
///         §5.4; r26 D26-02, s2 LF-1). The admin controls the demo
///         owner allowlist only, never funds or rules (PA-11, §12).
contract CovenantFactory is ICovenantFactory {
    address public immutable HUB;
    address public immutable ADMIN;
    address public immutable IMPL;

    mapping(address => bool) public isCovenant;
    mapping(address => bool) public allowed;

    error NotAdmin();
    error NotAllowed();

    event Allowed(address indexed owner, bool ok);
    event Created(address indexed owner, address covenant);

    constructor(address rc, address admin, address impl) {
        ADMIN = admin;
        IMPL = impl;
        HUB = address(new ReagentHub{salt: bytes32(0)}(rc));
    }

    function allow(address owner, bool ok) external {
        // [MU-060] the admin alone edits the allowlist (T-COV-CREATE, r27 D27-02)
        if (msg.sender != ADMIN) revert NotAdmin();
        allowed[owner] = ok;
        emit Allowed(owner, ok);
    }

    /// @notice A Covenant for the caller, owned by the caller (EOA owners only, §12).
    function create() external returns (address c) {
        // [MU-061] the demo allowlist (PA-11)
        if (!allowed[msg.sender]) revert NotAllowed();
        c = Clones.cloneDeterministic(IMPL, bytes32(uint256(uint160(msg.sender))));
        isCovenant[c] = true;
        Covenant(payable(c)).initialize(msg.sender, IReagentHub(HUB));
        emit Created(msg.sender, c);
    }

    function predict(address owner) external view returns (address) {
        return Clones.predictDeterministicAddress(IMPL, bytes32(uint256(uint160(owner))));
    }
}
