// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RcFixture} from "./base/RcFixture.sol";
import {IReagentRC} from "../src/interfaces/IReagentRC.sol";
import {LogRecord} from "../src/interfaces/IReactive.sol";
import {IReagentHub} from "../src/interfaces/IReagent.sol";
import {PreSwap} from "touchstone/types/PreSwap.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";
import {CuratorBundler} from "touchstone/periphery/CuratorBundler.sol";

/// @notice The curator record beyond breaches (spec §5.5 reactions; §9.2 R-GONE, R-ACTION; §9.3 A-ACTION-SPAM,
///         A-ESCAPE, A-SPAM), on the R layer.
contract RcConductTest is RcFixture {
    uint256 constant T_ACTION = 0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba;
    uint256 constant ACTION_BUDGET = 8;

    function setUp() public {
        _setUpRc();
    }

    function _hasAction(uint256 c, address vault) internal view returns (bool) {
        for (uint256 i; i < subsHist.length; ++i) {
            Sub memory s = subsHist[i];
            if (s.rc == address(rc) && s.until == 0 && s.chainId == c && s.emitter == vault && s.t0 == T_ACTION) return true;
        }
        return false;
    }

    function _action(V memory v) internal {
        _keepAlive(v, 40); // past the cooldown
        vm.prank(curatorOwner);
        v.bundler.setPositions(-1000, 1000, PreSwap(false, false, 0), 0, type(uint256).max);
        _keepAlive(v, 10);
    }

    function _toEpochStart(V memory v) internal {
        uint256 e = tier.EPOCH;
        uint256 next = (vm.getBlockNumber() / e + 1) * e;
        _keepAlive(v, next - vm.getBlockNumber() + 1);
        IVaultEntries(v.vault).poke(); // the entry that rolls the epoch
    }

    function _actionLogs(address vault) internal view returns (uint256 n) {
        for (uint256 i; i < originHist.length; ++i) {
            if (originHist[i].emitter == vault && originHist[i].topic0 == T_ACTION) ++n;
        }
    }

    // ================================================================== R-GONE

    function test_R_GONE__retiredSetsGoneOnBothHubs() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        vm.prank(curatorOwner);
        x.bundler.retire();
        _elapse(20);
        (,, , bool gone,) = rc.vaultOf(CA, x.vault);
        assertTrue(gone);
        (, uint32 g,,) = rc.conduct(1);
        assertEq(g, 1);
        (, uint32 ga,,) = ch[CA].hub.conduct(1);
        (, uint32 gb,,) = ch[CB].hub.conduct(1);
        assertEq(ga, 1, "chain A's Hub");
        assertEq(gb, 1, "chain B's Hub");
    }

    function test_R_GONE__exitedAfterThreeBreachesSetsGoneOnce() public {
        V memory x = _registeredVault(CB, 2);
        _on(CB);
        _age(x, 40);
        for (uint256 i; i < 3; ++i) {
            _latch(x, 1);
            if (_mode(x) == 2) break;
            _process(x);
            _backInRange(x);
            _keepAlive(x, 40);
        }
        assertEq(_mode(x), 2, "EXITED");
        _elapse(30);
        (, uint32 g,,) = rc.conduct(2);
        assertEq(g, 1, "gone counts the vault once");
    }

    // ================================================================== R-ACTION, A-ACTION-SPAM

    function test_R_ACTION__refreshesConductNeverArmsAnExit() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _action(x);
        _elapse(20);
        (,, uint32 a,) = rc.conduct(1);
        assertEq(a, 1);
        (,, uint32 ha,) = ch[CB].hub.conduct(1);
        assertEq(ha, 1, "the other chain's Hub holds the action count");
        assertEq(_deliveredCount(0, IReagentHub.rcExit.selector, 0), 0, "an action never arms an exit");
    }

    function test_R_ACTION__budgetThenExactUnsubscribeThenResubscribeAtTheNextEpoch() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _toEpochStart(x);
        _elapse(5);
        uint256 sends0 = _deliveredCount(CA, IReagentHub.rcConduct.selector, 0);
        for (uint256 i; i < ACTION_BUDGET + 1; ++i) {
            _action(x);
            _elapse(5);
        }
        uint256 sent = _deliveredCount(CA, IReagentHub.rcConduct.selector, 0) - sends0;
        assertEq(sent, ACTION_BUDGET, "one snapshot per action up to the budget");
        assertFalse(_hasAction(CA, x.vault), "Action unsubscribed at the budget");
        assertEq(unsubscribeMisses, 0, "the unsubscribe matched all six arguments");
        _toEpochStart(x);
        _elapse(20);
        assertTrue(_hasAction(CA, x.vault), "resubscribed at the next EpochRecorded");
        _action(x);
        _elapse(5);
        assertEq(_deliveredCount(CA, IReagentHub.rcConduct.selector, 0) - sends0, ACTION_BUDGET + 1);
    }

    function test_A_ACTION_SPAM__callbacksStayWithinTheBudgetPerEpoch() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _toEpochStart(x);
        _elapse(5);
        uint256 sends0 = _deliveredCount(0, IReagentHub.rcConduct.selector, 0);
        for (uint256 i; i < 3 * ACTION_BUDGET; ++i) {
            _action(x);
        }
        _elapse(10);
        uint256 sent = _deliveredCount(0, IReagentHub.rcConduct.selector, 0) - sends0;
        assertLe(sent, 2 * ACTION_BUDGET, "<= the budget per chain in the epoch");
    }

    /// @notice PC: without the budget (one snapshot per Action log), the same spam costs 2 callbacks per action.
    function test_A_ACTION_SPAM__PC_withoutTheBudgetCallbacksGrowWithTheSpam() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _toEpochStart(x);
        for (uint256 i; i < 3 * ACTION_BUDGET; ++i) {
            _action(x);
        }
        _elapse(10);
        assertGt(2 * _actionLogs(x.vault), 2 * ACTION_BUDGET, "a per-action rule exceeds the budget's bound");
    }

    // ================================================================== A-ESCAPE

    function test_A_ESCAPE__aFreshVaultOfARegisteredBundlerKeepsTheRecord() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _latch(x, 1);
        _elapse(10);
        V memory x2 = _registeredVault(CA, 1); // the curator moves to a fresh vault
        _on(CA);
        _age(x2, 400);
        _latch(x2, 1);
        _elapse(10);
        (uint32 b,,,) = rc.conduct(1);
        assertEq(b, 2, "the record follows the curator id, not the vault");
    }

    /// @notice PC: a per-vault record (reset at the move) shows the fresh vault's count only.
    function test_A_ESCAPE__PC_aPerVaultRecordLosesTheHistory() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        _latch(x, 1);
        V memory x2 = _registeredVault(CA, 1);
        _on(CA);
        _age(x2, 400);
        _latch(x2, 1);
        _elapse(10);
        (,, uint32 m2,,) = rc.vaultOf(CA, x2.vault);
        assertLt(m2, 2, "the fresh vault alone is below k = 2: the escape wins without the id record");
    }

    // ================================================================== A-SPAM

    function _spam(V memory x) internal {
        address o = makeAddr("outsider");
        for (uint256 i; i < 5; ++i) {
            _swap(x, i % 2 == 0, 1e15);
            vm.prank(o);
            IVaultEntries(x.vault).poke();
            token0.transfer(o, 1);
            _keepAlive(x, 10);
        }
    }

    function test_A_SPAM__outsiderTrafficNeverReachesTheRc() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        uint256 r0 = reactCalls;
        _spam(x);
        _elapse(10);
        assertEq(reactCalls, r0, "no reaction, no charge");
    }

    /// @notice PC: a wildcard-topic subscription on the vault (a never-list topic) would be billed for the spam.
    function test_A_SPAM__PC_aWildcardTopicWouldBeBilled() public {
        V memory x = _registeredVault(CA, 1);
        _on(CA);
        _age(x, 400);
        uint256 h0 = originHist.length;
        _spam(x);
        _elapse(10);
        uint256 billed;
        Sub memory w = Sub(address(rc), 0, 0, CA, x.vault, IGNORE, IGNORE, IGNORE, IGNORE);
        for (uint256 i = h0; i < originHist.length; ++i) {
            if (_matches(w, originHist[i])) ++billed;
        }
        assertGt(billed, 0, "a vault-wide subscription is billed for outsider traffic");
    }
}
