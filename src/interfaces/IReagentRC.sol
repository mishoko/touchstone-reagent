// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IReactive} from "./IReactive.sol";

/// @notice Callback kinds, indexing the RC's gas table (spec §5.6).
library Kind {
    uint8 internal constant CONDUCT = 0;
    uint8 internal constant VAULT = 1;
    uint8 internal constant BUDGET = 2;
    uint8 internal constant EXIT = 3;
    uint8 internal constant PLAN = 4;
}

/// @notice The reactive contract on Lasna (spec §3.2, §5.5): its registry, gas table and views.
interface IReagentRC is IReactive {
    // ------------------------------------------------------------------ registry (owner only)
    function addCurator(uint32 id) external;
    function addBundler(uint32 id, uint256 chain, address bundler) external;
    function addFactory(uint256 chain, address touchstoneFactory) external;
    function addHub(uint256 chain, address hub) external;
    function setGas(uint256 chain, uint8 kind, uint64 limit) external;

    // ------------------------------------------------------------------ payer (spec §3.2, R-PAYER)
    function pay(uint256 amount) external;

    // ------------------------------------------------------------------ views
    function OWNER() external view returns (address);
    function EXT() external view returns (address);
    function gasLimit(uint256 chain, uint8 kind) external view returns (uint64);
    function formulaGas(uint256 chain, uint8 kind) external pure returns (uint64);
    function hubOf(uint256 chain) external view returns (address);
    function factoryOf(uint256 chain) external view returns (address);
    function curatorExists(uint32 id) external view returns (bool);
    function bundlerId(uint256 chain, address bundler) external view returns (uint32);
    function vaultOf(uint256 chain, address vault)
        external
        view
        returns (uint32 id, address hook, uint32 maxSeq, bool gone, uint32 actions);
    function conduct(uint32 id) external view returns (uint32 breaches, uint32 gone, uint32 actions, uint32 seq);
    function seqOf(uint256 chain, uint32 id)
        external
        view
        returns (uint32 seqOut, uint32 seqApplied, uint32 seqTotals, uint32 hubLogCount);
    function counters() external view returns (uint256 pendingPairs, uint256 b6Active, uint256 sweeps, bool cronOn);

    // ------------------------------------------------------------------ events
    event CuratorAdded(uint32 indexed id);
    event BundlerAdded(uint32 indexed id, uint256 indexed chain, address bundler);
    event FactoryAdded(uint256 indexed chain, address factory);
    event HubAdded(uint256 indexed chain, address hub);
    event GasSet(uint256 indexed chain, uint8 indexed kind, uint64 previous, uint64 limit);
    event VaultRegistered(uint256 indexed chain, address indexed vault, uint32 indexed id, address hook);
    event Untracked(uint256 chain, address covenant);
    event ExitAbandoned(uint256 chain, address covenant, address vault);
    event ExitParked(uint256 chain, address covenant, address vault);
}
