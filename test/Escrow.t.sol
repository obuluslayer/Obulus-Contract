// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EscrowTest is BaseTest {
    // ---------------------------------------------------------------------------------------------
    // fund
    // ---------------------------------------------------------------------------------------------

    function test_fund_createsDealAndPullsFunds() public {
        uint256 buyerBefore = usdc.balanceOf(buyer);
        (bytes32 dealId, IEscrow.Offer memory o) = _fundDefault();

        assertEq(dealId, escrow.hashOffer(o), "dealId is the offer digest");
        assertEq(usdc.balanceOf(buyer), buyerBefore - (PRICE + BUYER_BOND), "buyer debited price+bond");
        assertEq(usdc.balanceOf(address(escrow)), PRICE + BUYER_BOND, "escrow holds price+bond");

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        assertEq(uint8(d.state), uint8(IEscrow.State.Funded));
        assertEq(d.buyer, buyer);
        assertEq(d.seller, seller);
        assertEq(d.arbiter, arbiter);
        assertEq(d.price, PRICE);
        assertEq(d.feeBps, FEE_BPS);
    }

    function test_fund_openOffer_funderBecomesBuyer() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.buyer = address(0); // open offer
        bytes memory sig = _sign(sellerW.privateKey, o);

        vm.prank(stranger);
        bytes32 dealId = escrow.fund(o, sig);

        assertEq(escrow.getDeal(dealId).buyer, stranger, "open offer: funder is buyer");
    }

    function test_fund_revertsOnExpiredSig() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.sigDeadline = uint64(block.timestamp); // expires now
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.warp(block.timestamp + 1);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.OfferExpired.selector);
        escrow.fund(o, sig);
    }

    function test_fund_revertsOnPastDeliverDeadline() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.deliverDeadline = uint64(block.timestamp); // not in the future
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.InvalidDeadline.selector);
        escrow.fund(o, sig);
    }

    function test_fund_revertsOnFeeTooHigh() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.feeBps = escrow.MAX_FEE_BPS() + 1;
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.FeeTooHigh.selector);
        escrow.fund(o, sig);
    }

    function test_fund_revertsOnTokenMismatch() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.token = address(0xdead);
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.TokenMismatch.selector);
        escrow.fund(o, sig);
    }

    function test_fund_revertsWhenDealExists() public {
        (, IEscrow.Offer memory o) = _fundDefault();
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectPartialRevert(IEscrow.DealExists.selector);
        escrow.fund(o, sig);
    }

    // ---------------------------------------------------------------------------------------------
    // markDelivered
    // ---------------------------------------------------------------------------------------------

    function test_markDelivered_pullsBondAndStartsWindow() public {
        (bytes32 dealId,) = _fundDefault();
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("delivery"));

        assertEq(usdc.balanceOf(seller), sellerBefore - SELLER_BOND, "seller posted bond");
        assertEq(usdc.balanceOf(address(escrow)), PRICE + BUYER_BOND + SELLER_BOND, "escrow holds all three");

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        assertEq(uint8(d.state), uint8(IEscrow.State.Delivered));
        assertEq(d.deliveryHash, keccak256("delivery"));
        assertEq(d.deliveredAt, uint64(block.timestamp));
    }

    function test_markDelivered_onlySeller() public {
        (bytes32 dealId,) = _fundDefault();
        vm.prank(stranger);
        vm.expectRevert(IEscrow.NotSeller.selector);
        escrow.markDelivered(dealId, keccak256("x"));
    }

    function test_markDelivered_revertsAfterDeadline() public {
        (bytes32 dealId, IEscrow.Offer memory o) = _fundDefault();
        vm.warp(o.deliverDeadline + 1);
        vm.prank(seller);
        vm.expectRevert(IEscrow.DeadlinePassed.selector);
        escrow.markDelivered(dealId, keccak256("x"));
    }

    // ---------------------------------------------------------------------------------------------
    // confirm (happy path)
    // ---------------------------------------------------------------------------------------------

    function test_confirm_paysSellerReturnsBondsAccruesFee() public {
        (bytes32 dealId,) = _delivered();

        vm.prank(buyer);
        escrow.confirm(dealId);

        uint256 fee = (PRICE * FEE_BPS) / 10_000; // 1e6
        assertEq(escrow.credits(seller), (PRICE - fee) + SELLER_BOND, "seller: price-fee + own bond");
        assertEq(escrow.credits(buyer), BUYER_BOND, "buyer: bond back");
        assertEq(escrow.credits(treasury), fee, "treasury: fee");
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Resolved));

        _assertConserved();
    }

    function test_confirm_onlyBuyer() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(stranger);
        vm.expectRevert(IEscrow.NotBuyer.selector);
        escrow.confirm(dealId);
    }

    function test_withdraw_transfersAndClears() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(buyer);
        escrow.confirm(dealId);

        uint256 sellerCredit = escrow.credits(seller);
        uint256 sellerBalBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        escrow.withdraw();

        assertEq(usdc.balanceOf(seller), sellerBalBefore + sellerCredit, "seller received credit");
        assertEq(escrow.credits(seller), 0, "credit cleared");

        vm.prank(seller);
        vm.expectRevert(IEscrow.NothingToWithdraw.selector);
        escrow.withdraw();
    }

    // ---------------------------------------------------------------------------------------------
    // claimTimeout
    // ---------------------------------------------------------------------------------------------

    function test_claimTimeout_permissionlessAfterWindow() public {
        (bytes32 dealId,) = _delivered();
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        vm.warp(uint256(d.deliveredAt) + d.confirmWindow + 1);

        // Anyone can call.
        vm.prank(stranger);
        escrow.claimTimeout(dealId);

        uint256 fee = (PRICE * FEE_BPS) / 10_000;
        assertEq(escrow.credits(seller), (PRICE - fee) + SELLER_BOND);
        assertEq(escrow.credits(buyer), BUYER_BOND);
        assertEq(escrow.credits(treasury), fee);
        _assertConserved();
    }

    function test_claimTimeout_revertsBeforeWindow() public {
        (bytes32 dealId,) = _delivered();
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        vm.warp(uint256(d.deliveredAt) + d.confirmWindow); // exactly at boundary → not elapsed
        vm.expectRevert(IEscrow.WindowNotElapsed.selector);
        escrow.claimTimeout(dealId);
    }

    // ---------------------------------------------------------------------------------------------
    // refundExpired
    // ---------------------------------------------------------------------------------------------

    function test_refundExpired_refundsBuyerNoFee() public {
        (bytes32 dealId, IEscrow.Offer memory o) = _fundDefault(); // never delivered
        vm.warp(o.deliverDeadline + 1);

        vm.prank(stranger); // permissionless
        escrow.refundExpired(dealId);

        assertEq(escrow.credits(buyer), PRICE + BUYER_BOND, "buyer fully refunded");
        assertEq(escrow.credits(seller), 0, "seller nothing (no bond posted)");
        assertEq(escrow.credits(treasury), 0, "no fee on undelivered");
        _assertConserved();
    }

    function test_refundExpired_revertsBeforeDeadline() public {
        (bytes32 dealId, IEscrow.Offer memory o) = _fundDefault();
        vm.warp(o.deliverDeadline); // exactly at deadline → not reached
        vm.expectRevert(IEscrow.DeadlineNotReached.selector);
        escrow.refundExpired(dealId);
    }

    function test_refundExpired_revertsAfterDelivery() public {
        (bytes32 dealId,) = _delivered();
        vm.warp(block.timestamp + 10 days);
        vm.expectPartialRevert(IEscrow.WrongState.selector);
        escrow.refundExpired(dealId);
    }

    // ---------------------------------------------------------------------------------------------
    // dispute + resolve
    // ---------------------------------------------------------------------------------------------

    function test_dispute_setsDisputedState() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(buyer);
        escrow.dispute(dealId);
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Disputed));
    }

    function test_dispute_onlyBuyer() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(stranger);
        vm.expectRevert(IEscrow.NotBuyer.selector);
        escrow.dispute(dealId);
    }

    function test_dispute_revertsAfterWindow() public {
        (bytes32 dealId,) = _delivered();
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        vm.warp(uint256(d.deliveredAt) + d.confirmWindow + 1);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.WindowElapsed.selector);
        escrow.dispute(dealId);
    }

    function test_dispute_allowedAtExactBoundary() public {
        (bytes32 dealId,) = _delivered();
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        vm.warp(uint256(d.deliveredAt) + d.confirmWindow); // exactly at boundary → still allowed
        vm.prank(buyer);
        escrow.dispute(dealId);
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Disputed));
    }

    function _disputed() internal returns (bytes32 dealId) {
        (dealId,) = _delivered();
        vm.prank(buyer);
        escrow.dispute(dealId);
    }

    function test_resolve_sellerFullyRight_slashesBuyerBond() public {
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(dealId, 10_000);

        uint256 fee = (PRICE * FEE_BPS) / 10_000; // 1e6
        uint256 arbFee = (BUYER_BOND * ARB_FEE_BPS) / 10_000; // 2e6
        assertEq(escrow.credits(seller), (PRICE - fee) + SELLER_BOND + (BUYER_BOND - arbFee));
        assertEq(escrow.credits(buyer), 0);
        assertEq(escrow.credits(arbiter), arbFee);
        assertEq(escrow.credits(treasury), fee);
        _assertConserved();
    }

    function test_resolve_sellerFullyWrong_slashesSellerBond() public {
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(dealId, 0);

        uint256 arbFee = (SELLER_BOND * ARB_FEE_BPS) / 10_000; // 2e6
        assertEq(escrow.credits(buyer), PRICE + BUYER_BOND + (SELLER_BOND - arbFee));
        assertEq(escrow.credits(seller), 0);
        assertEq(escrow.credits(arbiter), arbFee);
        assertEq(escrow.credits(treasury), 0);
        _assertConserved();
    }

    function test_resolve_tie_noFault() public {
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(dealId, 5_000);

        uint256 sellerPrice = (PRICE * 5_000) / 10_000; // 50e6
        uint256 fee = (sellerPrice * FEE_BPS) / 10_000; // 0.5e6
        assertEq(escrow.credits(seller), (sellerPrice - fee) + SELLER_BOND, "tie: seller bond returned");
        assertEq(escrow.credits(buyer), (PRICE - sellerPrice) + BUYER_BOND, "tie: buyer bond returned");
        assertEq(escrow.credits(arbiter), 0, "tie: no arb fee");
        assertEq(escrow.credits(treasury), fee);
        _assertConserved();
    }

    function test_resolve_partialSplits() public {
        // 60% to seller → buyer (minority) loses.
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(dealId, 6_000);
        _assertConserved();

        uint256 sellerPrice = 60e6;
        uint256 fee = (sellerPrice * FEE_BPS) / 10_000;
        uint256 arbFee = (BUYER_BOND * ARB_FEE_BPS) / 10_000;
        assertEq(escrow.credits(seller), (sellerPrice - fee) + SELLER_BOND + (BUYER_BOND - arbFee));
        assertEq(escrow.credits(buyer), PRICE - sellerPrice);
    }

    function test_resolve_onlyArbiter() public {
        bytes32 dealId = _disputed();
        vm.prank(stranger);
        vm.expectRevert(IEscrow.NotArbiter.selector);
        escrow.resolve(dealId, 5_000);

        // owner cannot resolve either
        vm.expectRevert(IEscrow.NotArbiter.selector);
        escrow.resolve(dealId, 5_000);
    }

    function test_resolve_revertsOnInvalidBps() public {
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        vm.expectRevert(IEscrow.InvalidBps.selector);
        escrow.resolve(dealId, 10_001);
    }

    function test_resolveExpired_absentArbiterRefundsBuyer() public {
        bytes32 dealId = _disputed();
        vm.warp(block.timestamp + RESOLVE_TIMEOUT + 1);

        vm.prank(stranger); // permissionless
        escrow.resolveExpired(dealId);

        assertEq(escrow.credits(buyer), PRICE + BUYER_BOND, "buyer made whole");
        assertEq(escrow.credits(seller), SELLER_BOND, "seller bond returned");
        assertEq(escrow.credits(arbiter), 0);
        assertEq(escrow.credits(treasury), 0);
        _assertConserved();
    }

    function test_resolveExpired_revertsBeforeTimeout() public {
        bytes32 dealId = _disputed();
        vm.warp(block.timestamp + RESOLVE_TIMEOUT); // exactly at boundary → not reached
        vm.expectRevert(IEscrow.DeadlineNotReached.selector);
        escrow.resolveExpired(dealId);
    }

    // ---------------------------------------------------------------------------------------------
    // state-machine enforcement
    // ---------------------------------------------------------------------------------------------

    function test_confirm_wrongState_whenFunded() public {
        (bytes32 dealId,) = _fundDefault();
        vm.prank(buyer);
        vm.expectPartialRevert(IEscrow.WrongState.selector);
        escrow.confirm(dealId);
    }

    function test_markDelivered_wrongState_whenDelivered() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(seller);
        vm.expectPartialRevert(IEscrow.WrongState.selector);
        escrow.markDelivered(dealId, keccak256("again"));
    }

    function test_doubleSettle_reverts() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(buyer);
        escrow.confirm(dealId);
        // now Resolved; claimTimeout must revert
        vm.warp(block.timestamp + 100 days);
        vm.expectPartialRevert(IEscrow.WrongState.selector);
        escrow.claimTimeout(dealId);
    }

    function test_resolve_wrongState_whenNotDisputed() public {
        (bytes32 dealId,) = _delivered();
        vm.prank(arbiter);
        vm.expectPartialRevert(IEscrow.WrongState.selector);
        escrow.resolve(dealId, 5_000);
    }

    // ---------------------------------------------------------------------------------------------
    // admin
    // ---------------------------------------------------------------------------------------------

    function test_setFeeBps_onlyOwnerAndCapped() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setFeeBps(200);

        escrow.setFeeBps(200); // owner == this
        assertEq(escrow.feeBps(), 200);

        uint16 maxFee = escrow.MAX_FEE_BPS(); // evaluate the view BEFORE arming expectRevert
        vm.expectRevert(IEscrow.FeeTooHigh.selector);
        escrow.setFeeBps(maxFee + 1);
    }

    function test_setFeeBps_doesNotAffectFundedDeal() public {
        (bytes32 dealId,) = _delivered();
        escrow.setFeeBps(1_000); // raise to 10% after funding

        vm.prank(buyer);
        escrow.confirm(dealId);

        uint256 fee = (PRICE * FEE_BPS) / 10_000; // still 1% (snapshotted)
        assertEq(escrow.credits(treasury), fee, "deal uses snapshotted fee, not the new one");
    }

    function test_setTreasury_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setTreasury(stranger);

        escrow.setTreasury(makeAddr("newTreasury"));
        assertEq(escrow.treasury(), makeAddr("newTreasury"));
    }

    function test_feeBps_zero_and_max() public {
        // feeBps = 0 → seller keeps the full price.
        IEscrow.Offer memory o = _defaultOffer();
        o.feeBps = 0;
        o.nonce = 42;
        bytes32 dealId = _fund(o);
        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("d"));
        vm.prank(buyer);
        escrow.confirm(dealId);
        assertEq(escrow.credits(treasury), 0);
        assertEq(escrow.credits(seller), PRICE + SELLER_BOND);
    }

    function test_treasuryAccumulatesAcrossDeals() public {
        uint256 fee = (PRICE * FEE_BPS) / 10_000;
        for (uint256 i = 0; i < 3; i++) {
            IEscrow.Offer memory o = _defaultOffer();
            o.nonce = 100 + i;
            bytes32 dealId = _fund(o);
            vm.prank(seller);
            escrow.markDelivered(dealId, keccak256(abi.encode(i)));
            vm.prank(buyer);
            escrow.confirm(dealId);
        }
        assertEq(escrow.credits(treasury), fee * 3, "treasury accrues every settled deal");
    }

    // ---------------------------------------------------------------------------------------------
    // fuzz: resolve conserves funds exactly for every split and every amount combination
    // ---------------------------------------------------------------------------------------------

    function testFuzz_resolveConserves(uint16 bps) public {
        bytes32 dealId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(dealId, uint16(bound(bps, 0, 10_000)));
        _assertConserved();
    }

    function testFuzz_resolveConservesAmounts(uint16 bps, uint256 price, uint256 bBond, uint256 sBond, uint16 fee)
        public
    {
        IEscrow.Offer memory o = _defaultOffer();
        o.price = bound(price, 1, 100_000e6);
        o.buyerBond = bound(bBond, 0, 1_000e6);
        o.sellerBond = bound(sBond, 0, 1_000e6);
        o.feeBps = uint16(bound(fee, 0, escrow.MAX_FEE_BPS()));
        o.nonce = 7777;

        bytes32 dealId = _fund(o);
        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("d"));
        vm.prank(buyer);
        escrow.dispute(dealId);
        vm.prank(arbiter);
        escrow.resolve(dealId, uint16(bound(bps, 0, 10_000)));

        uint256 total =
            escrow.credits(seller) + escrow.credits(buyer) + escrow.credits(arbiter) + escrow.credits(treasury);
        assertEq(usdc.balanceOf(address(escrow)), total, "balance == credits");
        assertEq(total, o.price + o.buyerBond + o.sellerBond, "exactly the deposited total is distributed");
    }

    // ---------------------------------------------------------------------------------------------
    // helper: total funds are conserved (escrow balance == sum of outstanding credits once all
    // active deals have settled in these single-deal tests)
    // ---------------------------------------------------------------------------------------------

    function _assertConserved() internal view {
        uint256 totalCredits =
            escrow.credits(seller) + escrow.credits(buyer) + escrow.credits(arbiter) + escrow.credits(treasury);
        assertEq(usdc.balanceOf(address(escrow)), totalCredits, "escrow balance == outstanding credits");
    }
}
