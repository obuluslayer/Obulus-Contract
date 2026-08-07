// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {ObulusStakingVault} from "../src/ObulusStakingVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for ObulusStakingVault: stake/unstake/withdrawal-delay, the arbiter-gated bounded slash
///         (happy + every refusal path), admin-cannot-seize, and the conservation identity per action.
contract StakingVaultTest is Test {
    ObulusEscrow internal escrow;
    MockUSDC internal usdc;
    ObulusStakingVault internal vault;

    // Vault params. The vault now ENFORCES `withdrawalDelay > escrow.resolveTimeout()` (anti-evasion
    // floor), so the delay must be STRICTLY greater than RESOLVE_TIMEOUT (7 days) — not merely equal.
    uint64 internal constant WITHDRAWAL_DELAY = 7 days + 1; // > escrow dispute window (strict)
    uint16 internal constant SLASH_CAP_BPS = 2_000; // 20% of stake
    address internal vaultTreasury = makeAddr("vault-treasury");

    // ObulusEscrow params (mirror BaseTest).
    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant ARB_FEE_BPS = 2_000;
    uint64 internal constant RESOLVE_TIMEOUT = 7 days;
    uint64 internal constant DELIVER_WINDOW = 1 hours;
    uint64 internal constant CONFIRM_WINDOW = 1 days;
    uint256 internal constant PRICE = 100e6;
    uint256 internal constant BUYER_BOND = 10e6;
    uint256 internal constant SELLER_BOND = 10e6;
    bytes32 internal constant SPEC_HASH = keccak256("spec");

    address internal escrowTreasury = makeAddr("escrow-treasury");
    Vm.Wallet internal sellerW;
    address internal seller;
    address internal buyer = makeAddr("buyer");
    address internal arbiter = makeAddr("arbiter");
    address internal staker = makeAddr("staker");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        sellerW = vm.createWallet("seller");
        seller = sellerW.addr;

        usdc = new MockUSDC();
        escrow = new ObulusEscrow(address(usdc), escrowTreasury, FEE_BPS, ARB_FEE_BPS, RESOLVE_TIMEOUT);
        // The test contract is the vault owner (deployer).
        vault = new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, WITHDRAWAL_DELAY, SLASH_CAP_BPS);

        _fund(staker);
        _fund(stranger);
        _fund(buyer);
        _fund(seller);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.startPrank(a);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }

    // --- conservation helper ---------------------------------------------------------------------

    /// @dev The headline identity, asserted after each mutating action in these unit tests.
    function _assertConserved() internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.totalStaked() + vault.totalPending(),
            "vault balance == totalStaked + totalPending"
        );
    }

    // --- escrow helpers: drive a deal to Disputed so its arbiter can authorise a slash ------------

    function _defaultOffer(address buyer_, address seller_) internal view returns (IEscrow.Offer memory o) {
        o = IEscrow.Offer({
            seller: seller_,
            buyer: buyer_,
            arbiter: arbiter,
            token: address(usdc),
            price: PRICE,
            buyerBond: BUYER_BOND,
            sellerBond: SELLER_BOND,
            deliverDeadline: uint64(block.timestamp) + DELIVER_WINDOW,
            confirmWindow: CONFIRM_WINDOW,
            feeBps: FEE_BPS,
            specHash: SPEC_HASH,
            nonce: 1,
            sigDeadline: uint64(block.timestamp) + 1 days
        });
    }

    function _sign(IEscrow.Offer memory o) internal view returns (bytes memory) {
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerW.privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Fund → markDelivered → dispute, leaving the deal in `Disputed` (seller == `seller`, buyer == `buyer`).
    function _disputedDeal() internal returns (bytes32 dealId) {
        IEscrow.Offer memory o = _defaultOffer(buyer, seller);
        bytes memory sig = _sign(o);
        vm.prank(buyer);
        dealId = escrow.fund(o, sig);
        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("delivery"));
        vm.prank(buyer);
        escrow.dispute(dealId);
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Disputed));
    }

    /// @dev Drive that disputed deal all the way to Resolved (so we can prove slash refuses post-terminal).
    function _resolveDeal(bytes32 dealId, uint16 sellerBps) internal {
        vm.prank(arbiter);
        escrow.resolve(dealId, sellerBps);
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Resolved));
    }

    // =============================================================================================
    // stake / unstake / withdraw
    // =============================================================================================

    function test_stake_credits_and_pulls() public {
        vm.prank(staker);
        vault.stake(1_000e6);

        assertEq(vault.stakeOf(staker), 1_000e6);
        assertEq(vault.totalStaked(), 1_000e6);
        _assertConserved();
    }

    function test_stake_zero_reverts() public {
        vm.prank(staker);
        vm.expectRevert(ObulusStakingVault.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_stake_accumulates() public {
        vm.startPrank(staker);
        vault.stake(100e6);
        vault.stake(50e6);
        vm.stopPrank();
        assertEq(vault.stakeOf(staker), 150e6);
        _assertConserved();
    }

    function test_unstake_moves_to_pending_and_starts_delay() public {
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(400e6);
        vm.stopPrank();

        assertEq(vault.stakeOf(staker), 600e6);
        (uint256 amt, uint64 unlockAt) = vault.pendingWithdrawal(staker);
        assertEq(amt, 400e6);
        assertEq(unlockAt, uint64(block.timestamp) + WITHDRAWAL_DELAY);
        assertEq(vault.totalPending(), 400e6);
        assertEq(vault.totalStaked(), 600e6);
        _assertConserved();
    }

    function test_unstake_more_than_stake_reverts() public {
        vm.startPrank(staker);
        vault.stake(100e6);
        vm.expectRevert(ObulusStakingVault.InsufficientStake.selector);
        vault.unstake(100e6 + 1);
        vm.stopPrank();
    }

    function test_withdraw_before_delay_reverts() public {
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(1_000e6);
        // one second before unlock
        vm.warp(block.timestamp + WITHDRAWAL_DELAY - 1);
        vm.expectRevert(ObulusStakingVault.WithdrawalLocked.selector);
        vault.withdraw();
        vm.stopPrank();
    }

    function test_withdraw_after_delay_pays_out() public {
        uint256 balBefore = usdc.balanceOf(staker);
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(1_000e6);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);
        vault.withdraw();
        vm.stopPrank();

        assertEq(usdc.balanceOf(staker), balBefore, "got the staked USDC back in full");
        (uint256 amt,) = vault.pendingWithdrawal(staker);
        assertEq(amt, 0);
        assertEq(vault.totalPending(), 0);
        _assertConserved();
    }

    function test_withdraw_without_pending_reverts() public {
        vm.prank(staker);
        vm.expectRevert(ObulusStakingVault.NoPendingWithdrawal.selector);
        vault.withdraw();
    }

    function test_unstake_again_resets_clock() public {
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(300e6);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 3 days);
        vault.unstake(200e6); // re-queue → whole bucket waits a fresh full delay
        vm.stopPrank();

        (uint256 amt, uint64 unlockAt) = vault.pendingWithdrawal(staker);
        assertEq(amt, 500e6);
        assertEq(unlockAt, uint64(t0 + 3 days) + WITHDRAWAL_DELAY);
        _assertConserved();

        // One second before the *new* (reset) unlock, the whole bucket must still be locked —
        // proving the re-queue extended the clock rather than letting the early portion mature.
        vm.warp(uint256(unlockAt) - 1);
        vm.prank(staker);
        vm.expectRevert(ObulusStakingVault.WithdrawalLocked.selector);
        vault.withdraw();

        // At the new unlock it matures in full.
        vm.warp(unlockAt);
        vm.prank(staker);
        vault.withdraw();
        assertEq(vault.totalPending(), 0);
        _assertConserved();
    }

    // =============================================================================================
    // slash — happy path
    // =============================================================================================

    function test_slash_happy_arbiter_slashes_party_to_treasury() public {
        // staker is the buyer of the disputed deal (the buyer can be any address; the seller must sign).
        bytes32 dealId = _disputedDealWithBuyer(staker);

        vm.prank(staker);
        vault.stake(1_000e6);

        uint256 cap = (uint256(1_000e6) * SLASH_CAP_BPS) / 10_000; // 200e6
        uint256 treBefore = usdc.balanceOf(vaultTreasury);

        vm.prank(arbiter);
        vault.slash(dealId, staker, 1_000e6); // request more than cap → clamped to cap

        assertEq(vault.stakeOf(staker), 1_000e6 - cap);
        assertEq(vault.totalStaked(), 1_000e6 - cap);
        assertTrue(vault.slashed(dealId));
        assertEq(usdc.balanceOf(vaultTreasury), treBefore + cap, "slashed funds went to treasury");
        _assertConserved();
    }

    function test_slash_respects_requested_amount_below_cap() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.prank(staker);
        vault.stake(1_000e6);

        uint256 treBefore = usdc.balanceOf(vaultTreasury);
        vm.prank(arbiter);
        vault.slash(dealId, staker, 50e6); // below the 200e6 cap → exact amount

        assertEq(vault.stakeOf(staker), 1_000e6 - 50e6);
        assertEq(usdc.balanceOf(vaultTreasury), treBefore + 50e6);
        _assertConserved();
    }

    function test_slash_can_target_seller_party() public {
        // The SELLER is a party too. The seller must be the signing wallet, so we slash `seller` here.
        bytes32 dealId = _disputedDealWithSeller(seller);
        vm.prank(seller);
        vault.stake(500e6);

        uint256 cap = (uint256(500e6) * SLASH_CAP_BPS) / 10_000; // 100e6
        vm.prank(arbiter);
        vault.slash(dealId, seller, type(uint256).max);
        assertEq(vault.stakeOf(seller), 500e6 - cap);
        _assertConserved();
    }

    // =============================================================================================
    // slash — refusal paths
    // =============================================================================================

    function test_slash_double_refused() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.prank(staker);
        vault.stake(1_000e6);

        vm.prank(arbiter);
        vault.slash(dealId, staker, 100e6);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(ObulusStakingVault.AlreadySlashed.selector, dealId));
        vault.slash(dealId, staker, 100e6);
    }

    function test_slash_non_arbiter_refused() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.prank(staker);
        vault.stake(1_000e6);

        vm.prank(stranger);
        vm.expectRevert(ObulusStakingVault.NotDealArbiter.selector);
        vault.slash(dealId, staker, 100e6);

        // even the vault owner (this contract) is not the arbiter → cannot slash.
        vm.expectRevert(ObulusStakingVault.NotDealArbiter.selector);
        vault.slash(dealId, staker, 100e6);
    }

    function test_slash_non_party_refused() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        // `stranger` is neither buyer nor seller of the deal.
        vm.prank(stranger);
        vault.stake(1_000e6);

        vm.prank(arbiter);
        vm.expectRevert(ObulusStakingVault.NotDealParty.selector);
        vault.slash(dealId, stranger, 100e6);
    }

    function test_slash_not_disputed_refused_funded() public {
        // A deal in Funded state (never delivered/disputed) cannot authorise a slash.
        IEscrow.Offer memory o = _defaultOffer(buyer, seller);
        bytes memory sig = _sign(o);
        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig);

        // seller is a party to the deal and stakes, but the deal is only Funded → slash must refuse.
        vm.prank(seller);
        vault.stake(1_000e6);

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(ObulusStakingVault.DealNotDisputed.selector, dealId));
        vault.slash(dealId, seller, 100e6);
    }

    function test_slash_resolved_refused_no_fault_readable() public {
        // The crux: once Resolved, fault is no longer readable, and slash must refuse.
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.prank(staker);
        vault.stake(1_000e6);

        _resolveDeal(dealId, 10_000); // seller fully favored; outcome only in the event

        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(ObulusStakingVault.DealNotDisputed.selector, dealId));
        vault.slash(dealId, staker, 100e6);
        _assertConserved();
    }

    function test_slash_nonexistent_deal_refused() public {
        bytes32 ghost = keccak256("no-such-deal");
        vm.prank(arbiter);
        // state == None → not Disputed.
        vm.expectRevert(abi.encodeWithSelector(ObulusStakingVault.DealNotDisputed.selector, ghost));
        vault.slash(ghost, staker, 100e6);
    }

    function test_slash_no_stake_refused() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        // staker has NOT staked anything.
        vm.prank(arbiter);
        vm.expectRevert(ObulusStakingVault.NothingToSlash.selector);
        vault.slash(dealId, staker, 100e6);
    }

    function test_slash_zero_amount_refused() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.prank(staker);
        vault.stake(1_000e6);
        vm.prank(arbiter);
        vm.expectRevert(ObulusStakingVault.NothingToSlash.selector);
        vault.slash(dealId, staker, 0);
    }

    function test_slash_base_includes_pending_and_drains_stake_first() public {
        // ANTI-EVASION: the slashable base is stakeOf + pendingOf, and the slash drains stake FIRST, then
        // reaches into the pending bucket for the remainder. (Old behavior — capping only standing stake
        // and never touching pending — was the unstake-evasion vector; see test_slash_resists_unstake_evasion.)
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(900e6); // 100e6 standing, 900e6 queued — but ALL 1000e6 is still in the vault
        vm.stopPrank();

        // cap is 20% of the COMBINED base (1_000e6) == 200e6. Stake only holds 100e6, so 100e6 comes from
        // stake and the remaining 100e6 from the pending bucket.
        uint256 treBefore = usdc.balanceOf(vaultTreasury);
        vm.prank(arbiter);
        vault.slash(dealId, staker, type(uint256).max);

        assertEq(vault.stakeOf(staker), 0, "standing stake drained first");
        (uint256 pending,) = vault.pendingWithdrawal(staker);
        assertEq(pending, 900e6 - 100e6, "remainder of the slash came out of the pending bucket");
        assertEq(usdc.balanceOf(vaultTreasury), treBefore + 200e6, "full capped 200e6 reached the treasury");
        _assertConserved();
    }

    /// @dev Slash drawing PURELY from the pending bucket: if the staker has unstaked everything, the slash
    ///      still lands (cap over pending), proving queued funds are not a safe harbour.
    function test_slash_reaches_fully_unstaked_pending() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(1_000e6); // EVERYTHING queued; standing stake is zero
        vm.stopPrank();
        assertEq(vault.stakeOf(staker), 0);

        uint256 cap = (uint256(1_000e6) * SLASH_CAP_BPS) / 10_000; // 200e6 of the pending base
        uint256 treBefore = usdc.balanceOf(vaultTreasury);
        vm.prank(arbiter);
        vault.slash(dealId, staker, type(uint256).max);

        (uint256 pending,) = vault.pendingWithdrawal(staker);
        assertEq(pending, 1_000e6 - cap, "slash drained the cap straight out of the pending bucket");
        assertEq(usdc.balanceOf(vaultTreasury), treBefore + cap);
        _assertConserved();
    }

    // =============================================================================================
    // slash — UNSTAKE-EVASION REGRESSION (the HIGH finding)
    // =============================================================================================

    /// @dev REPLAYS the exact reported attack. A staker who is a party to a LIVE Disputed deal front-runs
    ///      the arbiter by unstaking their ENTIRE stake (stakeOf -> pendingOf) in the same window. Under the
    ///      old code this zeroed the slashable set: slash reverted NothingToSlash, and after withdrawalDelay
    ///      the attacker withdrew 100% (treasury got 0). The fix makes the slash base = stakeOf + pendingOf,
    ///      so the slash STILL lands the capped amount out of the pending bucket, and the attacker can no
    ///      longer recover their full stake. This test asserts the old PoC outcome is now impossible.
    function test_slash_resists_unstake_evasion() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);

        // Attacker stakes 1000e6 while a party to the live dispute.
        vm.prank(staker);
        vault.stake(1_000e6);

        // Front-run: drain the whole standing stake into the withdrawal queue BEFORE the arbiter acts.
        vm.prank(staker);
        vault.unstake(1_000e6);
        assertEq(vault.stakeOf(staker), 0, "attacker zeroed standing stake (the old evasion)");

        // The arbiter slashes anyway. Old code: reverts NothingToSlash. New code: lands the cap.
        uint256 cap = (uint256(1_000e6) * SLASH_CAP_BPS) / 10_000; // 200e6
        uint256 treBefore = usdc.balanceOf(vaultTreasury);
        vm.prank(arbiter);
        vault.slash(dealId, staker, type(uint256).max);

        assertEq(usdc.balanceOf(vaultTreasury), treBefore + cap, "treasury credited the capped slash");
        (uint256 pending,) = vault.pendingWithdrawal(staker);
        assertEq(pending, 1_000e6 - cap, "pending shrank by exactly the slash");
        _assertConserved();

        // Now mature the withdrawal. The attacker can only recover what survived the slash — NOT the full
        // 1000e6 the old PoC let them reclaim.
        uint256 stakerBalBefore = usdc.balanceOf(staker);
        vm.warp(block.timestamp + WITHDRAWAL_DELAY);
        vm.prank(staker);
        vault.withdraw();

        uint256 recovered = usdc.balanceOf(staker) - stakerBalBefore;
        assertEq(recovered, 1_000e6 - cap, "attacker recovered stake MINUS the slash, not the full amount");
        assertLt(recovered, 1_000e6, "old PoC (full 1000e6 recovered) is now impossible");
        _assertConserved();
    }

    /// @dev Even partial unstaking + a fresh re-stake cannot dodge the cap: the base is the full in-vault
    ///      balance regardless of how it is split between stake and pending at slash time.
    function test_slash_evasion_partial_unstake_still_capped_on_full_base() public {
        bytes32 dealId = _disputedDealWithBuyer(staker);
        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(700e6); // 300e6 standing, 700e6 queued
        vm.stopPrank();

        uint256 cap = (uint256(1_000e6) * SLASH_CAP_BPS) / 10_000; // 200e6 over the full base
        vm.prank(arbiter);
        vault.slash(dealId, staker, type(uint256).max);

        // 200e6 cap comes entirely out of the 300e6 standing stake (stake-first), pending untouched here.
        assertEq(vault.stakeOf(staker), 300e6 - cap, "cap drawn from standing stake first");
        (uint256 pending,) = vault.pendingWithdrawal(staker);
        assertEq(pending, 700e6, "pending untouched because stake covered the whole slash");
        _assertConserved();
    }

    // =============================================================================================
    // admin — params only; can NEVER seize stake
    // =============================================================================================

    function test_admin_setters_work_within_bounds() public {
        // Must stay STRICTLY above resolveTimeout (7 days) — the enforced anti-evasion floor.
        vault.setWithdrawalDelay(8 days);
        assertEq(vault.withdrawalDelay(), 8 days);
        vault.setSlashCapBps(1_000);
        assertEq(vault.slashCapBps(), 1_000);
        address t2 = makeAddr("t2");
        vault.setTreasury(t2);
        assertEq(vault.treasury(), t2);
    }

    function test_admin_setSlashCap_over_max_reverts() public {
        vm.expectRevert(ObulusStakingVault.SlashCapTooHigh.selector);
        vault.setSlashCapBps(5_001);
    }

    function test_admin_setWithdrawalDelay_over_max_reverts() public {
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooHigh.selector);
        vault.setWithdrawalDelay(91 days);
    }

    // =============================================================================================
    // ANTI-EVASION CONFIG ENFORCEMENT (the HIGH finding): withdrawalDelay MUST strictly exceed
    // escrow.resolveTimeout(), enforced in BOTH the constructor and setWithdrawalDelay().
    // =============================================================================================

    /// @dev Construction with `withdrawalDelay <= resolveTimeout` MUST revert. This is the exact misconfig
    ///      (1d delay vs 7d timeout) that the reproduced full-evasion PoC relied on; it is now impossible
    ///      to deploy. We also reject the equality boundary (7d == 7d): the dispute window can mature
    ///      strictly before a same-block withdrawal unlocks (resolveExpired uses `>`, withdraw uses `>=`),
    ///      so only a STRICTLY greater delay closes the race.
    function test_constructor_rejects_delay_below_resolveTimeout() public {
        // 1 day delay vs 7 day resolveTimeout — the reproduced evasion config.
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooShort.selector);
        new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, 1 days, SLASH_CAP_BPS);
    }

    function test_constructor_rejects_delay_equal_to_resolveTimeout() public {
        // Equality is also rejected (must be STRICTLY greater) — closes the boundary race.
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooShort.selector);
        new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, RESOLVE_TIMEOUT, SLASH_CAP_BPS);
    }

    function test_constructor_accepts_delay_one_second_above_resolveTimeout() public {
        // The minimal valid config: exactly one second above the dispute window.
        ObulusStakingVault v =
            new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, RESOLVE_TIMEOUT + 1, SLASH_CAP_BPS);
        assertEq(v.withdrawalDelay(), uint256(RESOLVE_TIMEOUT) + 1);
    }

    function test_setWithdrawalDelay_rejects_value_below_resolveTimeout() public {
        // The owner cannot lower the delay back into the evasion zone (1d vs 7d).
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooShort.selector);
        vault.setWithdrawalDelay(1 days);
    }

    function test_setWithdrawalDelay_rejects_value_equal_to_resolveTimeout() public {
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooShort.selector);
        vault.setWithdrawalDelay(RESOLVE_TIMEOUT);
    }

    /// @dev END-TO-END: the reproduced misconfig evasion (unstake-all during a live dispute, warp the
    ///      SHORT delay, withdraw 100% while still Disputed, arbiter slash hits nothing) is now
    ///      unreachable because a vault with that short delay CANNOT be constructed in the first place.
    ///      We assert the construction reverts, then prove that on a CORRECTLY configured vault the same
    ///      attack cannot withdraw before the dispute window: at resolveTimeout the funds are still locked.
    function test_misconfig_evasion_is_undeployable_and_correct_config_keeps_funds_present() public {
        // (a) The evasion config (delay 1d < resolveTimeout 7d) cannot be deployed.
        vm.expectRevert(ObulusStakingVault.WithdrawalDelayTooShort.selector);
        new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, 1 days, SLASH_CAP_BPS);

        // (b) On the correctly configured vault (delay = 7d + 1), replay the evasion choreography: a party
        //     to a live dispute unstakes everything, then tries to withdraw at the moment the dispute
        //     window itself would expire. The withdrawal is STILL locked, so the funds remain physically
        //     present and the arbiter slash lands.
        bytes32 dealId = _disputedDealWithBuyer(staker);
        uint64 disputedAt = escrow.getDeal(dealId).disputedAt;

        vm.startPrank(staker);
        vault.stake(1_000e6);
        vault.unstake(1_000e6); // drain to pending — the evasion move
        vm.stopPrank();

        // Warp to exactly the dispute window edge (disputedAt + resolveTimeout). The deal is still Disputed
        // (resolveExpired uses strict `>`), and the withdrawal is still locked (unlockAt = unstakeTs + 7d+1
        // which is strictly later). The attacker CANNOT withdraw here.
        vm.warp(uint256(disputedAt) + RESOLVE_TIMEOUT);
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Disputed), "deal still disputed at edge");
        vm.prank(staker);
        vm.expectRevert(ObulusStakingVault.WithdrawalLocked.selector);
        vault.withdraw();

        // The arbiter slash still lands on the present pending funds — evasion defeated.
        uint256 cap = (uint256(1_000e6) * SLASH_CAP_BPS) / 10_000; // 200e6
        uint256 treBefore = usdc.balanceOf(vaultTreasury);
        vm.prank(arbiter);
        vault.slash(dealId, staker, type(uint256).max);
        assertEq(usdc.balanceOf(vaultTreasury), treBefore + cap, "slash landed on still-present pending funds");
        _assertConserved();
    }

    function test_admin_setTreasury_zero_reverts() public {
        vm.expectRevert(ObulusStakingVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    function test_nonOwner_cannot_set_params() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setWithdrawalDelay(1 days);
        vm.stopPrank();
    }

    /// @dev The core safety claim: no admin action can reduce a staker's stake or pull funds out.
    function test_admin_cannot_seize_stake() public {
        vm.prank(staker);
        vault.stake(1_000e6);
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        uint256 stakeBefore = vault.stakeOf(staker);

        // Exercise every owner-only knob (delay must stay strictly above the 7-day resolveTimeout floor).
        vault.setWithdrawalDelay(8 days);
        vault.setSlashCapBps(5_000);
        vault.setTreasury(makeAddr("attacker-treasury"));

        assertEq(usdc.balanceOf(address(vault)), vaultBalBefore, "no admin action moved vault funds");
        assertEq(vault.stakeOf(staker), stakeBefore, "no admin action touched stake");
        _assertConserved();
    }

    // =============================================================================================
    // disputed-deal builders where the STAKER is a specific party
    // =============================================================================================

    /// @dev Build a disputed deal whose buyer == `b` (seller is the default signing wallet).
    function _disputedDealWithBuyer(address b) internal returns (bytes32 dealId) {
        IEscrow.Offer memory o = _defaultOffer(b, seller);
        bytes memory sig = _sign(o);
        vm.prank(b);
        dealId = escrow.fund(o, sig);
        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("delivery"));
        vm.prank(b);
        escrow.dispute(dealId);
    }

    /// @dev Build a disputed deal whose seller == `s` (a fresh wallet so it can sign). buyer is the default.
    function _disputedDealWithSeller(address s) internal returns (bytes32 dealId) {
        // `s` must be able to sign the offer; we only have the default seller wallet's key, so the
        // "seller party" case reuses the default seller wallet and stakes under that address.
        require(s == seller, "seller-party tests must use the signing seller wallet");
        IEscrow.Offer memory o = _defaultOffer(buyer, s);
        bytes memory sig = _sign(o);
        vm.prank(buyer);
        dealId = escrow.fund(o, sig);
        vm.prank(s);
        escrow.markDelivered(dealId, keccak256("delivery"));
        vm.prank(buyer);
        escrow.dispute(dealId);
    }
}
