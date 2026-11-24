// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RcFixture} from "./base/RcFixture.sol";
import {IReagentRC, Kind} from "../src/interfaces/IReagentRC.sol";
import {LogRecord, IReactive} from "../src/interfaces/IReactive.sol";
import {IReagentHub} from "../src/interfaces/IReagent.sol";
import {CuratorBundler} from "touchstone/periphery/CuratorBundler.sol";

/// @notice The RC's registry, gas table, payer, subscriptions, dynamic registration and breach record (spec §3.2,
///         §5.1, §5.5, §5.6; §9.2 R-REG, R-SETGAS, R-PAYER, R-SUB, R-DYN, R-DYN-FOREIGN, R-BREACH, R-BREACH-DUP;
///         §9.3 A-DELTA, A-XCHAIN). The R layer: real Touchstone vaults on two chains, exact LogRecords, the RC on
///         a mock Lasna (test/base/RcEnv.sol).
contract RcCoreTest is RcFixture {
    // topic0s (spec §5.1, §5.2)
    uint256 constant T_LATCH = 0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346;
    uint256 constant T_PROCESSED = 0xf37492039a7f836f6b471f6a2c580a9743a545b9d3f3d4b1e3a47108e67ea59c;
    uint256 constant T_MODE = 0x73f069d8a008c9e2fe78e308751100d873455f99593c7d60eff545e91a90ab04;
    uint256 constant T_RETIRED = 0xfe4758e6ccdb65cb7d78b678b554dc5319e940c6ee582e94811b7d48fbb506c5;
    uint256 constant T_EPOCH = 0x52ac8c0ec192dc514cc63f10118a6ba589667d3548a5ffcb0886465085529050;
    uint256 constant T_ACTION = 0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba;
    uint256 constant T_DEPLOYED = 0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2;
    uint256 constant T_NOTE = 0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7;
    uint256 constant T_APPLIED = 0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615;
    uint256 constant T_BUDGET = 0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823;

    uint256 constant RESERVE = 40_000;
    uint64 constant MAX_GAS = 10_000_000;

    function setUp() public {
        _setUpRc();
    }

    // ================================================================== the gas table (spec §5.6, R-SETGAS)

    /// @dev NEED per chain and kind (spec §5.6 table, s3 LF-S3-1) and the formula, recomputed here (r1 D1-12).
    function _need(uint256 c, uint8 k) internal pure returns (uint256) {
        uint256[5] memory a = [uint256(35_000), 91_000, 345_000, 832_000, 1_198_000];
        uint256[5] memory b = [uint256(150_000), 437_000, 500_000, 2_220_000, 2_310_000];
        return c == CA ? a[k] : b[k];
    }

    function _formula(uint256 c, uint8 k) internal pure returns (uint64) {
        uint256 num = 11 * 64 * (64 * _need(c, k) + 63 * RESERVE);
        uint256 den = 10 * 63 * 63;
        return uint64((num + den - 1) / den + (c == CA ? 177_200 : 243_300));
    }

    function test_R_SETGAS__startsAtTheFormulaOnEveryChainAndKind() public view {
        for (uint8 k; k < 5; ++k) {
            assertEq(rc.formulaGas(CA, k), _formula(CA, k));
            assertEq(rc.formulaGas(CB, k), _formula(CB, k));
            assertEq(rc.gasLimit(CA, k), _formula(CA, k));
            assertEq(rc.gasLimit(CB, k), _formula(CB, k));
        }
        assertEq(rc.gasLimit(CB, Kind.EXIT), 2_808_138, "spec 5.6 table");
    }

    /// @notice The RC's gasLimits bring each Hub at least its own pre-check threshold, on both chains (D5-05).
    function test_R_SETGAS__gasLimitsCoverTheHubPrecheck() public {
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            _on(c); // the Hub selects its NEEDs by block.chainid
            (uint256 e, uint256 p) = ch[c].hub.needs();
            uint256 f = c == CA ? 177_200 : 243_300;
            assertEq(_need(c, Kind.EXIT), e, "the RC's exit NEED is the Hub's (D6-03)");
            assertEq(_need(c, Kind.PLAN), p, "the RC's plan NEED is the Hub's");
            assertGe((uint256(rc.gasLimit(c, Kind.EXIT)) - f) * 63 / 64, e * 64 / 63 + RESERVE, "exit");
            assertGe((uint256(rc.gasLimit(c, Kind.PLAN)) - f) * 63 / 64, p * 64 / 63 + RESERVE, "plan");
        }
    }

    function test_R_SETGAS__rangeFormulaToMaxOwnerOnly() public {
        uint64 f = _formula(CB, Kind.EXIT);
        bool ok;
        (ok,) = _ownerCall(abi.encodeCall(IReagentRC.setGas, (CB, Kind.EXIT, f - 1)));
        assertFalse(ok, "below the formula");
        (ok,) = _ownerCall(abi.encodeCall(IReagentRC.setGas, (CB, Kind.EXIT, MAX_GAS + 1)));
        assertFalse(ok, "above MAX");
        (ok,) = _ownerCall(abi.encodeCall(IReagentRC.setGas, (84532, Kind.EXIT, f)));
        assertFalse(ok, "unknown chain");
        (ok,) = _ownerCall(abi.encodeCall(IReagentRC.setGas, (CB, 5, f)));
        assertFalse(ok, "unknown kind");
        uint256 p = _lasna();
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        rc.setGas(CB, Kind.EXIT, f + 1);
        vm.expectEmit(address(rc));
        emit IReagentRC.GasSet(CB, Kind.EXIT, f, MAX_GAS);
        vm.prank(rcOwner);
        rc.setGas(CB, Kind.EXIT, MAX_GAS);
        assertEq(rc.gasLimit(CB, Kind.EXIT), MAX_GAS, "MAX accepted");
        vm.prank(rcOwner);
        rc.setGas(CB, Kind.EXIT, f);
        assertEq(rc.gasLimit(CB, Kind.EXIT), f, "a lower back to exactly the formula is accepted (D2-08)");
        _leave(p);
    }

    function test_R_SETGAS__theNextCallbackCarriesTheNewLimit() public {
        V memory x = _registeredVault(CA, 1);
        _ownerCall(abi.encodeCall(IReagentRC.setGas, (CB, Kind.CONDUCT, 600_000)));
        _on(CA);
        _age(x, 400);
        _latch(x, 1);
        _elapse(30);
        assertEq(_lastRequestLimit(CB, IReagentHub.rcConduct.selector), 600_000);
        assertEq(_lastRequestLimit(CA, IReagentHub.rcConduct.selector), _formula(CA, Kind.CONDUCT));
    }

    // ================================================================== registry (R-REG)

    function test_R_REG__ownerOnlyAndBounds() public {
        uint256 p = _lasna();
        address o = makeAddr("outsider");
        vm.startPrank(o);
        vm.expectRevert();
        rc.addCurator(9);
        vm.expectRevert();
        rc.addBundler(1, CA, address(1));
        vm.expectRevert();
        rc.addHub(CA, address(1));
        vm.expectRevert();
        rc.addFactory(CA, address(1));
        vm.stopPrank();
        vm.startPrank(rcOwner);
        vm.expectRevert();
        rc.addCurator(0); // ids start at 1 (r2 m-4)
        rc.addCurator(9);
        vm.expectRevert();
        rc.addCurator(9); // once
        vm.expectRevert();
        rc.addHub(CA, address(2)); // write-once
        vm.expectRevert();
        rc.addFactory(CB, address(2)); // write-once
        vm.expectRevert();
        rc.addBundler(77, CA, address(3)); // unknown curator
        for (uint160 i = 1; i <= 4; ++i) {
            rc.addBundler(9, CA, address(1000 + i));
        }
        vm.expectRevert();
        rc.addBundler(9, CA, address(1005)); // a fifth bundler per id per chain
        rc.addBundler(9, CB, address(1005)); // the other chain has its own 4
        vm.expectRevert();
        rc.addBundler(9, CB, address(1005)); // one id per bundler
        vm.stopPrank();
        _leave(p);
        assertEq(rc.hubOf(CA), address(ch[CA].hub));
        assertEq(rc.hubOf(CB), address(ch[CA].hub), "the live Hub address registers for both chains (D1-05)");
    }

    function test_R_REG__onlyTheTwoChainsAndBundlersNeedTheFactory() public {
        uint256 p = _lasna();
        address e2 = deployCode("RcExt.sol:RcExt");
        IReagentRC r2 = IReagentRC(payable(deployCode("ReagentRC.sol:ReagentRC", abi.encode(rcOwner, e2))));
        vm.startPrank(rcOwner);
        vm.expectRevert();
        r2.addHub(84532, address(1)); // only 1301 and 11155111
        vm.expectRevert();
        r2.addFactory(1, address(1));
        r2.addCurator(1);
        vm.expectRevert();
        r2.addBundler(1, CA, address(7)); // no factory on that chain yet (D1-10)
        r2.addFactory(CA, address(ch[CA].ts));
        r2.addBundler(1, CA, address(7));
        vm.stopPrank();
        _leave(p);
    }

    // ================================================================== payer (R-PAYER)

    function test_R_PAYER__onlySystemExactAmount() public {
        vm.deal(address(rc), 5 ether);
        uint256 p = _lasna();
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        rc.pay(1 ether);
        vm.prank(SYSTEM);
        vm.expectRevert();
        rc.pay(6 ether); // more than held: never a partial payment
        uint256 b = SYSTEM.balance;
        vm.prank(SYSTEM);
        rc.pay(1 ether);
        assertEq(SYSTEM.balance - b, 1 ether);
        assertEq(address(rc).balance, 4 ether);
        (bool ok,) = address(rc).call{value: 1}("");
        assertTrue(ok, "receive is open");
        _leave(p);
    }

    // ================================================================== subscriptions (R-SUB, R-DYN, R-DYN-FOREIGN)

    function _live() internal view returns (Sub[] memory out) {
        uint256 n;
        for (uint256 i; i < subsHist.length; ++i) {
            if (subsHist[i].rc == address(rc) && subsHist[i].until == 0) ++n;
        }
        out = new Sub[](n);
        n = 0;
        for (uint256 i; i < subsHist.length; ++i) {
            if (subsHist[i].rc == address(rc) && subsHist[i].until == 0) out[n++] = subsHist[i];
        }
    }

    function _has(uint256 c, address e, uint256 t0, uint256 t1) internal view returns (bool) {
        Sub[] memory s = _live();
        for (uint256 i; i < s.length; ++i) {
            if (s[i].chainId == c && s[i].emitter == e && s[i].t0 == t0 && s[i].t1 == t1 && s[i].t2 == IGNORE
                    && s[i].t3 == IGNORE) return true;
        }
        return false;
    }

    /// @dev No wildcard chain or emitter, never IGNORE as topic0, nothing from the never-list (spec §3.2, R-SUB).
    function _assertNoWildcardOrBanned() internal view {
        uint256[9] memory banned = [
            uint256(keccak256("Checkpoint(uint32,uint40,int24,int24,uint256)")),
            uint256(keccak256("Deposit(address,address,uint256,uint256,uint256)")),
            uint256(keccak256("Withdraw(address,address,address,uint256,uint256,uint256)")),
            uint256(keccak256("Transfer(address,address,uint256)")),
            uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")),
            uint256(keccak256("GapSet(uint32)")),
            uint256(keccak256("RefReadFailed()")),
            uint256(keccak256("CheckpointDeferred()")),
            uint256(keccak256("WitnessRolled(uint32,uint256,uint256,uint256)"))
        ];
        Sub[] memory s = _live();
        for (uint256 i; i < s.length; ++i) {
            assertTrue(s[i].chainId != 0, "no wildcard chain");
            assertTrue(s[i].emitter != address(0), "no wildcard emitter");
            assertTrue(s[i].t0 != IGNORE, "no wildcard topic0");
            for (uint256 j; j < banned.length; ++j) {
                assertTrue(s[i].t0 != banned[j], "never-list topic");
            }
        }
    }

    function test_R_SUB__exactTopicsNoWildcardNoNeverList() public {
        address hubA = address(ch[CA].hub);
        for (uint256 i; i < 2; ++i) {
            uint256 c = i == 0 ? CA : CB;
            assertTrue(_has(c, hubA, T_NOTE, IGNORE), "Note");
            assertTrue(_has(c, hubA, T_APPLIED, IGNORE), "Applied");
            assertTrue(_has(c, hubA, T_BUDGET, IGNORE), "BudgetApplied");
        }
        V memory x = _registeredVault(CA, 1);
        assertTrue(_has(CA, address(ch[CA].ts), T_DEPLOYED, uint256(uint160(address(x.bundler)))), "Deployed(topic1 = bundler)");
        assertTrue(_has(CA, x.vault, T_PROCESSED, IGNORE));
        assertTrue(_has(CA, x.vault, T_MODE, IGNORE));
        assertTrue(_has(CA, x.vault, T_RETIRED, IGNORE));
        assertTrue(_has(CA, x.vault, T_EPOCH, IGNORE));
        assertTrue(_has(CA, x.vault, T_ACTION, IGNORE));
        assertTrue(_has(CA, x.hook, T_LATCH, IGNORE));
        assertFalse(cronSubscribed(), "no Cron at rest");
        _assertNoWildcardOrBanned();
        assertEq(_live().length, 6 + 1 + 6, "the Hub's 3 per chain, the bundler's Deployed, the vault's 5 and the hook's 1");
    }

    function test_R_DYN__aRegisteredBundlersVaultIsSubscribedAndBoundFromReact() public {
        V memory x = _registeredVault(CB, 3);
        (uint32 id, address hook,,,) = rc.vaultOf(CB, x.vault);
        assertEq(id, 3);
        assertEq(hook, x.hook);
        assertEq(ch[CB].hub.vaultId(x.vault), 3, "rcVault delivered to chain B's Hub");
        assertEq(ch[CA].hub.vaultId(x.vault), 0, "not to chain A's");
        assertTrue(_has(CB, x.hook, T_LATCH, IGNORE));
    }

    /// @notice A latch emitted before the vault's subscriptions took effect is never delivered (D3-07): the
    ///         `Deployed` log is held, the vault breaches, then the `Deployed` arrives.
    function test_R_DYN__aLatchBeforeTheSubscriptionIsNotSeen() public {
        _on(CA);
        CuratorBundler b = _newBundler();
        uint256 p = _lasna();
        vm.startPrank(rcOwner);
        rc.addCurator(1);
        rc.addBundler(1, CA, address(b));
        vm.stopPrank();
        _elapse(2);
        _leave(p);
        _on(CA);
        holdDeployed = true;
        V memory x = _deployVaultWith(b);
        _flush(); // the policy applies at flush: hold the Deployed before clearing the flag
        holdDeployed = false;
        _age(x, 400);
        _latch(x, 1);
        _releaseHeldLogs();
        _elapse(5);
        (uint32 id,, uint32 maxSeq,,) = rc.vaultOf(CA, x.vault);
        assertEq(id, 1, "registered late");
        assertEq(maxSeq, 0, "the earlier latch was not delivered");
    }

    bool internal holdDeployed;

    function _logPolicy(LogRecord memory l) internal override returns (Act) {
        if (holdDeployed && l.topic0 == T_DEPLOYED) return Act.HOLD;
        if (holdFirstLatch && !heldOne && l.topic0 == T_LATCH) {
            heldOne = true;
            return Act.HOLD;
        }
        if (dupAll) return Act.DUP;
        return Act.DELIVER;
    }

    bool internal dupAll;

    function test_R_DYN_FOREIGN__anUnregisteredBundlerIsIgnored() public {
        _on(CA);
        V memory x = _deployVault(); // a bundler nobody registered
        _elapse(5);
        (uint32 id,,,,) = rc.vaultOf(CA, x.vault);
        assertEq(id, 0);
        assertEq(ch[CA].hub.vaultId(x.vault), 0, "never bound");
        assertFalse(_has(CA, x.vault, T_PROCESSED, IGNORE), "never subscribed");
        _assertNoWildcardOrBanned();
    }

    function test_R_DYN_FOREIGN__aForgedDeployedFromAnotherEmitterIsIgnored() public {
        LogRecord memory l;
        l.chainId = CA;
        l.emitter = makeAddr("fakeFactory");
        l.topic0 = T_DEPLOYED;
        l.topic1 = uint256(uint160(makeAddr("anyBundler")));
        l.data = abi.encode(makeAddr("v"), makeAddr("e"), makeAddr("h"));
        l.opCode = 2;
        _directReact(l);
        (uint32 id,,,,) = rc.vaultOf(CA, makeAddr("v"));
        assertEq(id, 0);
    }

    // ================================================================== breaches (R-BREACH, R-BREACH-DUP, A-DELTA)

    function _breachTwice(V memory x) internal {
        _on(CA);
        _age(x, 400);
        _latch(x, 1);
        _process(x);
        _backInRange(x);
        _keepAlive(x, 200);
        _latch(x, 1);
        _elapse(5);
    }

    function test_R_BREACH__b7IsTheSumOfMaxLatchedSeqsAndReachesTwoAndThree() public {
        V memory x = _registeredVault(CA, 1);
        V memory y = _registeredVault(CB, 1); // the same curator on chain B
        _breachTwice(x);
        (uint32 b,,, uint32 s) = rc.conduct(1);
        assertEq(b, 2, "k = 2 reachable");
        _on(CB);
        _age(y, 40);
        _latch(y, 1);
        _elapse(20);
        (b,,,) = rc.conduct(1);
        assertEq(b, 3, "k = 3 across chains");
        (uint32 hb,,,) = ch[CA].hub.conduct(1);
        (uint32 hb2,,,) = ch[CB].hub.conduct(1);
        assertEq(hb, 3, "both Hubs hold the record");
        assertEq(hb2, 3);
        assertGt(s, 0);
    }

    function test_R_BREACH_DUP__duplicatedLogsGiveTheSameRecord() public {
        V memory x = _registeredVault(CA, 1);
        dupAll = true;
        _breachTwice(x);
        dupAll = false;
        (uint32 b,,,) = rc.conduct(1);
        assertEq(b, 2, "a duplicated latch is not a second breach");
    }

    /// @notice A-DELTA: two separate breaches at k = 2 fire (the latched seq is cumulative).
    function test_A_DELTA__twoSeparateBreachesReachKTwo() public {
        V memory x = _registeredVault(CA, 1);
        _breachTwice(x);
        (uint32 b,,,) = rc.conduct(1);
        assertGe(b, 2);
    }

    /// @notice PC: with `BreachProcessed.count` (a per-checkpoint delta) as the record, the same logs never reach 2.
    function test_A_DELTA__PC_processedCountMaxNeverReachesTwo() public {
        V memory x = _registeredVault(CA, 1);
        _breachTwice(x);
        _process(x);
        _elapse(5);
        uint256 maxCount;
        uint256 n;
        for (uint256 i; i < originHist.length; ++i) {
            if (originHist[i].topic0 != T_PROCESSED || originHist[i].emitter != x.vault) continue;
            uint256 c = uint32(abi.decode(originHist[i].data, (uint256)));
            if (c > maxCount) maxCount = c;
            ++n;
        }
        assertGt(n, 1, "two BreachProcessed events");
        assertLt(maxCount, 2, "the delta record stays below k = 2: the attack wins without the latched seq");
    }

    // ================================================================== cross-chain filter (A-XCHAIN)

    function _noteRecord(uint256 chain_, address emitter) internal view returns (LogRecord memory l) {
        l.chainId = chain_;
        l.emitter = emitter;
        l.topic0 = T_APPLIED;
        l.topic1 = 1; // id
        l.data = abi.encode(uint64(999));
        l.opCode = 2;
    }

    function _directReact(LogRecord memory l) internal {
        uint256 p = _lasna();
        vm.prank(SYSTEM);
        (bool ok,) = address(rc).call(abi.encodeCall(IReactive.react, (l)));
        assertTrue(ok, "react never reverts for a log (PB-21)");
        _leave(p);
    }

    function test_A_XCHAIN__aHubCloneOrForeignChainIsNotProcessed() public {
        _directReact(_noteRecord(84532, address(ch[CA].hub))); // the Hub's address on a third chain
        _directReact(_noteRecord(CA, makeAddr("hubClone"))); // a clone on chain A
        (,, uint32 sa,) = rc.seqOf(84532, 1);
        assertEq(sa, 0);
        (, uint32 a,,) = rc.seqOf(CA, 1);
        assertEq(a, 0, "nothing recorded");
    }

    function test_A_XCHAIN__PC_theRegisteredChainAndHubAreProcessed() public {
        _directReact(_noteRecord(CA, address(ch[CA].hub)));
        (, uint32 a,,) = rc.seqOf(CA, 1);
        assertEq(a, 999, "the same record from the registered (chain, Hub) is processed");
    }

    function test_R_SUB__reactRevertsOnlyForAWrongCaller() public {
        uint256 p = _lasna();
        vm.prank(makeAddr("outsider"));
        vm.expectRevert();
        rc.react(_noteRecord(CA, address(ch[CA].hub)));
        _leave(p);
    }

    // ================================================================== more killers (s3 mutants)

    /// @notice R-EXT: the constructor refuses an extension without code (D2-07 class).
    function test_R_EXT__theConstructorRefusesAnExtensionWithoutCode() public {
        uint256 p = _lasna();
        vm.expectRevert();
        this.deployRc(makeAddr("noCode"));
        _leave(p);
    }

    function deployRc(address e) external returns (address) {
        return deployCode("ReagentRC.sol:ReagentRC", abi.encode(rcOwner, e));
    }

    /// @notice R-EXT: a direct call to the extension reverts, even from the system contract (s3 rc r2 D2-05).
    function test_R_EXT__aDirectCallToTheExtensionReverts() public {
        LogRecord memory l = _noteRecord(CA, address(ch[CA].hub));
        uint256 p = _lasna();
        vm.prank(SYSTEM);
        (bool ok,) = rcExt.call(abi.encodeWithSignature("markDirty(uint32)", uint32(1)));
        assertFalse(ok, "markDirty directly");
        vm.prank(SYSTEM);
        (ok,) = rcExt.call(abi.encodeWithSignature("cron()"));
        assertFalse(ok, "cron directly");
        l;
        _leave(p);
    }

    /// @notice R-DYN-FOREIGN: a `Deployed` from the registered factory naming an unregistered bundler is ignored.
    function test_R_DYN_FOREIGN__aDeployedForAnUnregisteredBundlerIsIgnored() public {
        LogRecord memory l;
        l.chainId = CA;
        l.emitter = address(ch[CA].ts);
        l.topic0 = T_DEPLOYED;
        l.topic1 = uint256(uint160(makeAddr("unregisteredBundler")));
        l.data = abi.encode(makeAddr("v2"), makeAddr("e2"), makeAddr("h2"));
        l.opCode = 2;
        _directReact(l);
        assertFalse(_has(CA, makeAddr("v2"), T_PROCESSED, IGNORE), "never subscribed");
        (uint32 id,,,,) = rc.vaultOf(CA, makeAddr("v2"));
        assertEq(id, 0);
    }

    /// @notice R-DYN: a duplicated `Deployed` changes nothing (one registration, no second subscription, D1-10).
    function test_R_DYN__aDuplicatedDeployedChangesNothing() public {
        dupAll = true;
        V memory x = _registeredVault(CA, 1);
        dupAll = false;
        uint256 n;
        Sub[] memory s = _live();
        for (uint256 i; i < s.length; ++i) {
            if (s[i].emitter == x.vault && s[i].t0 == T_PROCESSED) ++n;
        }
        assertEq(n, 1, "one subscription per topic");
        assertEq(_deliveredCount(CA, IReagentHub.rcVault.selector, 0), 1, "one rcVault");
    }

    bool internal holdFirstLatch;
    bool internal heldOne;

    /// @notice R-BREACH-DUP: reordered latches (the first delivered after the second) give the same record.
    function test_R_BREACH_DUP__reorderedLatchesGiveTheSameRecord() public {
        V memory x = _registeredVault(CA, 1);
        holdFirstLatch = true;
        _breachTwice(x);
        holdFirstLatch = false;
        (uint32 b,,,) = rc.conduct(1);
        assertEq(b, 2);
        _releaseHeldLogs();
        _elapse(20);
        (b,,,) = rc.conduct(1);
        assertEq(b, 2, "a late, older latch never lowers the record");
        (uint32 hb,,,) = ch[CB].hub.conduct(1);
        assertEq(hb, 2);
    }

    // ================================================================== helpers

    function _lastRequestLimit(uint256 c, bytes4 s) internal view returns (uint64 g) {
        for (uint256 i = deliveries.length; i > 0; --i) {
            if (deliveries[i - 1].chainId == c && deliveries[i - 1].selector == s) return deliveries[i - 1].gasLimit;
        }
    }
}
