// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IYieldSource} from "./interfaces/IYieldSource.sol";

/// @title ObulusYieldVault — OPT-IN, share-accounted surplus vault for agents & the protocol treasury
/// @author Obulus
/// @custom:landing        https://obuluslayer.xyz/
/// @custom:dapp           https://app.obuluslayer.xyz/
/// @custom:documentation  https://gitbook.obuluslayer.xyz/
/// @custom:github         https://github.com/obuluslayer
/// @custom:x              https://x.com/obuluslayer
/// @custom:telegram       https://t.me/obuluslayer
/// @notice A NEW, fully standalone contract. It is NOT part of the escrow settlement path and has NO
///         reference to any `ObulusEscrow`/`ObulusSubscriptionEscrow`/deal. It lets an agent (or the treasury) deposit
///         its OWN idle/surplus USDG — never escrow principal or bonds — and earn yield via a pluggable
///         yield source. Withdrawals are share-accounted and pull-based.
///
/// WHY THIS SHAPE (the lead architect's non-negotiable safety model):
///  The tempting-but-UNSAFE idea is "lock a deal's USDG into a pool while it's being processed." That is
///  REJECTED: a pool can lose value, be illiquid, or slip, which would break the escrow's conservation
///  invariant (principal + bonds must always settle in full). This vault sidesteps that ENTIRELY by being a
///  separate opt-in contract that only ever holds funds someone VOLUNTARILY deposited as surplus. ObulusEscrow is
///  untouched, so settlement safety is preserved BY CONSTRUCTION — there is literally no code path from a
///  deal's funds into this vault or its source.
///
/// REDEEMABILITY / FLOOR GUARANTEE — stated honestly, do NOT over-read it:
///  - With NO yield source set (the default, and the safe pass-through), the vault holds USDG directly and is
///    EXACTLY 1:1 redeemable: 1 share is minted per USDG on the first deposit and share price stays 1.0
///    because `totalAssets()` == the vault's own USDG balance. No depositor can ever redeem less than they
///    put in (absent a source).
///  - With a PRINCIPAL-PROTECTED source (e.g. `MockYieldSource`, which only ever accrues), share price rises
///    monotonically and every depositor redeems principal + their fair share of yield.
///  - With an AMM/LP source (e.g. the Uniswap v4 adapter), THERE IS NO FLOOR. `totalAssets()` can fall below
///    deposits due to impermanent loss / slippage / pool insolvency, so share price can DROP and a depositor
///    can redeem LESS than principal. This is the opt-in risk the depositor knowingly bears. We do not claim
///    "guaranteed yield." The admin choosing the source is the only party that decides this risk profile;
///    the admin still can NEVER seize funds (see below).
///
/// CONSERVATION / SOLVENCY INVARIANT (mirrors ObulusEscrow.sol's discipline):
///  - `totalAssets()` == idle USDG held by the vault + `source.totalAssets()` (0 if no source).
///  - Σ over depositors of `convertToAssets(balanceOf)` <= `totalAssets()` at all times (share math rounds
///    in the vault's favour, never a depositor's, so the vault can always honour every redemption against
///    what it can actually recover). With the null/Mock source this is an exact-or-favourable identity; with
///    a lossy source it still holds because both sides scale by the same (possibly < 1) recovery factor.
///  - The owner has NO power to move or seize deposits: admin is limited to {set/clear the yield source,
///    pause/unpause, set a withdrawal fee bounded by MAX_WITHDRAW_FEE_BPS that accrues to the treasury}.
///    Switching the source moves USDG between the vault and a source the OWNER trusts — it can never send a
///    depositor's funds to the owner. CEI + ReentrancyGuard + SafeERC20 throughout.
contract ObulusYieldVault is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants & immutables
    // ---------------------------------------------------------------------------------------------

    uint16 internal constant BPS = 10_000;
    /// @notice Hard ceiling on the withdrawal fee (2%). Admin can only set a fee at or below this; the fee is
    ///         taken from the withdrawn assets and sent to the treasury. It is NOT a power to seize stake: it
    ///         only ever applies to a depositor's OWN voluntary withdrawal, is bounded, and is disclosed.
    uint16 public constant MAX_WITHDRAW_FEE_BPS = 200; // 2%

    /// @notice Virtual shares/assets offset (ERC4626-style inflation-attack mitigation). The first depositor
    ///         cannot manipulate share price by donating directly to the vault, because the price uses
    ///         `totalShares + VIRTUAL_SHARES` and `totalAssets + 1` — a tiny constant the empty vault behaves
    ///         as if it already held. 1e3 virtual shares is the OZ-recommended decimal offset of 3.
    uint256 internal constant VIRTUAL_SHARES = 1e3;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice The underlying token — USDG on Robinhood Chain mainnet, MockUSDC on testnet. 6 decimals.
    IERC20 public immutable asset;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Shares held per depositor. Pure internal accounting (this vault is NOT itself an ERC20).
    mapping(address account => uint256) public balanceOf;
    /// @notice Total shares outstanding.
    uint256 public totalShares;

    /// @notice The configured yield source, or address(0) for the safe 1:1 pass-through.
    IYieldSource public yieldSource;

    /// @notice Withdrawal fee in bps (<= MAX_WITHDRAW_FEE_BPS), taken on withdraw/redeem, sent to treasury.
    uint16 public withdrawFeeBps;
    /// @notice Where withdrawal fees accrue. Never a depositor's principal — only the bounded fee slice.
    address public treasury;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Harvested(uint256 realized, uint256 totalAssetsAfter);
    event YieldSourceUpdated(address indexed oldSource, address indexed newSource, uint256 moved);
    event WithdrawFeeUpdated(uint16 withdrawFeeBps);
    event TreasuryUpdated(address indexed treasury);
    event WithdrawFeeTaken(address indexed payer, uint256 fee);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error WithdrawFeeTooHigh();
    error SourceAssetMismatch();
    error SourceStillFunded(uint256 residual);
    error SlippageExceeded(uint256 got, uint256 min);

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param asset_    The underlying token (USDG). Immutable.
    /// @param treasury_ Fee beneficiary (the protocol treasury). Can be updated by the owner.
    constructor(address asset_, address treasury_) Ownable(msg.sender) {
        if (asset_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        asset = IERC20(asset_);
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    // ---------------------------------------------------------------------------------------------
    // Valuation / share math
    // ---------------------------------------------------------------------------------------------

    /// @notice Total USDG the vault can account for: idle USDG it holds directly + what the source reports.
    ///         This is the single source of truth for share price. With no source it equals the vault's own
    ///         balance (→ exact 1:1). With a lossy source it can be LESS than total deposits (honest).
    function totalAssets() public view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        IYieldSource src = yieldSource;
        if (address(src) == address(0)) return idle;
        return idle + src.totalAssets();
    }

    /// @notice Convert an asset amount to shares, rounding DOWN (vault-favourable on deposit).
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _toShares(assets, totalShares, totalAssets());
    }

    /// @notice Convert a share amount to assets, rounding DOWN (vault-favourable on withdraw/redeem).
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _toAssets(shares, totalShares, totalAssets());
    }

    /// @dev shares = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS), rounded down.
    function _toShares(uint256 assets, uint256 ts, uint256 ta) internal pure returns (uint256) {
        return (assets * (ts + VIRTUAL_SHARES)) / (ta + VIRTUAL_ASSETS);
    }

    /// @dev assets = shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES), rounded down.
    function _toAssets(uint256 shares, uint256 ts, uint256 ta) internal pure returns (uint256) {
        return (shares * (ta + VIRTUAL_ASSETS)) / (ts + VIRTUAL_SHARES);
    }

    /// @notice Preview the shares minted for a deposit of `assets` (no state change).
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview the assets returned for redeeming `shares` BEFORE the withdrawal fee.
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice The maximum assets `owner` can currently redeem, net of fee and bounded by what the vault +
    ///         source can actually pay right now (liquidity). Useful for UIs; not used as a guard internally.
    function maxWithdraw(address owner) external view returns (uint256) {
        uint256 gross = convertToAssets(balanceOf[owner]);
        uint256 liquid = _liquidCapacity();
        uint256 payable_ = gross < liquid ? gross : liquid;
        return payable_ - _feeOn(payable_);
    }

    // ---------------------------------------------------------------------------------------------
    // deposit / withdraw / redeem
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposit `assets` USDG and mint shares to `receiver`. Pulls USDG from `msg.sender` (who must
    ///         have approved the vault). If a source is set, the idle USDG is routed to it. CEI: shares are
    ///         computed against the PRE-deposit valuation, then the pull happens, then routing.
    /// @param assets   Amount of USDG to deposit.
    /// @param receiver Share recipient.
    /// @return shares  Shares minted.
    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Price against the valuation BEFORE this deposit's USDG arrives. Pulling AFTER computing shares is
        // essential: if we read totalAssets() after the transfer it would already include `assets` and the
        // depositor would be under-credited.
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        shares = _toShares(assets, ts, ta);
        if (shares == 0) revert ZeroShares();

        // Effects.
        totalShares = ts + shares;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, assets, shares);

        // Interaction: pull the USDG in, then route idle funds to the source (if any).
        asset.safeTransferFrom(msg.sender, address(this), assets);
        _routeToSource(assets);
    }

    /// @notice Redeem `shares` for assets, sending net assets to `receiver`. Burns from `owner` (the caller).
    ///         A withdrawal fee (if set) is taken from the gross assets and sent to the treasury. Pull-based.
    /// @param shares      Shares to burn.
    /// @param receiver    Asset recipient.
    /// @param minAssetsOut Slippage floor on the NET assets the receiver gets (reverts if undershot).
    /// @return netAssets  Assets sent to `receiver` after the fee.
    function redeem(uint256 shares, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 netAssets)
    {
        return _withdrawByShares(shares, receiver, minAssetsOut);
    }

    /// @notice Withdraw an explicit `assets` amount (gross, before fee) by burning the share-equivalent from
    ///         the caller. Convenience wrapper over `redeem`. The fee is then taken from this gross amount.
    /// @param assets       Gross assets to withdraw (the share-equivalent is burned).
    /// @param receiver     Asset recipient.
    /// @param minAssetsOut Slippage floor on the NET assets received.
    /// @return netAssets   Assets sent to `receiver` after the fee.
    function withdraw(uint256 assets, address receiver, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 netAssets)
    {
        if (assets == 0) revert ZeroAmount();
        // shares to burn = ceil(assets / price) so the depositor cannot withdraw more value than they own.
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        uint256 shares = _toSharesRoundUp(assets, ts, ta);
        if (shares == 0) revert ZeroShares();
        return _withdrawByShares(shares, receiver, minAssetsOut);
    }

    /// @dev Shared redemption core. NOT payable; callable only via the nonReentrant external wrappers.
    ///
    /// LOSSY / ILLIQUID OVER-BURN FIX (audit remediation): the source can deliver LESS than `grossAssets`
    /// when it is lossy or illiquid (`_ensureLiquidity` returns `delivered <= grossAssets`). If we burned the
    /// full `shares` but only paid `delivered`, the un-paid `grossAssets - delivered` would unfairly accrue to
    /// the remaining shareholders AND self-harm the redeemer (they'd burn shares worth value they never got).
    /// We therefore burn ONLY the shares actually worth what was delivered: we provisionally burn `shares`
    /// (CEI — effects before the interaction so no reentrancy can read stale balances), then, if the source
    /// shorted us, we RE-CREDIT the redeemer the shares corresponding to the undelivered remainder, priced at
    /// the SAME pre-withdrawal valuation used to compute `grossAssets`. Net effect: shares-burned corresponds
    /// to assets-delivered (no over-burn), the redeemer keeps a claim on the value still stuck in the source,
    /// and the conservation/solvency invariant is preserved (the un-withdrawn value remains backed by shares).
    function _withdrawByShares(uint256 shares, address receiver, uint256 minAssetsOut)
        internal
        returns (uint256 netAssets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[msg.sender];
        if (shares > bal) revert InsufficientShares();

        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        // Gross assets owed for these shares, rounded DOWN (vault-favourable).
        uint256 grossAssets = _toAssets(shares, ts, ta);
        if (grossAssets == 0) revert ZeroAmount();

        // Effects: burn shares BEFORE any external interaction (CEI).
        balanceOf[msg.sender] = bal - shares;
        totalShares = ts - shares;

        // Interaction: ensure `grossAssets` USDG is physically present in the vault, pulling from the source
        // if idle isn't enough. `delivered` is what we could actually realize (<= grossAssets for a lossy /
        // illiquid source). We pay out exactly what we realized, so we can never transfer more than we hold.
        uint256 delivered = _ensureLiquidity(grossAssets);

        // OVER-BURN GUARD: if the source shorted us, re-credit the redeemer the shares worth the UNDELIVERED
        // remainder, priced at the same (pre-withdrawal) valuation that produced `grossAssets`. This makes the
        // shares ACTUALLY burned correspond to the assets ACTUALLY delivered — the redeemer never burns more
        // value than they receive, and the leftover value still in the source stays backed by their shares.
        if (delivered < grossAssets) {
            uint256 refundShares = _toSharesRoundDownAtPrice(grossAssets - delivered, ts, ta);
            // Cap at the shares we just burned (defensive; rounding can never exceed the burned amount, but
            // never re-credit more than was removed so totalShares can never be inflated).
            if (refundShares > shares) refundShares = shares;
            if (refundShares != 0) {
                balanceOf[msg.sender] += refundShares;
                totalShares += refundShares;
                // The shares that were genuinely consumed for the delivered assets.
                shares -= refundShares;
            }
        }

        // Fee (bounded, to treasury) is taken from the realized gross; depositor gets the remainder.
        uint256 fee = _feeOn(delivered);
        netAssets = delivered - fee;
        if (netAssets < minAssetsOut) revert SlippageExceeded(netAssets, minAssetsOut);

        emit Withdraw(msg.sender, receiver, msg.sender, netAssets, shares);

        if (fee != 0) {
            emit WithdrawFeeTaken(msg.sender, fee);
            asset.safeTransfer(treasury, fee);
        }
        asset.safeTransfer(receiver, netAssets);
    }

    // ---------------------------------------------------------------------------------------------
    // harvest — permissionless realization of source yield
    // ---------------------------------------------------------------------------------------------

    /// @notice Permissionless: ask the source to realize/compound pending yield so it shows up in
    ///         `totalAssets()` (and thus share price). No-op when no source is set or nothing to harvest.
    ///         This NEVER moves depositor shares; it only updates valuation. Safe for anyone to call.
    function harvest() external nonReentrant returns (uint256 realized) {
        IYieldSource src = yieldSource;
        if (address(src) == address(0)) return 0;
        realized = src.harvest();
        emit Harvested(realized, totalAssets());
    }

    // ---------------------------------------------------------------------------------------------
    // Internal routing / liquidity helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Push `assets` idle USDG to the source and notify it. No-op if no source. We push BEFORE calling
    ///      `source.deposit` so the source never pulls from us (it accounts for funds already delivered).
    function _routeToSource(uint256 assets) internal {
        IYieldSource src = yieldSource;
        if (address(src) == address(0) || assets == 0) return;
        asset.safeTransfer(address(src), assets);
        src.deposit(assets);
    }

    /// @dev Make at least `need` USDG physically present in the vault, pulling the shortfall from the source.
    ///      Returns the amount actually available afterward (<= need if the source couldn't honour in full).
    function _ensureLiquidity(uint256 need) internal returns (uint256 available) {
        uint256 idle = asset.balanceOf(address(this));
        if (idle >= need) return need;
        IYieldSource src = yieldSource;
        if (address(src) == address(0)) {
            // No source: we can only pay what we idly hold. (Shouldn't happen on the 1:1 path, but be safe.)
            return idle;
        }
        uint256 shortfall = need - idle;
        // The source returns what it ACTUALLY sent (may be less for a lossy/illiquid source).
        src.withdraw(shortfall, address(this));
        uint256 nowIdle = asset.balanceOf(address(this));
        return nowIdle >= need ? need : nowIdle;
    }

    /// @dev Idle USDG + what the source can pay out right now (used only for the `maxWithdraw` view).
    function _liquidCapacity() internal view returns (uint256) {
        uint256 idle = asset.balanceOf(address(this));
        IYieldSource src = yieldSource;
        if (address(src) == address(0)) return idle;
        return idle + src.maxWithdraw();
    }

    /// @dev shares = ceil(assets * (ts+VS) / (ta+VA)) — used so a fixed-asset withdraw burns AT LEAST the
    ///      share-equivalent (never lets a depositor extract more value than they own).
    function _toSharesRoundUp(uint256 assets, uint256 ts, uint256 ta) internal pure returns (uint256) {
        uint256 num = assets * (ts + VIRTUAL_SHARES);
        uint256 den = ta + VIRTUAL_ASSETS;
        return (num + den - 1) / den;
    }

    /// @dev shares = floor(assets * (ts+VS) / (ta+VA)) at an EXPLICIT (ts, ta) price snapshot. Used by the
    ///      over-burn guard to re-credit a redeemer the shares worth the UNDELIVERED remainder when a lossy /
    ///      illiquid source shorts a withdrawal. Rounding DOWN here is solvency-favourable: we never re-credit
    ///      more shares than the stranded value is worth, so remaining shareholders are never under-backed.
    function _toSharesRoundDownAtPrice(uint256 assets, uint256 ts, uint256 ta) internal pure returns (uint256) {
        return (assets * (ts + VIRTUAL_SHARES)) / (ta + VIRTUAL_ASSETS);
    }

    /// @dev The bounded withdrawal fee on a gross amount.
    function _feeOn(uint256 grossAssets) internal view returns (uint256) {
        uint16 f = withdrawFeeBps;
        if (f == 0) return 0;
        return (grossAssets * f) / BPS;
    }

    // ---------------------------------------------------------------------------------------------
    // Admin — source / pause / fee / treasury. NEVER able to seize deposits.
    // ---------------------------------------------------------------------------------------------

    /// @notice Set (or replace) the yield source. To preserve solvency we DRAIN the old source back into the
    ///         vault first (so its assets are reflected as idle), then move all idle USDG into the new source.
    ///         The owner cannot point the source at itself: USDG only ever flows vault↔source, never to the
    ///         owner. Setting `newSource == address(0)` reverts to the safe 1:1 pass-through.
    /// @dev    SAFETY: switching the source can only change WHERE the funds are custodied, never WHO owns the
    ///         shares. If the old source was lossy and returns less than booked, that loss was already
    ///         reflected in `totalAssets()` before the switch — the switch itself realizes nothing new.
    function setYieldSource(IYieldSource newSource) external onlyOwner nonReentrant {
        IYieldSource old = yieldSource;
        uint256 moved;

        // 1) Drain the old source fully back to the vault.
        if (address(old) != address(0)) {
            uint256 toPull = old.totalAssets();
            if (toPull != 0) old.withdraw(toPull, address(this));
            // Require the old source be (essentially) emptied so its residual can't be silently stranded.
            uint256 residual = old.totalAssets();
            if (residual != 0) revert SourceStillFunded(residual);
        }

        // 2) Adopt the new source (or go to pass-through).
        if (address(newSource) != address(0)) {
            if (newSource.asset() != address(asset)) revert SourceAssetMismatch();
            yieldSource = newSource;
            uint256 idle = asset.balanceOf(address(this));
            if (idle != 0) {
                asset.safeTransfer(address(newSource), idle);
                newSource.deposit(idle);
                moved = idle;
            }
        } else {
            yieldSource = IYieldSource(address(0));
        }

        emit YieldSourceUpdated(address(old), address(newSource), moved);
    }

    /// @notice Pause deposits (withdrawals stay OPEN — depositors must always be able to exit).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume deposits.
    function unpause() external onlyOwner {
        _unpause();
    }

    function setWithdrawFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_WITHDRAW_FEE_BPS) revert WithdrawFeeTooHigh();
        withdrawFeeBps = newFeeBps;
        emit WithdrawFeeUpdated(newFeeBps);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }
}
