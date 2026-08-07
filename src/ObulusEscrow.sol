// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEscrow} from "./interfaces/IEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ObulusEscrow — agent↔agent conditional escrow settled in USDC on Robinhood Chain
/// @author Obulus
/// @custom:x https://x.com/obuluslayer
/// @notice Non-custodial escrow for AI-agent commerce (Tier 2: optimistic release, arbiter on dispute).
///
/// Design invariants:
///  - Funds are only ever held by this contract; the owner has NO power to move deal funds.
///  - The arbiter is *bridled*: `resolve` can only split a disputed deal between its own buyer/seller
///    (+ protocol fee + a capped arbitration fee). A compromised arbiter key cannot steal — only mis-split.
///  - All payouts are pull-based (`credits` + `withdraw`) so a blocklisted/reverting party can never
///    brick a deal's transition or freeze a counterparty (USDC is upgradeable and has a blocklist).
///  - Every terminal path conserves funds exactly: sum(payouts + fees) == total deposited (no dust).
contract ObulusEscrow is IEscrow, EIP712, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------------------------------

    uint16 internal constant BPS = 10_000;
    /// @notice Hard ceiling on the protocol commission (10%).
    uint16 public constant MAX_FEE_BPS = 1_000;
    /// @notice Hard ceiling on the arbitration fee, as a fraction of the slashed bond (50%).
    uint16 public constant MAX_ARB_FEE_BPS = 5_000;

    /// @notice EIP-712 type hash for the signed `Offer`.
    bytes32 public constant OFFER_TYPEHASH = keccak256(
        "Offer(address seller,address buyer,address arbiter,address token,uint256 price,uint256 buyerBond,uint256 sellerBond,uint64 deliverDeadline,uint64 confirmWindow,uint16 feeBps,bytes32 specHash,uint256 nonce,uint64 sigDeadline)"
    );

    /// @notice The settlement token (USDC on Robinhood Chain).
    IERC20 public immutable usdc;
    /// @notice Arbitration fee as a fraction (bps) of the losing party's slashed bond.
    uint16 public immutable arbFeeBps;
    /// @notice Grace period after a dispute before anyone may trigger the absent-arbiter fallback.
    uint64 public immutable resolveTimeout;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Protocol commission advertised for new offers; snapshotted per-deal from the signed offer.
    uint16 public feeBps;
    /// @notice Where protocol commissions accrue (pull-based, like any other party).
    address public treasury;

    /// @notice dealId (== EIP-712 offer digest) → deal record.
    mapping(bytes32 dealId => Deal) internal deals;
    /// @notice Withdrawable balances. Settlement credits here; parties pull via `withdraw`.
    mapping(address account => uint256) public credits;
    /// @notice seller → nonce → cancelled. Lets a seller invalidate an unfunded offer.
    mapping(address seller => mapping(uint256 nonce => bool)) public cancelledNonce;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    constructor(address usdc_, address treasury_, uint16 feeBps_, uint16 arbFeeBps_, uint64 resolveTimeout_)
        EIP712("Obulus", "1")
        Ownable(msg.sender)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        if (arbFeeBps_ > MAX_ARB_FEE_BPS) revert ArbFeeTooHigh();
        if (resolveTimeout_ == 0) revert InvalidDeadline();
        if (resolveTimeout_ > 365 days) revert InvalidDeadline(); // bound so disputedAt + resolveTimeout (uint64) can't overflow
        usdc = IERC20(usdc_);
        treasury = treasury_;
        feeBps = feeBps_;
        arbFeeBps = arbFeeBps_;
        resolveTimeout = resolveTimeout_;
        emit TreasuryUpdated(treasury_);
        emit FeeBpsUpdated(feeBps_);
    }

    // ---------------------------------------------------------------------------------------------
    // fund — create + fund a deal from a signed offer
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function fund(Offer calldata offer, bytes calldata sellerSig) external nonReentrant returns (bytes32 dealId) {
        if (offer.token != address(usdc)) revert TokenMismatch();
        if (offer.seller == address(0) || offer.arbiter == address(0)) revert ZeroAddress();
        if (block.timestamp > offer.sigDeadline) revert OfferExpired();
        if (offer.deliverDeadline <= block.timestamp) revert InvalidDeadline();
        if (offer.confirmWindow == 0) revert InvalidDeadline();
        // Reject windows so large the uint64 confirm-deadline event math (markDelivered) would overflow —
        // deliveredAt <= deliverDeadline, so bounding their sum prevents the Panic-0x11 self-DoS.
        if (uint256(offer.deliverDeadline) + offer.confirmWindow > type(uint64).max) revert InvalidDeadline();
        if (offer.feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (cancelledNonce[offer.seller][offer.nonce]) revert NonceCancelled();

        // Authenticate the terms: dealId is the EIP-712 digest; the seller must have signed it.
        dealId = _hashOffer(offer);
        if (deals[dealId].state != State.None) revert DealExists(dealId);
        if (!SignatureChecker.isValidSignatureNow(offer.seller, dealId, sellerSig)) revert BadSignature();

        // Resolve the buyer: open offer → funder; directed offer → only the named buyer.
        address buyer = offer.buyer;
        if (buyer == address(0)) {
            buyer = msg.sender;
        } else if (msg.sender != buyer) {
            revert NotDesignatedBuyer();
        }

        // Effects: record the deal (terms frozen here).
        Deal storage d = deals[dealId];
        d.buyer = buyer;
        d.seller = offer.seller;
        d.arbiter = offer.arbiter;
        d.price = offer.price;
        d.buyerBond = offer.buyerBond;
        d.sellerBond = offer.sellerBond;
        d.deliverDeadline = offer.deliverDeadline;
        d.confirmWindow = offer.confirmWindow;
        d.feeBps = offer.feeBps;
        d.state = State.Funded;

        emit DealFunded(
            dealId,
            buyer,
            offer.seller,
            offer.arbiter,
            offer.price,
            offer.buyerBond,
            offer.sellerBond,
            offer.deliverDeadline,
            offer.confirmWindow,
            offer.feeBps,
            offer.specHash
        );

        // Interaction: pull the buyer's price + bond.
        usdc.safeTransferFrom(msg.sender, address(this), offer.price + offer.buyerBond);
    }

    // ---------------------------------------------------------------------------------------------
    // markDelivered — seller posts bond + delivery commitment
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function markDelivered(bytes32 dealId, bytes32 deliveryHash) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Funded) revert WrongState(dealId, State.Funded, d.state);
        if (msg.sender != d.seller) revert NotSeller();
        if (block.timestamp > d.deliverDeadline) revert DeadlinePassed();

        // Effects before interaction (CEI): a misbehaving token cannot re-enter into a second delivery.
        d.deliveredAt = uint64(block.timestamp);
        d.deliveryHash = deliveryHash;
        d.state = State.Delivered;

        emit Delivered(dealId, d.seller, deliveryHash, d.deliveredAt + d.confirmWindow);

        // Interaction: pull the seller's bond now (no bond is locked while a no-show seller stalls).
        uint256 bond = d.sellerBond;
        if (bond != 0) usdc.safeTransferFrom(msg.sender, address(this), bond);
    }

    // ---------------------------------------------------------------------------------------------
    // Happy-path settlement: confirm / claimTimeout
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function confirm(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Delivered) revert WrongState(dealId, State.Delivered, d.state);
        if (msg.sender != d.buyer) revert NotBuyer();
        (uint256 sellerPayout, uint256 fee) = _settleHappy(d);
        emit Confirmed(dealId, d.buyer, sellerPayout, fee);
    }

    /// @inheritdoc IEscrow
    function claimTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Delivered) revert WrongState(dealId, State.Delivered, d.state);
        if (block.timestamp <= uint256(d.deliveredAt) + d.confirmWindow) revert WindowNotElapsed();
        (uint256 sellerPayout, uint256 fee) = _settleHappy(d);
        emit TimedOut(dealId, msg.sender, sellerPayout, fee);
    }

    /// @dev Pays the seller (price − fee + own bond), returns the buyer's bond, accrues the fee. Conserves.
    function _settleHappy(Deal storage d) private returns (uint256 sellerPayout, uint256 fee) {
        d.state = State.Resolved;
        fee = (d.price * d.feeBps) / BPS;
        sellerPayout = (d.price - fee) + d.sellerBond;
        credits[d.seller] += sellerPayout;
        credits[d.buyer] += d.buyerBond;
        if (fee != 0) credits[treasury] += fee;
    }

    // ---------------------------------------------------------------------------------------------
    // Timeout refund: refundExpired
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function refundExpired(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Funded) revert WrongState(dealId, State.Funded, d.state);
        if (block.timestamp <= d.deliverDeadline) revert DeadlineNotReached();

        d.state = State.Resolved;
        // Seller never posted a bond while Funded; only the buyer's price + bond is held.
        uint256 refund = d.price + d.buyerBond;
        credits[d.buyer] += refund;
        emit Refunded(dealId, d.buyer, refund);
    }

    // ---------------------------------------------------------------------------------------------
    // Dispute + arbiter resolution
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function dispute(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Delivered) revert WrongState(dealId, State.Delivered, d.state);
        if (msg.sender != d.buyer) revert NotBuyer();
        if (block.timestamp > uint256(d.deliveredAt) + d.confirmWindow) revert WindowElapsed();

        d.disputedAt = uint64(block.timestamp);
        d.state = State.Disputed;
        emit Disputed(dealId, d.buyer, d.disputedAt + resolveTimeout);
    }

    /// @inheritdoc IEscrow
    function resolve(bytes32 dealId, uint16 sellerBps) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Disputed) revert WrongState(dealId, State.Disputed, d.state);
        if (msg.sender != d.arbiter) revert NotArbiter();
        if (sellerBps > BPS) revert InvalidBps();

        d.state = State.Resolved;

        uint256 sellerPrice = (d.price * sellerBps) / BPS;
        uint256 buyerPrice = d.price - sellerPrice; // subtraction → dust-free
        uint256 fee = (sellerPrice * d.feeBps) / BPS;

        uint256 sellerCredit;
        uint256 buyerCredit;
        uint256 arbFee;

        if (sellerBps > BPS / 2) {
            // Buyer is (mostly) wrong → buyer's bond is slashed to pay arbitration + compensate seller.
            arbFee = (d.buyerBond * arbFeeBps) / BPS;
            sellerCredit = (sellerPrice - fee) + d.sellerBond + (d.buyerBond - arbFee);
            buyerCredit = buyerPrice;
        } else if (sellerBps < BPS / 2) {
            // Seller is (mostly) wrong → seller's bond is slashed.
            arbFee = (d.sellerBond * arbFeeBps) / BPS;
            buyerCredit = buyerPrice + d.buyerBond + (d.sellerBond - arbFee);
            sellerCredit = (sellerPrice - fee);
        } else {
            // Exact tie → no fault: return both bonds, no arbitration fee.
            sellerCredit = (sellerPrice - fee) + d.sellerBond;
            buyerCredit = buyerPrice + d.buyerBond;
        }

        credits[d.seller] += sellerCredit;
        credits[d.buyer] += buyerCredit;
        if (fee != 0) credits[treasury] += fee;
        if (arbFee != 0) credits[d.arbiter] += arbFee;

        emit Resolved(dealId, d.arbiter, sellerBps, sellerCredit, buyerCredit, fee, arbFee);
    }

    /// @inheritdoc IEscrow
    function resolveExpired(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.state != State.Disputed) revert WrongState(dealId, State.Disputed, d.state);
        if (block.timestamp <= uint256(d.disputedAt) + resolveTimeout) revert DeadlineNotReached();

        d.state = State.Resolved;
        // Absent arbiter → neutral undo: buyer made whole, seller's bond returned. No fee, no arb fee.
        uint256 buyerRefund = d.price + d.buyerBond;
        credits[d.buyer] += buyerRefund;
        credits[d.seller] += d.sellerBond;
        emit Resolved(dealId, address(0), 0, d.sellerBond, buyerRefund, 0, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Withdraw (pull payments)
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        usdc.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Offer cancellation
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function cancelOffer(uint256 nonce) external {
        cancelledNonce[msg.sender][nonce] = true;
        emit OfferCancelled(msg.sender, nonce);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin — strictly limited to fee/treasury knobs; never touches deal funds.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @inheritdoc IEscrow
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeBpsUpdated(newFeeBps);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IEscrow
    function hashOffer(Offer calldata offer) external view returns (bytes32) {
        return _hashOffer(offer);
    }

    /// @inheritdoc IEscrow
    function getDeal(bytes32 dealId) external view returns (Deal memory) {
        return deals[dealId];
    }

    /// @notice The EIP-712 domain separator (exposed for off-chain signing/verification parity).
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _hashOffer(Offer calldata o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                OFFER_TYPEHASH,
                o.seller,
                o.buyer,
                o.arbiter,
                o.token,
                o.price,
                o.buyerBond,
                o.sellerBond,
                o.deliverDeadline,
                o.confirmWindow,
                o.feeBps,
                o.specHash,
                o.nonce,
                o.sigDeadline
            )
        );
        return _hashTypedDataV4(structHash);
    }
}
