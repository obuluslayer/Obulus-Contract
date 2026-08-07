// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseTest} from "./BaseTest.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1271} from "../src/mocks/MockERC1271.sol";

/// @notice A minimal contract account (no EOA key) that can hold USDC, approve the ObulusEscrow, and call
///         `fund()` itself — used to prove a SMART ACCOUNT is a valid funding `msg.sender`. It is the
///         buyer-side analogue of MockERC1271 (which proves the seller side via ERC-1271 isValidSignature).
contract SmartAccountBuyer {
    function approveEscrow(IERC20 token, address escrow) external {
        token.approve(escrow, type(uint256).max);
    }

    /// @dev Forwards to ObulusEscrow.fund as `this` (a contract) → msg.sender in fund() is this account.
    function fund(address escrow, IEscrow.Offer calldata offer, bytes calldata sellerSig)
        external
        returns (bytes32)
    {
        return IEscrow(escrow).fund(offer, sellerSig);
    }
}

/// @notice EIP-712 authentication, ERC-1271 (smart-account) signatures, replay & domain binding.
contract EscrowSigTest is BaseTest {
    function test_sig_validEOA_recoversSeller() public {
        IEscrow.Offer memory o = _defaultOffer();
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig);
        assertEq(escrow.getDeal(dealId).seller, seller);
    }

    function test_sig_wrongSigner_reverts() public {
        Vm.Wallet memory mallory = vm.createWallet("mallory");
        IEscrow.Offer memory o = _defaultOffer();
        bytes memory sig = _sign(mallory.privateKey, o); // not the seller
        vm.prank(buyer);
        vm.expectRevert(IEscrow.BadSignature.selector);
        escrow.fund(o, sig);
    }

    /// @dev Sign the canonical offer, then mutate one field before funding: the digest the contract
    ///      recomputes no longer matches the signature, so recovery != seller → BadSignature.
    function test_sig_tamperedFields_reject() public {
        IEscrow.Offer memory base = _defaultOffer();
        bytes memory sig = _sign(sellerW.privateKey, base); // signature over the untampered offer

        IEscrow.Offer memory t;
        t = _defaultOffer();
        t.price += 1;
        _fundExpectBadSig(t, sig);

        t = _defaultOffer();
        t.arbiter = address(0xBEEF);
        _fundExpectBadSig(t, sig);

        t = _defaultOffer();
        t.feeBps = 50;
        _fundExpectBadSig(t, sig);

        t = _defaultOffer();
        t.deliverDeadline += 1;
        _fundExpectBadSig(t, sig);

        t = _defaultOffer();
        t.buyerBond += 1;
        _fundExpectBadSig(t, sig);
    }

    function _fundExpectBadSig(IEscrow.Offer memory o, bytes memory sig) internal {
        vm.prank(buyer);
        vm.expectRevert(IEscrow.BadSignature.selector);
        escrow.fund(o, sig);
    }

    function test_replay_sameOffer_reverts() public {
        (, IEscrow.Offer memory o) = _fundDefault();
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectPartialRevert(IEscrow.DealExists.selector);
        escrow.fund(o, sig);
    }

    function test_directedOffer_wrongFunder_reverts() public {
        IEscrow.Offer memory o = _defaultOffer(); // directed to `buyer`
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(stranger);
        vm.expectRevert(IEscrow.NotDesignatedBuyer.selector);
        escrow.fund(o, sig);
    }

    function test_cancelOffer_blocksFunding() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.nonce = 7;
        bytes memory sig = _sign(sellerW.privateKey, o);

        vm.prank(seller);
        escrow.cancelOffer(7);

        vm.prank(buyer);
        vm.expectRevert(IEscrow.NonceCancelled.selector);
        escrow.fund(o, sig);
    }

    function test_cancelOffer_byOtherSeller_doesNotBlock() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.nonce = 8;
        bytes memory sig = _sign(sellerW.privateKey, o);

        vm.prank(stranger); // cancels stranger's nonce 8, not the seller's
        escrow.cancelOffer(8);

        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig); // still fundable
        assertEq(uint8(escrow.getDeal(dealId).state), uint8(IEscrow.State.Funded));
    }

    // --- ERC-1271 smart-account seller ----------------------------------------------------------

    function test_erc1271_smartAccountSeller_funds() public {
        Vm.Wallet memory ownerW = vm.createWallet("sa-owner");
        MockERC1271 wallet = new MockERC1271(ownerW.addr);

        IEscrow.Offer memory o = _defaultOffer();
        o.seller = address(wallet); // the seller is a contract
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig); // accepted via ERC-1271
        assertEq(escrow.getDeal(dealId).seller, address(wallet));

        // When the smart account rejects, funding fails.
        wallet.setAlwaysReject(true);
        IEscrow.Offer memory o2 = _defaultOffer();
        o2.seller = address(wallet);
        o2.nonce = 2;
        bytes32 digest2 = escrow.hashOffer(o2);
        (v, r, s) = vm.sign(ownerW.privateKey, digest2);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.BadSignature.selector);
        escrow.fund(o2, abi.encodePacked(r, s, v));
    }

    /// @dev Focused proof that an ERC-1271 smart-account seller is accepted by fund(): the offer is
    ///      signed by the wallet's OWNER (an EOA with no on-chain code), yet `offer.seller` is the
    ///      CONTRACT. SignatureChecker takes the isValidSignature path (not ECDSA recovery to seller),
    ///      and the deal records the contract as the seller.
    function test_erc1271_smartAccountSeller_accepted() public {
        Vm.Wallet memory ownerW = vm.createWallet("sa-seller-owner");
        MockERC1271 wallet = new MockERC1271(ownerW.addr);

        IEscrow.Offer memory o = _defaultOffer();
        o.seller = address(wallet);
        o.nonce = 11;
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW.privateKey, digest);

        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, abi.encodePacked(r, s, v));

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        assertEq(d.seller, address(wallet), "seller recorded as the smart account");
        assertEq(uint8(d.state), uint8(IEscrow.State.Funded), "funded via ERC-1271");
    }

    /// @dev An INVALID ERC-1271 signature must be rejected exactly like a bad EOA signature. Here the
    ///      smart account's owner did NOT sign — a *stranger* EOA did — so the wallet's isValidSignature
    ///      returns the failure magic and fund() reverts BadSignature. (The wallet itself is willing to
    ///      validate; it just doesn't recognise this signer. Distinct from the alwaysReject path above.)
    function test_erc1271_invalidSignature_rejected() public {
        Vm.Wallet memory ownerW = vm.createWallet("sa-seller-owner2");
        Vm.Wallet memory mallory = vm.createWallet("mallory-1271");
        MockERC1271 wallet = new MockERC1271(ownerW.addr);

        IEscrow.Offer memory o = _defaultOffer();
        o.seller = address(wallet);
        o.nonce = 12;
        bytes32 digest = escrow.hashOffer(o);
        // Signed by mallory, NOT the wallet owner → wallet.isValidSignature != MAGIC.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mallory.privateKey, digest);

        vm.prank(buyer);
        vm.expectRevert(IEscrow.BadSignature.selector);
        escrow.fund(o, abi.encodePacked(r, s, v));

        // Garbage (length-correct but non-recoverable) bytes are likewise rejected.
        bytes memory garbage = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        vm.prank(buyer);
        vm.expectRevert(IEscrow.BadSignature.selector);
        escrow.fund(o, garbage);
    }

    /// @dev A SMART ACCOUNT is fine as the funding `msg.sender`: a contract (SmartAccountBuyer) — which
    ///      has no private key and cannot be an `vm.prank`ed EOA — holds USDC, approves the ObulusEscrow, and
    ///      calls fund() itself. fund() pulls from `msg.sender` (the contract) and records it as buyer.
    ///      This is the 4337-style flow: the bundler/account, not an EOA, is the caller.
    function test_erc1271_smartAccountBuyer_canFund() public {
        SmartAccountBuyer saBuyer = new SmartAccountBuyer();
        // Fund the contract account and let it approve the escrow as itself.
        usdc.mint(address(saBuyer), 1_000_000e6);
        saBuyer.approveEscrow(IERC20(address(usdc)), address(escrow));

        // Open offer (buyer == address(0)) → the funder becomes the buyer. Seller is a normal EOA here;
        // what we're proving is the *caller* may be a contract account.
        IEscrow.Offer memory o = _defaultOffer();
        o.buyer = address(0);
        o.nonce = 13;
        bytes memory sig = _sign(sellerW.privateKey, o);

        uint256 balBefore = usdc.balanceOf(address(saBuyer));
        bytes32 dealId = saBuyer.fund(address(escrow), o, sig);

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        assertEq(d.buyer, address(saBuyer), "contract account recorded as buyer");
        assertEq(uint8(d.state), uint8(IEscrow.State.Funded), "funded by a contract msg.sender");
        // The price + buyer bond was pulled from the contract account, not from any EOA.
        assertEq(balBefore - usdc.balanceOf(address(saBuyer)), o.price + o.buyerBond, "pulled from the contract");
    }

    /// @dev The composition: a smart-account SELLER (ERC-1271) AND a smart-account BUYER (contract
    ///      msg.sender) in the same deal — both sides non-EOA — still settles into Funded.
    function test_erc1271_smartAccountBuyerAndSeller_canFund() public {
        Vm.Wallet memory ownerW = vm.createWallet("sa-seller-owner3");
        MockERC1271 sellerWallet = new MockERC1271(ownerW.addr);
        SmartAccountBuyer saBuyer = new SmartAccountBuyer();
        usdc.mint(address(saBuyer), 1_000_000e6);
        saBuyer.approveEscrow(IERC20(address(usdc)), address(escrow));

        IEscrow.Offer memory o = _defaultOffer();
        o.seller = address(sellerWallet);
        o.buyer = address(saBuyer); // directed to the contract buyer
        o.nonce = 14;
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerW.privateKey, digest);

        bytes32 dealId = saBuyer.fund(address(escrow), o, abi.encodePacked(r, s, v));

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        assertEq(d.seller, address(sellerWallet), "smart-account seller");
        assertEq(d.buyer, address(saBuyer), "smart-account buyer");
        assertEq(uint8(d.state), uint8(IEscrow.State.Funded), "both-smart-account deal funded");
    }

    // --- domain binding (cross-chain replay protection) -----------------------------------------

    function test_domainSeparator_isChainSpecific() public {
        IEscrow.Offer memory o = _defaultOffer();
        bytes32 digestHere = escrow.hashOffer(o);

        uint256 original = block.chainid;
        vm.chainId(999999);
        bytes32 digestElsewhere = escrow.hashOffer(o);
        vm.chainId(original);

        assertTrue(digestHere != digestElsewhere, "digest binds chainid: no cross-chain replay");
    }

    // --- audit: deliver-window math must not overflow uint64 (else markDelivered self-DoS) --------

    function test_fund_rejectsOverflowingDeliverWindow() public {
        IEscrow.Offer memory o = _defaultOffer();
        o.confirmWindow = type(uint64).max; // deliverDeadline + confirmWindow overflows uint64
        bytes memory sig = _sign(sellerW.privateKey, o);
        vm.prank(buyer);
        vm.expectRevert(IEscrow.InvalidDeadline.selector);
        escrow.fund(o, sig);
    }
}
