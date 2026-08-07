// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ObulusSubscriptionEscrow} from "../../src/ObulusSubscriptionEscrow.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Bounded action driver for the ObulusSubscriptionEscrow fund-conservation invariant. Every
///         function is a randomised, state-aware action; invalid actions self-skip via try/catch
///         (the invariant profile also runs fail_on_revert=false). Tracks all subs and all actors so
///         the invariant can sum held value + outstanding credits.
contract SubscriptionHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ObulusSubscriptionEscrow public immutable esc;
    MockUSDC public immutable usdc;

    uint256[] internal sellerPks;
    address[] public sellers;
    address[] public subscribers;
    address public arbiter;
    address public treasury;

    bytes32[] public subIds;
    address[] public actorsList;
    mapping(address => uint256) internal nonceOf;

    constructor(ObulusSubscriptionEscrow _esc, MockUSDC _usdc, address _treasury) {
        esc = _esc;
        usdc = _usdc;
        treasury = _treasury;
        arbiter = address(uint160(uint256(keccak256("sub-arbiter"))));

        for (uint256 i; i < 2; i++) {
            Vm.Wallet memory w = vm.createWallet(string(abi.encodePacked("sub-seller-", vm.toString(i))));
            sellerPks.push(w.privateKey);
            sellers.push(w.addr);
        }
        for (uint256 i; i < 2; i++) {
            subscribers.push(address(uint160(uint256(keccak256(abi.encodePacked("sub-subscriber-", i))))));
        }
        _setup(arbiter);
        _setup(treasury);
        for (uint256 i; i < sellers.length; i++) _setup(sellers[i]);
        for (uint256 i; i < subscribers.length; i++) _setup(subscribers[i]);
    }

    function _setup(address a) internal {
        usdc.mint(a, 1e24);
        vm.prank(a);
        usdc.approve(address(esc), type(uint256).max);
        actorsList.push(a);
    }

    function subIdsLength() external view returns (uint256) {
        return subIds.length;
    }

    function actorsLength() external view returns (uint256) {
        return actorsList.length;
    }

    // --- actions ---------------------------------------------------------------------------------

    function start(uint256 si, uint256 pp, uint256 np, bool open) external {
        uint256 sIdx = si % sellers.length;
        uint256 subIdx = si % subscribers.length;
        address seller = sellers[sIdx];
        address subscriber = subscribers[subIdx];
        ObulusSubscriptionEscrow.SubOffer memory o = ObulusSubscriptionEscrow.SubOffer({
            seller: seller,
            subscriber: open ? address(0) : subscriber,
            arbiter: arbiter,
            token: address(usdc),
            periodPrice: 1e6 + (pp % (100e6)),
            sellerBond: 50e6,
            subscriberBond: 30e6,
            numPeriods: uint32(1 + (np % 4)),
            periodLength: 1 days,
            challengeWindow: 1 hours,
            startAt: uint64(block.timestamp),
            feeBps: 100,
            specHash: keccak256("inv"),
            nonce: nonceOf[seller]++,
            sigDeadline: uint64(block.timestamp) + 1 days
        });
        bytes32 digest = esc.hashSubOffer(o); // BEFORE prank (a call would consume it)
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(sellerPks[sIdx], digest);
        vm.prank(subscriber);
        try esc.start(o, abi.encodePacked(r, s2, v)) returns (bytes32 id) {
            subIds.push(id);
        } catch {}
    }

    function activate(uint256 i) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        ObulusSubscriptionEscrow.Sub memory s = esc.getSub(id);
        vm.prank(s.seller);
        try esc.activate(id) {} catch {}
    }

    function claim(uint256 i) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        try esc.claimPeriod(id) {} catch {}
    }

    function dispute(uint256 i) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        ObulusSubscriptionEscrow.Sub memory s = esc.getSub(id);
        vm.prank(s.subscriber);
        try esc.disputePeriod(id) {} catch {}
    }

    function resolve(uint256 i, uint256 period, uint256 bps) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        ObulusSubscriptionEscrow.Sub memory s = esc.getSub(id);
        uint32 p = s.numPeriods == 0 ? 0 : uint32(period % s.numPeriods);
        vm.prank(s.arbiter);
        try esc.resolvePeriod(id, p, uint16(bps % 10_001)) {} catch {}
    }

    function resolveExpired(uint256 i, uint256 period) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        ObulusSubscriptionEscrow.Sub memory s = esc.getSub(id);
        uint32 p = s.numPeriods == 0 ? 0 : uint32(period % s.numPeriods);
        try esc.resolvePeriodExpired(id, p) {} catch {}
    }

    function revoke(uint256 i) external {
        if (subIds.length == 0) return;
        bytes32 id = subIds[i % subIds.length];
        ObulusSubscriptionEscrow.Sub memory s = esc.getSub(id);
        vm.prank(s.subscriber);
        try esc.revoke(id) {} catch {}
    }

    function expire(uint256 i) external {
        if (subIds.length == 0) return;
        try esc.expireSub(subIds[i % subIds.length]) {} catch {}
    }

    function close(uint256 i) external {
        if (subIds.length == 0) return;
        try esc.close(subIds[i % subIds.length]) {} catch {}
    }

    function withdraw(uint256 a) external {
        address actor = actorsList[a % actorsList.length];
        vm.prank(actor);
        try esc.withdraw() {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + (dt % (3 days)) + 1);
    }
}
