// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Shared setup: a fresh ObulusEscrow over a MockUSDC, funded actors, and offer build/sign helpers.
abstract contract BaseTest is Test {
    ObulusEscrow internal escrow;
    MockUSDC internal usdc;

    // Default economic terms (USDC has 6 decimals).
    uint256 internal constant PRICE = 100e6;
    uint256 internal constant BUYER_BOND = 10e6;
    uint256 internal constant SELLER_BOND = 10e6;
    uint16 internal constant FEE_BPS = 100; // 1%
    uint16 internal constant ARB_FEE_BPS = 2_000; // 20% of the slashed bond
    uint64 internal constant RESOLVE_TIMEOUT = 7 days;
    uint64 internal constant DELIVER_WINDOW = 1 hours;
    uint64 internal constant CONFIRM_WINDOW = 1 days;

    Vm.Wallet internal sellerW;
    address internal seller;
    address internal buyer = makeAddr("buyer");
    address internal arbiter = makeAddr("arbiter");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant SPEC_HASH = keccak256("service-spec-v1");

    function setUp() public virtual {
        sellerW = vm.createWallet("seller");
        seller = sellerW.addr;

        usdc = new MockUSDC();
        escrow = new ObulusEscrow(address(usdc), treasury, FEE_BPS, ARB_FEE_BPS, RESOLVE_TIMEOUT);

        // Fund actors generously and pre-approve the escrow.
        _fundActor(buyer);
        _fundActor(seller);
        _fundActor(stranger);
    }

    function _fundActor(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.prank(a);
        usdc.approve(address(escrow), type(uint256).max);
    }

    // --- offer helpers ---------------------------------------------------------------------------

    function _defaultOffer() internal view returns (IEscrow.Offer memory o) {
        o = IEscrow.Offer({
            seller: seller,
            buyer: buyer,
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

    function _sign(uint256 pk, IEscrow.Offer memory o) internal view returns (bytes memory) {
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _fund(IEscrow.Offer memory o) internal returns (bytes32 dealId) {
        bytes memory sig = _sign(sellerW.privateKey, o);
        address funder = o.buyer == address(0) ? buyer : o.buyer;
        vm.prank(funder);
        dealId = escrow.fund(o, sig);
    }

    function _fundDefault() internal returns (bytes32 dealId, IEscrow.Offer memory o) {
        o = _defaultOffer();
        dealId = _fund(o);
    }

    /// @dev Drive a deal all the way to the Delivered state with the default terms.
    function _delivered() internal returns (bytes32 dealId, IEscrow.Offer memory o) {
        (dealId, o) = _fundDefault();
        vm.prank(seller);
        escrow.markDelivered(dealId, keccak256("delivery"));
    }
}
