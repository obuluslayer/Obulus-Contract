// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEscrow} from "./interfaces/IEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Minimal local extension of `IEscrow` exposing the two settlement-config getters the vault must
///         read at deploy/admin time. The shared `IEscrow` interface (an off-chain integration contract)
///         declares neither `usdc()` nor `resolveTimeout()`, but the concrete `ObulusEscrow` exposes both as
///         public immutables. We declare them here — WITHOUT editing `IEscrow.sol` — so the vault can
///         (a) assert it settles in the same token as the escrow (`usdc_ == escrow.usdc()`), making the
///         otherwise-dead `TokenMismatch` error live, and (b) ENFORCE on-chain that the unstake→withdraw
///         delay strictly exceeds the escrow's dispute-resolution window (`escrow.resolveTimeout()`), so
///         funds unstaked during a live dispute are still physically present when the arbiter slashes.
interface IEscrowConfig {
    function usdc() external view returns (address);
    function resolveTimeout() external view returns (uint64);
}

/// @title ObulusStakingVault — standing USDC collateral for agents, slashable on adjudicated fault
/// @author Obulus
/// @custom:x https://x.com/obuluslayer
/// @notice A NEW, standalone auxiliary contract. It lets an agent post standing collateral that a
///         counterparty (or the protocol) can rely on beyond the per-deal bonds held by `ObulusEscrow`.
///         The vault READS `ObulusEscrow` to authorise a slash, but NEVER calls or mutates it.
///
/// Slashing trust model — read this first:
///  The crux is *who is authorised to slash, and on what on-chain proof*. The ideal design is a
///  permissionless `reportSlash(dealId)` that reads the resolved deal and proves the staker was the
///  at-fault party. That is IMPOSSIBLE here without modifying `ObulusEscrow` (forbidden): `ObulusEscrow.resolve`
///  sets `state = Resolved` but DOES NOT persist the split outcome — there is no `sellerBps`, no fault
///  flag, nothing in the `Deal` struct that records *who lost*. The resolution outcome lives ONLY in
///  the `Resolved` event, which is not readable on-chain. So after resolution the deal is indistinguishable
///  between "seller at fault", "buyer at fault", and "tie".
///
///  We therefore fall back to the DOCUMENTED alternative: an **arbiter-authorised slash**, gated while
///  the deal is still present and `Disputed` in `ObulusEscrow`. The arbiter is the protocol's *already-bridled*
///  authority: in `ObulusEscrow.resolve` it can already split that exact deal's price and bonds between its own
///  buyer/seller. Letting that same arbiter ALSO slash that same party's standing stake — bounded, and
///  only for a deal it is the live arbiter of — introduces NO NEW trust surface. A compromised arbiter key
///  could already mis-split the disputed deal; the only new power is a *capped* hit on the staker's
///  collateral, which (a) cannot exceed `slashCap`-bps of that staker's funds still in the vault (stake +
///  any queued-but-unwithdrawn pending) *per deal*, (b) goes to the treasury not the caller (no profit
///  motive → no griefing incentive), and (c) can fire at most once per deal. NOTE the cap is PER DEAL: a
///  party to N distinct disputed deals can be slashed up to ~N times (each capped on the base remaining at
///  that moment → geometric decay), so the cumulative hit CAN exceed a single deal's cap. This is a
///  per-deal ceiling, not a global one — by design, since each adjudicated fault justifies its own hit.
///
///  Why slash during `Disputed` (not after `Resolved`): `msg.sender == d.arbiter` is the gate, and the
///  arbiter only has reason to act on an open dispute. Slashing alongside the resolve decision is the
///  natural window — the same actor, the same adjudication, the same bounded authority. After `Resolved`
///  we can no longer tell fault apart anyway, so a post-hoc slash would be unverifiable.
///
/// Design invariants (mirroring ObulusEscrow.sol):
///  - CONSERVATION: vault USDC balance == Σ stakeOf(all) + Σ pending withdrawals. Slashed funds leave the
///    vault to the treasury and are removed from `stakeOf` and/or `pendingOf` in the same step (a slash may
///    reach into the pending bucket to defeat unstake-evasion), so the identity always holds.
///  - The owner has NO power to move stake: admin is limited to `withdrawalDelay`, `treasury`, `slashCap`.
///  - Pull-payment + CEI throughout; a blocklisted/reverting staker can never brick another's accounting.
contract ObulusStakingVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------------------------------

    uint16 internal constant BPS = 10_000;
    /// @notice Hard ceiling on the slash cap (50% of stake). Admin can only lower the effective cap below this.
    uint16 public constant MAX_SLASH_CAP_BPS = 5_000;
    /// @notice Hard ceiling on the configurable withdrawal delay (bounds timer math; 90 days is ample).
    uint64 public constant MAX_WITHDRAWAL_DELAY = 90 days;

    /// @notice The collateral token (USDC on Robinhood Chain) — must equal the ObulusEscrow's settlement token.
    IERC20 public immutable usdc;
    /// @notice The ObulusEscrow this vault reads to authorise slashes. Read-only; never called to mutate.
    IEscrow public immutable escrow;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Standing collateral per agent.
    mapping(address account => uint256) public stakeOf;

    /// @notice A queued unstake: `amount` claimable once `block.timestamp >= unlockAt`.
    struct Pending {
        uint256 amount;
        uint64 unlockAt;
    }

    /// @notice account → its single in-flight withdrawal request (re-requesting re-queues the delay).
    mapping(address account => Pending) public pendingOf;

    /// @notice Sum of all queued withdrawals — kept exact so the conservation identity is O(1) checkable.
    uint256 public totalPending;
    /// @notice Sum of all standing stake — kept exact for the same reason.
    uint256 public totalStaked;

    /// @notice dealId → already slashed. A deal can authorise at most ONE slash, ever (no double-slash).
    mapping(bytes32 dealId => bool) public slashed;

    /// @notice Delay (seconds) between `unstake` and `withdraw`. ENFORCED on-chain (constructor +
    ///         `setWithdrawalDelay`) to be STRICTLY GREATER THAN `escrow.resolveTimeout()`. It does NOT
    ///         block slashing (slash reaches pending too); it guarantees that funds unstaked during a live
    ///         dispute are still PHYSICALLY PRESENT in the vault when the arbiter slashes — i.e. it keeps
    ///         them reachable rather than letting a staker withdraw before adjudication.
    ///
    ///         BOUNDARY RACE — read honestly: `escrow.resolveExpired` matures the dispute with a STRICT
    ///         `>` (`block.timestamp > disputedAt + resolveTimeout`) while `withdraw()` here unlocks with a
    ///         `>=` (`block.timestamp >= unlockAt`). Enforcing `withdrawalDelay > resolveTimeout` (not just
    ///         `>=`) closes the same-block tie: if a staker unstakes and disputes in the same block, the
    ///         deal's dispute window can still expire strictly BEFORE the withdrawal unlocks, leaving the
    ///         arbiter a window to slash the still-present pending funds. The deterrent therefore assumes
    ///         the arbiter resolves WITHIN the dispute window — which is exactly the window in which it is
    ///         the bound authority.
    ///
    ///         COVERAGE LIMIT — this vault does NOT track per-deal membership (out of scope by design).
    ///         The presence guarantee only holds for disputes that mature before a queued withdrawal
    ///         unlocks. An agent who unstakes FORFEITS coverage of any deal whose dispute could mature
    ///         after its unlock. For full coverage of a covered deal, `withdrawalDelay` should exceed that
    ///         deal's entire remaining lifetime — up to `deliverDeadline + confirmWindow + resolveTimeout`
    ///         measured from the unstake — not merely `resolveTimeout`. We enforce only the
    ///         `> resolveTimeout` floor on-chain (the one relation we can read from the escrow); the
    ///         operator must set the delay high enough to cover the max lifetime of the deals it backs.
    uint64 public withdrawalDelay;
    /// @notice Where slashed funds accrue. Never the caller/reporter (no profit motive).
    address public treasury;
    /// @notice Effective per-deal slash ceiling, in bps of the staker's *current* in-vault funds
    ///         (stakeOf + pendingOf), applied PER disputed deal. <= MAX_SLASH_CAP_BPS.
    uint16 public slashCapBps;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 newStake);
    event Unstaked(address indexed account, uint256 amount, uint64 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    /// @param dealId   The ObulusEscrow deal whose arbiter authorised the slash.
    /// @param account  The at-fault party whose stake was reduced.
    /// @param amount   USDC moved to the treasury.
    event Slashed(bytes32 indexed dealId, address indexed account, address indexed arbiter, uint256 amount);
    event WithdrawalDelayUpdated(uint64 withdrawalDelay);
    event TreasuryUpdated(address indexed treasury);
    event SlashCapUpdated(uint16 slashCapBps);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error TokenMismatch();
    error InsufficientStake();
    error NoPendingWithdrawal();
    error WithdrawalLocked();
    error SlashCapTooHigh();
    error WithdrawalDelayTooHigh();
    /// @notice `withdrawalDelay` must STRICTLY exceed `escrow.resolveTimeout()` (anti-evasion floor).
    ///         Reverting here makes the previously documentation-only relation a hard on-chain invariant.
    error WithdrawalDelayTooShort();
    error NotDealArbiter();
    error DealNotDisputed(bytes32 dealId);
    error AlreadySlashed(bytes32 dealId);
    error NotDealParty();
    error NothingToSlash();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param usdc_            Collateral token; must equal `escrow_.usdc()` for a coherent system.
    /// @param escrow_          The ObulusEscrow read (never mutated) to authorise slashes.
    /// @param treasury_        Slash beneficiary.
    /// @param withdrawalDelay_ Initial unstake→withdraw delay; MUST be STRICTLY > `escrow_.resolveTimeout()`
    ///                         (enforced — reverts `WithdrawalDelayTooShort` otherwise) and <= MAX_WITHDRAWAL_DELAY.
    /// @param slashCapBps_     Initial slash ceiling in bps of stake; <= MAX_SLASH_CAP_BPS.
    constructor(
        address usdc_,
        address escrow_,
        address treasury_,
        uint64 withdrawalDelay_,
        uint16 slashCapBps_
    ) Ownable(msg.sender) {
        if (usdc_ == address(0) || escrow_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (slashCapBps_ > MAX_SLASH_CAP_BPS) revert SlashCapTooHigh();
        if (withdrawalDelay_ > MAX_WITHDRAWAL_DELAY) revert WithdrawalDelayTooHigh();
        // Token coherence: the vault and the escrow it reads MUST settle in the same token, otherwise the
        // collateral posted here is denominated differently from the deals it backs. Enforced (not just
        // documented) via the local `IEscrowConfig.usdc()` extension so `TokenMismatch` is a live guard.
        if (usdc_ != IEscrowConfig(escrow_).usdc()) revert TokenMismatch();
        // Anti-evasion floor (ENFORCED, not just documented): the unstake→withdraw delay must STRICTLY
        // exceed the escrow's dispute window, so funds unstaked during a live dispute remain physically
        // present (slashable in the pending bucket) until at least one block AFTER the dispute could
        // expire. A misconfigured `withdrawalDelay <= resolveTimeout` is rejected at deploy time, making
        // the reproduced "1d delay vs 7d timeout" full-evasion deployment impossible.
        if (withdrawalDelay_ <= IEscrowConfig(escrow_).resolveTimeout()) revert WithdrawalDelayTooShort();
        usdc = IERC20(usdc_);
        escrow = IEscrow(escrow_);
        treasury = treasury_;
        withdrawalDelay = withdrawalDelay_;
        slashCapBps = slashCapBps_;
        emit TreasuryUpdated(treasury_);
        emit WithdrawalDelayUpdated(withdrawalDelay_);
        emit SlashCapUpdated(slashCapBps_);
    }

    // ---------------------------------------------------------------------------------------------
    // stake / unstake / withdraw
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposit `amount` USDC as standing collateral.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Effects (CEI): credit before pulling so a reentrant token cannot double-count.
        stakeOf[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount, stakeOf[msg.sender]);
        // Interaction.
        usdc.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Begin withdrawing `amount` from stake. Funds become claimable via `withdraw` only after
    ///         `withdrawalDelay`. Moves value from `stakeOf` into a pending bucket (still vault-held, still
    ///         conserved) — it cannot be yanked instantly. NOTE: queuing does NOT make funds un-slashable;
    ///         `slash` reaches into the pending bucket too (see `slash`), so unstaking during a live dispute
    ///         is not an escape hatch. Re-calling adds to the pending amount and resets the clock on the
    ///         whole bucket.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 s = stakeOf[msg.sender];
        if (amount > s) revert InsufficientStake();

        stakeOf[msg.sender] = s - amount;
        totalStaked -= amount;

        Pending storage p = pendingOf[msg.sender];
        uint256 newPending = p.amount + amount;
        uint64 unlockAt = uint64(block.timestamp) + withdrawalDelay;
        p.amount = newPending;
        p.unlockAt = unlockAt; // reset the clock: the whole bucket waits the full delay
        totalPending += amount;

        emit Unstaked(msg.sender, amount, unlockAt);
    }

    /// @notice Claim a matured withdrawal request in full.
    function withdraw() external nonReentrant {
        Pending memory p = pendingOf[msg.sender];
        if (p.amount == 0) revert NoPendingWithdrawal();
        if (block.timestamp < p.unlockAt) revert WithdrawalLocked();

        // Effects.
        delete pendingOf[msg.sender];
        totalPending -= p.amount;
        emit Withdrawn(msg.sender, p.amount);

        // Interaction.
        usdc.safeTransfer(msg.sender, p.amount);
    }

    // ---------------------------------------------------------------------------------------------
    // slash — arbiter-authorised, bounded, single-shot, no profit motive
    // ---------------------------------------------------------------------------------------------

    /// @notice Slash a bounded amount of `account`'s collateral, authorised by the live arbiter of a
    ///         disputed ObulusEscrow deal that `account` is a party to. Slashed funds go to the treasury.
    /// @dev Gate (all required):
    ///       1. The deal is currently `Disputed` in ObulusEscrow (the only window where fault is being adjudicated
    ///          and the arbiter is still the bound authority).
    ///       2. `msg.sender == deal.arbiter` (the protocol's already-bridled authority; no new trust).
    ///       3. `account` is a party to the deal (its buyer or seller) — cannot slash an unrelated agent.
    ///       4. `!slashed[dealId]` — THIS deal authorises at most one slash, ever (no double-slash).
    ///
    ///      Slashable base — anti-evasion: the cap is taken over ALL of `account`'s funds still physically
    ///      in the vault, i.e. `stakeOf[account] + pendingOf[account].amount`, NOT just standing stake.
    ///      This closes a front-run: a party to an open dispute could otherwise call `unstake(stakeOf)` to
    ///      drain `stakeOf` into the pending bucket and leave nothing slashable, then `withdraw` 100% after
    ///      the delay. Because `withdrawalDelay >= the escrow dispute window`, funds moved to `pending`
    ///      during a live dispute are STILL physically present (not yet withdrawable) when the arbiter
    ///      slashes — so they remain reachable. We deduct from `stakeOf` FIRST, then from `pendingOf` for
    ///      any remainder, decrementing `totalStaked` / `totalPending` accordingly. Conservation
    ///      (`balance == totalStaked + totalPending`) is preserved because the slashed wei leaves to the
    ///      treasury and is subtracted from the aggregates in the same step. Already-WITHDRAWN funds are
    ///      gone from the vault and thus unreachable — the delay is exactly what keeps them present.
    ///
    ///      The amount is capped at `slashCapBps` of that combined base AND at the caller-requested
    ///      `amount` (so the arbiter can choose a proportionate, smaller hit).
    ///
    ///      BOUND SCOPE — per-deal, NOT global: `slashed[dealId]` only prevents re-slashing the SAME deal.
    ///      A party to N distinct disputed deals can be slashed once PER deal, each hit capped at
    ///      `slashCapBps` of the base remaining at that moment (so the sequence decays geometrically toward
    ///      the floor). The cumulative loss can therefore exceed a single deal's cap; the cap is a per-deal
    ///      ceiling, not a global one. This is intended: distinct adjudicated faults each justify a hit.
    /// @param dealId  The disputed ObulusEscrow deal authorising the slash.
    /// @param account The at-fault party (must be the deal's buyer or seller).
    /// @param amount  The arbiter's requested slash; the executed amount is min(amount, cap-of-base).
    function slash(bytes32 dealId, address account, uint256 amount) external nonReentrant {
        if (slashed[dealId]) revert AlreadySlashed(dealId);

        IEscrow.Deal memory d = escrow.getDeal(dealId);
        // (1) live dispute window.
        if (d.state != IEscrow.State.Disputed) revert DealNotDisputed(dealId);
        // (2) only the deal's own arbiter — the bridled authority.
        if (msg.sender != d.arbiter) revert NotDealArbiter();
        // (3) target must be a party to THIS deal.
        if (account != d.buyer && account != d.seller) revert NotDealParty();

        uint256 s = stakeOf[account];
        uint256 pend = pendingOf[account].amount;
        // Slashable base = everything still physically in the vault for this account (anti-unstake-evasion).
        uint256 base = s + pend;
        if (base == 0 || amount == 0) revert NothingToSlash();

        // (4) bound: never more than slashCapBps of the combined base, and never more than requested.
        uint256 cap = (base * slashCapBps) / BPS;
        uint256 toSlash = amount < cap ? amount : cap;
        if (toSlash == 0) revert NothingToSlash(); // cap rounded to zero on a dust base

        // Effects (CEI): record the single-shot flag, then drain from stake FIRST, pending for the rest.
        slashed[dealId] = true;

        uint256 fromStake = toSlash < s ? toSlash : s;
        if (fromStake != 0) {
            stakeOf[account] = s - fromStake;
            totalStaked -= fromStake;
        }
        uint256 fromPending = toSlash - fromStake;
        if (fromPending != 0) {
            // Drain the remainder out of the queued withdrawal. unlockAt is untouched: shrinking a pending
            // bucket cannot extend or shorten its timer. The bucket may now be 0 (fully consumed).
            pendingOf[account].amount = pend - fromPending;
            totalPending -= fromPending;
        }

        emit Slashed(dealId, account, msg.sender, toSlash);

        // Interaction: slashed funds leave to the treasury (NOT the caller → no profit/griefing motive).
        usdc.safeTransfer(treasury, toSlash);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin — strictly params; can NEVER seize or move stake.
    // ---------------------------------------------------------------------------------------------

    function setWithdrawalDelay(uint64 newDelay) external onlyOwner {
        if (newDelay > MAX_WITHDRAWAL_DELAY) revert WithdrawalDelayTooHigh();
        // Same anti-evasion floor as the constructor: the delay must STRICTLY exceed the escrow dispute
        // window. The owner cannot lower the delay into the evasion zone (`<= resolveTimeout`).
        if (newDelay <= IEscrowConfig(address(escrow)).resolveTimeout()) revert WithdrawalDelayTooShort();
        withdrawalDelay = newDelay;
        emit WithdrawalDelayUpdated(newDelay);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setSlashCapBps(uint16 newCap) external onlyOwner {
        if (newCap > MAX_SLASH_CAP_BPS) revert SlashCapTooHigh();
        slashCapBps = newCap;
        emit SlashCapUpdated(newCap);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The matured/queued withdrawal for `account` (amount + unlock timestamp).
    function pendingWithdrawal(address account) external view returns (uint256 amount, uint64 unlockAt) {
        Pending memory p = pendingOf[account];
        return (p.amount, p.unlockAt);
    }

    /// @notice Total value the vault must hold to honour all obligations. Equals the USDC balance.
    function totalObligations() external view returns (uint256) {
        return totalStaked + totalPending;
    }
}
