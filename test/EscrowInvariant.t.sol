// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

/// @notice The headline correctness guarantee: across any sequence of actions over many deals and
///         actors, the escrow's USDC balance equals exactly the value held by open deals plus the
///         outstanding withdrawable credits. No wei is ever created or destroyed.
contract EscrowInvariantTest is StdInvariant, Test {
    ObulusEscrow internal escrow;
    MockUSDC internal usdc;
    EscrowHandler internal handler;
    address internal treasury = makeAddr("inv-treasury");

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new ObulusEscrow(address(usdc), treasury, 100, 2_000, 7 days);
        handler = new EscrowHandler(escrow, usdc, treasury);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.markDelivered.selector;
        selectors[2] = handler.confirm.selector;
        selectors[3] = handler.claimTimeout.selector;
        selectors[4] = handler.refundExpired.selector;
        selectors[5] = handler.dispute.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.resolveExpired.selector;
        selectors[8] = handler.withdraw.selector;
        selectors[9] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev escrow.balance == Σ held(open deals) + Σ credits(all actors).
    function invariant_fundsConserved() public view {
        uint256 expected;

        uint256 n = handler.dealsLength();
        for (uint256 i; i < n; i++) {
            IEscrow.Deal memory d = escrow.getDeal(handler.deals(i));
            if (d.state == IEscrow.State.Funded) {
                expected += d.price + d.buyerBond;
            } else if (d.state == IEscrow.State.Delivered || d.state == IEscrow.State.Disputed) {
                expected += d.price + d.buyerBond + d.sellerBond;
            }
            // None / Resolved hold nothing (value moved into credits).
        }

        uint256 m = handler.actorsLength();
        for (uint256 i; i < m; i++) {
            expected += escrow.credits(handler.actorsList(i));
        }

        assertEq(usdc.balanceOf(address(escrow)), expected, "escrow balance == held + outstanding credits");
    }

    /// @dev The owner can never change the escrow's token balance (admin has no power over funds).
    function invariant_ownerCannotMoveFunds() public {
        uint256 balBefore = usdc.balanceOf(address(escrow));
        // owner == this test contract (deployer)
        escrow.setFeeBps(250);
        escrow.setTreasury(makeAddr("rotated-treasury"));
        escrow.setTreasury(treasury);
        assertEq(usdc.balanceOf(address(escrow)), balBefore, "admin actions never move escrow funds");
    }
}
