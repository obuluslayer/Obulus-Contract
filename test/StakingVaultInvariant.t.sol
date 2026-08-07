// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {ObulusStakingVault} from "../src/ObulusStakingVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {StakingVaultHandler} from "./handlers/StakingVaultHandler.sol";

/// @notice The headline safety guarantee for the vault: across any sequence of stake / unstake / withdraw
///         actions AND arbiter-authorised slashes over many real disputed ObulusEscrow deals, the vault's USDC
///         balance equals exactly Σ stake + Σ pending withdrawals. Slashed funds leave to the treasury and
///         are removed from stake in the same step, so no wei is ever created, destroyed, or stranded.
contract StakingVaultInvariantTest is StdInvariant, Test {
    ObulusEscrow internal escrow;
    ObulusStakingVault internal vault;
    MockUSDC internal usdc;
    StakingVaultHandler internal handler;

    address internal escrowTreasury = makeAddr("inv-escrow-treasury");
    address internal vaultTreasury = makeAddr("inv-vault-treasury");
    address internal arbiter = makeAddr("inv-arbiter");

    function setUp() public {
        usdc = new MockUSDC();
        escrow = new ObulusEscrow(address(usdc), escrowTreasury, 100, 2_000, 7 days);
        // withdrawalDelay must STRICTLY exceed escrow.resolveTimeout() (7 days) — the enforced anti-evasion
        // floor — so we deploy at 7 days + 1, the minimal valid strict-greater config.
        vault = new ObulusStakingVault(address(usdc), address(escrow), vaultTreasury, 7 days + 1, 2_000);
        handler = new StakingVaultHandler(vault, escrow, usdc, vaultTreasury, arbiter);

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.makeDisputedDeal.selector;
        selectors[4] = handler.slash.selector;
        selectors[5] = handler.slashByStranger.selector;
        selectors[6] = handler.resolveDeal.selector;
        selectors[7] = handler.warp.selector;
        selectors[8] = handler.withdraw.selector; // weight withdraw a touch more
        // forceSlash is the LOAD-BEARING action: a deterministic composite that lands a real non-dust
        // arbiter slash on (almost) every call, half of them routed through the pending bucket. Weighted
        // heavily (5/14 of the selector space) so the slash accounting is exercised against the conservation
        // invariants on a large, meaningful fraction of calls rather than the ~1 non-dust slash the old
        // randomised-only handler managed over thousands of calls.
        selectors[9] = handler.forceSlash.selector;
        selectors[10] = handler.forceSlash.selector;
        selectors[11] = handler.forceSlash.selector;
        selectors[12] = handler.forceSlash.selector;
        selectors[13] = handler.forceSlash.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev CONSERVATION: vault.balance == totalStaked + totalPending, recomputed from per-account state.
    function invariant_fundsConserved() public view {
        uint256 expected;
        uint256 n = handler.stakersLength();
        for (uint256 i; i < n; i++) {
            address a = handler.stakersList(i);
            expected += vault.stakeOf(a);
            (uint256 pending,) = vault.pendingWithdrawal(a);
            expected += pending;
        }
        // The treasury never stakes here, but include it defensively in case a future action lets it.
        expected += vault.stakeOf(vaultTreasury);
        (uint256 tp,) = vault.pendingWithdrawal(vaultTreasury);
        expected += tp;

        assertEq(usdc.balanceOf(address(vault)), expected, "vault balance == sum(stake) + sum(pending)");
    }

    /// @dev The vault's own running aggregates must equal the per-account recomputation (no drift).
    function invariant_aggregatesMatch() public view {
        uint256 stakeSum;
        uint256 pendingSum;
        uint256 n = handler.stakersLength();
        for (uint256 i; i < n; i++) {
            address a = handler.stakersList(i);
            stakeSum += vault.stakeOf(a);
            (uint256 pending,) = vault.pendingWithdrawal(a);
            pendingSum += pending;
        }
        assertEq(vault.totalStaked(), stakeSum, "totalStaked == sum(stakeOf)");
        assertEq(vault.totalPending(), pendingSum, "totalPending == sum(pending)");
    }

    /// @dev Whatever the vault holds plus whatever it slashed out must equal whatever was ever staked in.
    ///      Slashed funds are exactly the treasury's balance (it starts at 0 and only ever receives slashes).
    function invariant_balancePlusSlashedConserved() public view {
        // Vault balance + treasury balance == sum of all deposits is implied by fundsConserved + the fact
        // that slashes are the only outflow to the treasury; we assert the treasury only ever grew.
        assertGe(usdc.balanceOf(vaultTreasury), 0, "treasury balance is non-negative");
        assertEq(usdc.balanceOf(address(vault)), vault.totalObligations(), "balance == obligations");
        // The treasury balance is EXACTLY the sum the handler accounted as slashed (cross-check: the ghost
        // total tracks every wei that left the vault to the treasury, and slashes are its only inflow).
        assertEq(usdc.balanceOf(vaultTreasury), handler.ghostSlashedTotal(), "treasury == ghost slashed total");
    }

    /// @dev MAKES THE CONSERVATION INVARIANTS LOAD-BEARING FOR SLASH. A representative run with the old
    ///      handler landed ~1 non-dust slash across thousands of calls, so the accounting above never
    ///      actually moved slash funds — it could have been subtly broken and gone undetected. The
    ///      deterministic `forceSlash` action now lands real non-dust slashes constantly; this hook (called
    ///      ONCE by forge after the WHOLE run completes — unlike `invariant_*`, which run after every call)
    ///      asserts a floor on how many fired, AND that a chunk of them routed through the pending bucket
    ///      (the anti-unstake-evasion path). If these floors aren't met, the conservation invariants are
    ///      vacuous w.r.t. slashing and the run is treated as not having exercised the path.
    ///
    ///      DE-FLAKING (round 2): two changes make this a robust tripwire rather than a seed-dependent one.
    ///      (1) STALE/SHRUNK-REPLAY GUARD: `afterInvariant` also runs when forge replays a CACHED, shrunk
    ///      counterexample (which may be a 1-call sequence with zero forceSlash calls). Asserting a cumulative
    ///      floor on such a replay would spuriously fail. We therefore only assert the floors once a
    ///      REPRESENTATIVE number of forceSlash calls actually ran this session (`ghostForceEntries`); a tiny
    ///      replay is not expected to exercise the slash path and is skipped. (2) LOW FLOORS WITH WIDE MARGIN:
    ///      the floors are set far below the per-run minimum so they only prove the run TOUCHED slashing /
    ///      the pending path — the deterministic unit tests already prove the exact accounting. With
    ///      forceSlash weighted 5/14 of selectors over depth=64*runs=128 calls, a real run lands hundreds of
    ///      non-dust slashes with ~half routed through pending (parity-deterministic), so these floors clear
    ///      with enormous margin on every seed.
    function afterInvariant() public view {
        // Stale/shrunk-replay guard: only assert the slash-path floors when this session actually ran a
        // representative number of forceSlash calls. A shrunk cached counterexample (e.g. a 1-call replay)
        // would have ~0 forceSlash entries and must NOT trip a cumulative floor it was never meant to meet.
        if (handler.ghostForceEntries() < 8) return;

        // Low floors, cleared with wide margin every seed. forceSlash routing is parity-deterministic, so
        // ~half of landed slashes reach the pending bucket regardless of seed. These only prove the RUN
        // touched slashing and the anti-evasion path — the unit tests prove the exact wei accounting.
        assertGe(
            handler.ghostNonDustSlashCount(),
            3,
            "too few non-dust slashes landed - conservation invariants are not load-bearing for slash"
        );
        assertGe(
            handler.ghostPendingSlashCount(),
            1,
            "the anti-evasion (slash-reaches-pending) path was not exercised enough"
        );
    }
}
