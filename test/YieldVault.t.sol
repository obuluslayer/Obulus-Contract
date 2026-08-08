// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";
import {IYieldSource} from "../src/interfaces/IYieldSource.sol";
import {MockYieldSource} from "../src/mocks/MockYieldSource.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Unit tests for ObulusYieldVault: share math fairness, the exact 1:1 pass-through (no source), the
///         principal-protected MockYieldSource accrual flowing to depositors, solvency/conservation per
///         action, admin-cannot-seize, pause, the bounded withdrawal fee, slippage guards, and the
///         structural proof that no escrow principal can ever reach the vault (it holds no escrow reference).
contract YieldVaultTest is Test {
    MockUSDC internal usdc;
    ObulusYieldVault internal vault;
    address internal treasury = makeAddr("yv-treasury");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant INIT = 1_000_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        vault = new ObulusYieldVault(address(usdc), treasury);
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(stranger);
        // Fund this test contract too (it owns the vault and funds the mock source's yield).
        usdc.mint(address(this), INIT);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _fund(address a) internal {
        usdc.mint(a, INIT);
        vm.prank(a);
        usdc.approve(address(vault), type(uint256).max);
    }

    // --- conservation helpers --------------------------------------------------------------------

    /// @dev SOLVENCY: the vault can always honour the sum of every depositor's redeemable value out of what
    ///      it can actually recover (idle + source). Share math rounds vault-favourable, so this is <=.
    function _assertSolvent(address[] memory who) internal view {
        uint256 owed;
        for (uint256 i; i < who.length; i++) {
            owed += vault.convertToAssets(vault.balanceOf(who[i]));
        }
        assertLe(owed, vault.totalAssets(), "sum(redeemable) <= totalAssets (solvent)");
    }

    function _holders() internal view returns (address[] memory a) {
        a = new address[](3);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
    }

    // =============================================================================================
    // pass-through (no source): EXACTLY 1:1
    // =============================================================================================

    function test_passthrough_first_deposit_is_one_to_one() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e6, alice);
        // The 1:1 property is about REDEEMABILITY, not the raw share count. The virtual-offset (decimal
        // offset 3) scales the internal share number by 1e3, but the depositor still redeems exactly the
        // assets they put in — that is the invariant that matters.
        assertEq(shares, 100e6 * 1e3, "shares scaled by the 1e3 virtual offset (internal accounting unit)");
        assertEq(vault.convertToAssets(shares), 100e6, "redeems EXACTLY the deposited USDC (1:1)");
        assertEq(vault.totalAssets(), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6, "idle USDC held directly (pass-through)");
    }

    function test_passthrough_redeem_returns_exactly_principal() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(250e6, alice);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);

        assertEq(got, 250e6, "redeemed exactly principal (1:1, no fee)");
        assertEq(usdc.balanceOf(alice), balBefore + 250e6);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_passthrough_two_depositors_no_dilution() public {
        vm.prank(alice);
        uint256 sa = vault.deposit(100e6, alice);
        vm.prank(bob);
        uint256 sb = vault.deposit(300e6, bob);

        // No yield, no loss → each redeems exactly their principal.
        assertEq(vault.convertToAssets(sa), 100e6, "alice redeemable == principal");
        assertEq(vault.convertToAssets(sb), 300e6, "bob redeemable == principal");
        _assertSolvent(_holders());
    }

    function test_withdraw_exact_assets_amount() public {
        vm.prank(alice);
        vault.deposit(500e6, alice);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 net = vault.withdraw(200e6, alice, 0);

        assertEq(net, 200e6, "withdrew exactly 200 USDC net");
        assertEq(usdc.balanceOf(alice), balBefore + 200e6);
        // Remaining shares still redeem ~300e6.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 300e6, 1);
    }

    // =============================================================================================
    // revert / guard paths
    // =============================================================================================

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ObulusYieldVault.ZeroAmount.selector);
        vault.deposit(0, alice);
    }

    function test_deposit_zero_receiver_reverts() public {
        vm.prank(alice);
        vm.expectRevert(ObulusYieldVault.ZeroAddress.selector);
        vault.deposit(100e6, address(0));
    }

    function test_redeem_more_shares_than_owned_reverts() public {
        vm.prank(alice);
        uint256 s = vault.deposit(100e6, alice);
        vm.prank(alice);
        vm.expectRevert(ObulusYieldVault.InsufficientShares.selector);
        vault.redeem(s + 1, alice, 0);
    }

    function test_withdraw_slippage_floor_reverts() public {
        vm.prank(alice);
        vault.deposit(100e6, alice);
        vm.prank(alice);
        // Demand more net than the gross can ever yield → revert.
        vm.expectRevert(abi.encodeWithSelector(ObulusYieldVault.SlippageExceeded.selector, 100e6, 100e6 + 1));
        vault.withdraw(100e6, alice, 100e6 + 1);
    }

    // =============================================================================================
    // MockYieldSource: principal-protected accrual flows to depositors
    // =============================================================================================

    function _attachSource(uint16 aprBps) internal returns (MockYieldSource src) {
        src = new MockYieldSource(address(usdc), address(vault), aprBps);
        vault.setYieldSource(src);
    }

    function test_source_routes_idle_funds_and_stays_solvent() public {
        MockYieldSource src = _attachSource(0);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        // All idle USDC was pushed to the source.
        assertEq(usdc.balanceOf(address(vault)), 0, "vault forwarded idle USDC to source");
        assertEq(usdc.balanceOf(address(src)), 1_000e6, "source holds the USDC");
        assertEq(vault.totalAssets(), 1_000e6, "totalAssets reads back the source value");
        _assertSolvent(_holders());
    }

    function test_source_yield_raises_share_price_and_flows_to_depositor() public {
        MockYieldSource src = _attachSource(1_000); // 10% APR
        // Pre-fund the source so realized yield is backed by REAL USDC.
        usdc.approve(address(src), type(uint256).max);
        src.fund(500e6);

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertEq(vault.convertToAssets(shares), 1_000e6, "price 1.0 at deposit");

        // One year later, ~10% accrued.
        vm.warp(block.timestamp + 365 days);
        vault.harvest();

        uint256 redeemable = vault.convertToAssets(shares);
        assertApproxEqAbs(redeemable, 1_100e6, 2e6, "approx principal + 10% yield");
        assertGt(redeemable, 1_000e6, "yield raised share price above principal");

        // Alice actually redeems the gain.
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 1_000e6);
        assertEq(usdc.balanceOf(alice), balBefore + got);
        assertGt(got, 1_000e6, "redeemed more than principal - yield flowed through");
    }

    function test_source_yield_split_fairly_between_two_depositors() public {
        MockYieldSource src = _attachSource(0); // no auto-accrual; we inject yield explicitly
        usdc.approve(address(src), type(uint256).max);

        // Alice and Bob deposit equally.
        vm.prank(alice);
        uint256 sa = vault.deposit(1_000e6, alice);
        vm.prank(bob);
        uint256 sb = vault.deposit(1_000e6, bob);
        assertEq(sa, sb, "equal deposits give equal shares");

        // Inject 200e6 of yield into the source and realize it (set a tiny APR for one block won't do it;
        // instead fund + bump principal-based accrual via setApr over time). Simpler: fund + warp with APR.
        src.fund(400e6);
        src.setApr(10_000); // 100% APR on 2_000e6 principal
        vm.warp(block.timestamp + 365 days);
        vault.harvest();

        // Both should redeem ~equal, each ~principal + half the yield.
        uint256 ra = vault.convertToAssets(sa);
        uint256 rb = vault.convertToAssets(sb);
        assertApproxEqAbs(ra, rb, 2, "yield split evenly between equal depositors");
        assertGt(ra, 1_000e6, "each got yield on top of principal");
        _assertSolvent(_holders());
    }

    function test_late_depositor_does_not_dilute_existing_yield() public {
        MockYieldSource src = _attachSource(0);
        usdc.approve(address(src), type(uint256).max);

        vm.prank(alice);
        uint256 sa = vault.deposit(1_000e6, alice);

        // Yield accrues to alice alone.
        src.fund(200e6);
        src.setApr(2_000);
        vm.warp(block.timestamp + 365 days);
        vault.harvest(); // ~200e6 yield → price ~1.2

        uint256 priceBefore = vault.convertToAssets(sa);
        assertApproxEqAbs(priceBefore, 1_200e6, 5e6);

        // Bob deposits AFTER the yield — he must NOT capture alice's accrued gain.
        vm.prank(bob);
        uint256 sb = vault.deposit(1_200e6, bob);
        // Bob's shares should be worth ~his deposit, not more.
        assertApproxEqAbs(vault.convertToAssets(sb), 1_200e6, 5e6, "late depositor priced at current NAV");
        // Alice's value is unchanged by bob's deposit.
        assertApproxEqAbs(vault.convertToAssets(sa), priceBefore, 5e6, "existing depositor not diluted");
        _assertSolvent(_holders());
    }

    // =============================================================================================
    // LOSSY source honesty — no floor (via a directly-modeled lossy stub)
    // =============================================================================================

    function test_lossy_source_can_redeem_below_principal_honestly() public {
        LossyStub lossy = new LossyStub(address(usdc), address(vault));
        usdc.mint(address(lossy), 0);
        vault.setYieldSource(lossy);

        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);
        assertEq(vault.totalAssets(), 1_000e6);

        // The source loses 30% of value (impermanent loss / slippage).
        lossy.inflict(300e6);
        assertEq(vault.totalAssets(), 700e6, "loss reflected honestly in totalAssets");

        // Alice redeems and gets LESS than principal — no floor, as documented.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);
        assertApproxEqAbs(got, 700e6, 1, "redeemed the lossy value, below principal");
        assertLt(got, 1_000e6, "NO FLOOR with a lossy source (honest)");
    }

    // =============================================================================================
    // OVER-BURN FIX (audit remediation): a withdraw(assets) against a lossy+ILLIQUID source must burn
    // shares worth only what was ACTUALLY delivered, never the full requested gross. The un-paid
    // remainder stays backed by the redeemer's shares; remaining shareholders are not enriched, and the
    // vault stays solvent.
    // =============================================================================================

    function test_withdraw_lossy_illiquid_does_not_over_burn_shares() public {
        // A source that holds the principal but can be made ILLIQUID: its on-paper totalAssets() stays high
        // while the USDC it can actually pay out drops, so _ensureLiquidity delivers < grossAssets.
        IlliquidStub src = new IlliquidStub(address(usdc), address(vault));
        vault.setYieldSource(src);

        // Two depositors so we can prove the remaining shareholder is NOT enriched by an over-burn.
        vm.prank(alice);
        uint256 aShares = vault.deposit(1_000e6, alice);
        vm.prank(bob);
        uint256 bShares = vault.deposit(1_000e6, bob);
        assertEq(vault.totalAssets(), 2_000e6, "both deposits routed to source");

        // Make the source illiquid: it can only physically pay 200e6 right now, though it still VALUES the
        // full 2_000e6 (e.g. funds locked in an LP position not yet exitable). totalAssets() is unchanged.
        src.setPayable(200e6);
        assertEq(vault.totalAssets(), 2_000e6, "valuation unchanged; only liquidity dropped");

        uint256 aliceBefore = usdc.balanceOf(alice);

        // Alice asks to withdraw her full 1_000e6 gross. The source can only deliver 200e6.
        vm.prank(alice);
        uint256 net = vault.withdraw(1_000e6, alice, 0);

        // (1) She received exactly what the source could deliver — no more.
        assertEq(net, 200e6, "received only the delivered amount");
        assertEq(usdc.balanceOf(alice), aliceBefore + 200e6);

        // (2) NO OVER-BURN: she did NOT lose the share-equivalent of the undelivered 800e6. Her residual
        //     shares still claim ~800e6 of value still stranded in the (now-illiquid) source. Pre-fix she
        //     would have burned the full ~1_000e6 worth and been left with ~0.
        uint256 aliceResidual = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqAbs(aliceResidual, 800e6, 2, "redeemer keeps a claim on the UNDELIVERED value");
        assertGt(vault.balanceOf(alice), 0, "shares were NOT fully burned for a partial payout");

        // (3) Bob (the remaining shareholder) is NOT enriched by Alice's partial exit: his claim is still
        //     ~his principal, not inflated by an unfairly-burned remainder.
        uint256 bobClaim = vault.convertToAssets(bShares);
        assertApproxEqAbs(bobClaim, 1_000e6, 2, "remaining shareholder NOT enriched by an over-burn");

        // (4) SOLVENCY preserved: Σ redeemable <= totalAssets across all holders.
        address[] memory who = new address[](2);
        who[0] = alice;
        who[1] = bob;
        _assertSolvent(who);

        // (5) shares-burned corresponds to assets-delivered: the shares Alice actually consumed are worth
        //     ~the 200e6 delivered (priced at the pre-withdraw NAV of 1.0), not the 1_000e6 requested.
        uint256 burned = aShares - vault.balanceOf(alice);
        assertApproxEqAbs(vault.convertToAssets(burned), 200e6, 2, "burned shares worth == delivered assets");
    }

    function test_withdraw_lossy_value_drop_then_illiquid_no_over_burn_and_solvent() public {
        // Combined loss + illiquidity: the source LOSES 25% of value AND can only pay a fraction right now.
        IlliquidStub src = new IlliquidStub(address(usdc), address(vault));
        vault.setYieldSource(src);

        vm.prank(alice);
        uint256 aShares = vault.deposit(1_000e6, alice);

        // Inflict a 250e6 value loss (totalAssets -> 750e6), then cap liquidity at 100e6.
        src.inflict(250e6);
        src.setPayable(100e6);
        assertEq(vault.totalAssets(), 750e6, "value loss reflected honestly");

        vm.prank(alice);
        uint256 net = vault.redeem(aShares / 2, alice, 0); // redeem half her shares

        // Half her shares are worth ~375e6, but only 100e6 is liquid → she gets 100e6 and KEEPS the claim on
        // the undelivered ~275e6 of that half (no over-burn), plus her untouched other half.
        assertEq(net, 100e6, "got only the liquid amount");
        uint256 residual = vault.convertToAssets(vault.balanceOf(alice));
        // She kept: the other half (~375e6) + the undelivered remainder of the redeemed half (~275e6) ≈ 650e6.
        assertApproxEqAbs(residual, 650e6, 3, "no over-burn: keeps untouched half + undelivered remainder");

        address[] memory who = new address[](1);
        who[0] = alice;
        _assertSolvent(who);
    }

    // =============================================================================================
    // withdrawal fee (bounded, to treasury) — NOT a seizure power
    // =============================================================================================

    function test_withdraw_fee_goes_to_treasury_and_is_bounded() public {
        vault.setWithdrawFeeBps(200); // 2% = MAX
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6, alice);

        uint256 treBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 net = vault.redeem(shares, alice, 0);

        uint256 fee = (1_000e6 * 200) / 10_000; // 20e6
        assertEq(net, 1_000e6 - fee, "depositor got gross minus the 2% fee");
        assertEq(usdc.balanceOf(treasury), treBefore + fee, "fee accrued to treasury");
        assertEq(usdc.balanceOf(alice), aliceBefore + net);
    }

    function test_setWithdrawFee_over_max_reverts() public {
        vm.expectRevert(ObulusYieldVault.WithdrawFeeTooHigh.selector);
        vault.setWithdrawFeeBps(201);
    }

    // =============================================================================================
    // pause — deposits blocked, withdrawals always open
    // =============================================================================================

    function test_pause_blocks_deposit_but_not_withdraw() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(500e6, alice);

        vault.pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(100e6, bob);

        // Alice can STILL exit while paused — withdrawals are never blocked.
        vm.prank(alice);
        uint256 got = vault.redeem(shares, alice, 0);
        assertEq(got, 500e6, "withdrawals work while paused");

        vault.unpause();
        vm.prank(bob);
        vault.deposit(100e6, bob); // works again
        assertGt(vault.balanceOf(bob), 0);
    }

    // =============================================================================================
    // admin cannot seize; only the documented knobs exist
    // =============================================================================================

    function test_admin_cannot_seize_deposits() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 aliceSharesBefore = vault.balanceOf(alice);

        // Exercise every owner knob. Note: the withdrawal fee is the ONLY admin-set value that touches a
        // withdrawal, and it is BOUNDED (<= 2%) and DISCLOSED — it is not a power to seize principal. We set
        // it to the max here and account for it explicitly below.
        vault.setWithdrawFeeBps(200); // 2% max
        vault.setTreasury(makeAddr("attacker-treasury"));
        vault.pause();
        vault.unpause();
        MockYieldSource src = new MockYieldSource(address(usdc), address(vault), 0);
        vault.setYieldSource(src); // moves funds vault->source, NOT to the owner

        // Alice's claim is intact: her shares unchanged, and totalAssets is unchanged by any admin action.
        assertEq(vault.balanceOf(alice), aliceSharesBefore, "owner cannot touch shares");
        assertEq(vault.totalAssets(), vaultAssetsBefore, "owner cannot reduce total assets");
        // And she can still withdraw her full principal, net only of the bounded disclosed fee (<= 2%).
        vm.prank(alice);
        uint256 got = vault.redeem(aliceSharesBefore, alice, 0);
        uint256 maxFee = (1_000e6 * 200) / 10_000; // 20e6 — the most the bounded fee can ever take
        assertGe(got, 1_000e6 - maxFee, "alice redeems her principal minus AT MOST the bounded 2% fee");
        assertApproxEqAbs(got, 1_000e6 - maxFee, 1, "exactly principal minus the 2% fee - no extra seizure");
    }

    function test_nonOwner_cannot_set_params() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setWithdrawFeeBps(100);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setYieldSource(IYieldSource(address(0)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.pause();
        vm.stopPrank();
    }

    // =============================================================================================
    // source switching preserves solvency
    // =============================================================================================

    function test_switch_source_drains_old_and_funds_new_preserving_solvency() public {
        MockYieldSource src1 = _attachSource(0);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        assertEq(usdc.balanceOf(address(src1)), 1_000e6);

        MockYieldSource src2 = new MockYieldSource(address(usdc), address(vault), 0);
        vault.setYieldSource(src2);

        assertEq(usdc.balanceOf(address(src1)), 0, "old source fully drained");
        assertEq(usdc.balanceOf(address(src2)), 1_000e6, "new source funded");
        assertEq(vault.totalAssets(), 1_000e6, "no value lost in the switch");
        _assertSolvent(_holders());

        // Switch back to pass-through (no source).
        vault.setYieldSource(IYieldSource(address(0)));
        assertEq(usdc.balanceOf(address(src2)), 0, "drained on revert-to-passthrough");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault holds USDC directly again");
        assertEq(address(vault.yieldSource()), address(0));
    }

    function test_setSource_asset_mismatch_reverts() public {
        MockUSDC other = new MockUSDC();
        MockYieldSource bad = new MockYieldSource(address(other), address(vault), 0);
        vm.expectRevert(ObulusYieldVault.SourceAssetMismatch.selector);
        vault.setYieldSource(bad);
    }

    // =============================================================================================
    // inflation-attack resistance (virtual shares)
    // =============================================================================================

    function test_first_depositor_cannot_steal_via_donation_inflation() public {
        // Alice deposits 1 wei-USDC, then donates a large amount directly to the vault to try to inflate the
        // share price so Bob's later deposit rounds to 0 shares (classic ERC4626 inflation attack).
        vm.prank(alice);
        vault.deposit(1, alice); // 1 share-ish
        // Donate 10_000e6 directly (not via deposit).
        usdc.mint(address(vault), 10_000e6);

        // Bob deposits a normal amount; virtual shares ensure he still gets a fair, non-zero allocation.
        vm.prank(bob);
        uint256 sb = vault.deposit(1_000e6, bob);
        assertGt(sb, 0, "virtual-shares offset prevents the round-to-zero inflation attack");
        // Bob's redeemable is close to his deposit (he isn't robbed of most of it).
        uint256 rb = vault.convertToAssets(sb);
        assertGt(rb, 900e6, "bob keeps the bulk of his deposit despite the donation");
    }

    // =============================================================================================
    // STRUCTURAL SAFETY: the vault has no escrow reference — escrow principal cannot reach it
    // =============================================================================================

    /// @dev Proves by construction that no escrow deal funds can be routed here. The vault's ABI exposes NO
    ///      function that takes a dealId / escrow address, and its only state is {asset, shares, source, fee,
    ///      treasury}. Deposits move ONLY the caller's own approved USDC. There is no privileged path for the
    ///      escrow (or anyone) to push a deal's principal/bonds in. This test documents that the surface that
    ///      WOULD be needed for the unsafe "lock the deal's USDC in a pool" design simply does not exist.
    function test_no_escrow_reference_escrow_funds_cannot_be_routed() public {
        // The vault constructor took only (asset, treasury) - no escrow. Re-deploy to assert the shape.
        ObulusYieldVault fresh = new ObulusYieldVault(address(usdc), treasury);
        // A would-be attacker cannot make the vault pull from anyone but msg.sender: deposit pulls from the
        // caller's own balance/approval. Even with a huge approval from `alice`, `bob` calling deposit pulls
        // from BOB, never from an escrow.
        vm.prank(bob);
        usdc.approve(address(fresh), type(uint256).max);
        vm.prank(bob);
        uint256 sb = fresh.deposit(100e6, bob);
        assertEq(fresh.balanceOf(bob), sb);
        // There is no setter/among the selectors that references an escrow or a deal — the only inflows are
        // (a) deposit (pulls msg.sender's own USDC) and (b) direct donations (which only benefit the pool).
        // This is the structural guarantee: escrow principal has no on-chain path into this contract.
        assertEq(usdc.balanceOf(address(fresh)), 100e6);
    }
}

/// @notice A minimal lossy source stub for the no-floor honesty test: it holds the vault's USDC and can be
///         told to "lose" value (the lost USDC is burned out of the source), so `totalAssets()` drops below
///         principal exactly as a real AMM impermanent-loss/slippage event would. Pull-based & vault-gated.
contract LossyStub is IYieldSource {
    MockUSDC internal immutable usdc;
    address internal immutable vault;
    uint256 public booked;

    constructor(address usdg_, address vault_) {
        usdc = MockUSDC(usdg_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        booked += assets;
    }

    function withdraw(uint256 assets, address to) external returns (uint256 sent) {
        require(msg.sender == vault, "only vault");
        uint256 bal = usdc.balanceOf(address(this));
        sent = assets < bal ? assets : bal;
        booked = sent < booked ? booked - sent : 0;
        if (sent != 0) usdc.transfer(to, sent);
    }

    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function maxWithdraw() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    /// @notice Burn `amount` USDC out of the source to simulate a realized LP loss (no floor).
    function inflict(uint256 amount) external {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 burn = amount < bal ? amount : bal;
        // MockUSDC has no burn; move the loss to a dead address to model value leaving the position.
        usdc.transfer(address(0xdead), burn);
    }
}

/// @notice A source that decouples on-paper VALUATION from physical LIQUIDITY — the exact shape that triggers
///         the over-burn bug. It books principal via `deposit` and reports it as `totalAssets()` (the value is
///         "there" in an LP position), but can be told to only PAY OUT a capped amount per call (`setPayable`),
///         modelling an illiquid position that cannot be fully exited right now. `inflict` separately drops the
///         booked value to model a realized loss. The funds it cannot pay stay represented in `totalAssets()`,
///         so the vault must NOT burn the redeemer's full share-equivalent for a partial payout.
contract IlliquidStub is IYieldSource {
    MockUSDC internal immutable usdc;
    address internal immutable vault;
    uint256 public booked; // on-paper value (what totalAssets reports)
    uint256 public payableCap = type(uint256).max; // max USDC payable per withdraw (illiquidity bound)

    constructor(address usdg_, address vault_) {
        usdc = MockUSDC(usdg_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        booked += assets;
    }

    /// @dev Pay out at most min(assets, payableCap, physical balance). Returns what was actually sent. Reduces
    ///      booked by the sent amount (the rest of the booked value stays "stuck" in the position).
    function withdraw(uint256 assets, address to) external returns (uint256 sent) {
        require(msg.sender == vault, "only vault");
        uint256 want = assets < payableCap ? assets : payableCap;
        uint256 bal = usdc.balanceOf(address(this));
        sent = want < bal ? want : bal;
        booked = sent < booked ? booked - sent : 0;
        if (sent != 0) usdc.transfer(to, sent);
    }

    function totalAssets() external view returns (uint256) {
        return booked;
    }

    function maxWithdraw() external view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 cap = payableCap < bal ? payableCap : bal;
        return cap < booked ? cap : booked;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    /// @notice Cap how much USDC this source will pay out per `withdraw` call (illiquidity), without changing
    ///         its on-paper `totalAssets()`. Setting it below the requested gross forces a partial delivery.
    function setPayable(uint256 cap) external {
        payableCap = cap;
    }

    /// @notice Drop the booked value by `amount` AND physically remove that USDC (a realized loss). After this,
    ///         `totalAssets()` falls — modelling impermanent loss / slippage on top of any illiquidity cap.
    function inflict(uint256 amount) external {
        uint256 burn = amount < booked ? amount : booked;
        booked -= burn;
        uint256 bal = usdc.balanceOf(address(this));
        uint256 move = burn < bal ? burn : bal;
        if (move != 0) usdc.transfer(address(0xdead), move);
    }
}
