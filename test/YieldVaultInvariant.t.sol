// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";
import {MockYieldSource} from "../src/mocks/MockYieldSource.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {YieldVaultHandler} from "./handlers/YieldVaultHandler.sol";

/// @notice The headline safety guarantees for the ObulusYieldVault on the principal-protected path: across any
///         sequence of deposit / redeem / withdraw / harvest / fee-changes / source-toggles, the vault is
///         always SOLVENT (every depositor's redeemable value is covered by what the vault can recover) and
///         every wei is CONSERVED (deposits-in == payouts + fees + still-held value). The source used here is
///         the principal-protected MockYieldSource, so there is a real floor; the lossy/no-floor behaviour is
///         covered by the unit tests (the invariant deliberately uses a non-lossy source so a hard
///         conservation equality is assertable).
contract YieldVaultInvariantTest is StdInvariant, Test {
    ObulusYieldVault internal vault;
    MockYieldSource internal source;
    MockUSDC internal usdc;
    YieldVaultHandler internal handler;

    address internal treasury = makeAddr("yv-inv-treasury");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new ObulusYieldVault(address(usdc), treasury);
        source = new MockYieldSource(address(usdc), address(vault), 1_000); // 10% APR, principal-protected
        // This contract is the vault owner; attach the source so the yielding path is live from the start.
        vault.setYieldSource(source);

        handler = new YieldVaultHandler(vault, source, usdc, treasury, address(this));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.deposit.selector; // weight deposits
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.withdrawAssets.selector;
        selectors[4] = handler.harvest.selector;
        selectors[5] = handler.accrueYield.selector;
        selectors[6] = handler.setFee.selector;
        selectors[7] = handler.toggleSource.selector;
        selectors[8] = handler.redeem.selector; // weight redeems
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The owner (this test contract) must NOT itself be a fuzz target, otherwise its admin powers get
    ///      randomly invoked outside the handler. The handler is the sole target.

    // ---------------------------------------------------------------------------------------------
    // SOLVENCY: every depositor can be paid out of what the vault can actually recover.
    // ---------------------------------------------------------------------------------------------

    function invariant_solvent() public view {
        uint256 owed;
        uint256 n = handler.depositorsLength();
        for (uint256 i; i < n; i++) {
            owed += vault.convertToAssets(vault.balanceOf(handler.depositorsList(i)));
        }
        assertLe(owed, vault.totalAssets(), "sum(redeemable) <= totalAssets (vault is solvent)");
    }

    /// @dev totalAssets is exactly the idle USDC the vault holds + the source's reported assets. The vault
    ///      never books value it cannot point to.
    function invariant_totalAssets_is_backed() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 src = address(vault.yieldSource()) == address(0) ? 0 : vault.yieldSource().totalAssets();
        assertEq(vault.totalAssets(), idle + src, "totalAssets == idle + source assets");
    }

    /// @dev PHYSICAL CONSERVATION of every wei: the sum of REAL USDC token balances across every party in the
    ///      system (depositors + vault + source + treasury + the handler itself) equals exactly the total
    ///      USDC the handler ever minted. No wei is created or destroyed by any vault operation. This is the
    ///      rigorous statement; it does NOT depend on any source's possibly-unfunded VALUATION (the
    ///      MockYieldSource can transiently value pending APR it isn't yet funded for — but physical USDC is
    ///      always exact). Solvency below ties valuation back to recoverable assets.
    function invariant_physical_usdc_conserved() public view {
        uint256 sum;
        uint256 n = handler.depositorsLength();
        for (uint256 i; i < n; i++) {
            sum += usdc.balanceOf(handler.depositorsList(i));
        }
        sum += usdc.balanceOf(address(vault));
        sum += usdc.balanceOf(address(source));
        sum += usdc.balanceOf(treasury);
        sum += usdc.balanceOf(address(handler));
        assertEq(sum, handler.ghostMinted(), "physical USDC across all parties == total ever minted");
    }

    /// @dev The treasury only ever RECEIVES (fees). It never funds the vault, so its balance equals the ghost
    ///      fee total exactly.
    function invariant_treasury_is_fee_only() public view {
        assertEq(usdc.balanceOf(treasury), handler.ghostFees(), "treasury balance == sum of fees taken");
    }

    /// @dev STRUCTURAL: the vault holds NO escrow reference and exposes no escrow-funded inflow. The vault's
    ///      physically-held USDC (idle + what it routed to the source) can never exceed the depositor inflow
    ///      plus realized yield still in the system — there is no back-door (e.g. escrow principal) path in.
    ///      Concretely: vault-idle + source-held <= deposits + funded-yield - paid-out - fees.
    function invariant_no_unaccounted_inflow() public view {
        uint256 inSystem = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(source));
        uint256 trackedNet =
            handler.ghostDeposited() + handler.ghostYieldFunded() - handler.ghostWithdrawnNet() - handler.ghostFees();
        assertLe(inSystem, trackedNet, "no unaccounted (e.g. escrow) inflow ever reached the vault/source");
    }
}
