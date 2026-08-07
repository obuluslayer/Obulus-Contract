// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IYieldSource — pluggable yield backend for `ObulusYieldVault`
/// @author Obulus
/// @notice A yield source is an OPT-IN, swappable backend the `ObulusYieldVault` may route its idle USDC to. The
///         vault holds the depositors' shares; the source holds (some or all of) the underlying USDC and
///         tries to grow it. The vault always values itself by `totalAssets()` read back from the source plus
///         whatever idle USDC it still holds directly, so share price reflects realized gains AND realized
///         losses honestly.
///
/// SAFETY / RISK CONTRACT — read this precisely; it is deliberately NOT over-claimed:
///  - This interface makes NO guarantee of a floor. A source MAY lose value. Concretely, an AMM/LP source
///    (e.g. the Uniswap v4 adapter) exposes deposited USDC to impermanent loss, slippage and pool
///    insolvency: `totalAssets()` can return LESS than was deposited, and `withdraw()` can return less than
///    requested. When the vault is backed by such a source, DEPOSITORS BEAR MARKET RISK and the vault is
///    NOT 1:1 redeemable.
///  - Only TWO configurations are principal-protected / 1:1 by construction: (a) NO source set at all (the
///    vault is a pure pass-through holding USDC directly), or (b) a source that is itself principal-protected
///    and honours full redemption (the `MockYieldSource` models this for tests). Do not deploy an AMM source
///    and tell depositors their principal is safe — it is not.
///  - The vault NEVER routes escrow principal or bonds here. A source only ever receives funds a depositor
///    VOLUNTARILY deposited as non-principal surplus. There is no code path from `ObulusEscrow` to a source.
///
/// ACCOUNTING CONTRACT the vault relies on:
///  - `deposit(assets)` is called by the vault, which has ALREADY transferred `assets` USDC to the source
///    (CEI: the vault pushes, then notifies). The source must account for those `assets` as now under
///    management. It must NOT pull from the vault.
///  - `withdraw(assets, to)` instructs the source to return up to `assets` USDC to `to` (the vault). It
///    returns the amount ACTUALLY sent, which MAY be < `assets` for a lossy/illiquid source. The vault
///    treats the returned amount as ground truth and never assumes it got the full request.
///  - `totalAssets()` is the source's best honest estimate of the USDC currently recoverable from it,
///    including accrued-but-unrealized yield where the source can value it. It MUST be monotonic only to the
///    extent the underlying is — i.e. it may go DOWN for a lossy source.
///  - `maxWithdraw()` is the amount the source can honour RIGHT NOW (liquidity-limited). The vault uses it to
///    avoid requesting more than the source can pay in one call.
interface IYieldSource {
    /// @notice The underlying token this source manages. MUST equal the vault's `asset()` (USDC).
    function asset() external view returns (address);

    /// @notice Notify the source that `assets` USDC have just been transferred to it by the vault and should
    ///         be put to work. Caller is the vault. The source MUST NOT pull tokens from the caller.
    /// @param assets The amount of USDC already delivered to this source.
    function deposit(uint256 assets) external;

    /// @notice Return up to `assets` USDC to `to`. For a lossy/illiquid source the amount actually sent MAY
    ///         be less than `assets`; the source returns the amount it actually transferred.
    /// @param assets The requested amount.
    /// @param to     Recipient (always the vault).
    /// @return sent  The amount of USDC actually transferred to `to` (<= assets).
    function withdraw(uint256 assets, address to) external returns (uint256 sent);

    /// @notice The source's honest valuation of the USDC currently recoverable from it (principal +
    ///         realized/estimable yield, minus realized/estimable loss). MAY decrease for a lossy source.
    function totalAssets() external view returns (uint256);

    /// @notice The maximum the source can pay out in a single `withdraw` right now (liquidity bound).
    function maxWithdraw() external view returns (uint256);

    /// @notice Realize/compound any pending yield into `totalAssets()`. Permissionless and idempotent: a
    ///         source with nothing to harvest is a no-op. Returns the assets newly realized (0 for a no-op).
    function harvest() external returns (uint256 realized);
}
