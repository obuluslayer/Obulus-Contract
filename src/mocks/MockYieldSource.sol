// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";

/// @notice TEST-ONLY principal-protected yield source with DETERMINISTIC accrual, so the vault's share
///         accounting and conservation are unit- and invariant-testable locally without any live AMM.
///
/// MODEL: it tracks `principal` (assets booked via `deposit`) plus `accrued` yield. `harvest()` and
///        `totalAssets()` accrue a fixed APR-style amount based on elapsed time since the last touch. Yield
///        is "minted" by the test funding this contract with extra USDC (see `fund`) — i.e. the realized
///        yield is REAL USDC sitting here, never fictitious. Because it only ever accrues (never loses), it
///        models the principal-protected / 1:1-or-better configuration: a depositor always redeems principal
///        plus their fair share of accrued yield. (The lossy/AMM risk profile is exercised by the v4 adapter
///        path + MockPoolManager, not here.)
/// @custom:landing        https://obuluslayer.xyz/
/// @custom:dapp           https://app.obuluslayer.xyz/
/// @custom:documentation  https://gitbook.obuluslayer.xyz/
/// @custom:github         https://github.com/obuluslayer
/// @custom:x              https://x.com/obuluslayer
/// @custom:telegram       https://t.me/obuluslayer
contract MockYieldSource is IYieldSource {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable vault;

    /// @notice Assets booked as principal via `deposit` (does not include accrued yield).
    uint256 public principal;
    /// @notice Yield realized into the balance via `harvest` (USDC actually present here).
    uint256 public realizedYield;

    /// @notice Annual yield rate in bps applied to `principal` (e.g. 500 = 5% APR), accrued linearly.
    uint16 public aprBps;
    /// @notice Last timestamp accrual was computed.
    uint64 public lastAccrual;

    error OnlyVault();
    error NotFunded(uint256 want, uint256 have);

    constructor(address token_, address vault_, uint16 aprBps_) {
        token = IERC20(token_);
        vault = vault_;
        aprBps = aprBps_;
        lastAccrual = uint64(block.timestamp);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @inheritdoc IYieldSource
    function asset() external view returns (address) {
        return address(token);
    }

    /// @dev The yield that has accrued (in USDC terms) since `lastAccrual`, not yet folded into state.
    function _pendingAccrual() internal view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || principal == 0 || aprBps == 0) return 0;
        // principal * aprBps/10_000 * dt/365days
        return (principal * aprBps * dt) / (10_000 * 365 days);
    }

    /// @inheritdoc IYieldSource
    /// @dev Booked principal + realized yield + still-pending accrual. Monotonic non-decreasing (no loss).
    function totalAssets() public view returns (uint256) {
        return principal + realizedYield + _pendingAccrual();
    }

    /// @inheritdoc IYieldSource
    function maxWithdraw() external view returns (uint256) {
        // Liquidity-bound by whatever USDC is physically here (the test funds yield ahead of time).
        uint256 bal = token.balanceOf(address(this));
        uint256 owed = totalAssets();
        return bal < owed ? bal : owed;
    }

    /// @inheritdoc IYieldSource
    /// @dev The vault has already transferred `assets` to this contract before calling. We just book it.
    function deposit(uint256 assets) external onlyVault {
        _accrue();
        principal += assets;
    }

    /// @inheritdoc IYieldSource
    /// @dev Pay out up to `assets` to `to`. Reduces realized yield first, then principal (so principal is
    ///      the last thing to leave). Returns the amount actually sent (capped by USDC physically present).
    function withdraw(uint256 assets, address to) external onlyVault returns (uint256 sent) {
        _accrue();
        uint256 bal = token.balanceOf(address(this));
        sent = assets < bal ? assets : bal;
        if (sent == 0) return 0;

        // Account the outflow: drain realized yield first, then principal.
        uint256 fromYield = sent < realizedYield ? sent : realizedYield;
        realizedYield -= fromYield;
        uint256 fromPrincipal = sent - fromYield;
        if (fromPrincipal != 0) {
            principal = fromPrincipal < principal ? principal - fromPrincipal : 0;
        }

        token.safeTransfer(to, sent);
    }

    /// @inheritdoc IYieldSource
    /// @dev Realize the pending accrual. The USDC backing it must already have been `fund`ed into this
    ///      contract by the test harness; we move it from pending into `realizedYield` (real, present USDC).
    function harvest() external returns (uint256 realized) {
        return _accrue();
    }

    function _accrue() internal returns (uint256 realized) {
        realized = _pendingAccrual();
        lastAccrual = uint64(block.timestamp);
        if (realized == 0) return 0;
        realizedYield += realized;
    }

    // --- test helpers ----------------------------------------------------------------------------

    /// @notice TEST-ONLY: pre-fund this source with USDC that backs future accrued yield, so harvested yield
    ///         is always backed by REAL tokens (never fictitious). The deployer/test calls this.
    function fund(uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice TEST-ONLY: change the APR to exercise different accrual rates.
    function setApr(uint16 newApr) external {
        _accrue();
        aprBps = newApr;
    }
}
