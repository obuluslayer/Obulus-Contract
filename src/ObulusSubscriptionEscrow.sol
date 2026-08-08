// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ObulusSubscriptionEscrow — recurring agent↔agent escrow (Tier 3) settled in USDG on Robinhood Chain
/// @author Obulus
/// @notice Sibling of `ObulusEscrow` for *continuous* services: the subscriber prepays N periods, the
///         provider claims each period after a challenge window (optimistic release), the subscriber
///         can dispute a period (bridled arbiter) or revoke the subscription (refunding the
///         unconsumed periods). Same economic model as Tier 2, applied per period.
///
/// @dev    ⚠️ DRAFT. NEW immutable, fund-holding contract — the highest-risk component. MUST receive
///         an independent external audit + extensive invariant/fuzz testing before holding real funds.
///
/// Dispute model (v1 — fixes the v0 single-cursor freeze): claim/dispute advance a time-ordered
/// `cursor`. Disputing the cursor period SETS IT ASIDE (advances the cursor) so later periods keep
/// settling in parallel; a set-aside period is resolved independently by its index via
/// `resolvePeriod(subId, period, …)` / `resolvePeriodExpired(subId, period)`. So a single slow
/// dispute no longer blocks claims, later disputes, `close` or `revoke`, and never expires the
/// dispute windows of subsequent periods. Pending disputes only ever delay `close` (bonds return).
/// `claimPeriod` is permissionless, so the subscriber can advance the cursor itself (by accepting a
/// fine period) to reach and dispute a later one.
///
/// Liveness backstop: `expireSub` is a permissionless, time-gated full settlement (analog of
/// ObulusEscrow.refundExpired) so funds can NEVER be frozen by mutual inactivity (both parties gone).
///
/// Anti-grief: disputing requires a deposit (= periodPrice), forfeited to the seller if the dispute is
/// frivolous (subscriber ruled against) and refunded otherwise (tie, seller-fault, or absent arbiter),
/// so spamming disputes is costly for the subscriber.
///
/// Remaining known limitations (audit + tuning before real funds):
///  - `revoke` does not pro-rate the in-progress period (it is refunded to the subscriber).
///  - A subscriber can still delay the seller's liquidity by ~resolveTimeout per dispute; size
///    resolveTimeout and pick available arbiters accordingly.
///
/// Design invariants (mirrors ObulusEscrow.sol):
///  - Funds are only ever held by this contract; the owner has NO power to move them.
///  - The arbiter is *bridled*: `resolvePeriod` only splits ONE period's price between that sub's
///    subscriber/seller (+ capped protocol fee + capped arbitration fee from a bounded bond slash).
///  - All payouts are pull-based (`credits` + `withdraw`).
///  - Bond slashing is bounded per period (`bond/numPeriods`) and by the remaining bond.
///  - Conservation: usdg.balanceOf(this) ==
///        Σ_subs (escrowedPrice + sellerBondRem + subscriberBondRem) + Σ credits[].
///    At all times escrowedPrice == (numPeriods - settledCount) * periodPrice.
/// @custom:landing        https://obuluslayer.xyz/
/// @custom:dapp           https://app.obuluslayer.xyz/
/// @custom:documentation  https://gitbook.obuluslayer.xyz/
/// @custom:github         https://github.com/obuluslayer
/// @custom:x              https://x.com/obuluslayer
/// @custom:telegram       https://t.me/obuluslayer
contract ObulusSubscriptionEscrow is EIP712, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000;
    uint16 public constant MAX_ARB_FEE_BPS = 5_000;

    bytes32 public constant SUB_OFFER_TYPEHASH = keccak256(
        "SubOffer(address seller,address subscriber,address arbiter,address token,uint256 periodPrice,uint256 sellerBond,uint256 subscriberBond,uint32 numPeriods,uint64 periodLength,uint64 challengeWindow,uint64 startAt,uint16 feeBps,bytes32 specHash,uint256 nonce,uint64 sigDeadline)"
    );

    IERC20 public immutable usdg;
    uint16 public immutable arbFeeBps;
    uint64 public immutable resolveTimeout;

    uint16 public feeBps;
    address public treasury;

    enum State {
        None,
        Active,
        Closed
    }

    struct SubOffer {
        address seller;
        address subscriber; // address(0) → open: the funder becomes the subscriber
        address arbiter;
        address token; // must equal usdg
        uint256 periodPrice;
        uint256 sellerBond; // provider stake, posted at activate
        uint256 subscriberBond; // anti-abuse, posted at start
        uint32 numPeriods;
        uint64 periodLength; // seconds
        uint64 challengeWindow; // seconds after a period ends, during which the subscriber may dispute
        uint64 startAt; // unix ts of period 0 start
        uint16 feeBps;
        bytes32 specHash;
        uint256 nonce;
        uint64 sigDeadline;
    }

    struct Sub {
        address subscriber;
        address seller;
        address arbiter;
        uint256 periodPrice;
        uint256 sellerBond; // original (for the per-period slash cap)
        uint256 subscriberBond; // original
        uint256 escrowedPrice; // remaining prepaid price still held
        uint256 sellerBondRem; // remaining seller bond
        uint256 subscriberBondRem; // remaining subscriber bond
        uint256 depositHeld; // anti-grief dispute deposits currently held for pending disputes
        uint32 numPeriods;
        uint32 cursor; // next period to claim/dispute (time-ordered)
        uint32 settledCount; // periods finalized (claim/resolve/expire/revoke)
        uint64 periodLength;
        uint64 challengeWindow;
        uint64 startAt;
        uint64 activatedAt; // when the seller activated; accrual starts at max(startAt, activatedAt)
        uint16 feeBps;
        bool activated;
        State state;
    }

    mapping(bytes32 subId => Sub) internal subs;
    /// @notice period dispute timestamps: subId → period → disputedAt (0 = not under a pending dispute).
    mapping(bytes32 subId => mapping(uint32 period => uint64)) public periodDisputedAt;
    /// @notice Withdrawable balances (pull payments).
    mapping(address account => uint256) public credits;
    /// @notice seller → nonce → cancelled (invalidate an un-started offer).
    mapping(address seller => mapping(uint256 nonce => bool)) public cancelledNonce;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event SubStarted(
        bytes32 indexed subId,
        address indexed subscriber,
        address indexed seller,
        address arbiter,
        uint256 periodPrice,
        uint32 numPeriods,
        uint64 startAt,
        uint64 periodLength,
        uint64 challengeWindow,
        uint16 feeBps,
        bytes32 specHash
    );
    event SubActivated(bytes32 indexed subId, address indexed seller, uint256 sellerBond);
    event PeriodClaimed(bytes32 indexed subId, address indexed by, uint32 period, uint256 sellerPayout, uint256 fee);
    event PeriodDisputed(bytes32 indexed subId, address indexed subscriber, uint32 period, uint64 resolveBy);
    event PeriodResolved(
        bytes32 indexed subId,
        address indexed arbiter,
        uint32 period,
        uint16 sellerBps,
        uint256 sellerCredit,
        uint256 subscriberCredit,
        uint256 fee,
        uint256 arbFee
    );
    event SubRevoked(bytes32 indexed subId, address indexed by, uint256 refundedPrice, uint256 sellerEarned, uint32 periodsLeft);
    event SubClosed(bytes32 indexed subId, uint256 sellerBondReturned, uint256 subscriberBondReturned);
    event Withdrawn(address indexed account, uint256 amount);
    event OfferCancelled(address indexed seller, uint256 nonce);
    event TreasuryUpdated(address treasury);
    event FeeBpsUpdated(uint16 feeBps);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error FeeTooHigh();
    error ArbFeeTooHigh();
    error TokenMismatch();
    error InvalidParams();
    error OfferExpired();
    error NonceCancelled();
    error BadSignature();
    error SubExists(bytes32 subId);
    error WrongState();
    error NotSubscriber();
    error NotSeller();
    error NotArbiter();
    error NotActivated();
    error AlreadyActivated();
    error NotDisputed();
    error AlreadyDisputed();
    error NothingDue();
    error PeriodNotElapsed();
    error WindowElapsed();
    error PeriodNotStarted();
    error AllPeriodsSettled();
    error DeadlineNotReached();
    error InvalidBps();
    error NotDesignatedSubscriber();
    error NothingToWithdraw();
    error DisputesPending();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    constructor(address usdg_, address treasury_, uint16 feeBps_, uint16 arbFeeBps_, uint64 resolveTimeout_)
        EIP712("ObulusSubscription", "1")
        Ownable(msg.sender)
    {
        if (usdg_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (arbFeeBps_ > MAX_ARB_FEE_BPS) revert ArbFeeTooHigh();
        if (resolveTimeout_ == 0) revert InvalidParams();
        usdg = IERC20(usdg_);
        treasury = treasury_;
        feeBps = feeBps_;
        arbFeeBps = arbFeeBps_;
        resolveTimeout = resolveTimeout_;
        emit TreasuryUpdated(treasury_);
        emit FeeBpsUpdated(feeBps_);
    }

    // ---------------------------------------------------------------------------------------------
    // start — subscriber prepays N periods from a signed offer
    // ---------------------------------------------------------------------------------------------

    function start(SubOffer calldata offer, bytes calldata sellerSig) external nonReentrant returns (bytes32 subId) {
        if (offer.token != address(usdg)) revert TokenMismatch();
        if (offer.seller == address(0) || offer.arbiter == address(0)) revert ZeroAddress();
        if (block.timestamp > offer.sigDeadline) revert OfferExpired();
        if (offer.numPeriods == 0 || offer.periodLength == 0 || offer.periodPrice == 0) revert InvalidParams();
        if (offer.feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        // A non-zero bond smaller than numPeriods would never be slashable (floor(bond/N)==0): reject it.
        if (offer.sellerBond != 0 && offer.sellerBond < offer.numPeriods) revert InvalidParams();
        if (offer.subscriberBond != 0 && offer.subscriberBond < offer.numPeriods) revert InvalidParams();
        if (cancelledNonce[offer.seller][offer.nonce]) revert NonceCancelled();

        subId = _hashOffer(offer);
        if (subs[subId].state != State.None) revert SubExists(subId);
        if (!SignatureChecker.isValidSignatureNow(offer.seller, subId, sellerSig)) revert BadSignature();

        address subscriber = offer.subscriber;
        if (subscriber == address(0)) {
            subscriber = msg.sender;
        } else if (msg.sender != subscriber) {
            revert NotDesignatedSubscriber();
        }

        uint256 totalPrice = uint256(offer.numPeriods) * offer.periodPrice;

        Sub storage s = subs[subId];
        s.subscriber = subscriber;
        s.seller = offer.seller;
        s.arbiter = offer.arbiter;
        s.periodPrice = offer.periodPrice;
        s.sellerBond = offer.sellerBond;
        s.subscriberBond = offer.subscriberBond;
        s.escrowedPrice = totalPrice;
        s.subscriberBondRem = offer.subscriberBond;
        s.numPeriods = offer.numPeriods;
        s.periodLength = offer.periodLength;
        s.challengeWindow = offer.challengeWindow;
        s.startAt = offer.startAt;
        s.feeBps = offer.feeBps;
        s.state = State.Active;

        emit SubStarted(
            subId,
            subscriber,
            offer.seller,
            offer.arbiter,
            offer.periodPrice,
            offer.numPeriods,
            offer.startAt,
            offer.periodLength,
            offer.challengeWindow,
            offer.feeBps,
            offer.specHash
        );

        usdg.safeTransferFrom(msg.sender, address(this), totalPrice + offer.subscriberBond);
    }

    // ---------------------------------------------------------------------------------------------
    // activate — seller posts their bond to begin serving
    // ---------------------------------------------------------------------------------------------

    function activate(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (msg.sender != s.seller) revert NotSeller();
        if (s.activated) revert AlreadyActivated();

        s.activated = true;
        s.activatedAt = uint64(block.timestamp);
        s.sellerBondRem = s.sellerBond;
        emit SubActivated(subId, s.seller, s.sellerBond);

        if (s.sellerBond != 0) usdg.safeTransferFrom(msg.sender, address(this), s.sellerBond);
    }

    // ---------------------------------------------------------------------------------------------
    // claimPeriod — optimistic release of the cursor period after its challenge window
    // ---------------------------------------------------------------------------------------------

    function claimPeriod(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (!s.activated) revert NotActivated();
        if (s.cursor >= s.numPeriods) revert AllPeriodsSettled();

        uint32 p = s.cursor; // the cursor period is never under dispute (disputing advances the cursor)
        uint256 claimableAt = _effStart(s) + (uint256(p) + 1) * s.periodLength + s.challengeWindow;
        if (block.timestamp <= claimableAt) revert PeriodNotElapsed();

        uint256 fee = (s.periodPrice * s.feeBps) / BPS;
        uint256 sellerPayout = s.periodPrice - fee;

        s.escrowedPrice -= s.periodPrice;
        s.settledCount += 1;
        s.cursor = p + 1;

        credits[s.seller] += sellerPayout;
        if (fee != 0) credits[treasury] += fee;

        emit PeriodClaimed(subId, msg.sender, p, sellerPayout, fee);
        if (s.settledCount == s.numPeriods) _close(subId, s);
    }

    // ---------------------------------------------------------------------------------------------
    // disputePeriod — subscriber contests the cursor period; sets it aside (cursor advances)
    // ---------------------------------------------------------------------------------------------

    function disputePeriod(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (!s.activated) revert NotActivated();
        if (msg.sender != s.subscriber) revert NotSubscriber();
        if (s.cursor >= s.numPeriods) revert AllPeriodsSettled();

        uint32 p = s.cursor;
        uint256 eff = _effStart(s);
        uint256 periodStart = eff + uint256(p) * s.periodLength;
        uint256 windowEnd = eff + (uint256(p) + 1) * s.periodLength + s.challengeWindow;
        if (block.timestamp < periodStart) revert PeriodNotStarted();
        if (block.timestamp > windowEnd) revert WindowElapsed();

        // Set the period aside (does NOT settle it) and advance the cursor so later periods proceed.
        periodDisputedAt[subId][p] = uint64(block.timestamp);
        s.cursor = p + 1;
        s.depositHeld += s.periodPrice; // anti-grief deposit: refunded if upheld, forfeited if frivolous
        emit PeriodDisputed(subId, s.subscriber, p, uint64(block.timestamp) + resolveTimeout);

        usdg.safeTransferFrom(msg.sender, address(this), s.periodPrice);
    }

    // ---------------------------------------------------------------------------------------------
    // resolvePeriod — bridled arbiter splits a set-aside period's price (+ bounded bond slash)
    // ---------------------------------------------------------------------------------------------

    function resolvePeriod(bytes32 subId, uint32 period, uint16 sellerBps) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (msg.sender != s.arbiter) revert NotArbiter();
        if (periodDisputedAt[subId][period] == 0) revert NotDisputed();
        if (sellerBps > BPS) revert InvalidBps();

        uint256 price = s.periodPrice;
        uint256 sellerPrice = (price * sellerBps) / BPS;
        uint256 buyerPrice = price - sellerPrice; // subtraction → dust-free
        uint256 fee = (sellerPrice * s.feeBps) / BPS;

        uint256 sellerCredit = sellerPrice - fee;
        uint256 subscriberCredit = buyerPrice;
        uint256 arbFee;

        if (sellerBps > BPS / 2) {
            uint256 slash = _slash(s.subscriberBond, s.subscriberBondRem, s.numPeriods);
            s.subscriberBondRem -= slash;
            arbFee = (slash * arbFeeBps) / BPS;
            sellerCredit += (slash - arbFee);
        } else if (sellerBps < BPS / 2) {
            uint256 slash = _slash(s.sellerBond, s.sellerBondRem, s.numPeriods);
            s.sellerBondRem -= slash;
            arbFee = (slash * arbFeeBps) / BPS;
            subscriberCredit += (slash - arbFee);
        }
        // sellerBps == BPS/2 → no fault, no slash, no arbFee.

        // Dispute deposit (= periodPrice): frivolous dispute (subscriber wrong) → seller; else refunded.
        if (sellerBps > BPS / 2) sellerCredit += price;
        else subscriberCredit += price;
        s.depositHeld -= price;

        s.escrowedPrice -= price;
        s.settledCount += 1;
        periodDisputedAt[subId][period] = 0;

        credits[s.seller] += sellerCredit;
        credits[s.subscriber] += subscriberCredit;
        if (fee != 0) credits[treasury] += fee;
        if (arbFee != 0) credits[s.arbiter] += arbFee;

        emit PeriodResolved(subId, s.arbiter, period, sellerBps, sellerCredit, subscriberCredit, fee, arbFee);
        if (s.settledCount == s.numPeriods) _close(subId, s);
    }

    /// @notice Absent-arbiter fallback for a set-aside period: anyone can settle it after the timeout
    ///         as a neutral 50/50 split of the period price (no slash, no fee).
    function resolvePeriodExpired(bytes32 subId, uint32 period) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        uint64 dAt = periodDisputedAt[subId][period];
        if (dAt == 0) revert NotDisputed();
        if (block.timestamp <= uint256(dAt) + resolveTimeout) revert DeadlineNotReached();

        uint256 price = s.periodPrice;
        uint256 sellerHalf = price / 2;
        uint256 buyerHalf = price - sellerHalf;

        s.escrowedPrice -= price;
        s.depositHeld -= price; // refund the dispute deposit — arbiter absence isn't the subscriber's fault
        s.settledCount += 1;
        periodDisputedAt[subId][period] = 0;

        credits[s.seller] += sellerHalf;
        credits[s.subscriber] += buyerHalf + price; // half the period price + the refunded deposit
        emit PeriodResolved(subId, address(0), period, BPS / 2, sellerHalf, buyerHalf, 0, 0);
        if (s.settledCount == s.numPeriods) _close(subId, s);
    }

    // ---------------------------------------------------------------------------------------------
    // revoke — subscriber cancels the remaining (non-disputed) periods
    // ---------------------------------------------------------------------------------------------

    /// @notice Cancels every not-yet-handled period at once: fully-served periods are paid to the
    ///         seller (deemed accepted — the subscriber chose to revoke rather than dispute), the rest
    ///         is refunded to the subscriber. Periods already set aside under dispute are unaffected
    ///         and must still be resolved; bonds return at `close`. v1 NOTE: no intra-period proration
    ///         — a period in progress (started, not ended) is refunded to the subscriber.
    function revoke(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (msg.sender != s.subscriber) revert NotSubscriber();
        if (s.cursor >= s.numPeriods) revert NothingDue();
        _settleRemaining(subId, s);
    }

    // ---------------------------------------------------------------------------------------------
    // expireSub — permissionless liveness backstop (analog of ObulusEscrow.refundExpired)
    // ---------------------------------------------------------------------------------------------

    /// @notice Once the whole subscription is long over, ANYONE can force-settle the not-yet-handled
    ///         periods so funds can never be frozen by mutual inactivity (both parties gone). Served
    ///         periods → seller (deemed accepted), the rest → subscriber; set-aside disputes still
    ///         settle via `resolvePeriodExpired` (also permissionless). Closes if nothing is pending.
    function expireSub(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (s.cursor >= s.numPeriods) revert NothingDue();
        // Only after every period's service + challenge window has closed, plus a grace = resolveTimeout.
        uint256 hardEnd =
            _effStart(s) + uint256(s.numPeriods) * s.periodLength + s.challengeWindow + resolveTimeout;
        if (block.timestamp <= hardEnd) revert DeadlineNotReached();
        _settleRemaining(subId, s);
    }

    // ---------------------------------------------------------------------------------------------
    // close — all periods consumed: return the remaining bonds
    // ---------------------------------------------------------------------------------------------

    function close(bytes32 subId) external nonReentrant {
        Sub storage s = subs[subId];
        if (s.state != State.Active) revert WrongState();
        if (s.settledCount < s.numPeriods) revert DisputesPending();
        _close(subId, s);
    }

    function _close(bytes32 subId, Sub storage s) private {
        uint256 sellerBack = s.sellerBondRem;
        uint256 subBack = s.subscriberBondRem;
        s.sellerBondRem = 0;
        s.subscriberBondRem = 0;
        s.state = State.Closed;

        if (sellerBack != 0) credits[s.seller] += sellerBack;
        if (subBack != 0) credits[s.subscriber] += subBack;

        emit SubClosed(subId, sellerBack, subBack);
    }

    // ---------------------------------------------------------------------------------------------
    // withdraw (pull payments)
    // ---------------------------------------------------------------------------------------------

    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        usdg.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Offer cancellation + admin (fee/treasury knobs only — never touch sub funds)
    // ---------------------------------------------------------------------------------------------

    function cancelOffer(uint256 nonce) external {
        cancelledNonce[msg.sender][nonce] = true;
        emit OfferCancelled(msg.sender, nonce);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeBpsUpdated(newFeeBps);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function hashSubOffer(SubOffer calldata offer) external view returns (bytes32) {
        return _hashOffer(offer);
    }

    function getSub(bytes32 subId) external view returns (Sub memory) {
        return subs[subId];
    }

    /// @notice Number of periods set aside under a still-pending dispute (delays close).
    function pendingDisputes(bytes32 subId) external view returns (uint32) {
        Sub memory s = subs[subId];
        return s.cursor - s.settledCount;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    /// @dev Settles every not-yet-handled period [cursor, numPeriods): fully-ended periods are paid to
    ///      the seller (deemed accepted), the rest refunded to the subscriber. Shared by revoke (only
    ///      the subscriber) and expireSub (permissionless, time-gated). Auto-closes if none pending.
    function _settleRemaining(bytes32 subId, Sub storage s) private {
        uint32 cursor = s.cursor;
        uint32 remaining = s.numPeriods - cursor;
        uint32 served = 0;
        if (s.activated && block.timestamp > _effStart(s)) {
            uint256 ended = (block.timestamp - _effStart(s)) / s.periodLength; // # of periods fully ended
            if (ended > s.numPeriods) ended = s.numPeriods;
            if (ended > cursor) served = uint32(ended) - cursor;
        }
        uint32 future = remaining - served;

        uint256 feePer = (s.periodPrice * s.feeBps) / BPS;
        uint256 sellerEarned = uint256(served) * (s.periodPrice - feePer);
        uint256 feeTotal = uint256(served) * feePer;
        uint256 refund = uint256(future) * s.periodPrice;

        s.escrowedPrice -= uint256(remaining) * s.periodPrice;
        s.settledCount += remaining;
        s.cursor = s.numPeriods;

        if (refund != 0) credits[s.subscriber] += refund;
        if (sellerEarned != 0) credits[s.seller] += sellerEarned;
        if (feeTotal != 0) credits[treasury] += feeTotal;

        emit SubRevoked(subId, msg.sender, refund, sellerEarned, future);
        if (s.settledCount == s.numPeriods) _close(subId, s);
    }

    /// @dev Period accrual starts no earlier than the seller's activation (anti late-activate).
    function _effStart(Sub storage s) private view returns (uint256) {
        return s.startAt > s.activatedAt ? s.startAt : s.activatedAt;
    }

    /// @dev Per-period bounded slash: min(bond/numPeriods, remaining). Guarantees Σ slashes ≤ bond.
    function _slash(uint256 bond, uint256 remaining, uint32 numPeriods) private pure returns (uint256) {
        uint256 cap = bond / numPeriods;
        return cap < remaining ? cap : remaining;
    }

    function _hashOffer(SubOffer calldata o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SUB_OFFER_TYPEHASH,
                o.seller,
                o.subscriber,
                o.arbiter,
                o.token,
                o.periodPrice,
                o.sellerBond,
                o.subscriberBond,
                o.numPeriods,
                o.periodLength,
                o.challengeWindow,
                o.startAt,
                o.feeBps,
                o.specHash,
                o.nonce,
                o.sigDeadline
            )
        );
        return _hashTypedDataV4(structHash);
    }
}
