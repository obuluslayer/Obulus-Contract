// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ObulusEscrow} from "../../src/ObulusEscrow.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Bounded action driver for the fund-conservation invariant. Every external function is a
///         randomised, state-aware action the fuzzer may call; invalid actions self-skip or revert
///         harmlessly (fail_on_revert = false). Tracks all created deals and all actors so the
///         invariant can sum held value + outstanding credits.
contract EscrowHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ObulusEscrow public immutable escrow;
    MockUSDC public immutable usdc;

    uint256[] internal sellerPks;
    address[] public sellers;
    address[] public buyers;
    address public arbiter;
    address public treasury;

    bytes32[] public deals;
    address[] public actorsList; // every address that could ever hold a credit
    mapping(address => uint256) internal nonceOf;

    constructor(ObulusEscrow _escrow, MockUSDC _usdc, address _treasury) {
        escrow = _escrow;
        usdc = _usdc;
        treasury = _treasury;
        arbiter = address(uint160(uint256(keccak256("handler-arbiter"))));

        for (uint256 i; i < 2; i++) {
            Vm.Wallet memory w = vm.createWallet(string(abi.encodePacked("h-seller-", vm.toString(i))));
            sellerPks.push(w.privateKey);
            sellers.push(w.addr);
        }
        for (uint256 i; i < 2; i++) {
            buyers.push(address(uint160(uint256(keccak256(abi.encodePacked("h-buyer-", i))))));
        }

        _setupActor(arbiter);
        _setupActor(treasury);
        for (uint256 i; i < sellers.length; i++) {
            _setupActor(sellers[i]);
        }
        for (uint256 i; i < buyers.length; i++) {
            _setupActor(buyers[i]);
        }
    }

    function _setupActor(address a) internal {
        usdc.mint(a, 1e18);
        vm.prank(a);
        usdc.approve(address(escrow), type(uint256).max);
        actorsList.push(a);
    }

    // --- actions ---------------------------------------------------------------------------------

    function fund(
        uint256 sSeed,
        uint256 bSeed,
        uint256 price,
        uint256 bBond,
        uint256 sBond,
        uint256 feeBps,
        uint256 delivDur,
        uint256 confWin
    ) public {
        uint256 si = sSeed % sellers.length;
        address seller = sellers[si];
        address buyer = buyers[bSeed % buyers.length];

        IEscrow.Offer memory o = IEscrow.Offer({
            seller: seller,
            buyer: buyer,
            arbiter: arbiter,
            token: address(usdc),
            price: _bound(price, 1, 1_000e6),
            buyerBond: _bound(bBond, 0, 100e6),
            sellerBond: _bound(sBond, 0, 100e6),
            deliverDeadline: uint64(block.timestamp + _bound(delivDur, 1, 30 days)),
            confirmWindow: uint64(_bound(confWin, 1, 30 days)),
            feeBps: uint16(_bound(feeBps, 0, 1_000)),
            specHash: keccak256(abi.encode(seller, nonceOf[seller])),
            nonce: nonceOf[seller]++,
            sigDeadline: uint64(block.timestamp + 365 days)
        });

        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPks[si], digest);
        vm.prank(buyer);
        try escrow.fund(o, abi.encodePacked(r, s, v)) returns (bytes32 id) {
            deals.push(id);
        } catch {}
    }

    function markDelivered(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Funded, seed);
        if (!ok) return;
        vm.prank(escrow.getDeal(id).seller);
        try escrow.markDelivered(id, keccak256(abi.encode(id))) {} catch {}
    }

    function confirm(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Delivered, seed);
        if (!ok) return;
        vm.prank(escrow.getDeal(id).buyer);
        try escrow.confirm(id) {} catch {}
    }

    function claimTimeout(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Delivered, seed);
        if (!ok) return;
        IEscrow.Deal memory d = escrow.getDeal(id);
        vm.warp(uint256(d.deliveredAt) + d.confirmWindow + 1);
        try escrow.claimTimeout(id) {} catch {}
    }

    function refundExpired(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Funded, seed);
        if (!ok) return;
        IEscrow.Deal memory d = escrow.getDeal(id);
        vm.warp(uint256(d.deliverDeadline) + 1);
        try escrow.refundExpired(id) {} catch {}
    }

    function dispute(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Delivered, seed);
        if (!ok) return;
        IEscrow.Deal memory d = escrow.getDeal(id);
        if (block.timestamp > uint256(d.deliveredAt) + d.confirmWindow) return;
        vm.prank(d.buyer);
        try escrow.dispute(id) {} catch {}
    }

    function resolve(uint256 seed, uint256 bps) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Disputed, seed);
        if (!ok) return;
        vm.prank(escrow.getDeal(id).arbiter);
        try escrow.resolve(id, uint16(_bound(bps, 0, 10_000))) {} catch {}
    }

    function resolveExpired(uint256 seed) public {
        (bytes32 id, bool ok) = _pick(IEscrow.State.Disputed, seed);
        if (!ok) return;
        IEscrow.Deal memory d = escrow.getDeal(id);
        vm.warp(uint256(d.disputedAt) + escrow.resolveTimeout() + 1);
        try escrow.resolveExpired(id) {} catch {}
    }

    function withdraw(uint256 seed) public {
        address a = actorsList[seed % actorsList.length];
        vm.prank(a);
        try escrow.withdraw() {} catch {}
    }

    function warp(uint256 dt) public {
        vm.warp(block.timestamp + _bound(dt, 1, 15 days));
    }

    // --- views for the invariant -----------------------------------------------------------------

    function dealsLength() external view returns (uint256) {
        return deals.length;
    }

    function actorsLength() external view returns (uint256) {
        return actorsList.length;
    }

    // --- helpers ---------------------------------------------------------------------------------

    function _pick(IEscrow.State want, uint256 seed) internal view returns (bytes32 id, bool ok) {
        uint256 n = deals.length;
        if (n == 0) return (bytes32(0), false);
        for (uint256 i; i < n; i++) {
            bytes32 cand = deals[(seed + i) % n];
            if (escrow.getDeal(cand).state == want) return (cand, true);
        }
        return (bytes32(0), false);
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) (lo, hi) = (hi, lo);
        return lo + (x % (hi - lo + 1));
    }
}
