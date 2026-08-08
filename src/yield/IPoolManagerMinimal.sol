// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Minimal local Uniswap v4 interfaces (declared in-repo to avoid a heavy submodule)
/// @notice These mirror the GENUINE v4-core ABI shapes (PoolKey / IHooks / Currency / BalanceDelta /
///         ModifyLiquidityParams / IPoolManager.unlock+modifyLiquidity+take+settle+sync) closely enough that
///         the adapter coded against them is the same shape that would compile against the real
///         the real Uniswap v4-core package. The task explicitly permits declaring these minimal interfaces locally when a
///         full v4 submodule install would risk the existing carefully-tuned Foundry build/test suite. The
///         field names, types and function signatures here are taken from v4-core
///         (src/types/PoolKey.sol, src/types/Currency.sol, src/types/PoolOperation.sol,
///         src/interfaces/IPoolManager.sol, src/interfaces/callback/IUnlockCallback.sol).
///
/// LIVE-INFRA NOTE: the real v4 adapter requires a deployed `PoolManager`, an initialized + funded USDG pool,
/// and (for fee-claiming via a hook) a hook contract deployed at a CREATE2 address whose low bits encode the
/// enabled hook flags. None of that exists in this sandbox, so the adapter's accounting/shape is exercised
/// against `MockPoolManager` which simulates the unlock/modifyLiquidity/fee mechanics deterministically.

/// @dev v4 wraps token addresses in a `Currency` user-defined value type (address-backed).
type Currency is address;

using {currencyEquals as ==} for Currency global;

function currencyEquals(Currency a, Currency b) pure returns (bool) {
    return Currency.unwrap(a) == Currency.unwrap(b);
}

/// @dev v4 packs (amount0, amount1) as two int128 into one int256. We expose the same packing helpers the
///      adapter needs without pulling the full library.
type BalanceDelta is int256;

function toBalanceDelta(int128 _amount0, int128 _amount1) pure returns (BalanceDelta balanceDelta) {
    assembly ("memory-safe") {
        balanceDelta := or(shl(128, _amount0), and(sub(shl(128, 1), 1), _amount1))
    }
}

library BalanceDeltaLibrary {
    function amount0(BalanceDelta bd) internal pure returns (int128 a0) {
        assembly ("memory-safe") {
            a0 := sar(128, bd)
        }
    }

    function amount1(BalanceDelta bd) internal pure returns (int128 a1) {
        assembly ("memory-safe") {
            a1 := signextend(15, bd)
        }
    }
}

using BalanceDeltaLibrary for BalanceDelta global;

/// @notice The hooks of a pool. The adapter does not implement a hook (it's a plain LP), so it only needs
///         the type to fill the PoolKey. Kept minimal — a real hook would implement the before/after methods.
interface IHooks {}

/// @notice Pool identity (mirror of v4-core `PoolKey`).
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

/// @notice Mirror of v4-core `ModifyLiquidityParams`.
struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

/// @notice Mirror of v4-core `IUnlockCallback`. The adapter implements this so the PoolManager can call back
///         while unlocked.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Minimal mirror of v4-core `IPoolManager`: the exact subset the LP adapter touches.
interface IPoolManagerMinimal {
    /// @notice Open a lock and call `unlockCallback` on the caller; net deltas must be zero by the end.
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Add/remove liquidity. Positive `liquidityDelta` adds; negative removes. Returns the caller's
    ///         net balance delta and the fees accrued to the position.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /// @notice Pull `amount` of `currency` from the manager to `to` (settling a negative delta the caller is
    ///         owed). Used to collect removed liquidity + fees.
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Mark the start of paying a positive delta the caller owes; followed by a real token transfer.
    function sync(Currency currency) external;

    /// @notice Pay what the caller owes (after transferring tokens to the manager). Returns amount credited.
    function settle() external payable returns (uint256 paid);
}
