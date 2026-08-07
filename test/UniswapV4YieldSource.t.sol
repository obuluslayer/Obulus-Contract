// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";
import {IYieldSource} from "../src/interfaces/IYieldSource.sol";
import {UniswapV4YieldSource} from "../src/yield/UniswapV4YieldSource.sol";
import {MockPoolManager} from "../src/mocks/MockPoolManager.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {PoolKey, Currency, IHooks} from "../src/yield/IPoolManagerMinimal.sol";

/// @notice Exercises the GENUINE-shape Uniswap v4 LP adapter against the MockPoolManager: the unlock →
///         modifyLiquidity → settle/take flow on deposit, fee harvesting raising share price, partial/illiquid
///         withdrawals returning the ACTUAL amount, and the NO-FLOOR honesty of a lossy position. Plus a full
///         end-to-end wiring of the adapter as a live ObulusYieldVault source so depositors transparently earn the
///         simulated LP fees through share price.
contract UniswapV4YieldSourceTest is Test {
    MockUSDC internal usdc;
    MockPoolManager internal manager;
    ObulusYieldVault internal vault;
    UniswapV4YieldSource internal source;

    address internal treasury = makeAddr("v4-treasury");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
        manager = new MockPoolManager(address(usdc));
        vault = new ObulusYieldVault(address(usdc), treasury);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        source =
            new UniswapV4YieldSource(address(usdc), address(manager), address(vault), key, -887220, 887220, true);
        vault.setYieldSource(source);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // Fund the test contract so it can inject fees / pre-fund the manager.
        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(manager), type(uint256).max);
    }

    function test_deposit_LPs_into_v4_via_unlock_flow() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // The adapter LP'd the USDC into the manager (single-sided model): the manager holds the USDC and the
        // adapter's recorded liquidity equals the deposit.
        assertEq(usdc.balanceOf(address(manager)), 1_000e6, "manager custodies the LP'd USDC");
        assertEq(manager.liquidityOf(address(source)), 1_000e6, "adapter position == deposit");
        assertEq(vault.totalAssets(), 1_000e6, "vault values the position at 1:1 (no fees yet)");
        assertEq(usdc.balanceOf(address(source)), 0, "adapter holds no idle USDC after LPing");
    }

    function test_harvest_collects_fees_and_raises_share_price() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertEq(vault.convertToAssets(shares), 1_000e6);

        // Simulate trading fees accruing to the adapter's position (backed by real USDC).
        manager.accrueFees(address(source), 50e6);
        assertEq(vault.totalAssets(), 1_050e6, "fees show up in totalAssets immediately (position view)");

        // Harvest realizes the fees as idle USDC in the adapter (collected via the remove(0)+fees path).
        uint256 realized = vault.harvest();
        assertEq(realized, 50e6, "harvest collected the 50e6 fees");
        assertEq(vault.totalAssets(), 1_050e6, "value unchanged by realization (moved position->idle)");

        // Share price rose: alice redeems principal + fees (vault-favourable rounding may keep <=1 wei).
        assertApproxEqAbs(vault.convertToAssets(shares), 1_050e6, 1, "share price reflects the harvested yield");
        assertLe(vault.convertToAssets(shares), 1_050e6, "never values above what's recoverable");
    }

    function test_withdraw_returns_principal_plus_fees_actually_sent() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        manager.accrueFees(address(source), 100e6); // 10% fees

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);

        // Vault-favourable rounding may leave 1 wei of dust in the vault — the depositor is never overpaid.
        assertApproxEqAbs(got, 1_100e6, 1, "redeemed principal + the LP fees (minus <=1 wei dust)");
        assertLe(got, 1_100e6, "never overpaid (rounding favours the vault)");
        assertEq(usdc.balanceOf(alice), balBefore + got);
        assertEq(vault.totalShares(), 0);
    }

    function test_lossy_position_has_NO_FLOOR_and_is_honest() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);

        // Impermanent loss / slippage: the position loses 40% of its value.
        manager.inflictLoss(address(source), 400e6);
        assertEq(vault.totalAssets(), 600e6, "loss reflected honestly (no floor)");

        // Alice redeems and gets LESS than principal — exactly the documented opt-in market risk.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);
        assertEq(got, 600e6, "redeemed the lossy value");
        assertLt(got, 1_000e6, "NO principal floor with an AMM source (as documented)");
    }

    function test_illiquid_withdraw_returns_actual_amount_not_requested() public {
        // The vault never assumes it got the full request: if the source can only pay part, the depositor
        // gets the partial amount and the share burn reflects the realized value.
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);

        // Lose half the position liquidity (illiquidity model): only 500e6 recoverable.
        manager.inflictLoss(address(source), 500e6);

        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);
        assertEq(got, 500e6, "got exactly what the position could actually pay");
        assertLt(got, 1_000e6, "vault paid the realized amount, never more than it held");
    }

    function test_only_vault_can_deposit_or_withdraw() public {
        vm.prank(alice);
        vm.expectRevert(UniswapV4YieldSource.OnlyVault.selector);
        source.deposit(100e6);

        vm.prank(alice);
        vm.expectRevert(UniswapV4YieldSource.OnlyVault.selector);
        source.withdraw(100e6, alice);
    }

    function test_adapter_constructor_rejects_asset_mismatch() public {
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0xBEEF)), // not USDC
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vm.expectRevert(UniswapV4YieldSource.AssetMismatch.selector);
        new UniswapV4YieldSource(address(usdc), address(manager), address(vault), badKey, -100, 100, true);
    }

    // =============================================================================================
    // HARD GUARD (audit remediation): the adapter is a NON-PRODUCTION test skeleton and must say so, and
    // must be impossible to construct without an explicit acknowledgement.
    // =============================================================================================

    function test_constructor_reverts_without_test_skeleton_acknowledgement() public {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(0)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        // Passing `acknowledgeTestSkeleton = false` MUST revert — this is the guard that prevents the skeleton
        // from being silently constructed and wired into a ObulusYieldVault on a real network.
        vm.expectRevert(UniswapV4YieldSource.NotProductionReady.selector);
        new UniswapV4YieldSource(address(usdc), address(manager), address(vault), key, -887220, 887220, false);
    }

    function test_adapter_is_marked_not_production_ready() public view {
        assertFalse(source.IS_PRODUCTION_READY(), "skeleton must report IS_PRODUCTION_READY == false");
        assertFalse(source.isLive(), "skeleton must report isLive() == false");
    }
}
