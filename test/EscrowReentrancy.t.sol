// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {ReentrantToken} from "../src/mocks/ReentrantToken.sol";

/// @notice Proves the `nonReentrant` guard + checks-effects-interactions prevent any double payout,
///         even when the settlement token re-enters the escrow on every transfer.
contract EscrowReentrancyTest is Test {
    ObulusEscrow internal esc;
    ReentrantToken internal rt;
    Vm.Wallet internal sellerW;
    address internal buyer = makeAddr("buyer");
    address internal arbiter = makeAddr("arbiter");

    function setUp() public {
        sellerW = vm.createWallet("seller");
        rt = new ReentrantToken();
        // Make the reentrant token itself the treasury, so it holds a real credit the re-entry
        // could try to drain mid-transfer if the guard were missing.
        esc = new ObulusEscrow(address(rt), address(rt), 100, 2_000, 7 days);

        rt.mint(buyer, 1_000e6);
        rt.mint(sellerW.addr, 1_000e6);
        vm.prank(buyer);
        rt.approve(address(esc), type(uint256).max);
        vm.prank(sellerW.addr);
        rt.approve(address(esc), type(uint256).max);
    }

    function _offer() internal view returns (IEscrow.Offer memory o) {
        o = IEscrow.Offer({
            seller: sellerW.addr,
            buyer: buyer,
            arbiter: arbiter,
            token: address(rt),
            price: 100e6,
            buyerBond: 10e6,
            sellerBond: 10e6,
            deliverDeadline: uint64(block.timestamp) + 1 hours,
            confirmWindow: 1 days,
            feeBps: 100,
            specHash: keccak256("spec"),
            nonce: 1,
            sigDeadline: uint64(block.timestamp) + 1 days
        });
    }

    function test_withdraw_reentrancy_cannotDoublePay() public {
        // Drive a deal to settlement so seller + treasury(rt) hold credits.
        IEscrow.Offer memory o = _offer();
        bytes32 digest = esc.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerW.privateKey, digest);
        vm.prank(buyer);
        bytes32 dealId = esc.fund(o, abi.encodePacked(r, s, v));
        vm.prank(sellerW.addr);
        esc.markDelivered(dealId, keccak256("d"));
        vm.prank(buyer);
        esc.confirm(dealId);

        uint256 sellerCredit = esc.credits(sellerW.addr);
        uint256 treasuryCredit = esc.credits(address(rt));
        assertGt(treasuryCredit, 0, "treasury has a fee credit to (try to) steal");

        // Arm the attack: every rt transfer re-enters withdraw(). The guard must block it.
        rt.setAttack(address(esc), abi.encodeWithSelector(IEscrow.withdraw.selector));

        uint256 sellerBalBefore = rt.balanceOf(sellerW.addr);
        vm.prank(sellerW.addr);
        esc.withdraw();

        // Seller paid exactly once; the re-entrant withdraw was rejected (treasury credit untouched).
        assertEq(rt.balanceOf(sellerW.addr), sellerBalBefore + sellerCredit, "paid exactly once");
        assertEq(esc.credits(sellerW.addr), 0, "seller credit cleared");
        assertEq(esc.credits(address(rt)), treasuryCredit, "treasury credit NOT drained by re-entry");

        // Conservation: escrow still holds exactly the unwithdrawn credits.
        assertEq(rt.balanceOf(address(esc)), esc.credits(buyer) + esc.credits(address(rt)));
    }
}
