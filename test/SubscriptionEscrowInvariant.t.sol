// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ObulusSubscriptionEscrow} from "../src/ObulusSubscriptionEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {SubscriptionHandler} from "./handlers/SubscriptionHandler.sol";

/// @notice Headline correctness guarantee for the Tier-3 escrow: across any sequence of actions over
///         many subscriptions and actors, the contract's USDC balance equals exactly the value held
///         by open subs (prepaid price + bonds + pending dispute deposits) plus outstanding credits.
///         No wei is ever created, destroyed, or frozen unaccountably.
contract SubscriptionEscrowInvariantTest is StdInvariant, Test {
    ObulusSubscriptionEscrow internal esc;
    MockUSDC internal usdc;
    SubscriptionHandler internal handler;
    address internal treasury = makeAddr("sub-inv-treasury");

    function setUp() public {
        usdc = new MockUSDC();
        esc = new ObulusSubscriptionEscrow(address(usdc), treasury, 100, 2_000, 7 days);
        handler = new SubscriptionHandler(esc, usdc, treasury);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.start.selector;
        selectors[1] = handler.activate.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.dispute.selector;
        selectors[4] = handler.resolve.selector;
        selectors[5] = handler.resolveExpired.selector;
        selectors[6] = handler.revoke.selector;
        selectors[7] = handler.expire.selector;
        selectors[8] = handler.close.selector;
        selectors[9] = handler.withdraw.selector;
        selectors[10] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev esc.balance == Σ held(open subs) + Σ credits(all actors). No wei created/destroyed/frozen.
    function invariant_fundsConserved() public view {
        uint256 expected;

        uint256 n = handler.subIdsLength();
        for (uint256 i; i < n; i++) {
            ObulusSubscriptionEscrow.Sub memory s = esc.getSub(handler.subIds(i));
            expected += s.escrowedPrice + s.sellerBondRem + s.subscriberBondRem + s.depositHeld;
        }

        uint256 m = handler.actorsLength();
        for (uint256 i; i < m; i++) {
            expected += esc.credits(handler.actorsList(i));
        }

        assertEq(usdc.balanceOf(address(esc)), expected, "sub escrow balance == held + outstanding credits");
    }

    /// @dev Σ slashes can never exceed the posted bonds: remaining bonds stay in [0, original].
    function invariant_bondsWithinBounds() public view {
        uint256 n = handler.subIdsLength();
        for (uint256 i; i < n; i++) {
            ObulusSubscriptionEscrow.Sub memory s = esc.getSub(handler.subIds(i));
            assertLe(s.sellerBondRem, s.sellerBond, "sellerBondRem <= original");
            assertLe(s.subscriberBondRem, s.subscriberBond, "subscriberBondRem <= original");
        }
    }

    /// @dev The owner can never change the contract's token balance (admin has no power over funds).
    function invariant_ownerCannotMoveFunds() public {
        uint256 balBefore = usdc.balanceOf(address(esc));
        esc.setFeeBps(250);
        esc.setTreasury(makeAddr("rotated"));
        esc.setTreasury(treasury);
        assertEq(usdc.balanceOf(address(esc)), balBefore, "admin actions never move escrow funds");
    }
}
