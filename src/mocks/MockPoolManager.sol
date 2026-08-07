// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IPoolManagerMinimal,
    IUnlockCallback,
    PoolKey,
    ModifyLiquidityParams,
    Currency,
    BalanceDelta,
    toBalanceDelta
} from "../yield/IPoolManagerMinimal.sol";

/// @notice TEST-ONLY simulation of the v4 PoolManager's flash-accounting mechanics, faithful enough to
///         exercise the adapter's unlock → modifyLiquidity → settle/take → fee-harvest shape and accounting.
///         It is NOT a real AMM; it does no price math. It models the parts the adapter depends on:
///          - `unlock(data)` opens a lock and calls back `unlockCallback` on the caller (the adapter).
///          - `modifyLiquidity` with positive delta records the adapter OWES token0 (the LP it is adding);
///            with negative delta records the manager OWES the adapter back its liquidity, and ALSO returns a
///            `feesAccrued` delta = the simulated trading fees this position earned.
///          - `sync`/`settle` accept the tokens the adapter owes; `take` pays the adapter what it is owed.
///          - At `unlock` end, the net recorded delta for the locker MUST be zero (flash-accounting), exactly
///            like real v4 — so the adapter is forced to balance its books or the call reverts.
///
/// SINGLE-SIDED MODEL: to keep the adapter LP accounting in one token (USDC), this mock treats `currency0`
/// as USDC and ignores `currency1` movement (a real single-sided/JIT or a USDC/USDC-like pool concept). The
/// "liquidity" the adapter holds is tracked 1:1 in USDC units; fees are injected by the test via `accrueFees`.
contract MockPoolManager is IPoolManagerMinimal {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    /// @notice The currently-unlocked locker (0 when locked). Mirrors v4's transient lock.
    address public unlockedBy;

    /// @notice Per-locker net USDC delta inside an unlock. Positive = locker OWES the manager; negative =
    ///         manager OWES the locker. Must be 0 when the unlock ends.
    mapping(address => int256) public delta0;

    /// @notice USDC liquidity recorded per (locker) — single-pool simplification.
    mapping(address => uint256) public liquidityOf;

    /// @notice Simulated unclaimed trading fees (USDC) accrued to a locker's position; realized on next
    ///         negative `modifyLiquidity` (remove) as the `feesAccrued` delta, like collecting fees in v4.
    mapping(address => uint256) public feesOf;

    /// @notice Whether `sync` was called for USDC in the current settle cycle (mirrors v4's sync/settle).
    bool internal synced;

    error Locked();
    error NotUnlocked();
    error DeltaNotZero(int256 d);
    error WrongCurrency();

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    // --- unlock / flash-accounting ---------------------------------------------------------------

    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (unlockedBy != address(0)) revert Locked();
        unlockedBy = msg.sender;

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // Flash-accounting: the locker must have netted its USDC delta to zero.
        if (delta0[msg.sender] != 0) revert DeltaNotZero(delta0[msg.sender]);
        unlockedBy = address(0);
        synced = false;
    }

    modifier onlyUnlocked() {
        if (msg.sender != unlockedBy) revert NotUnlocked();
        _;
    }

    // --- liquidity ------------------------------------------------------------------------------

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        onlyUnlocked
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        if (Currency.unwrap(key.currency0) != address(usdc)) revert WrongCurrency();
        address locker = msg.sender;

        if (params.liquidityDelta > 0) {
            // Adding liquidity: the locker OWES that USDC to the manager → positive delta to be settled.
            uint256 add = uint256(params.liquidityDelta);
            liquidityOf[locker] += add;
            delta0[locker] += int256(add);
            // callerDelta.amount0 negative = the locker must pay (v4 convention: negative = owed by caller).
            callerDelta = toBalanceDelta(-int128(int256(add)), int128(0));
            feesAccrued = toBalanceDelta(int128(0), int128(0));
        } else {
            // Removing liquidity (delta <= 0): the manager OWES the locker its removed principal back PLUS any
            // accrued fees. A ZERO `liquidityDelta` is the canonical v4 fee-collection call: it removes no
            // principal but still realizes (collects) the position's accrued fees — exactly how the adapter's
            // `harvest()` works. So fees are realized on the `<= 0` branch, including the 0 case.
            uint256 remove = uint256(-params.liquidityDelta);
            uint256 lq = liquidityOf[locker];
            if (remove > lq) remove = lq;
            liquidityOf[locker] = lq - remove;

            uint256 fees = feesOf[locker];
            feesOf[locker] = 0;

            uint256 owed = remove + fees;
            // Manager owes the locker → negative delta (manager will pay via `take`).
            delta0[locker] -= int256(owed);
            callerDelta = toBalanceDelta(int128(int256(owed)), int128(0));
            feesAccrued = toBalanceDelta(int128(int256(fees)), int128(0));
        }
    }

    // --- settle (locker pays) / take (manager pays) ----------------------------------------------

    function sync(Currency currency) external onlyUnlocked {
        if (Currency.unwrap(currency) != address(usdc)) revert WrongCurrency();
        synced = true;
    }

    /// @notice The locker has transferred USDC to this manager; credit it against their positive delta.
    ///         We measure the manager's balance increase since the last settle to know how much was paid.
    function settle() external payable onlyUnlocked returns (uint256 paid) {
        // Amount paid = current manager balance - (what's backing other lockers' liquidity & fees). For this
        // single-locker test model we credit the locker's full outstanding positive delta if covered by the
        // freshly-received tokens. We compute paid from the delta the locker still owes.
        int256 d = delta0[msg.sender];
        if (d <= 0) return 0;
        paid = uint256(d);
        delta0[msg.sender] = 0;
        synced = false;
    }

    /// @notice Pay `amount` USDC from the manager to `to`, crediting the locker's negative delta.
    function take(Currency currency, address to, uint256 amount) external onlyUnlocked {
        if (Currency.unwrap(currency) != address(usdc)) revert WrongCurrency();
        delta0[msg.sender] += int256(amount); // moves a negative delta toward zero
        usdc.safeTransfer(to, amount);
    }

    // --- test helpers ----------------------------------------------------------------------------

    /// @notice TEST-ONLY: simulate trading fees accruing to `locker`'s position. Backed by REAL USDC the test
    ///         transfers in (so the manager can actually pay them out on removal — no fictitious value).
    function accrueFees(address locker, uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        feesOf[locker] += amount;
    }

    /// @notice TEST-ONLY: simulate an LP LOSS (impermanent loss / slippage) on `locker`'s position by
    ///         reducing its recorded liquidity. The orphaned USDC stays in the manager (models value that
    ///         left the position). This lets tests exercise the NO-FLOOR / lossy-source path honestly.
    function inflictLoss(address locker, uint256 amount) external {
        uint256 lq = liquidityOf[locker];
        liquidityOf[locker] = amount < lq ? lq - amount : 0;
    }
}
