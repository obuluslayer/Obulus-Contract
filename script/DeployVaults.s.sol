// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ObulusStakingVault, IEscrowConfig} from "../src/ObulusStakingVault.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";

/// @title DeployVaults — OPT-IN, env-gated deploy of the auxiliary ObulusStakingVault / ObulusYieldVault
/// @author Obulus
/// @notice A SEPARATE script from `Deploy.s.sol` so the core ObulusEscrow deploy is never touched. It reads the
///         ALREADY-DEPLOYED ObulusEscrow (from an `ESCROW` env override, or from `deployments/<chainId>.json` written
///         by `Deploy.s.sol`) and conditionally deploys the two standalone auxiliary contracts, then EXTENDS
///         the same `deployments/<chainId>.json` with their addresses — additively, preserving every existing
///         key (`escrow`, `usdc`, `chainId`, `deployBlock`) so all current readers keep working.
///
/// EVERYTHING HERE DEFAULTS OFF: with no env set, this script deploys NOTHING (both gates false) and writes
/// nothing. You opt in per-contract with `DEPLOY_STAKING=true` / `DEPLOY_YIELD=true`.
///
/// Env:
///   PRIVATE_KEY        deployer key (falls back to the unlocked sender)
///   ESCROW            override the ObulusEscrow address; else read from deployments/<chainId>.json
///   TREASURY_ADDRESS   fee/slash beneficiary (defaults to the deployer)
///   DEPLOY_STAKING     "true" to deploy the ObulusStakingVault (default off)
///   DEPLOY_YIELD       "true" to deploy the ObulusYieldVault   (default off)
///   STAKING_WITHDRAWAL_DELAY  unstake→withdraw delay in seconds; MUST be > escrow.resolveTimeout()
///                             (asserted at SCRIPT time so a misconfig fails fast). Default 8 days.
///   STAKING_SLASH_CAP_BPS     per-deal slash ceiling in bps (<= MAX_SLASH_CAP_BPS). Default 1000 (10%).
///
/// NOTE: the ObulusYieldVault is deployed with NO yield source — the safe, exactly-1:1 pass-through. The Uniswap v4
///       adapter is a NON-PRODUCTION test skeleton (see UniswapV4YieldSource) and is DELIBERATELY never wired
///       in here. Setting a real, vetted yield source is a separate, explicit owner action post-deploy.
contract DeployVaults is Script {
    /// @notice Fully-resolved deploy config. `run()` fills this from env; tests can build it explicitly and
    ///         call `deploy()` directly (no reliance on `vm.setEnv`, which Foundry does not isolate per-test).
    struct VaultConfig {
        address escrow; // already-deployed ObulusEscrow
        address treasury; // fee/slash beneficiary
        bool deployStaking; // gate (default off)
        bool deployYield; // gate (default off)
        uint64 stakingWithdrawalDelay; // unstake→withdraw delay; asserted > escrow.resolveTimeout()
        uint16 stakingSlashCapBps; // per-deal slash ceiling
        bool broadcast; // true in `run()` (real deploy); false in tests (plain calls)
    }

    /// @notice Production entrypoint: read every knob from env (all gates default OFF), then deploy.
    function run() external returns (address stakingVault, address yieldVault) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        address escrow = _resolveEscrow();

        // Resolve the broadcasting sender for the treasury default (does not start broadcasting yet).
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;
        if (treasury == address(0)) treasury = deployer;

        VaultConfig memory cfg = VaultConfig({
            escrow: escrow,
            treasury: treasury,
            deployStaking: vm.envOr("DEPLOY_STAKING", false),
            deployYield: vm.envOr("DEPLOY_YIELD", false),
            stakingWithdrawalDelay: uint64(vm.envOr("STAKING_WITHDRAWAL_DELAY", uint256(8 days))),
            stakingSlashCapBps: uint16(vm.envOr("STAKING_SLASH_CAP_BPS", uint256(1_000))),
            broadcast: true
        });

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        (stakingVault, yieldVault) = _deployFrom(cfg);
        vm.stopBroadcast();

        _extendDeployment(cfg.escrow, IEscrowConfig(cfg.escrow).usdc(), stakingVault, yieldVault);

        console2.log("chainId        :", block.chainid);
        console2.log("ObulusEscrow         :", cfg.escrow);
        console2.log("treasury       :", cfg.treasury);
    }

    /// @notice Param-driven deploy core (used directly by tests). Performs the gated deploys + the fail-fast
    ///         staking-delay assert, then EXTENDS deployments/<chainId>.json. Does NOT manage broadcasting.
    function deploy(VaultConfig memory cfg) external returns (address stakingVault, address yieldVault) {
        (stakingVault, yieldVault) = _deployFrom(cfg);
        _extendDeployment(cfg.escrow, IEscrowConfig(cfg.escrow).usdc(), stakingVault, yieldVault);
    }

    /// @dev The actual gated contract creations + the fail-fast assert. No env, no broadcast, no file I/O.
    function _deployFrom(VaultConfig memory cfg) internal returns (address stakingVault, address yieldVault) {
        // Read USDC straight from the ObulusEscrow so the vaults always settle in the SAME token as the deals they
        // back — never a stale or mismatched env value. (ObulusStakingVault re-asserts this in its constructor.)
        address usdc = IEscrowConfig(cfg.escrow).usdc();

        // --- ObulusStakingVault (opt-in) ---------------------------------------------------------------
        if (cfg.deployStaking) {
            // FAIL-FAST ASSERT (mirrors the on-chain guard, but caught at SCRIPT time before any tx): the
            // unstake→withdraw delay MUST strictly exceed the escrow's dispute window, otherwise funds
            // unstaked during a live dispute could be withdrawn before the arbiter can slash them. We read
            // resolveTimeout() from the live ObulusEscrow so a misconfigured delay aborts the deploy immediately.
            uint64 resolveTimeout = IEscrowConfig(cfg.escrow).resolveTimeout();
            require(
                cfg.stakingWithdrawalDelay > resolveTimeout,
                "DeployVaults: STAKING_WITHDRAWAL_DELAY must be > escrow.resolveTimeout()"
            );

            ObulusStakingVault sv =
                new ObulusStakingVault(usdc, cfg.escrow, cfg.treasury, cfg.stakingWithdrawalDelay, cfg.stakingSlashCapBps);
            stakingVault = address(sv);
            console2.log("ObulusStakingVault   :", stakingVault);
            console2.log("  withdrawDelay:", cfg.stakingWithdrawalDelay);
            console2.log("  slashCapBps  :", cfg.stakingSlashCapBps);
        }

        // --- ObulusYieldVault (opt-in) — NO source, safe 1:1 pass-through ------------------------------
        if (cfg.deployYield) {
            ObulusYieldVault yv = new ObulusYieldVault(usdc, cfg.treasury);
            yieldVault = address(yv);
            console2.log("ObulusYieldVault     :", yieldVault);
            console2.log("  yieldSource  : (none - safe 1:1 pass-through)");
        }
    }

    /// @dev ESCROW env override, else the `escrow` field of deployments/<chainId>.json (written by Deploy.s.sol).
    function _resolveEscrow() internal view returns (address) {
        address fromEnv = vm.envOr("ESCROW", address(0));
        if (fromEnv != address(0)) return fromEnv;
        string memory path = _deploymentPath();
        require(vm.exists(path), "DeployVaults: no ESCROW env and no deployments/<chainId>.json - deploy ObulusEscrow first");
        string memory json = vm.readFile(path);
        require(vm.keyExistsJson(json, ".escrow"), "DeployVaults: deployments file missing `escrow` key");
        return vm.parseJsonAddress(json, ".escrow");
    }

    /// @dev ADDITIVELY extend deployments/<chainId>.json with the vault addresses. If the file exists we set
    ///      ONLY the new keys via the targeted `writeJson(value, path, key)` form, preserving every existing
    ///      field so current readers (escrow/usdc/chainId/deployBlock) are untouched. If it does not exist
    ///      (ESCROW was supplied by env), we create it with the full field set.
    function _extendDeployment(address escrow, address usdc, address stakingVault, address yieldVault) internal {
        string memory path = _deploymentPath();

        if (vm.exists(path)) {
            // Targeted, key-level writes — non-destructive to the existing JSON object.
            if (stakingVault != address(0)) {
                vm.writeJson(vm.toString(stakingVault), path, ".stakingVault");
            }
            if (yieldVault != address(0)) {
                vm.writeJson(vm.toString(yieldVault), path, ".yieldVault");
            }
        } else {
            if (!vm.exists("deployments")) vm.createDir("deployments", true);
            string memory obj = "deployment";
            // Each serialize call returns the running JSON; we keep the latest so the file always carries the
            // full field set whether or not the optional vault keys are present (no placeholder/marker key).
            vm.serializeAddress(obj, "escrow", escrow);
            vm.serializeAddress(obj, "usdc", usdc);
            vm.serializeUint(obj, "chainId", block.chainid);
            string memory json = vm.serializeUint(obj, "deployBlock", block.number);
            if (stakingVault != address(0)) json = vm.serializeAddress(obj, "stakingVault", stakingVault);
            if (yieldVault != address(0)) json = vm.serializeAddress(obj, "yieldVault", yieldVault);
            vm.writeJson(json, path);
        }
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }
}
