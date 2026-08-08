// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEscrow — agent↔agent conditional escrow (Tier 2)
/// @notice The interface is the integration contract shared by the off-chain Hub, SDK and frontend.
///         Deals are created on-chain at `fund()` time from a seller-signed EIP-712 `Offer`; the funder
///         (`msg.sender`) is the buyer. All payouts are pull-based (`credits` + `withdraw`).
interface IEscrow {
    /// @dev `None` is the default for an uncreated deal id, so every guarded function reverts on it.
    enum State {
        None,
        Funded,
        Delivered,
        Disputed,
        Resolved
    }

    /// @notice The signed terms of a deal. The EIP-712 hash of this struct is the `dealId`.
    /// @param seller          Service provider; must equal the recovered signer of the offer.
    /// @param buyer           Designated buyer, or address(0) for an open offer fundable by anyone.
    /// @param arbiter         Per-deal arbiter that may `resolve` a dispute (bridled: split only).
    /// @param token           Settlement token; must equal the escrow's immutable USDG address.
    /// @param price           Service price in token base units.
    /// @param buyerBond       Buyer anti-grief bond, posted at fund, returned on happy path.
    /// @param sellerBond      Seller anti-grief bond, posted at markDelivered, returned on happy path.
    /// @param deliverDeadline Absolute unix ts by which the seller must `markDelivered`.
    /// @param confirmWindow   Duration (seconds) of the buyer's review window, started at delivery.
    /// @param feeBps          Protocol commission in bps, agreed in the signature, snapshotted at fund.
    /// @param specHash        Commitment to the off-chain service spec/id/tier.
    /// @param nonce           Seller nonce; lets the seller cancel an unfunded offer via `cancelOffer`.
    /// @param sigDeadline     Absolute unix ts after which the offer signature is no longer fundable.
    struct Offer {
        address seller;
        address buyer;
        address arbiter;
        address token;
        uint256 price;
        uint256 buyerBond;
        uint256 sellerBond;
        uint64 deliverDeadline;
        uint64 confirmWindow;
        uint16 feeBps;
        bytes32 specHash;
        uint256 nonce;
        uint64 sigDeadline;
    }

    /// @notice On-chain deal record. Terms are frozen at fund; timers and outcome fill in over time.
    struct Deal {
        address buyer;
        uint16 feeBps;
        State state;
        address seller;
        address arbiter;
        uint256 price;
        uint256 buyerBond;
        uint256 sellerBond;
        uint64 deliverDeadline;
        uint64 confirmWindow;
        uint64 deliveredAt;
        uint64 disputedAt;
        bytes32 deliveryHash;
    }

    // ---------------------------------------------------------------------------------------------
    // Events — `dealId` indexed first; the Hub reconstructs the full lifecycle from these.
    // ---------------------------------------------------------------------------------------------

    event DealFunded(
        bytes32 indexed dealId,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 price,
        uint256 buyerBond,
        uint256 sellerBond,
        uint64 deliverDeadline,
        uint64 confirmWindow,
        uint16 feeBps,
        bytes32 specHash
    );
    event Delivered(bytes32 indexed dealId, address indexed seller, bytes32 deliveryHash, uint64 confirmDeadline);
    event Confirmed(bytes32 indexed dealId, address indexed buyer, uint256 sellerPayout, uint256 fee);
    event TimedOut(bytes32 indexed dealId, address indexed caller, uint256 sellerPayout, uint256 fee);
    event Refunded(bytes32 indexed dealId, address indexed buyer, uint256 buyerRefund);
    event Disputed(bytes32 indexed dealId, address indexed buyer, uint64 resolveDeadline);
    /// @dev `arbiter` is address(0) when settled via the permissionless `resolveExpired` fallback.
    event Resolved(
        bytes32 indexed dealId,
        address indexed arbiter,
        uint16 sellerBps,
        uint256 sellerPayout,
        uint256 buyerPayout,
        uint256 fee,
        uint256 arbFee
    );
    event Withdrawn(address indexed account, uint256 amount);
    event OfferCancelled(address indexed seller, uint256 indexed nonce);
    event TreasuryUpdated(address indexed treasury);
    event FeeBpsUpdated(uint16 feeBps);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error WrongState(bytes32 dealId, State expected, State actual);
    error NotBuyer();
    error NotSeller();
    error NotArbiter();
    error NotDesignatedBuyer();
    error DealExists(bytes32 dealId);
    error BadSignature();
    error OfferExpired();
    error InvalidDeadline();
    error DeadlinePassed();
    error DeadlineNotReached();
    error WindowNotElapsed();
    error WindowElapsed();
    error InvalidBps();
    error FeeTooHigh();
    error ArbFeeTooHigh();
    error TokenMismatch();
    error NonceCancelled();
    error ZeroAddress();
    error NothingToWithdraw();

    // ---------------------------------------------------------------------------------------------
    // State-transitioning functions
    // ---------------------------------------------------------------------------------------------

    /// @notice Buyer creates and funds a deal from a seller-signed offer. Pulls `price + buyerBond`.
    function fund(Offer calldata offer, bytes calldata sellerSig) external returns (bytes32 dealId);

    /// @notice Seller marks the deliverable committed; pulls `sellerBond` and starts the confirm window.
    function markDelivered(bytes32 dealId, bytes32 deliveryHash) external;

    /// @notice Buyer accepts the delivery; pays the seller and returns both bonds.
    function confirm(bytes32 dealId) external;

    /// @notice Permissionless: after the confirm window elapses with no dispute, pay the seller.
    function claimTimeout(bytes32 dealId) external;

    /// @notice Permissionless: after the deliver deadline elapses with no delivery, refund the buyer.
    function refundExpired(bytes32 dealId) external;

    /// @notice Buyer contests the delivery before the window closes.
    function dispute(bytes32 dealId) external;

    /// @notice Arbiter-only: split a disputed deal. `sellerBps` is the seller's share of the price in bps.
    function resolve(bytes32 dealId, uint16 sellerBps) external;

    /// @notice Permissionless fallback: if the arbiter never resolves, refund the buyer and return bonds.
    function resolveExpired(bytes32 dealId) external;

    /// @notice Withdraw the caller's accumulated payout credits.
    function withdraw() external;

    /// @notice Seller invalidates an unfunded offer carrying this nonce.
    function cancelOffer(uint256 nonce) external;

    // ---------------------------------------------------------------------------------------------
    // Admin (owner has no power over deal funds)
    // ---------------------------------------------------------------------------------------------

    function setTreasury(address newTreasury) external;
    function setFeeBps(uint16 newFeeBps) external;

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The EIP-712 digest of an offer == its `dealId`.
    function hashOffer(Offer calldata offer) external view returns (bytes32);
    function getDeal(bytes32 dealId) external view returns (Deal memory);
    function credits(address account) external view returns (uint256);
}
