// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {ReagentHub} from "../src/ReagentHub.sol";
import {ICovenant, IReagentHub, ICovenantFactory, NoteKind, Outcome, Rulebook} from "../src/interfaces/IReagent.sol";

// ---------------------------------------------------------------------- positive-control harnesses (spec §9)
// Each removes exactly one defence; the matching attack must then win. Production never overrides these hooks.

contract HubNoProxyCheck is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _checkProxy() internal view override {}
}

contract HubNoRcCheck is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _checkRc(address) internal view override {}
}

contract HubNoNonceGate is ReagentHub {
    constructor(address rc) ReagentHub(rc) {}

    function _staleBudget(uint64, uint64) internal pure override returns (bool) {
        return false;
    }
}

/// @notice A stand-in factory for the harness Hubs: every address is one of its Covenants.
contract AnyFactory {
    function isCovenant(address) external pure returns (bool) {
        return true;
    }
}

contract HubTest is ReagentEnv {
    function setUp() public {
        _setUpReagent(1301);
    }

    // ================================================================== T-HUB-CONDUCT, I-MONO, I-IDEM

    /// @notice T-HUB-CONDUCT: a monotone, seq-gated merge that never reverts after auth.
    function test_T_HUB_CONDUCT__monotoneMergeSeqGateNeverReverts() public {
        vm.prank(PROXY);
        hub.rcConduct(RC, IDX, 2, 0, 5, 10);
        (uint32 b, uint32 g, uint32 a, uint64 s) = hub.conduct(IDX);
        assertEq(abi.encode(b, g, a, s), abi.encode(uint32(2), uint32(0), uint32(5), uint64(10)));
        // a newer seq with LOWER counts: counts never fall, the seq advances
        vm.prank(PROXY);
        hub.rcConduct(RC, IDX, 1, 1, 3, 11);
        (b, g, a, s) = hub.conduct(IDX);
        assertEq(abi.encode(b, g, a, s), abi.encode(uint32(2), uint32(1), uint32(5), uint64(11)), "per-field max");
        // an older or equal seq: Stale(1, seq), nothing changes, no revert
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcConduct(RC, IDX, 9, 9, 9, 11);
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1, "Stale");
        (b, g, a, s) = hub.conduct(IDX);
        assertEq(b, 2, "a replay changes nothing (I-IDEM)");
        assertEq(s, 11);
    }

    // ================================================================== A-SPOOF-*, I-AUTH

    /// @notice A-SPOOF-PROXY: a callback from anyone but the proxy reverts and changes nothing.
    function test_A_SPOOF_PROXY__nonProxyCallbackReverts() public {
        vm.expectRevert(ReagentHub.NotProxy.selector);
        hub.rcConduct(RC, IDX, 3, 1, 0, 1);
        (uint32 b,,, uint64 s) = hub.conduct(IDX);
        assertEq(b + s, 0, "nothing applied");
    }

    function test_A_SPOOF_PROXY__PC_withoutTheProxyCheckTheSpoofApplies() public {
        HubNoProxyCheck h = new HubNoProxyCheck(RC);
        h.rcConduct(RC, IDX, 3, 1, 0, 1); // from this test contract, not the proxy
        (uint32 b,,,) = h.conduct(IDX);
        assertEq(b, 3, "the spoof applies once the check is gone");
        // and the same call against the real Hub is refused (the control fails on unmutated code)
        vm.expectRevert(ReagentHub.NotProxy.selector);
        hub.rcConduct(RC, IDX, 3, 1, 0, 1);
    }

    /// @notice A-SPOOF-RC: a foreign RC's callback (the network injects its own address) reverts.
    function test_A_SPOOF_RC__foreignRcReverts() public {
        vm.prank(PROXY);
        vm.expectRevert(ReagentHub.NotRc.selector);
        hub.rcConduct(makeAddr("foreignRc"), IDX, 3, 1, 0, 1);
    }

    function test_A_SPOOF_RC__PC_withoutTheRcCheckTheForeignRcApplies() public {
        vm.chainId(1301);
        HubNoRcCheck h = new HubNoRcCheck(RC);
        vm.prank(h.PROXY());
        h.rcConduct(makeAddr("foreignRc"), IDX, 3, 1, 0, 1);
        (uint32 b,,,) = h.conduct(IDX);
        assertEq(b, 3);
        vm.prank(PROXY);
        vm.expectRevert(ReagentHub.NotRc.selector);
        hub.rcConduct(makeAddr("foreignRc"), IDX, 3, 1, 0, 1);
    }

    /// @notice A-SPOOF-WORD: a zero or garbled first word reverts on every callback.
    function test_A_SPOOF_WORD__zeroOrGarbledFirstWordReverts() public {
        address[2] memory words = [address(0), address(uint160(RC) ^ 1)];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(PROXY);
            vm.expectRevert(ReagentHub.NotRc.selector);
            hub.rcConduct(words[i], IDX, 1, 0, 0, 1);
            vm.expectRevert(ReagentHub.NotRc.selector);
            hub.rcVault(words[i], address(1), IDX);
            vm.expectRevert(ReagentHub.NotRc.selector);
            hub.rcBudget(words[i], address(1), IDX, 1, 1, 0);
            vm.expectRevert(ReagentHub.NotRc.selector);
            hub.rcExit(words[i], address(1), address(1), 0, 0);
            vm.expectRevert(ReagentHub.NotRc.selector);
            hub.rcAllocate(words[i], address(1), address(1), 0);
            vm.stopPrank();
        }
    }

    function test_A_SPOOF_WORD__PC_withoutTheRcCheckAZeroWordApplies() public {
        vm.chainId(1301);
        HubNoRcCheck h = new HubNoRcCheck(RC);
        vm.prank(h.PROXY());
        h.rcVault(address(0), address(0xBEEF), IDX);
        assertEq(h.vaultId(address(0xBEEF)), IDX, "a zero word binds a vault once the check is gone");
        vm.prank(PROXY);
        vm.expectRevert(ReagentHub.NotRc.selector);
        hub.rcVault(address(0), address(0xBEEF), IDX);
    }

    // ================================================================== rcVault (A-IDSPOOF's Hub side)

    function test_T_HUB_CONDUCT__rcVaultIsWriteOnceAndBounded() public {
        _bind(address(0xA1), IDX);
        vm.recordLogs();
        _bind(address(0xA1), IDY); // a rebind attempt
        assertEq(hub.vaultId(address(0xA1)), IDX, "write-once");
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1);
        _bind(address(0xA2), IDX);
        _bind(address(0xA3), IDX);
        _bind(address(0xA4), IDX);
        vm.recordLogs();
        _bind(address(0xA5), IDX); // a fifth vault of one id on one chain
        assertEq(hub.vaultId(address(0xA5)), 0, "a fifth vault is not bound");
        assertEq(hub.idVaults(IDX).length, 4);
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1);
        _bind(address(0xA6), 0);
        assertEq(hub.vaultId(address(0xA6)), 0, "id 0 never binds");
    }

    // ================================================================== T-HUB-ABI

    /// @notice T-HUB-ABI: the §5 selectors and topic0s equal the compiled ones, plus the proxy-called `pay`.
    function test_T_HUB_ABI__selectorsAndTopicsMatchTheSpec() public pure {
        assertEq(IReagentHub.rcConduct.selector, bytes4(0xa5596b44));
        assertEq(IReagentHub.rcBudget.selector, bytes4(0xa084332b));
        assertEq(IReagentHub.rcExit.selector, bytes4(0x0be444a4));
        assertEq(IReagentHub.rcAllocate.selector, bytes4(0xae7a4572));
        assertEq(IReagentHub.rcVault.selector, bytes4(0xfe0faba3));
        assertEq(IReagentHub.note.selector, bytes4(0x338aac61));
        assertEq(IReagentHub.syncRules.selector, bytes4(0x387e4ab8));
        assertEq(IReagentHub.FACTORY.selector, bytes4(0x2dd31000));
        assertEq(IReagentHub.pay.selector, bytes4(0xc290d691), "the selector the proxies call (G1, PUSH32)");
        assertEq(bytes4(keccak256("coverDebt()")), bytes4(0x7a90b990));
        assertEq(ICovenant.allocate.selector, bytes4(0xb8fec1ad));
        assertEq(ICovenant.leave.selector, bytes4(0x1063e3d9));
        assertEq(ICovenant.setRules.selector, bytes4(0xb4388557));
        assertEq(ICovenant.tighten.selector, bytes4(0x1dae7e0c));
        assertEq(ICovenant.rcExit.selector, bytes4(0x2e355a7c));
        assertEq(ICovenant.rcAllocate.selector, bytes4(0x40b12815));
        assertEq(ICovenant.emitState.selector, bytes4(0x77b0c1c7));
        assertEq(ICovenant.flush.selector, bytes4(0x6b9f96ea));
        assertEq(ICovenantFactory.create.selector, bytes4(0xefc81a8c));
        assertEq(ICovenantFactory.isCovenant.selector, bytes4(0x50542a6e));
        assertEq(ICovenantFactory.allow.selector, bytes4(0x110496e5));
        assertEq(IReagentHub.Applied.selector, bytes32(0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615));
        assertEq(IReagentHub.BudgetApplied.selector, bytes32(0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823));
        assertEq(IReagentHub.Note.selector, bytes32(0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7));
        assertEq(IReagentHub.Stale.selector, bytes32(0xefb60aea3ab96907066bbced4f58785ff7b8c28be82924866fc6839082f32530));
        assertEq(IReagentHub.VaultBound.selector, bytes32(0x4a93a23c2057d5ed35e9b920e7650109f5cfb0417a8dfea5c7a960a04cc02af4));
    }

    // ================================================================== T-HUB-PAY, I-ETH (F-004)

    /// @notice T-HUB-PAY (a): only the proxy may ask for payment.
    function test_T_HUB_PAY__payFromNonProxyReverts() public {
        vm.deal(address(hub), 1 ether);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ReagentHub.NotProxy.selector);
        hub.pay(1 ether);
        assertEq(address(hub).balance, 1 ether);
        assertEq(attacker.balance, 0);
    }

    /// @notice T-HUB-PAY (b): exactly the amount, or a revert on a short balance; ETH goes only to the proxy.
    function test_T_HUB_PAY__exactAmountToTheProxyOnly() public {
        vm.deal(address(hub), 1 ether);
        vm.etch(PROXY, hex"00"); // a proxy that accepts ETH (STOP)
        uint256 p0 = PROXY.balance;
        vm.prank(PROXY);
        hub.pay(0.4 ether);
        assertEq(PROXY.balance - p0, 0.4 ether, "exactly the amount, to the proxy");
        assertEq(address(hub).balance, 0.6 ether);
        vm.prank(PROXY);
        vm.expectRevert(ReagentHub.ShortBalance.selector);
        hub.pay(0.7 ether);
        assertEq(address(hub).balance, 0.6 ether, "no partial payment");
    }

    /// @notice T-HUB-PAY (d): `sweep` moves the whole balance into the Hub's reserves at the proxy.
    function test_T_HUB_PAY__sweepDepositsTheWholeBalanceForTheHub() public {
        MockDepositProxy m = new MockDepositProxy();
        vm.etch(PROXY, address(m).code);
        vm.deal(address(hub), 0.3 ether);
        vm.prank(makeAddr("anyone"));
        hub.sweep();
        assertEq(address(hub).balance, 0);
        assertEq(MockDepositProxy(payable(PROXY)).reserves(address(hub)), 0.3 ether, "credited to the Hub itself");
        vm.deal(address(hub), 0.1 ether);
        hub.coverDebt();
        assertEq(MockDepositProxy(payable(PROXY)).reserves(address(hub)), 0.4 ether, "coverDebt is the same action");
    }

    // ================================================================== A-REPLAY (rcBudget nonce gate)

    function _cov() internal returns (ICovenant c) {
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
    }

    /// @notice A-REPLAY: an older `rcBudget` replayed after a newer one changes nothing.
    function test_A_REPLAY__olderBudgetAfterNewerIsStale() public {
        ICovenant c = _cov();
        _budget(address(c), IDX, 2e18, 5); // a lower from the 3e18 default
        _budget(address(c), IDX, 4e18, 6); // a raise
        (uint128 b,,) = hub.budget(address(c), IDX);
        assertEq(b, 4e18);
        vm.recordLogs();
        _budget(address(c), IDX, 2e18, 5); // the old lower, replayed
        (b,,) = hub.budget(address(c), IDX);
        assertEq(b, 4e18, "the replay changes nothing");
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 1);
    }

    function test_A_REPLAY__PC_withoutTheNonceGateTheReplayRevertsB() public {
        ICovenant c = _cov();
        vm.prank(address(factory)); // the harness's FACTORY immutable must be the real factory
        HubNoNonceGate h = new HubNoNonceGate(RC);
        vm.etch(address(hub), address(h).code); // same storage (budget state, ids), the gate removed
        _budget(address(c), IDX, 2e18, 5);
        _budget(address(c), IDX, 4e18, 6);
        _budget(address(c), IDX, 2e18, 5);
        (uint128 b,,) = hub.budget(address(c), IDX);
        assertEq(b, 2e18, "without the gate the replayed lower applies (B moves back)");
    }

    // ================================================================== A-COV-AUTH (the Hub side)

    /// @notice A-COV-AUTH: only Covenants of this Hub's factory may `note` or `syncRules`.
    function test_A_COV_AUTH__outsidersCannotNoteOrSync() public {
        vm.startPrank(makeAddr("eve"));
        vm.expectRevert(ReagentHub.NotCovenant.selector);
        hub.note(NoteKind.STATE, "");
        uint32[4] memory ids_;
        vm.expectRevert(ReagentHub.NotCovenant.selector);
        hub.syncRules(0, ids_);
        vm.stopPrank();
    }

    // ================================================================== T-HUB-RELAY

    /// @notice T-HUB-RELAY: a non-factory covenant or an unbound vault is Stale(3); a short delivery DEFERRED; a
    ///         revert inside the Covenant RELAY_FAILED; none reverts.
    function test_T_HUB_RELAY__membershipGasCheckAndRelayFailure() public {
        ICovenant c = _cov();
        vm.recordLogs();
        _exit(address(0xC0FFEE), X.vault, 0); // not a Covenant of this factory
        _exit(address(c), address(0xDEAD), 0); // an unbound vault
        assertEq(_count(vm.getRecordedLogs(), STALE_TOPIC), 2, "Stale(3) twice");
        // short gas: DEFERRED, no call into the Covenant
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcExit{gas: 600_000}(RC, address(c), X.vault, 0, 0);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(found);
        (uint8 o,,) = _exitOutcome(d);
        assertEq(o, Outcome.DEFERRED, "DEFERRED");
        // a revert inside the Covenant: RELAY_FAILED
        vm.mockCallRevert(address(c), abi.encodeWithSelector(ICovenant.rcExit.selector), "boom");
        vm.recordLogs();
        _exit(address(c), X.vault, 0);
        (d, found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(found);
        (o,,) = _exitOutcome(d);
        assertEq(o, Outcome.RELAY_FAILED, "RELAY_FAILED");
    }
}

/// @notice A stand-in for the callback proxy's reserve accounting (depositTo credits the recipient).
contract MockDepositProxy {
    mapping(address => uint256) public reserves;

    function depositTo(address r) external payable {
        reserves[r] += msg.value;
    }

    receive() external payable {}
}
