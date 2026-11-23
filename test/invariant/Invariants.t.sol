// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReagentEnv} from "../base/ReagentEnv.sol";
import {ReagentHub} from "../../src/ReagentHub.sol";
import {ICovenant, Rulebook, NoteKind, Outcome} from "../../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {Obs} from "touchstone/types/Obs.sol";
import {ITouchstoneHook} from "touchstone/interfaces/ITouchstoneHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The callback proxy's reserve accounting, etched at the Hub's PROXY address (I-ETH).
contract ProxyStandIn {
    mapping(address => uint256) public reserves;

    function depositTo(address r) external payable {
        reserves[r] += msg.value;
    }

    receive() external payable {}
}

/// @notice Drives a Covenant, its Hub and a real Touchstone through every actor's moves (spec §9.4), raising a flag
///         the moment a §4 invariant breaks. Every move swallows its own reverts (fail_on_revert = false).
contract Handler is ReagentEnv {
    ICovenant public c;
    address public eve = makeAddr("eve");
    address public twin = makeAddr("twin");
    V[] internal vs;
    uint32[3] internal ids = [IDX, IDX, IDY];

    // ghosts
    mapping(address => uint32) public ghostBase; // the handler's own exit baseline per vault (F1-07)
    mapping(address => bool) public ghostSet;
    mapping(address => bool) public ghostGone; // gone at the baseline (r2 F2-01)
    bool public b6Broken; // E <= B after every allocation (I-B6SUM first clause, r2 m-5)
    uint256 public allocated; // Σ shares allocated, per all vaults
    uint256 public left;
    uint256 public exited;
    uint256 public ethIn;
    uint256 public ethPaid;
    uint256 public ethSwept;
    uint64 public seenSeq;
    uint32 public seenBreaches;
    uint32 public seenGone;
    // flags (the invariant is "never raised")
    bool public authBroken;
    bool public idemBroken;
    bool public leaveBroken;
    bool public tightBroken;
    bool public staleBroken;
    bool public monoBroken;

    constructor() {
        _setUpReagent(1301);
        _setUpVaults();
        vs.push(X);
        vs.push(X2);
        vs.push(Y);
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
        vm.startPrank(alice);
        c.setAgent(agentKey);
        c.setAllowed(X.vault, true);
        c.setAllowed(Y.vault, true);
        vm.stopPrank();
        vm.etch(PROXY, address(new ProxyStandIn()).code);
        // every run starts with positions (non-vacuity: leave, exit and the ledger have something to act on)
        vm.startPrank(alice);
        c.allocate(X.vault, 1e23, type(uint256).max, type(uint256).max);
        c.allocate(Y.vault, 1e23, type(uint256).max, type(uint256).max);
        c.allocate(X2.vault, 1e23, type(uint256).max, type(uint256).max); // two vaults of one id (F1-01's shape)
        vm.stopPrank();
        allocated = 3e23;
        for (uint256 i; i < vs.length; ++i) {
            ghostBase[vs[i].vault] = _obs(vs[i]).breachSeq; // the exit baseline at each holding's opening
            ghostSet[vs[i].vault] = true;
        }
        for (uint256 i; i < 3; ++i) {
            V memory v = vs[i];
            token0.mint(twin, 1e30);
            token1.mint(twin, 1e30);
            vm.startPrank(twin);
            token0.approve(v.vault, type(uint256).max);
            token1.approve(v.vault, type(uint256).max);
            vm.stopPrank();
        }
    }

    function hubIdOf(address v) external view returns (uint32) {
        return hub.vaultId(v);
    }

    function tok0() external view returns (address) {
        return address(token0);
    }

    function tok1() external view returns (address) {
        return address(token1);
    }

    function hubAddr() external view returns (address) {
        return address(hub);
    }

    function vaultCount() external view returns (uint256) {
        return vs.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return vs[i].vault;
    }

    function _v(uint256 seed) internal view returns (V memory) {
        return vs[seed % vs.length];
    }

    // ------------------------------------------------------------------ owner

    function allocate(uint256 seed, uint256 amt) external {
        V memory v = _v(seed);
        uint256 s = bound(amt, 1e18, 3e23);
        bool opening = c.ledger(v.vault) == 0;
        uint32 seqNow = _obs(v).breachSeq;
        vm.prank(alice);
        try c.allocate(v.vault, s, type(uint256).max, type(uint256).max) {
            allocated += s;
            if (opening) (ghostBase[v.vault], ghostSet[v.vault], ghostGone[v.vault]) = (seqNow, true, false);
            _checkB6(v);
        } catch {}
    }

    /// @notice I-LEAVE: whenever Touchstone's withdraw would succeed for the twin, the owner's `leave` succeeds.
    function leave(uint256 seed, uint256 amt) external {
        V memory v = _v(seed);
        uint256 l = c.ledger(v.vault);
        if (l == 0) return;
        uint256 s = bound(amt, 1, l);
        uint256 snap = vm.snapshotState();
        vm.prank(twin);
        bool twinOk;
        try IVaultEntries(v.vault).deposit(s, type(uint256).max, type(uint256).max, twin) {
            vm.prank(twin);
            try IVaultEntries(v.vault).withdraw(s, 0, 0, twin) {
                twinOk = true;
            } catch {}
        } catch {
            twinOk = true; // a deposit refused (mode) says nothing about withdraw: compare against withdraw alone
        }
        vm.revertToState(snap);
        vm.prank(alice);
        try c.leave(v.vault, s, 0, 0) {
            left += s;
        } catch {
            if (twinOk) leaveBroken = true;
        }
    }

    function setRules(uint8 k, bool b3, uint16 b4) external {
        Rulebook memory r = _rules(IDX, IDY);
        r.k = uint8(bound(k, 1, 3));
        r.b3 = b3;
        r.b4FloorBps = uint16(bound(b4, 0, 9_000));
        vm.prank(alice);
        try c.setRules(r) {} catch {}
    }

    function unpause(bool x) external {
        uint32 id = x ? IDX : IDY;
        vm.prank(alice);
        try c.unpause(id) {
            address[] memory bv = hub.idVaults(id);
            for (uint256 i; i < bv.length; ++i) {
                ghostBase[bv[i]] = ITouchstoneHook(VaultHook(bv[i]).HOOK()).obs().breachSeq;
                ghostSet[bv[i]] = true;
                ghostGone[bv[i]] = uint8(_ld(bv[i], 19) >> 32) == 2;
            }
        } catch {}
    }

    function sweepShares(uint256 seed, uint256 amt) external {
        V memory v = _v(seed);
        vm.prank(alice);
        try c.sweep(v.vault, bound(amt, 0, 1e24)) {} catch {}
    }

    // ------------------------------------------------------------------ agent

    /// @notice I-TIGHT: a successful `tighten` never loosens a field.
    function tighten(uint8 k, uint128 budget, bool dropY) external {
        Rulebook memory o = c.rules();
        Rulebook memory r = c.rules();
        r.k = uint8(bound(k, 1, 3));
        r.budget = uint128(bound(budget, 0, 20e18));
        r.agentCapPerEpoch = r.budget / 10 < o.agentCapPerEpoch ? r.budget / 10 : o.agentCapPerEpoch;
        if (dropY) r.ids = [IDX, uint32(0), uint32(0), uint32(0)];
        vm.prank(agentKey);
        try c.tighten(r) {
            Rulebook memory n = c.rules();
            if (n.k > o.k || n.budget > o.budget || n.agentCapPerEpoch > o.agentCapPerEpoch) tightBroken = true;
        } catch {}
    }

    function agentAllocate(uint256 seed, uint256 amt) external {
        V memory v = _v(seed);
        uint256 s = bound(amt, 1e18, 1e23);
        bool opening = c.ledger(v.vault) == 0;
        uint32 seqNow = _obs(v).breachSeq;
        vm.prank(agentKey);
        try c.agentAllocate(v.vault, s, type(uint256).max, type(uint256).max) {
            allocated += s;
            if (opening) (ghostBase[v.vault], ghostSet[v.vault], ghostGone[v.vault]) = (seqNow, true, false);
            _checkB6(v);
        } catch {}
    }

    // ------------------------------------------------------------------ the RC (through the proxy)

    /// @notice I-MONO and I-IDEM: conduct counts never fall; a replayed snapshot changes nothing.
    function conduct(bool x, uint32 b, uint32 g, bool replay) external {
        uint32 id = x ? IDX : IDY;
        (uint32 b0, uint32 g0, uint32 a0, uint64 s0) = hub.conduct(id);
        vm.prank(PROXY);
        hub.rcConduct(RC, id, uint32(bound(b, 0, 6)), uint32(bound(g, 0, 1)), 0, replay ? s0 : s0 + 1);
        (uint32 b1, uint32 g1, uint32 a1, uint64 s1) = hub.conduct(id);
        if (b1 < b0 || g1 < g0 || a1 < a0 || s1 < s0) monoBroken = true;
        if (replay && (b1 != b0 || g1 != g0 || s1 != s0)) idemBroken = true;
    }

    function budget(bool x, uint128 b, uint64 nonceDelta) external {
        uint32 id = x ? IDX : IDY;
        (uint128 b0, uint64 n0,) = hub.budget(address(c), id);
        uint64 n = nonceDelta % 2 == 0 ? n0 : n0 + 1; // half the time a replay of the last nonce
        uint64 r = c.rulesNonce();
        vm.prank(PROXY);
        hub.rcBudget(RC, address(c), id, uint128(bound(b, 0, 10e18)), n, r);
        if (n == n0 && n0 != 0) {
            (uint128 b1,,) = hub.budget(address(c), id);
            if (b1 != b0) idemBroken = true;
        }
    }

    /// @notice I-STALE: an `rcExit` withdraws only if, after its own `processBreach`, the Covenant is paused for the
    ///         id and (B7/B3) the vault has a local breach or gone event since the Covenant's baseline for it.
    function exit(uint256 seed) external {
        V memory v = _v(seed);
        uint32 id = hub.vaultId(v.vault);
        (,,, uint64 s) = hub.conduct(id);
        uint256 l0 = c.ledger(v.vault);
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcExit{gas: 5_000_000}(RC, address(c), v.vault, s, 0);
        (bytes memory d, bool f) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        if (!f) return;
        (uint8 o,,) = _exitOutcome(d);
        if (o == Outcome.DONE && l0 > 0) {
            ++dones;
            exited += l0;
            // judged on the state after the call (it includes the exit's own processBreach)
            if (!_pausedNow(id) || !_triggered(v)) staleBroken = true;
        }
    }

    function _checkB6(V memory v) internal {
        uint32 id = hub.vaultId(v.vault);
        (uint128 b,,) = hub.budget(address(c), id);
        if (c.rules().maxShareBps != 0 && c.exposure(id) > b) b6Broken = true;
    }

    function _pausedNow(uint32 id) internal view returns (bool) {
        if (hub.paused(address(c), id)) return true;
        Rulebook memory r = c.rules();
        address[] memory bv = hub.idVaults(id);
        uint256 sum;
        for (uint256 i; i < bv.length; ++i) {
            if (!ghostSet[bv[i]]) continue;
            uint32 bs = ghostBase[bv[i]];
            uint32 sq = ITouchstoneHook(VaultHook(bv[i]).HOOK()).obs().breachSeq;
            sum += sq > bs ? sq - bs : 0;
            if (r.b3 && uint8(_ld(bv[i], 19) >> 32) == 2 && !ghostGone[bv[i]]) return true;
        }
        return sum >= r.k;
    }

    /// @dev Judged on the handler's own ghost baseline (F1-07), never on the Covenant's view of itself.
    function _triggered(V memory v) internal view returns (bool) {
        return _obs(v).breachSeq > ghostBase[v.vault] || (_mode(v) == 2 && !ghostGone[v.vault]);
    }

    // ------------------------------------------------------------------ outsiders (I-AUTH, I-OWN)

    /// @notice I-AUTH: a spoofed callback (wrong proxy or wrong first word) reverts and changes nothing.
    function spoof(uint8 which, bool wrongWord) external {
        address from = wrongWord ? PROXY : eve;
        address rc = wrongWord ? eve : RC;
        (uint32 b0,,, uint64 s0) = hub.conduct(IDX);
        uint256 l0 = c.ledger(X.vault);
        vm.startPrank(from);
        bool ok;
        uint256 w = which % 4;
        if (w == 0) (ok,) = address(hub).call(abi.encodeCall(ReagentHub.rcConduct, (rc, IDX, 9, 1, 0, s0 + 1)));
        if (w == 1) (ok,) = address(hub).call(abi.encodeCall(ReagentHub.rcExit, (rc, address(c), X.vault, 0, 0)));
        if (w == 2) (ok,) = address(hub).call(abi.encodeCall(ReagentHub.rcBudget, (rc, address(c), IDX, 1, 99, 0)));
        if (w == 3) (ok,) = address(c).call(abi.encodeCall(ICovenant.rcExit, (X.vault, 0, 0)));
        vm.stopPrank();
        (uint32 b1,,, uint64 s1) = hub.conduct(IDX);
        if (ok || b1 != b0 || s1 != s0 || c.ledger(X.vault) != l0) authBroken = true;
    }

    function donate(uint256 seed, uint256 amt) external {
        V memory v = _v(seed);
        uint256 s = bound(amt, 1, 1e20);
        vm.prank(twin);
        try IVaultEntries(v.vault).deposit(s, type(uint256).max, type(uint256).max, twin) {
            vm.prank(twin);
            IERC20(v.vault).transfer(address(c), s);
        } catch {}
    }

    // ------------------------------------------------------------------ the curator and time

    function breach(uint256 seed, bool process_) external {
        V memory v = _v(seed);
        if (_mode(v) == 2) return;
        _latch(v, 1);
        ++breaches;
        if (process_) _process(v);
        _backInRange(v);
        _keepAlive(v, 60);
    }

    /// @notice A breach, its snapshot delivered, a wait past the drip, then the RC's exit (I-STALE's main path).
    function cycle(uint256 seed, bool deliver) external {
        V memory v = _v(seed);
        if (_mode(v) == 2) return;
        IVaultEntries(v.vault).poke();
        _latch(v, 1);
        _process(v);
        if (deliver) {
            uint32 id = hub.vaultId(v.vault);
            (uint32 b, uint32 g,, uint64 s) = hub.conduct(id);
            vm.prank(PROXY);
            hub.rcConduct(RC, id, b + 1, g, 0, s + 1);
        }
        _backInRange(v);
        _keepAlive(v, tier.FORFEIT_DRIP_BLOCKS + 60);
        this.exit(seed);
    }

    function wait(uint256 blocks) external {
        V[] memory a = new V[](3);
        (a[0], a[1], a[2]) = (vs[0], vs[1], vs[2]);
        _keepAliveAll(a, bound(blocks, 10, 400));
    }

    // ------------------------------------------------------------------ the Hub's ETH (I-ETH)

    function ethSend(uint256 amt) external {
        uint256 a = bound(amt, 0, 1 ether);
        vm.deal(address(this), a);
        (bool ok,) = address(hub).call{value: a}("");
        if (ok) ethIn += a;
    }

    function ethPay(uint256 amt, bool fromProxy) external {
        uint256 a = bound(amt, 0, 2 ether);
        uint256 b0 = address(hub).balance;
        vm.prank(fromProxy ? PROXY : eve);
        try hub.pay(a) {
            ethPaid += a;
            if (!fromProxy || b0 - address(hub).balance != a) authBroken = true;
        } catch {}
    }

    uint256 public dones;
    uint256 public breaches;

    function ethSweep() external {
        uint256 b0 = address(hub).balance;
        vm.prank(eve);
        hub.sweep();
        ethSwept += b0;
    }
}

interface VaultHook {
    function HOOK() external view returns (address);
}

/// @notice The §4 invariants at 64 × 64 (spec §9.4; the 256 × 128 campaign runs before the freeze).
contract InvariantsTest is Test {
    Handler internal h;

    function setUp() public {
        h = new Handler();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](18);
        sel[0] = Handler.allocate.selector;
        sel[1] = Handler.leave.selector;
        sel[2] = Handler.setRules.selector;
        sel[3] = Handler.unpause.selector;
        sel[4] = Handler.sweepShares.selector;
        sel[5] = Handler.tighten.selector;
        sel[6] = Handler.agentAllocate.selector;
        sel[7] = Handler.conduct.selector;
        sel[8] = Handler.budget.selector;
        sel[9] = Handler.exit.selector;
        sel[10] = Handler.spoof.selector;
        sel[11] = Handler.donate.selector;
        sel[12] = Handler.breach.selector;
        sel[13] = Handler.wait.selector;
        sel[14] = Handler.ethSend.selector;
        sel[15] = Handler.ethPay.selector;
        sel[16] = Handler.ethSweep.selector;
        sel[17] = Handler.cycle.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    /// @notice Non-vacuity: the handler reaches every outcome the invariants judge (an exit DONE, a leave, a
    ///         spoof, a replay, a pay and a sweep), so a passing campaign is not a campaign that never acted.
    function test_I_SHARES__handlerReachesEveryOutcome() public {
        h.breach(0, true); // X latched and processed
        h.wait(200); // past the drip
        h.exit(0);
        assertGt(h.dones(), 0, "an exit DONE");
        h.leave(2, 5e22);
        assertGt(h.left(), 0, "a leave");
        h.spoof(0, false);
        h.spoof(1, true);
        h.conduct(true, 3, 0, false);
        h.conduct(true, 3, 0, true);
        h.ethSend(1 ether);
        h.ethPay(0.1 ether, true);
        h.ethSweep();
        assertGt(h.ethIn(), 0);
        assertGt(h.ethPaid(), 0);
        assertGt(h.ethSwept(), 0);
        assertFalse(h.authBroken() || h.idemBroken() || h.leaveBroken() || h.staleBroken() || h.monoBroken());
    }

    function afterInvariant() external view {
        console2.log("coverage: allocated", h.allocated(), "left", h.left());
        console2.log("coverage: exits DONE", h.dones(), "breaches", h.breaches());
    }

    /// @notice I-OWN: tokens left the Covenant only to the owner or a vault: no third party ever gained any.
    function invariant_I_OWN__noThirdPartyEverReceivesTokens() public view {
        ICovenant c = h.c();
        address[3] memory others = [h.eve(), c.agent(), h.hubAddr()];
        for (uint256 i; i < 3; ++i) {
            assertEq(IERC20(h.tok0()).balanceOf(others[i]), 0);
            assertEq(IERC20(h.tok1()).balanceOf(others[i]), 0);
        }
    }

    function invariant_I_AUTH__spoofedCallbacksNeverApply() public view {
        assertFalse(h.authBroken());
    }

    function invariant_I_IDEM__replaysChangeNothing() public view {
        assertFalse(h.idemBroken());
    }

    function invariant_I_LEAVE__leaveWorksWheneverWithdrawWould() public view {
        assertFalse(h.leaveBroken());
    }

    function invariant_I_TIGHT__theAgentNeverLoosens() public view {
        assertFalse(h.tightBroken());
    }

    /// @notice I-SHARES: per vault ledger <= balanceOf; in total, ledger = Σ allocated − Σ left − Σ exited.
    function invariant_I_SHARES__ledgerBoundedAndBooked() public view {
        ICovenant c = h.c();
        uint256 total;
        for (uint256 i; i < h.vaultCount(); ++i) {
            address v = h.vaultAt(i);
            assertLe(c.ledger(v), IERC20(v).balanceOf(address(c)), "ledger <= balanceOf");
            total += c.ledger(v);
        }
        assertEq(total, h.allocated() - h.left() - h.exited(), "booked");
    }

    /// @notice I-B6SUM's base (F1-01): an id with any holding on this chain has exposure, an id with none has none.
    function invariant_I_SHARES__exposureFollowsTheIdsHoldings() public view {
        ICovenant c = h.c();
        uint32[2] memory ids_ = [uint32(1), uint32(2)];
        for (uint256 k; k < 2; ++k) {
            uint256 held_;
            for (uint256 i; i < h.vaultCount(); ++i) {
                if (h.hubIdOf(h.vaultAt(i)) == ids_[k]) held_ += c.ledger(h.vaultAt(i));
            }
            if (held_ > 0) assertGt(c.exposure(ids_[k]), 0, "a held id has exposure");
            else assertEq(c.exposure(ids_[k]), 0, "an empty id has none");
        }
    }

    function invariant_I_SHARES__exposureWithinTheChainBudgetAfterEveryAllocation() public view {
        assertFalse(h.b6Broken());
    }

    function invariant_I_MONO__theMirrorNeverDecreases() public view {
        assertFalse(h.monoBroken());
    }

    function invariant_I_STALE__exitsWithdrawOnlyWhenPausedAndTriggered() public view {
        assertFalse(h.staleBroken());
    }

    /// @notice I-ETH: the Hub's balance moved only by `pay` to the proxy (exact) and `sweep` into its reserves.
    function invariant_I_ETH__ethLeavesOnlyToTheProxy() public view {
        assertEq(h.hubAddr().balance + h.ethPaid() + h.ethSwept(), h.ethIn(), "accounted");
        assertEq(h.eve().balance, 0, "no outsider gained ETH");
    }
}
