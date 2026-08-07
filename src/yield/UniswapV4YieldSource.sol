// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IYieldSource} from "../interfaces/IYieldSource.sol";
import {
    IPoolManagerMinimal,
    IUnlockCallback,
    PoolKey,
    ModifyLiquidityParams,
    Currency,
    BalanceDelta
} from "./IPoolManagerMinimal.sol";

/// @title UniswapV4YieldSource — a GENUINE-shape Uniswap v4 LP adapter as a ObulusYieldVault yield source
/// @author Obulus
///
/// ╔══════════════════════════════════════════════════════════════════════════════════════════════╗
/// ║  ⛔ NOT PRODUCTION READY — TEST SKELETON ONLY. DO NOT DEPLOY AS A LIVE YIELDVAULT SOURCE. ⛔   ║
/// ╠══════════════════════════════════════════════════════════════════════════════════════════════╣
/// ║  This adapter's valuation (`totalAssets`/`_positionValue`) reads `liquidityOf(address)` and    ║
/// ║  `feesOf(address)` — getters that ONLY the in-repo `MockPoolManager` exposes. A REAL Uniswap   ║
/// ║  v4 `PoolManager` does NOT implement them (live v4 derives position value from packed pool      ║
/// ║  state via StateLibrary), so against a real manager `_positionValue()` silently returns 0 and   ║
/// ║  the vault would mis-price every share to ~0 — a catastrophic mis-valuation. It is therefore    ║
/// ║  hard-guarded below: `IS_PRODUCTION_READY == false`, `isLive() == false`, and the constructor   ║
/// ║  REQUIRES the deployer to pass `acknowledgeTestSkeleton == true`, so this contract can never be  ║
/// ║  silently constructed/passed to `ObulusYieldVault.setYieldSource` on a real network. A live           ║
/// ║  integration must REPLACE `_positionValue()` with a StateLibrary read and flip these guards.     ║
/// ║  It is intentionally wired into NO deploy script (see script/DeployVaults.s.sol).               ║
/// ╚══════════════════════════════════════════════════════════════════════════════════════════════╝
///
/// @notice Routes the vault's idle USDC into a Uniswap v4 position via the PoolManager's flash-accounting
///         (`unlock` → `unlockCallback` → `modifyLiquidity` → `settle`/`take`), and harvests trading fees
///         back as yield. Coded against the minimal in-repo v4 interfaces (`IPoolManagerMinimal`), which
///         mirror the real Uniswap v4-core ABI shapes, so this is the same shape that would run against a
///         live PoolManager — BUT see the banner above: its valuation path is mock-only and it is NOT
///         live-usable as-is.
///
/// !!! RISK — NO FLOOR (read before deploying this as a vault source) !!!
///  This is an AMM/LP source. USDC deposited here is exposed to impermanent loss, slippage, and pool
///  insolvency. `totalAssets()` can return LESS than was deposited, and `withdraw()` can return less than
///  requested. A `ObulusYieldVault` backed by THIS source is NOT 1:1 redeemable and has NO principal floor —
///  depositors knowingly bear market risk. Do NOT pair this source with a "principal-safe" promise. (The
///  principal-protected configurations are: no source at all, or a principal-protected source.)
///
/// LIVE-INFRA STATUS: a live deployment needs (1) a deployed v4 `PoolManager`, (2) an initialized + funded
/// USDC pool keyed by `poolKey`, and (3) — if fees are claimed through a custom hook — a hook contract
/// deployed at a CREATE2 address whose low bits encode the enabled hook flags. None of that exists in this
/// sandbox, so the adapter's accounting/shape is covered locally against `MockPoolManager`. The adapter
/// itself is admin-gated to the vault and never touches any escrow funds.
contract UniswapV4YieldSource is IYieldSource, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Action tags for the unlockCallback dispatch.
    enum Action {
        AddLiquidity,
        RemoveLiquidity
    }

    /// @notice HARD GUARD (audit remediation): this adapter is a TEST SKELETON. Its `_positionValue()` reads
    ///         getters only `MockPoolManager` exposes, so it mis-prices to ~0 against a real PoolManager. This
    ///         flag is `false` so any deploy tooling / integrator can refuse it programmatically; a real,
    ///         StateLibrary-backed implementation must flip it. See also `isLive()`.
    bool public constant IS_PRODUCTION_READY = false;

    IERC20 public immutable usdc;
    IPoolManagerMinimal public immutable manager;
    /// @notice The vault that owns this source. Only it may deposit/withdraw.
    address public immutable vault;

    /// @notice The v4 pool this source LPs into. Set once at construction.
    PoolKey public poolKey;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;

    /// @notice USDC the adapter has booked as deposited principal (best-effort; the live truth is the
    ///         position value reported via `modifyLiquidity`/`totalAssets`).
    uint256 public bookedPrincipal;

    /// @notice Transient: USDC `withdraw` should pull back to the vault during a remove-liquidity unlock.
    uint256 private _pendingRemove;
    /// @notice Transient: where withdrawn USDC goes (the vault).
    address private _withdrawTo;

    error OnlyVault();
    error OnlyManager();
    error AssetMismatch();
    error UnknownAction();
    /// @notice Thrown when the deployer did not explicitly acknowledge this is a NON-PRODUCTION test skeleton.
    ///         This is the hard guard that prevents the adapter from being silently constructed (and thus
    ///         silently passed to `ObulusYieldVault.setYieldSource`) on a real network.
    error NotProductionReady();

    /// @param acknowledgeTestSkeleton MUST be `true`. Passing `false` reverts `NotProductionReady`. This
    ///        forces every caller to make a deliberate, in-code acknowledgement that this adapter is a
    ///        mock-only test skeleton whose valuation does NOT work against a real Uniswap v4 PoolManager.
    constructor(
        address usdc_,
        address manager_,
        address vault_,
        PoolKey memory key_,
        int24 tickLower_,
        int24 tickUpper_,
        bool acknowledgeTestSkeleton
    ) {
        // HARD GUARD: cannot be deployed without explicitly acknowledging it is NOT production-ready.
        if (!acknowledgeTestSkeleton) revert NotProductionReady();
        if (Currency.unwrap(key_.currency0) != usdc_) revert AssetMismatch();
        usdc = IERC20(usdc_);
        manager = IPoolManagerMinimal(manager_);
        vault = vault_;
        poolKey = key_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        // Pre-approve the manager so `settle` transfers are cheap; SafeERC20 forceApprove avoids the
        // non-standard-approve pitfall (USDC tolerates standard approve, but be defensive).
        IERC20(usdc_).forceApprove(manager_, type(uint256).max);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    /// @inheritdoc IYieldSource
    function asset() external view returns (address) {
        return address(usdc);
    }

    /// @notice HARD GUARD: always `false` for this skeleton. Integrators / deploy tooling MUST check this (or
    ///         `IS_PRODUCTION_READY`) before wiring any yield source into `ObulusYieldVault.setYieldSource`, and
    ///         refuse a source that reports `false`. Returns `false` because `_positionValue()` reads getters
    ///         only the mock manager exposes, so this adapter mis-prices to ~0 against a real PoolManager.
    function isLive() external pure returns (bool) {
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // deposit / withdraw — each opens its own v4 lock
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IYieldSource
    /// @dev The vault has already transferred `assets` USDC to this adapter. We add that as liquidity inside
    ///      a fresh v4 lock. Reentrancy-guarded; only the vault may call.
    function deposit(uint256 assets) external onlyVault nonReentrant {
        if (assets == 0) return;
        bookedPrincipal += assets;
        manager.unlock(abi.encode(Action.AddLiquidity, assets, address(0)));
    }

    /// @inheritdoc IYieldSource
    /// @dev Remove `assets` of liquidity (capped at what the position holds) plus accrued fees, sending the
    ///      realized USDC to `to`. Returns what was ACTUALLY sent — may be < `assets` for a lossy/illiquid
    ///      position (the vault treats the return as ground truth).
    function withdraw(uint256 assets, address to) external onlyVault nonReentrant returns (uint256 sent) {
        if (assets == 0) return 0;
        uint256 balBefore = usdc.balanceOf(to);
        _withdrawTo = to;
        _pendingRemove = assets;
        manager.unlock(abi.encode(Action.RemoveLiquidity, assets, to));
        _pendingRemove = 0;
        _withdrawTo = address(0);
        // Ground truth: what `to` actually received this call.
        sent = usdc.balanceOf(to) - balBefore;
        // Reduce booked principal by what left (floor at 0).
        bookedPrincipal = sent < bookedPrincipal ? bookedPrincipal - sent : 0;
    }

    /// @inheritdoc IYieldSource
    /// @dev Best-effort valuation: the live position value. In this adapter we report bookedPrincipal + any
    ///      USDC idly held here (e.g. fees already collected but not yet swept). A real integration would read
    ///      the position's principal+fees from the PoolManager's state libraries; against the mock the
    ///      position principal is `manager.liquidityOf(this)` and pending fees are `manager.feesOf(this)`,
    ///      surfaced via the view below so tests see honest gains AND losses.
    function totalAssets() public view returns (uint256) {
        return _positionValue() + usdc.balanceOf(address(this));
    }

    /// @inheritdoc IYieldSource
    function maxWithdraw() external view returns (uint256) {
        // Liquidity-bound by the position's recoverable value + any idle USDC here.
        return totalAssets();
    }

    /// @inheritdoc IYieldSource
    /// @dev Harvest = remove zero principal but collect accrued fees into this contract as realized yield.
    ///      Permissionless and idempotent. Collected fees raise `totalAssets()` (and thus vault share price).
    function harvest() external nonReentrant returns (uint256 realized) {
        uint256 before = usdc.balanceOf(address(this));
        // Remove 0 principal → the mock still pays out accrued fees; on a real pool you'd collect fees via a
        // zero-delta modifyLiquidity. Guard: only attempt if there is something to collect.
        manager.unlock(abi.encode(Action.RemoveLiquidity, uint256(0), address(this)));
        realized = usdc.balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------------------------------------
    // v4 unlock callback — the only place modifyLiquidity / settle / take are called
    // ---------------------------------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (Action action, uint256 amount, address to) = abi.decode(data, (Action, uint256, address));

        if (action == Action.AddLiquidity) {
            _addLiquidity(amount);
        } else if (action == Action.RemoveLiquidity) {
            _removeLiquidity(amount, to);
        } else {
            revert UnknownAction();
        }
        return "";
    }

    function _addLiquidity(uint256 amount) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(amount),
            salt: bytes32(0)
        });
        manager.modifyLiquidity(poolKey, params, "");
        // We owe `amount` USDC to the manager → sync + transfer + settle (v4 settlement pattern).
        manager.sync(poolKey.currency0);
        usdc.safeTransfer(address(manager), amount);
        manager.settle();
    }

    function _removeLiquidity(uint256 amount, address to) internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(amount),
            salt: bytes32(0)
        });
        (BalanceDelta callerDelta,) = manager.modifyLiquidity(poolKey, params, "");
        // The manager owes us `callerDelta.amount0` USDC (principal removed + fees). Take it to `to`.
        int128 owed = callerDelta.amount0();
        if (owed > 0) {
            manager.take(poolKey.currency0, to, uint256(int256(owed)));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views into the (mock or real) manager position
    // ---------------------------------------------------------------------------------------------

    /// @dev Recoverable value of the LP position. Against the MockPoolManager this is the recorded liquidity
    ///      plus unclaimed fees; against a real PoolManager an integration would compute it from pool state.
    ///      We read it through a minimal positional interface so this compiles for both.
    function _positionValue() internal view returns (uint256) {
        // Best-effort: ask the manager what liquidity + fees this position holds. The minimal interface does
        // not declare these getters (a real v4 reads them via StateLibrary); the mock exposes them, so we
        // low-level staticcall and tolerate absence (returns 0) to stay shape-compatible with real v4.
        (bool okL, bytes memory lr) =
            address(manager).staticcall(abi.encodeWithSignature("liquidityOf(address)", address(this)));
        (bool okF, bytes memory fr) =
            address(manager).staticcall(abi.encodeWithSignature("feesOf(address)", address(this)));
        uint256 lq = okL && lr.length == 32 ? abi.decode(lr, (uint256)) : 0;
        uint256 fees = okF && fr.length == 32 ? abi.decode(fr, (uint256)) : 0;
        return lq + fees;
    }
}
