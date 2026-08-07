// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {YieldVaultLossyHandler, LossyIlliquidSource} from "./handlers/YieldVaultLossyHandler.sol";

/// @notice The over-burn remediation's headline invariant: against a LOSSY + ILLIQUID source the fuzzer can
///         push into adverse states (realized losses via `inflict`, illiquidity via `setLossy`), the vault is
///         ALWAYS solvent — every depositor's redeemable value is covered by what the vault can actually
///         recover (Σ redeemable <= totalAssets). Pre-fix, a withdraw(assets) against an illiquid source
///         over-burned the redeemer's shares (paying < gross but burning the full gross-equivalent), which
///         silently moved value to remaining shareholders; the fuzzer drives exactly those partial-delivery
///         paths here and solvency must hold throughout. Physical USDC is also conserved modulo the tracked
///         loss sink (the only place wei leave the system is an inflicted realized loss).
contract YieldVaultLossyInvariantTest is StdInvariant, Test {
    ObulusYieldVault internal vault;
    LossyIlliquidSource internal source;
    MockUSDC internal usdc;
    YieldVaultLossyHandler internal handler;

    address internal treasury = makeAddr("yv-lossy-inv-treasury");

    function setUp() public {
        usdc = new MockUSDC();
        vault = new ObulusYieldVault(address(usdc), treasury);
        source = new LossyIlliquidSource(address(usdc), address(vault));
        // This contract owns the vault; attach the lossy source so the adverse path is live from the start.
        vault.setYieldSource(source);

        handler = new YieldVaultLossyHandler(vault, source, usdc, treasury, address(this));

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.deposit.selector; // weight deposits
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.withdrawAssets.selector;
        selectors[4] = handler.withdrawAssets.selector; // weight the over-burn-prone path
        selectors[5] = handler.inflict.selector;
        selectors[6] = handler.setLossy.selector;
        selectors[7] = handler.setFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev SOLVENCY under loss + illiquidity: every depositor can be paid out of what the vault can actually
    ///      recover. The over-burn fix is precisely what keeps this true on partial deliveries.
    function invariant_lossy_solvent() public view {
        uint256 owed;
        uint256 n = handler.depositorsLength();
        for (uint256 i; i < n; i++) {
            owed += vault.convertToAssets(vault.balanceOf(handler.depositorsList(i)));
        }
        assertLe(owed, vault.totalAssets(), "sum(redeemable) <= totalAssets (solvent under loss/illiquidity)");
    }

    /// @dev totalAssets is exactly the idle USDC the vault holds + the source's reported (post-loss) value.
    function invariant_lossy_totalAssets_is_backed() public view {
        uint256 idle = usdc.balanceOf(address(vault));
        uint256 src = address(vault.yieldSource()) == address(0) ? 0 : vault.yieldSource().totalAssets();
        assertEq(vault.totalAssets(), idle + src, "totalAssets == idle + source assets");
    }

    /// @dev PHYSICAL CONSERVATION modulo the tracked loss sink: real USDC across all live parties + the wei
    ///      physically destroyed by inflicted losses == everything ever minted. No wei is created by any vault
    ///      operation; the ONLY destruction is an explicitly-tracked realized loss.
    function invariant_lossy_physical_usdc_conserved() public view {
        uint256 sum;
        uint256 n = handler.depositorsLength();
        for (uint256 i; i < n; i++) {
            sum += usdc.balanceOf(handler.depositorsList(i));
        }
        sum += usdc.balanceOf(address(vault));
        sum += usdc.balanceOf(address(source));
        sum += usdc.balanceOf(treasury);
        sum += usdc.balanceOf(address(handler));
        assertEq(sum + handler.ghostLost(), handler.ghostMinted(), "physical USDC + inflicted loss == minted");
    }
}
