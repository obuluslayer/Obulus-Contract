// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ObulusEscrow} from "../../src/ObulusEscrow.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";
import {ObulusStakingVault} from "../../src/ObulusStakingVault.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Bounded action driver for the ObulusStakingVault conservation invariant. Every external function is a
///         randomised, state-aware action the fuzzer may call; invalid actions self-skip or revert
///         harmlessly (fail_on_revert = false). It also drives the *real* ObulusEscrow into Disputed states so the
///         arbiter-gated `slash` path is exercised against genuine on-chain deal records — never a stub.
///
/// LOAD-BEARING SLASH PATH: the original handler wrapped slash in try/catch over randomised inputs, so a
/// representative run landed essentially ONE non-dust slash across thousands of calls — the conservation
/// invariants passed but never actually exercised the slash accounting. To fix that, `forceSlash` is a
/// DETERMINISTIC composite: it guarantees adequate stake, mints a fresh Disputed deal, optionally has the
/// target unstake everything first (exercising the anti-evasion / slash-reaches-pending path), and then
/// lands a real, non-dust arbiter slash. Ghost counters (`ghostSlashCount`, `ghostNonDustSlashCount`,
/// `ghostPendingSlashCount`) are incremented ONLY on a slash that actually moved funds to the treasury, and
/// `invariant_slashPathIsExercised` asserts a meaningful number of non-dust slashes occurred over the run.
///
/// Tracked actors are fixed buyers/stakers and ONE seller wallet (the only key we can sign with). The
/// invariant sums stake + pending over every actor + the treasury, asserting it equals the vault balance.
contract StakingVaultHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ObulusStakingVault public immutable vault;
    ObulusEscrow public immutable escrow;
    MockUSDC public immutable usdc;
    address public immutable treasury;
    address public immutable arbiter;

    uint256 internal sellerPk;
    address public seller;
    address[] public stakers; // addresses that stake (includes buyers + the seller)
    address[] public buyers;

    bytes32[] public deals;
    mapping(address => uint256) internal nonceOf;

    // --- ghost accounting for the slash path -----------------------------------------------------
    /// @notice Total slashes that actually moved funds to the treasury (any non-zero amount).
    uint256 public ghostSlashCount;
    /// @notice Slashes whose executed amount was non-dust (>= NON_DUST). The invariant asserts a floor on this.
    uint256 public ghostNonDustSlashCount;
    /// @notice Slashes that had to reach into the pending bucket (target had unstaked) — proves the
    ///         anti-evasion path is genuinely exercised, not just standing-stake slashes.
    uint256 public ghostPendingSlashCount;
    /// @notice Cumulative USDC moved to the treasury via slashes (cross-check against treasury balance).
    uint256 public ghostSlashedTotal;
    /// @notice Diagnostics: forceSlash entries, and how many bailed before landing (deal-creation / top-up).
    uint256 public ghostForceEntries;
    uint256 public ghostForceBailedTopUp;
    uint256 public ghostForceBailedDeal;

    /// @notice Monotonic counter of forceSlash invocations, used to make the unstake-first (pending-path)
    ///         routing DETERMINISTIC by call-index parity rather than a fuzzer-chosen bool. This pins the
    ///         pending-path count to ~half of landed forceSlash calls on every seed, removing the
    ///         seed-to-seed variance that made the afterInvariant floor flaky.
    uint256 public ghostForceIndex;

    /// @dev "Non-dust" floor for a meaningful slash, in USDC base-6. forceSlash always stakes well above this.
    uint256 internal constant NON_DUST = 1e6; // 1 USDC

    constructor(ObulusStakingVault _vault, ObulusEscrow _escrow, MockUSDC _usdc, address _treasury, address _arbiter) {
        vault = _vault;
        escrow = _escrow;
        usdc = _usdc;
        treasury = _treasury;
        arbiter = _arbiter;

        Vm.Wallet memory w = vm.createWallet("sv-seller");
        sellerPk = w.privateKey;
        seller = w.addr;

        for (uint256 i; i < 3; i++) {
            buyers.push(address(uint160(uint256(keccak256(abi.encodePacked("sv-buyer-", i))))));
        }

        // Everyone who can stake: the seller + all buyers.
        _setupStaker(seller);
        for (uint256 i; i < buyers.length; i++) {
            _setupStaker(buyers[i]);
        }
    }

    function _setupStaker(address a) internal {
        usdc.mint(a, 1e18);
        vm.startPrank(a);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
        stakers.push(a);
    }

    // --- vault actions ---------------------------------------------------------------------------

    function stake(uint256 sSeed, uint256 amount) public {
        address a = stakers[sSeed % stakers.length];
        uint256 amt = _bound(amount, 1, 1_000e6);
        vm.prank(a);
        try vault.stake(amt) {} catch {}
    }

    function unstake(uint256 sSeed, uint256 amount) public {
        address a = stakers[sSeed % stakers.length];
        uint256 s = vault.stakeOf(a);
        if (s == 0) return;
        uint256 amt = _bound(amount, 1, s);
        vm.prank(a);
        try vault.unstake(amt) {} catch {}
    }

    function withdraw(uint256 sSeed) public {
        address a = stakers[sSeed % stakers.length];
        vm.prank(a);
        try vault.withdraw() {} catch {}
    }

    // --- escrow driver: fund → markDelivered → dispute, so slash has real Disputed deals -----------

    /// @dev Create a fresh disputed deal whose buyer is one of our buyers and seller is the signing wallet.
    function makeDisputedDeal(uint256 bSeed) public {
        address buyer = buyers[bSeed % buyers.length];
        _newDisputedDeal(buyer); // best-effort; records into `deals` on success
    }

    /// @dev Internal: build one Disputed deal with `buyer` as a party. Returns 0x0 on any step failure.
    ///      Used both by the randomised `makeDisputedDeal` and the deterministic `forceSlash`.
    function _newDisputedDeal(address buyer) internal returns (bytes32 id) {
        IEscrow.Offer memory o = IEscrow.Offer({
            seller: seller,
            buyer: buyer,
            arbiter: arbiter,
            token: address(usdc),
            price: 100e6,
            buyerBond: 10e6,
            sellerBond: 10e6,
            // Far-future deadlines so a fuzz `warp` (up to 15 days) between fund/markDelivered cannot expire
            // the deal and silently starve the slash path. fund+markDelivered+dispute all run in ONE call
            // here (same block.timestamp), so a generous window only ever helps the deal reach Disputed.
            deliverDeadline: uint64(block.timestamp + 3650 days),
            confirmWindow: uint64(365 days),
            feeBps: 100,
            specHash: keccak256(abi.encode(seller, nonceOf[seller])),
            nonce: nonceOf[seller]++,
            sigDeadline: uint64(block.timestamp + 365 days)
        });
        bytes32 digest = escrow.hashOffer(o);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, digest);
        vm.prank(buyer);
        try escrow.fund(o, abi.encodePacked(r, s, v)) returns (bytes32 funded) {
            vm.prank(seller);
            try escrow.markDelivered(funded, keccak256(abi.encode(funded))) {
                vm.prank(buyer);
                try escrow.dispute(funded) {
                    deals.push(funded);
                    id = funded;
                } catch {}
            } catch {}
        } catch {}
    }

    /// @dev Arbiter slashes a party of a tracked deal. The slash MUST keep conservation (funds → treasury).
    ///      Randomised input; mostly self-skips. ghost counters are updated on any landed slash.
    function slash(uint256 dSeed, uint256 amount, bool targetBuyer) public {
        uint256 n = deals.length;
        if (n == 0) return;
        bytes32 dealId = deals[dSeed % n];
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        address account = targetBuyer ? d.buyer : d.seller;
        _arbiterSlash(dealId, account, _bound(amount, 0, 2_000e6));
    }

    /// @dev DETERMINISTIC, load-bearing slash. Guarantees a real non-dust arbiter slash actually lands so the
    ///      conservation invariants are exercised against genuine slash accounting on EVERY call (subject to
    ///      single-shot-per-deal: a fresh deal is minted each time). The pending-path (unstake-first) routing
    ///      is chosen DETERMINISTICALLY by call-index parity — NOT a fuzzer bool — so roughly half of all
    ///      landed forceSlash calls drain to the pending bucket on EVERY seed. This pins the pending-path
    ///      count instead of leaving it to the fuzzer's bool distribution, which is what made the
    ///      afterInvariant floor flaky across seeds. fail_on_revert stays sane: each sub-step is guarded, and
    ///      the slash itself is built to land (adequate stake, live disputed deal, arbiter caller, party
    ///      target, requested amount above the cap). The `_unused` parameter is kept only so the selector
    ///      signature/weighting in the invariant harness is unchanged; its value is ignored.
    function forceSlash(uint256 sSeed, bool _unused) public {
        _unused; // routing is by parity below, not by this bool
        ghostForceEntries += 1;
        // DETERMINISTIC pending-path routing: alternate by call-index parity so ~half of all landed slashes
        // reach into the pending bucket regardless of fuzz seed.
        bool unstakeFirst = (ghostForceIndex % 2 == 0);
        ghostForceIndex += 1;
        // Use a BUYER as the slashed party (buyers are funded actors; seller is the signing wallet).
        address party = buyers[sSeed % buyers.length];

        // Ensure adequate stake well above the dust floor (top up so the cap is non-dust even after prior
        // slashes/unstakes shrank the base).
        uint256 want = 500e6;
        (uint256 pendAmt,) = vault.pendingWithdrawal(party);
        uint256 have = vault.stakeOf(party) + pendAmt;
        if (have < want) {
            uint256 topUp = want - have;
            // Mint generously so the stake always succeeds regardless of prior spend.
            usdc.mint(party, topUp);
            vm.prank(party);
            try vault.stake(topUp) {} catch { ghostForceBailedTopUp += 1; return; }
        }

        // Optionally drain standing stake into the pending bucket FIRST — the exact unstake-evasion move.
        if (unstakeFirst) {
            uint256 s = vault.stakeOf(party);
            if (s != 0) {
                vm.prank(party);
                try vault.unstake(s) {} catch {}
            }
        }

        // Mint a fresh live Disputed deal in which `party` is the buyer.
        bytes32 dealId = _newDisputedDeal(party);
        if (dealId == bytes32(0)) { ghostForceBailedDeal += 1; return; }

        // Request well above any cap so the executed amount is the full cap of the (non-dust) base.
        _arbiterSlash(dealId, party, type(uint256).max);
    }

    /// @dev Shared slash executor with ghost accounting. Measures the treasury delta so the ghost counters
    ///      reflect what ACTUALLY moved, not what was requested.
    function _arbiterSlash(bytes32 dealId, address account, uint256 amount) internal {
        bool reachesPending = vault.stakeOf(account) < _minNonZero(amount, _capOf(account));
        uint256 treBefore = usdc.balanceOf(treasury);
        vm.prank(arbiter);
        try vault.slash(dealId, account, amount) {
            uint256 moved = usdc.balanceOf(treasury) - treBefore;
            if (moved != 0) {
                ghostSlashCount += 1;
                ghostSlashedTotal += moved;
                if (moved >= NON_DUST) ghostNonDustSlashCount += 1;
                if (reachesPending) ghostPendingSlashCount += 1;
            }
        } catch {}
    }

    /// @dev An adversary tries to slash; must never succeed (not the arbiter) → conservation unaffected.
    function slashByStranger(uint256 dSeed, uint256 amount) public {
        uint256 n = deals.length;
        if (n == 0) return;
        bytes32 dealId = deals[dSeed % n];
        IEscrow.Deal memory d = escrow.getDeal(dealId);
        vm.prank(address(uint160(uint256(keccak256("sv-stranger")))));
        try vault.slash(dealId, d.buyer, _bound(amount, 0, 2_000e6)) {} catch {}
    }

    /// @dev Resolve a disputed deal sometimes, so slash starts refusing it (post-terminal path).
    function resolveDeal(uint256 dSeed, uint256 bps) public {
        uint256 n = deals.length;
        if (n == 0) return;
        bytes32 dealId = deals[dSeed % n];
        if (escrow.getDeal(dealId).state != IEscrow.State.Disputed) return;
        vm.prank(arbiter);
        try escrow.resolve(dealId, uint16(_bound(bps, 0, 10_000))) {} catch {}
    }

    function warp(uint256 dt) public {
        vm.warp(block.timestamp + _bound(dt, 1, 15 days));
    }

    // --- views for the invariant -----------------------------------------------------------------

    function stakersLength() external view returns (uint256) {
        return stakers.length;
    }

    function stakersList(uint256 i) external view returns (address) {
        return stakers[i];
    }

    function dealsLength() external view returns (uint256) {
        return deals.length;
    }

    // --- helpers ---------------------------------------------------------------------------------

    function _capOf(address account) internal view returns (uint256) {
        (uint256 pendAmt,) = vault.pendingWithdrawal(account);
        uint256 base = vault.stakeOf(account) + pendAmt;
        return (base * vault.slashCapBps()) / 10_000;
    }

    function _minNonZero(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) (lo, hi) = (hi, lo);
        return lo + (x % (hi - lo + 1));
    }
}
