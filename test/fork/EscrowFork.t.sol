// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ObulusEscrow} from "../../src/ObulusEscrow.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";

/// @notice End-to-end against a REAL USDC token on a live-network fork (no real funds) — meant for
///         Robinhood Chain once a canonical USDC exists there (none published by Circle yet).
///         Skips automatically when FORK_RPC_URL or FORK_USDC_ADDRESS is unset so the default
///         `forge test` stays offline.
///         Run with: `FORK_USDC_ADDRESS=0x… forge test --match-path 'test/fork/*' --fork-url $FORK_RPC_URL`.
contract EscrowForkTest is Test {
    address internal USDC;

    ObulusEscrow internal escrow;
    IERC20 internal usdc;
    bool internal forkAvailable;

    Vm.Wallet internal sellerW;
    address internal buyer = makeAddr("buyer");
    address internal arbiter = makeAddr("arbiter");
    address internal treasury = makeAddr("treasury");

    uint256 internal constant PRICE = 100e6;
    uint256 internal constant BOND = 10e6;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        USDC = vm.envOr("FORK_USDC_ADDRESS", address(0));
        if (bytes(rpc).length == 0 || USDC == address(0)) return;
        vm.createSelectFork(rpc);
        forkAvailable = true;

        sellerW = vm.createWallet("seller");
        usdc = IERC20(USDC);
        escrow = new ObulusEscrow(USDC, treasury, 100, 2_000, 7 days);

        _fund(buyer);
        _fund(sellerW.addr);
    }

    function _fund(address a) internal {
        deal(USDC, a, 1_000e6); // set a real USDC balance on the fork
        vm.prank(a);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function _offer() internal view returns (IEscrow.Offer memory o) {
        o = IEscrow.Offer({
            seller: sellerW.addr,
            buyer: buyer,
            arbiter: arbiter,
            token: USDC,
            price: PRICE,
            buyerBond: BOND,
            sellerBond: BOND,
            deliverDeadline: uint64(block.timestamp) + 1 hours,
            confirmWindow: 1 days,
            feeBps: 100,
            specHash: keccak256("spec"),
            nonce: 1,
            sigDeadline: uint64(block.timestamp) + 1 days
        });
    }

    function _sign(IEscrow.Offer memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerW.privateKey, escrow.hashOffer(o));
        return abi.encodePacked(r, s, v);
    }

    function test_fork_happyPath_realUSDC() public {
        if (!forkAvailable) {
            vm.skip(true);
            return;
        }

        IEscrow.Offer memory o = _offer();
        bytes memory sig = _sign(o); // sign BEFORE pranking (hashOffer is an external call)
        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig);

        vm.prank(sellerW.addr);
        escrow.markDelivered(dealId, keccak256("delivery"));

        vm.prank(buyer);
        escrow.confirm(dealId);

        uint256 sellerBefore = usdc.balanceOf(sellerW.addr);
        vm.prank(sellerW.addr);
        escrow.withdraw();

        uint256 fee = (PRICE * 100) / 10_000;
        assertEq(usdc.balanceOf(sellerW.addr), sellerBefore + (PRICE - fee) + BOND, "seller paid in real USDC");

        vm.prank(buyer);
        escrow.withdraw();
        assertEq(escrow.credits(buyer), 0);
    }

    function test_fork_disputeResolve_realUSDC() public {
        if (!forkAvailable) {
            vm.skip(true);
            return;
        }

        IEscrow.Offer memory o = _offer();
        bytes memory sig = _sign(o); // sign BEFORE pranking (hashOffer is an external call)
        vm.prank(buyer);
        bytes32 dealId = escrow.fund(o, sig);
        vm.prank(sellerW.addr);
        escrow.markDelivered(dealId, keccak256("delivery"));
        vm.prank(buyer);
        escrow.dispute(dealId);

        vm.prank(arbiter);
        escrow.resolve(dealId, 7_000); // seller mostly right

        // Conservation in real USDC: the escrow holds exactly the sum of outstanding credits.
        uint256 credits =
            escrow.credits(sellerW.addr) + escrow.credits(buyer) + escrow.credits(arbiter) + escrow.credits(treasury);
        assertEq(usdc.balanceOf(address(escrow)), credits);
        assertEq(credits, PRICE + BOND + BOND, "all deposited USDC accounted for");
    }
}
