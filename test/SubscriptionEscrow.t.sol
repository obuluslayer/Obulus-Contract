// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ObulusSubscriptionEscrow} from "../src/ObulusSubscriptionEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

contract SubscriptionEscrowTest is Test {
    ObulusSubscriptionEscrow internal sub;
    MockUSDC internal usdc;

    uint256 internal constant PERIOD_PRICE = 100e6;
    uint32 internal constant NUM = 3;
    uint256 internal constant SELLER_BOND = 150e6;
    uint256 internal constant SUB_BOND = 30e6;
    uint16 internal constant FEE_BPS = 100; // 1%
    uint16 internal constant ARB_FEE_BPS = 2_000; // 20% of the slashed bond
    uint64 internal constant RESOLVE_TIMEOUT = 7 days;
    uint64 internal constant PERIOD_LEN = 1 days;
    uint64 internal constant CHALLENGE = 1 hours;

    Vm.Wallet internal sellerW;
    address internal seller;
    address internal subscriber = makeAddr("subscriber");
    address internal arbiter = makeAddr("arbiter");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_000_000);
        sellerW = vm.createWallet("seller");
        seller = sellerW.addr;
        usdc = new MockUSDC();
        sub = new ObulusSubscriptionEscrow(address(usdc), treasury, FEE_BPS, ARB_FEE_BPS, RESOLVE_TIMEOUT);
        _fund(subscriber);
        _fund(seller);
        _fund(stranger);
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.prank(a);
        usdc.approve(address(sub), type(uint256).max);
    }

    function _offer() internal view returns (ObulusSubscriptionEscrow.SubOffer memory o) {
        o = ObulusSubscriptionEscrow.SubOffer({
            seller: seller,
            subscriber: subscriber,
            arbiter: arbiter,
            token: address(usdc),
            periodPrice: PERIOD_PRICE,
            sellerBond: SELLER_BOND,
            subscriberBond: SUB_BOND,
            numPeriods: NUM,
            periodLength: PERIOD_LEN,
            challengeWindow: CHALLENGE,
            startAt: uint64(block.timestamp),
            feeBps: FEE_BPS,
            specHash: keccak256("sub-spec"),
            nonce: 1,
            sigDeadline: uint64(block.timestamp) + 1 days
        });
    }

    function _sign(ObulusSubscriptionEscrow.SubOffer memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerW.privateKey, sub.hashSubOffer(o));
        return abi.encodePacked(r, s, v);
    }

    function _start() internal returns (bytes32 subId, ObulusSubscriptionEscrow.SubOffer memory o) {
        o = _offer();
        bytes memory sig = _sign(o); // sign BEFORE prank: _sign calls hashSubOffer (a call) which would consume the prank
        vm.prank(subscriber);
        subId = sub.start(o, sig);
    }

    function _startActivated() internal returns (bytes32 subId) {
        (subId,) = _start();
        vm.prank(seller);
        sub.activate(subId);
    }

    function _conserved(bytes32 subId) internal view {
        ObulusSubscriptionEscrow.Sub memory s = sub.getSub(subId);
        uint256 held = s.escrowedPrice + s.sellerBondRem + s.subscriberBondRem + s.depositHeld;
        uint256 creditsSum = sub.credits(subscriber) + sub.credits(seller) + sub.credits(treasury)
            + sub.credits(arbiter) + sub.credits(stranger);
        assertEq(usdc.balanceOf(address(sub)), held + creditsSum, "conservation broken");
    }

    function _claimableAt(ObulusSubscriptionEscrow.SubOffer memory o, uint256 p) internal pure returns (uint256) {
        return uint256(o.startAt) + (p + 1) * o.periodLength + o.challengeWindow;
    }

    // -------------------------------------------------------------------------------------------

    function test_start_pullsPrepaidAndBond() public {
        uint256 before = usdc.balanceOf(subscriber);
        (bytes32 subId,) = _start();
        assertEq(usdc.balanceOf(subscriber), before - (NUM * PERIOD_PRICE + SUB_BOND));
        ObulusSubscriptionEscrow.Sub memory s = sub.getSub(subId);
        assertEq(s.escrowedPrice, NUM * PERIOD_PRICE);
        assertEq(s.subscriberBondRem, SUB_BOND);
        assertEq(uint8(s.state), uint8(ObulusSubscriptionEscrow.State.Active));
        assertFalse(s.activated);
        _conserved(subId);
    }

    function test_happyPath_multiPeriod() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        _conserved(subId);
        for (uint256 p = 0; p < NUM; p++) {
            vm.warp(_claimableAt(o, p) + 1);
            sub.claimPeriod(subId);
            _conserved(subId);
        }
        // the last claim auto-closes the sub (bonds returned)
        _conserved(subId);

        uint256 fee = (PERIOD_PRICE * FEE_BPS) / 10_000;
        assertEq(sub.credits(seller), NUM * (PERIOD_PRICE - fee) + SELLER_BOND);
        assertEq(sub.credits(subscriber), SUB_BOND);
        assertEq(sub.credits(treasury), NUM * fee);
        assertEq(uint8(sub.getSub(subId).state), uint8(ObulusSubscriptionEscrow.State.Closed));
    }

    /// The structural fix: a dispute on period 0 must NOT block claiming period 1.
    function test_disputeDoesNotBlockLaterPeriods() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();

        // dispute period 0 (cursor advances to 1; period 0 set aside)
        vm.warp(o.startAt + 10);
        vm.prank(subscriber);
        sub.disputePeriod(subId);
        assertEq(sub.pendingDisputes(subId), 1);
        assertEq(sub.getSub(subId).cursor, 1);

        // period 1 matures and is claimable EVEN THOUGH period 0 is still disputed
        vm.warp(_claimableAt(o, 1) + 1);
        sub.claimPeriod(subId);
        _conserved(subId);
        ObulusSubscriptionEscrow.Sub memory s1 = sub.getSub(subId);
        assertEq(s1.settledCount, 1); // period 1 claimed; the dispute is not yet settled
        assertEq(s1.cursor, 2);
        assertEq(sub.credits(seller), PERIOD_PRICE - (PERIOD_PRICE * FEE_BPS) / 10_000);

        // resolve the set-aside period 0 independently
        vm.prank(arbiter);
        sub.resolvePeriod(subId, 0, 5_000);
        _conserved(subId);
        assertEq(sub.pendingDisputes(subId), 0);
        assertEq(sub.getSub(subId).settledCount, 2);
    }

    function test_dispute_sellerFault_slashesSellerBond() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(o.startAt + 10);
        vm.prank(subscriber);
        sub.disputePeriod(subId);

        uint16 sellerBps = 2_000;
        vm.prank(arbiter);
        sub.resolvePeriod(subId, 0, sellerBps);
        _conserved(subId);

        uint256 sellerPrice = (PERIOD_PRICE * sellerBps) / 10_000;
        uint256 buyerPrice = PERIOD_PRICE - sellerPrice;
        uint256 fee = (sellerPrice * FEE_BPS) / 10_000;
        uint256 cap = SELLER_BOND / NUM;
        uint256 arbFee = (cap * ARB_FEE_BPS) / 10_000;

        assertEq(sub.credits(seller), sellerPrice - fee);
        assertEq(sub.credits(subscriber), buyerPrice + (cap - arbFee) + PERIOD_PRICE); // + refunded dispute deposit
        assertEq(sub.credits(arbiter), arbFee);
        assertEq(sub.credits(treasury), fee);
        ObulusSubscriptionEscrow.Sub memory s = sub.getSub(subId);
        assertEq(s.sellerBondRem, SELLER_BOND - cap);
        assertEq(s.settledCount, 1);
        assertEq(sub.pendingDisputes(subId), 0);
    }

    function test_dispute_subscriberFault_slashesSubscriberBond() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(o.startAt + 10);
        vm.prank(subscriber);
        sub.disputePeriod(subId);
        vm.prank(arbiter);
        sub.resolvePeriod(subId, 0, 8_000);
        _conserved(subId);
        assertEq(sub.getSub(subId).subscriberBondRem, SUB_BOND - SUB_BOND / NUM);
        // frivolous dispute → seller gets: price share + slashed-bond compensation + forfeited deposit
        uint256 sellerPrice = (PERIOD_PRICE * 8_000) / 10_000;
        uint256 fee = (sellerPrice * FEE_BPS) / 10_000;
        uint256 cap = SUB_BOND / NUM;
        uint256 arbFee = (cap * ARB_FEE_BPS) / 10_000;
        assertEq(sub.credits(seller), (sellerPrice - fee) + (cap - arbFee) + PERIOD_PRICE);
        assertEq(sub.getSub(subId).depositHeld, 0);
    }

    function test_resolvePeriodExpired_neutralSplit() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(o.startAt + 10);
        vm.prank(subscriber);
        sub.disputePeriod(subId);

        vm.warp(block.timestamp + RESOLVE_TIMEOUT + 1);
        sub.resolvePeriodExpired(subId, 0);
        _conserved(subId);

        assertEq(sub.credits(seller), PERIOD_PRICE / 2);
        assertEq(sub.credits(subscriber), (PERIOD_PRICE - PERIOD_PRICE / 2) + PERIOD_PRICE); // half + refunded deposit
        assertEq(sub.getSub(subId).settledCount, 1);
        assertEq(sub.pendingDisputes(subId), 0);
    }

    function test_revoke_refundsUnconsumedAndBonds() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(_claimableAt(o, 0) + 1);
        sub.claimPeriod(subId);

        vm.prank(subscriber);
        sub.revoke(subId);
        _conserved(subId);

        assertEq(sub.credits(subscriber), (NUM - 1) * PERIOD_PRICE + SUB_BOND);
        assertEq(sub.credits(seller), (PERIOD_PRICE - (PERIOD_PRICE * FEE_BPS) / 10_000) + SELLER_BOND);
        assertEq(uint8(sub.getSub(subId).state), uint8(ObulusSubscriptionEscrow.State.Closed));
    }

    function test_revoke_beforeActivate_fullRefundNoSellerBond() public {
        (bytes32 subId,) = _start();
        vm.prank(subscriber);
        sub.revoke(subId);
        _conserved(subId);
        assertEq(sub.credits(subscriber), NUM * PERIOD_PRICE + SUB_BOND);
        assertEq(sub.credits(seller), 0);
    }

    /// Critical-fix regression: revoke cannot claw back already-served periods from the seller.
    function test_revoke_paysSellerForServedPeriods() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(uint256(o.startAt) + 2 * o.periodLength + 1); // periods 0,1 fully served, unclaimed
        vm.prank(subscriber);
        sub.revoke(subId);
        _conserved(subId);

        uint256 fee = (PERIOD_PRICE * FEE_BPS) / 10_000;
        assertEq(sub.credits(seller), 2 * (PERIOD_PRICE - fee) + SELLER_BOND);
        assertEq(sub.credits(subscriber), PERIOD_PRICE + SUB_BOND);
        assertEq(sub.credits(treasury), 2 * fee);
    }

    /// Revoke while a period is set aside under dispute: revoke settles the rest, bonds wait for close.
    function test_revoke_withPendingDispute_closesAfterResolve() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(o.startAt + 10);
        vm.prank(subscriber);
        sub.disputePeriod(subId); // period 0 set aside, cursor=1

        vm.prank(subscriber);
        sub.revoke(subId); // settles periods 1,2 (future → refund); period 0 still pending
        _conserved(subId);
        assertEq(uint8(sub.getSub(subId).state), uint8(ObulusSubscriptionEscrow.State.Active)); // not closed yet
        assertEq(sub.pendingDisputes(subId), 1);

        // close must wait for the pending dispute
        vm.expectRevert(ObulusSubscriptionEscrow.DisputesPending.selector);
        sub.close(subId);

        vm.prank(arbiter);
        sub.resolvePeriod(subId, 0, 5_000); // settles the last pending period → auto-closes
        _conserved(subId);
        assertEq(uint8(sub.getSub(subId).state), uint8(ObulusSubscriptionEscrow.State.Closed));
    }

    /// C1 fix: funds can never be frozen by mutual inactivity — anyone can expire the sub after the grace.
    function test_expireSub_permissionlessAfterTimeout() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        // both parties vanish; warp past the hard end (all periods + challenge + resolveTimeout grace)
        vm.warp(uint256(o.startAt) + NUM * o.periodLength + o.challengeWindow + RESOLVE_TIMEOUT + 1);
        vm.prank(stranger); // a third party rescues the funds
        sub.expireSub(subId);
        _conserved(subId);

        uint256 fee = (PERIOD_PRICE * FEE_BPS) / 10_000;
        assertEq(sub.credits(seller), NUM * (PERIOD_PRICE - fee) + SELLER_BOND);
        assertEq(sub.credits(subscriber), SUB_BOND);
        assertEq(sub.credits(treasury), NUM * fee);
        assertEq(uint8(sub.getSub(subId).state), uint8(ObulusSubscriptionEscrow.State.Closed));
    }

    function test_expireSub_beforeTimeout_reverts() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(uint256(o.startAt) + NUM * o.periodLength + o.challengeWindow + 1); // before the grace
        vm.expectRevert(ObulusSubscriptionEscrow.DeadlineNotReached.selector);
        sub.expireSub(subId);
    }

    function test_boundedSlash_neverExceedsBond() public {
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        o.numPeriods = 2;
        o.sellerBond = 10e6; // cap = 5e6 per period
        bytes memory sig = _sign(o);
        vm.prank(subscriber);
        bytes32 subId = sub.start(o, sig);
        vm.prank(seller);
        sub.activate(subId);

        for (uint256 p = 0; p < 2; p++) {
            vm.warp(uint256(o.startAt) + p * o.periodLength + 10);
            vm.prank(subscriber);
            sub.disputePeriod(subId);
            vm.prank(arbiter);
            sub.resolvePeriod(subId, uint32(p), 0); // fully seller-fault
            _conserved(subId);
        }
        ObulusSubscriptionEscrow.Sub memory s = sub.getSub(subId);
        assertEq(s.sellerBondRem, 0);
        assertEq(s.settledCount, 2);
    }

    function test_accessControl() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(o.startAt + 10);

        vm.prank(stranger);
        vm.expectRevert(ObulusSubscriptionEscrow.NotSubscriber.selector);
        sub.disputePeriod(subId);

        vm.prank(subscriber);
        sub.disputePeriod(subId);

        vm.prank(stranger);
        vm.expectRevert(ObulusSubscriptionEscrow.NotArbiter.selector);
        sub.resolvePeriod(subId, 0, 5_000);
    }

    function test_claimBeforeWindow_reverts() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(_claimableAt(o, 0) - 5);
        vm.expectRevert(ObulusSubscriptionEscrow.PeriodNotElapsed.selector);
        sub.claimPeriod(subId);
    }

    function test_rejectsBondSmallerThanNumPeriods() public {
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        o.sellerBond = uint256(NUM) - 1; // non-zero but < numPeriods → unslashable
        bytes memory sig = _sign(o);
        vm.prank(subscriber);
        vm.expectRevert(ObulusSubscriptionEscrow.InvalidParams.selector);
        sub.start(o, sig);
    }

    function test_withdraw() public {
        bytes32 subId = _startActivated();
        ObulusSubscriptionEscrow.SubOffer memory o = _offer();
        vm.warp(_claimableAt(o, 0) + 1);
        sub.claimPeriod(subId);
        uint256 bal = usdc.balanceOf(seller);
        uint256 credit = sub.credits(seller);
        vm.prank(seller);
        sub.withdraw();
        assertEq(usdc.balanceOf(seller), bal + credit);
        assertEq(sub.credits(seller), 0);
    }
}
