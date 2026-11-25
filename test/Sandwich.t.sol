// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReagentEnv} from "./base/ReagentEnv.sol";
import {CovenantBase} from "../src/CovenantBase.sol";
import {ICovenant, Rulebook, NoteKind, Outcome} from "../src/interfaces/IReagent.sol";
import {IVaultEntries} from "touchstone/interfaces/ITouchstoneVaultExtension.sol";

/// @notice A-EXIT-SANDWICH and A-DEPOSIT-SANDWICH (spec §9.3): an attacker moves spot in the vault's own v4 pool
///         before a Covenant's exit or deposit and swaps back after it. Everything is valued at the reference
///         (tick 0: raw token0 = raw token1), the price the Covenant's min-outs and max-ins use. The attacker is this
///         test contract (the swap router's payer); its net is its balance change over the front and back legs.
contract SandwichTest is ReagentEnv {
    ICovenant internal c;
    uint256 internal constant SH = 1e23;
    uint256 internal constant DEP = SH; // the deposit size of the agent cell AND its PC (s8-forge r1 m-02)
    uint256 internal constant FRONT = 6e17; // the front leg of every deposit cell
    address internal twin = makeAddr("twin");

    function setUp() public {
        _setUpReagent(1301);
        _setUpVaults();
        c = _covenant(alice);
        _setRules(c, _rules(IDX, IDY));
        vm.startPrank(alice);
        c.setAgent(agentKey);
        c.setAllowed(X.vault, true);
        vm.stopPrank();
        V[] memory all = new V[](3);
        (all[0], all[1], all[2]) = (X, X2, Y);
        _keepAliveAll(all, 2 * tier.EPOCH); // pay accrues, so a breach forfeits and starts a drip
        _alloc(c, X.vault, SH);
        token0.mint(twin, 1e30);
        token1.mint(twin, 1e30);
        vm.startPrank(twin);
        token0.approve(X.vault, type(uint256).max);
        token1.approve(X.vault, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _val(address who) internal view returns (uint256) {
        return token0.balanceOf(who) + token1.balanceOf(who); // value at the reference tick 0
    }

    function _bals(address who) internal view returns (uint256, uint256) {
        return (token0.balanceOf(who), token1.balanceOf(who));
    }

    /// @dev The front leg: `amountIn` of token0 (down) or token1 (up) into the vault's pool. Returns what it bought.
    function _front(bool down, uint256 amountIn) internal returns (uint256 bought) {
        (uint256 b0, uint256 b1) = _bals(address(this));
        _swap(X, down, amountIn);
        (uint256 c0, uint256 c1) = _bals(address(this));
        bought = down ? c1 - b1 : c0 - b0;
    }

    /// @dev The back leg: sells what the front leg bought.
    function _back(bool down, uint256 bought) internal {
        _swap(X, !down, bought);
    }

    /// @dev The attacker's net at the reference over the bracketed legs (signed).
    function _net(uint256 before) internal view returns (int256) {
        return int256(_val(address(this))) - int256(before);
    }

    function _exitNow() internal returns (uint8 o, uint256 a0, uint256 a1) {
        (,,, uint64 s) = hub.conduct(IDX);
        vm.recordLogs();
        _exit(address(c), X.vault, s);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.EXIT);
        assertTrue(found, "an EXIT note");
        (o, a0, a1) = _exitOutcome(d);
    }

    /// @dev The exit's preconditions: a breach on X latched and processed, the Hub paused, the reference back in
    ///      range, the drip waited out.
    function _readyToExit() internal {
        IVaultEntries(X.vault).poke();
        _latch(X, 1);
        _process(X);
        (uint32 b, uint32 g,,) = hub.conduct(IDX);
        _conduct(IDX, b + 1, g);
        _backInRange(X);
        _keepAlive(X, 60);
        uint256 end = _dripEnd(X);
        if (vm.getBlockNumber() < end) _keepAlive(X, end - vm.getBlockNumber() + 10);
    }

    function _plan(uint128 amount) internal returns (uint8 outcome, uint8 reason) {
        vm.prank(alice);
        c.setPlan(X.vault, amount);
        _keepAlive(X, tier.EPOCH);
        IVaultEntries(X.vault).poke();
        uint32 cur = uint32(_ld(X.vault, 8) >> 40);
        vm.recordLogs();
        vm.prank(PROXY);
        hub.rcAllocate{gas: 5_000_000}(RC, address(c), X.vault, cur - 1);
        (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.PLAN);
        assertTrue(found, "a PLAN note");
        (,, outcome, reason) = abi.decode(d, (address, uint32, uint8, uint8));
    }

    // ================================================================== A-EXIT-SANDWICH

    /// @notice A-EXIT-SANDWICH (must lose): for both directions and two sizes, the front leg, the Covenant's exit,
    ///         the back leg. The exit is DONE, the owner's take valued at the reference is never below the unmoved
    ///         exit's (spec §14 #47: a pro-rata withdrawal's composition at any spot is worth at least its value at
    ///         the reference), and the attacker's round trip nets at most zero.
    function test_A_EXIT_SANDWICH__theOwnersTakeNeverDropsAndTheAttackerLoses() public {
        _readyToExit();
        uint256 snap = vm.snapshotState();
        (uint8 o, uint256 u0, uint256 u1) = _exitNow();
        assertEq(o, Outcome.DONE, "the unmoved exit");
        uint256 fair = u0 + u1;
        uint256[2] memory sizes = [uint256(1e17), uint256(6e17)];
        for (uint256 d; d < 2; ++d) {
            for (uint256 i; i < 2; ++i) {
                vm.revertToState(snap);
                bool down = d == 0;
                uint256 before = _val(address(this));
                uint256 bought = _front(down, sizes[i]);
                (uint8 o2, uint256 a0, uint256 a1) = _exitNow();
                _back(down, bought);
                assertEq(o2, Outcome.DONE, "a sandwich leg cannot block the exit");
                assertGe(a0 + a1, fair, "the owner's take at the reference: never below the unmoved exit's");
                int256 net = _net(before);
                assertLe(net, 0, "the attacker's round trip around an in-kind exit does not profit");
                emit log_named_int("attacker net (down=1/up=0 x size)", net);
                emit log_named_uint("owner take over fair", a0 + a1 - fair);
            }
        }
    }

    /// @notice A-EXIT-SANDWICH's positive control (the detector is live): the same sandwich against a PRICE-BASED
    ///         exit, which is what an in-kind exit avoids. The twin holds the same shares, withdraws at the moved
    ///         spot and sells the token the moved spot gave it back into the pool for token1 before the back leg.
    ///         Its take falls below the unmoved in-kind exit's: the cell's assertion fails for a sold exit.
    function test_A_EXIT_SANDWICH__PC_aPriceBasedExitLosesToTheSameSandwich() public {
        vm.prank(twin);
        IVaultEntries(X.vault).deposit(SH, type(uint256).max, type(uint256).max, twin);
        _readyToExit();
        uint256 snap = vm.snapshotState();
        (uint8 o, uint256 u0, uint256 u1) = _exitNow();
        assertEq(o, Outcome.DONE);
        uint256 fair = u0 + u1; // the Covenant's unmoved in-kind take for the same SH
        // the same price-based exit with no sandwich: what a sale costs on its own (the pool's fee and impact)
        vm.revertToState(snap);
        uint256 tu = _val(twin);
        vm.prank(twin);
        (uint256 wu,) = IVaultEntries(X.vault).withdraw(SH, 0, 0, twin);
        _sellAs(twin, wu);
        uint256 soldUnmoved = _val(twin) - tu;
        vm.revertToState(snap);
        uint256 before = _val(address(this));
        uint256 bought = _front(true, 6e17); // spot far below: token0 is cheap in the pool
        uint256 t0 = _val(twin);
        vm.prank(twin);
        (uint256 w0,) = IVaultEntries(X.vault).withdraw(SH, 0, 0, twin);
        // the price-based exit sells its token0 into the moved pool for token1 (as a swap-to-cash exit would)
        uint256 sold = _sellAs(twin, w0);
        _back(true, bought);
        uint256 take = _val(twin) - t0;
        int256 attacker = _net(before);
        assertLt(take, fair, "PC: the price-based exit's take is below the unmoved exit's");
        // s8-forge r1 m-01: the loss is the sandwich's, not the sale's own cost: the sandwiched sale takes > 1% less
        // than the same sale unmoved, and the attacker nets > 0
        assertLt(take * 100, soldUnmoved * 99, "PC: the sandwich, not the sale, costs the price-based exit > 1%");
        assertGt(attacker, 0, "PC: the attacker profits from the price-based exit");
        emit log_named_uint("price-based take (sandwiched)", take);
        emit log_named_uint("price-based take (unmoved)", soldUnmoved);
        emit log_named_uint("unmoved in-kind take", fair);
        emit log_named_uint("token0 sold", sold);
        emit log_named_int("attacker net", attacker);
    }

    /// @dev `who` sells `amount0` token0 for token1 through the vault's pool (a router call paid by `who`).
    function _sellAs(address who, uint256 amount0) internal returns (uint256) {
        // the test router is approved by this contract only: the twin's token0 is routed through it and the token1
        // bought is returned, so the attacker's balance is unchanged by this leg
        vm.prank(who);
        token0.transfer(address(this), amount0);
        (, uint256 b1) = _bals(address(this));
        _swap(X, true, amount0);
        (, uint256 c1) = _bals(address(this));
        token1.transfer(who, c1 - b1);
        return amount0;
    }

    // ================================================================== A-DEPOSIT-SANDWICH

    /// @notice A-DEPOSIT-SANDWICH (must lose): the front leg moves spot, then the agent's deposit is refused
    ///         (PriceTolerance) and the plan's is SKIPPED (slippage); the Covenant pays nothing; the attacker's
    ///         round trip with no victim in between nets at most zero.
    function test_A_DEPOSIT_SANDWICH__theDepositIsRefusedAndTheAttackerLoses() public {
        // control: the same allocation at the reference goes through
        uint256 snap0 = vm.snapshotState();
        vm.prank(agentKey);
        c.agentAllocate(X.vault, DEP, type(uint256).max, type(uint256).max);
        vm.revertToState(snap0);
        for (uint256 d; d < 2; ++d) {
            uint256 snap = vm.snapshotState();
            bool down = d == 0;
            uint256 before = _val(address(this));
            uint256 cv = _val(address(c));
            uint256 bought = _front(down, FRONT);
            vm.prank(agentKey);
            vm.expectRevert(CovenantBase.PriceTolerance.selector);
            c.agentAllocate(X.vault, DEP, type(uint256).max, type(uint256).max);
            _back(down, bought);
            assertEq(_val(address(c)), cv, "the Covenant paid nothing");
            int256 net = _net(before);
            assertLe(net, 0, "the attacker's round trip with no deposit in between does not profit");
            emit log_named_int("attacker net (agent)", net);
            vm.revertToState(snap);
        }
    }

    /// @notice The plan path of the same cell: a plan deposit due while spot is moved is SKIPPED (slippage) and its
    ///         tokens stay in the Covenant.
    function test_A_DEPOSIT_SANDWICH__aPlanDepositAtAMovedSpotIsSkipped() public {
        token1.mint(address(c), 1e18); // the plan's token1 sits in the Covenant
        uint256 snap = vm.snapshotState();
        (uint8 o0,) = _plan(0.1e18);
        assertEq(o0, Outcome.DONE, "control: the same plan at the reference deposits");
        for (uint256 dir; dir < 2; ++dir) {
            vm.revertToState(snap);
            vm.prank(alice);
            c.setPlan(X.vault, 0.1e18);
            _keepAlive(X, tier.EPOCH);
            IVaultEntries(X.vault).poke();
            uint32 cur = uint32(_ld(X.vault, 8) >> 40);
            uint256 cv = _val(address(c));
            uint256 before = _val(address(this));
            uint256 bought = _front(dir == 0, FRONT);
            vm.recordLogs();
            vm.prank(PROXY);
            hub.rcAllocate{gas: 5_000_000}(RC, address(c), X.vault, cur - 1);
            (bytes memory d, bool found) = _lastNote(vm.getRecordedLogs(), address(c), NoteKind.PLAN);
            _back(dir == 0, bought);
            assertTrue(found);
            (,, uint8 o, uint8 reason) = abi.decode(d, (address, uint32, uint8, uint8));
            assertEq(o, Outcome.SKIPPED, "the plan skips at a moved spot");
            assertEq(reason, Outcome.SKIP_SLIPPAGE, "reason: slippage");
            assertEq(_val(address(c)), cv, "the plan's tokens stay in the Covenant");
            assertLe(_net(before), 0, "the attacker's round trip around a skipped plan does not profit");
        }
    }

    /// @notice A-DEPOSIT-SANDWICH's positive control (max-ins removed): the same deposit without the Covenant's
    ///         max-in check is a direct vault deposit at unbounded max-ins at the moved spot (the Covenant's own call
    ///         minus the check). The depositor overpays at the reference and the attacker nets > 0 on the swap back.
    function test_A_DEPOSIT_SANDWICH__PC_withoutTheMaxInsTheDepositorOverpaysAndTheAttackerProfits() public {
        uint256 shares = DEP; // the agent cell's size
        uint256 before = _val(address(this));
        uint256 t0 = _val(twin);
        uint256 bought = _front(true, FRONT);
        vm.prank(twin);
        IVaultEntries(X.vault).deposit(shares, type(uint256).max, type(uint256).max, twin);
        _back(true, bought);
        vm.prank(twin);
        IVaultEntries(X.vault).withdraw(shares, 0, 0, twin);
        int256 depositor = int256(_val(twin)) - int256(t0);
        int256 attacker = _net(before);
        emit log_named_int("depositor net (round trip at the reference)", depositor);
        emit log_named_int("attacker net", attacker);
        assertLt(depositor, 0, "PC: the depositor overpays at the reference");
        assertGt(attacker, 0, "PC: the attacker nets > 0 on the swap back");
    }
}
