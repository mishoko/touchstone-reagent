// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReagentHub} from "../src/ReagentHub.sol";

/// @notice The 11155111 gas twins (spec §5.6 method (a), §9.1 T-SEPGAS-*, §9.3 A-SEPGAS63) are scripted
///         `eth_simulateV1` runs (`script/deploy/sepgas.py`) recorded in `audits/gas-need.json`. These tests bind the
///         record to the code: every run passed, and the NEED each twin ran at is the one the Hub's code holds
///         under chain id 11155111 (a stale record fails here).
contract SepGasRecordTest is Test {
    string internal j;

    function setUp() public {
        j = vm.readFile("./audits/gas-need.json");
    }

    function _row(string memory kind, string memory leg) internal view returns (bool) {
        return vm.parseJsonBool(j, string.concat(".sepolia_twins.", kind, ".", leg, ".pass"));
    }

    function _outcome(string memory kind, string memory leg) internal view returns (string memory) {
        return vm.parseJsonString(j, string.concat(".sepolia_twins.", kind, ".", leg, ".outcome"));
    }

    function _hubNeeds() internal returns (uint256 e, uint256 p) {
        vm.chainId(11155111);
        ReagentHub h = new ReagentHub(address(1));
        (e, p) = h.needs();
    }

    function test_T_SEPGAS_EXIT__doneAtTheFormulaDeferredBelowNeedCoversTheMeasuredMinimum() public {
        (uint256 e,) = _hubNeeds();
        assertEq(vm.parseJsonUint(j, ".sepolia_twins.rcExit.need"), e, "the twin ran at the Hub's NEED");
        assertTrue(_row("rcExit", "formula"), "DONE at the formula gasLimit");
        assertEq(_outcome("rcExit", "formula"), "DONE");
        assertTrue(_row("rcExit", "minus1"), "DEFERRED 1% under the pre-check");
        assertTrue(_row("rcExit", "measured"), "NEED >= 1.3 x the Covenant's measured need bound");
        assertTrue(vm.parseJsonBool(j, ".sepolia_twins.rcExit.pass"));
    }

    function test_T_SEPGAS_PLAN__doneAtTheFormulaDeferredBelowNeedCoversTheMeasuredMinimum() public {
        (, uint256 p) = _hubNeeds();
        assertEq(vm.parseJsonUint(j, ".sepolia_twins.rcAllocate.need"), p, "the twin ran at the Hub's NEED");
        assertTrue(_row("rcAllocate", "formula"));
        assertEq(_outcome("rcAllocate", "formula"), "DONE");
        assertTrue(_row("rcAllocate", "minus1"));
        assertTrue(_row("rcAllocate", "measured"));
    }

    function test_T_SEPGAS_CONDUCT__appliesAtTheFormulaAndNeedCoversTheMeasuredMinimum() public view {
        assertEq(vm.parseJsonUint(j, ".sepolia_twins.rcConduct.need"), 150_000);
        assertTrue(_row("rcConduct", "formula"));
        assertTrue(_row("rcConduct", "measured"), "NEED >= 1.3 x the Sepolia minimum; 1,000 under it fails");
        assertEq(vm.parseJsonString(j, ".sepolia_twins.rcConduct.measured.under1000"), "FAILED", "the PC: 1,000 under the minimum");
    }

    function test_T_SEPGAS_BUDGET__answersAtTheFormulaAndNeedCoversTheMeasuredMinimum() public view {
        assertEq(vm.parseJsonUint(j, ".sepolia_twins.rcBudget.need"), 500_000);
        assertTrue(_row("rcBudget", "formula"));
        assertEq(_outcome("rcBudget", "formula"), "ANSWERED", "BudgetApplied and the STATE note");
        assertTrue(_row("rcBudget", "measured"), "1,000 under the minimum loses the STATE (STALE6 or worse)");
        assertTrue(vm.parseJsonBool(j, ".sepolia_twins.rcBudget.pass"));
    }

    function test_T_SEPGAS_VAULT__bindsAtTheFormulaAndNeedCoversTheMeasuredMinimum() public view {
        assertEq(vm.parseJsonUint(j, ".sepolia_twins.rcVault.need"), 437_000);
        assertTrue(_row("rcVault", "formula"));
        assertTrue(_row("rcVault", "measured"));
        assertEq(vm.parseJsonString(j, ".sepolia_twins.rcVault.measured.under1000"), "FAILED", "the PC: 1,000 under the minimum");
    }

    /// @notice A-SEPGAS63: on 11155111, a delivery one unit under the pre-check threshold is DEFERRED (no try burnt).
    function test_A_SEPGAS63__aShortDeliveryIsDeferredOnSepolia() public view {
        assertEq(_outcome("rcExit", "a_sepgas63"), "DEFERRED");
        assertTrue(_row("rcExit", "a_sepgas63"));
    }

    /// @notice PC: the Hub with the forge (1301) NEED on 11155111 lets a short delivery through and burns a try.
    function test_A_SEPGAS63__PC_theForgeNeedBurnsATryOnSepolia() public view {
        string memory o = _outcome("rcExit", "pc");
        assertTrue(keccak256(bytes(o)) != keccak256("DONE") && keccak256(bytes(o)) != keccak256("DEFERRED"), o);
        assertTrue(_row("rcExit", "pc"));
    }
}
