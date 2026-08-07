// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ObulusSubscriptionEscrow} from "../src/ObulusSubscriptionEscrow.sol";

/// @title DeploySubscription — OPT-IN, env-gated deploy of the auxiliary ObulusSubscriptionEscrow (Tier 3 "rent")
/// @author Obulus
/// @notice A SEPARATE script from `Deploy.s.sol` / `DeployVaults.s.sol` so the core ObulusEscrow deploy is never
///         touched. It reads the SETTLEMENT TOKEN (`usdc`) from the ALREADY-WRITTEN
///         `deployments/<chainId>.json` (the file `Deploy.s.sol` produces — see `_resolveUsdc`), deploys a
///         ObulusSubscriptionEscrow that settles in that SAME token, then EXTENDS the same
///         `deployments/<chainId>.json` with `subscriptionEscrow` — ADDITIVELY, preserving every existing key
///         (`escrow`, `usdc`, `chainId`, `deployBlock`, and any `stakingVault`/`yieldVault`) so all current
///         readers keep working. This mirrors `DeployVaults._extendDeployment` field-for-field.
///
/// EVERYTHING HERE DEFAULTS OFF: with no env set, this script deploys NOTHING (the gate is false) and writes
/// nothing. You opt in with `DEPLOY_SUBSCRIPTION=true`.
///
/// ObulusSubscriptionEscrow constructor is `(usdc, treasury, feeBps, arbFeeBps, resolveTimeout)` — the same
/// commission/arbitration/timeout knobs as the single ObulusEscrow, applied per period. The defaults mirror
/// `Deploy.s.sol` (feeBps 1%, arbFeeBps 20%, resolveTimeout 7 days) so the two surfaces stay coherent.
///
/// Env (all optional, sensible defaults):
///   PRIVATE_KEY          deployer key (falls back to the unlocked sender / anvil default)
///   DEPLOY_SUBSCRIPTION  "true" to deploy the ObulusSubscriptionEscrow (default off → no-op)
///   USDG_ADDRESS         override the settlement token (USDC_ADDRESS still accepted); else read `usdc` from deployments/<chainId>.json
///   TREASURY_ADDRESS     fee/commission sink (defaults to the deployer)
///   SUB_FEE_BPS          protocol commission per claimed period, default 100 (1%); <= MAX_FEE_BPS (1000)
///   SUB_ARB_FEE_BPS      arbitration fee as a fraction of the slashed bond, default 2000 (20%); <= 5000
///   SUB_RESOLVE_TIMEOUT  absent-arbiter fallback grace in seconds, default 7 days (must be > 0)
contract DeploySubscription is Script {
    /// @notice Fully-resolved deploy config. `run()` fills this from env; tests can build it explicitly and
    ///         call `deploy()` directly (no reliance on `vm.setEnv`, which Foundry does not isolate per-test).
    struct SubConfig {
        address usdc; // settlement token (read from deployments/<chainId>.json, or USDC_ADDRESS override)
        address treasury; // fee/commission sink
        bool deploy; // gate (default off)
        uint16 feeBps; // protocol commission per claimed period
        uint16 arbFeeBps; // arbitration fee on a slashed bond
        uint64 resolveTimeout; // absent-arbiter fallback grace
        bool broadcast; // true in `run()` (real deploy); false in tests (plain calls)
    }

    /// @notice Production entrypoint: read every knob from env (the gate defaults OFF), then deploy.
    function run() external returns (address subscriptionEscrow) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        address usdc = _resolveUsdc();

        // Resolve the broadcasting sender for the treasury default (does not start broadcasting yet).
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;
        if (treasury == address(0)) treasury = deployer;

        SubConfig memory cfg = SubConfig({
            usdc: usdc,
            treasury: treasury,
            deploy: vm.envOr("DEPLOY_SUBSCRIPTION", false),
            feeBps: uint16(vm.envOr("SUB_FEE_BPS", uint256(100))),
            arbFeeBps: uint16(vm.envOr("SUB_ARB_FEE_BPS", uint256(2_000))),
            resolveTimeout: uint64(vm.envOr("SUB_RESOLVE_TIMEOUT", uint256(7 days))),
            broadcast: true
        });

        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        subscriptionEscrow = _deployFrom(cfg);
        vm.stopBroadcast();

        if (subscriptionEscrow != address(0)) _extendDeployment(subscriptionEscrow);

        console2.log("chainId            :", block.chainid);
        console2.log("USDC               :", cfg.usdc);
        console2.log("treasury           :", cfg.treasury);
        console2.log("ObulusSubscriptionEscrow :", subscriptionEscrow);
    }

    /// @notice Param-driven deploy core (used directly by tests). Performs the gated deploy then EXTENDS
    ///         deployments/<chainId>.json. Does NOT manage broadcasting.
    function deploy(SubConfig memory cfg) external returns (address subscriptionEscrow) {
        subscriptionEscrow = _deployFrom(cfg);
        if (subscriptionEscrow != address(0)) _extendDeployment(subscriptionEscrow);
    }

    /// @dev The actual gated contract creation. No env, no broadcast, no file I/O. Returns address(0) when
    ///      the gate is off (so `run()`/`deploy()` write nothing — the default no-op path).
    function _deployFrom(SubConfig memory cfg) internal returns (address subscriptionEscrow) {
        if (!cfg.deploy) return address(0);
        ObulusSubscriptionEscrow sub =
            new ObulusSubscriptionEscrow(cfg.usdc, cfg.treasury, cfg.feeBps, cfg.arbFeeBps, cfg.resolveTimeout);
        subscriptionEscrow = address(sub);
        console2.log("ObulusSubscriptionEscrow :", subscriptionEscrow);
        console2.log("  feeBps           :", cfg.feeBps);
        console2.log("  arbFeeBps        :", cfg.arbFeeBps);
        console2.log("  resolveTimeout   :", cfg.resolveTimeout);
    }

    /// @dev USDC_ADDRESS env override, else the `usdc` field of deployments/<chainId>.json (written by
    ///      Deploy.s.sol). The subscription contract MUST settle in the same token as the single escrow.
    function _resolveUsdc() internal view returns (address) {
        // USDG_ADDRESS is the current name; USDC_ADDRESS stays accepted through the rename.
        address fromEnv = vm.envOr("USDG_ADDRESS", vm.envOr("USDC_ADDRESS", address(0)));
        if (fromEnv != address(0)) return fromEnv;
        string memory path = _deploymentPath();
        require(
            vm.exists(path),
            "DeploySubscription: no USDC_ADDRESS env and no deployments/<chainId>.json - deploy ObulusEscrow first"
        );
        string memory json = vm.readFile(path);
        require(vm.keyExistsJson(json, ".usdc"), "DeploySubscription: deployments file missing `usdc` key");
        return vm.parseJsonAddress(json, ".usdc");
    }

    /// @dev ADDITIVELY extend deployments/<chainId>.json with `subscriptionEscrow`. If the file exists we set
    ///      ONLY the new key via the targeted `writeJson(value, path, key)` form, preserving every existing
    ///      field so current readers (escrow/usdc/chainId/deployBlock/stakingVault/yieldVault) are untouched.
    ///      If it does not exist (USDC was supplied by env), we create it carrying usdc + the new key.
    function _extendDeployment(address subscriptionEscrow) internal {
        string memory path = _deploymentPath();

        if (vm.exists(path)) {
            // Targeted, key-level write — non-destructive to the existing JSON object.
            vm.writeJson(vm.toString(subscriptionEscrow), path, ".subscriptionEscrow");
        } else {
            if (!vm.exists("deployments")) vm.createDir("deployments", true);
            string memory obj = "deployment";
            vm.serializeUint(obj, "chainId", block.chainid);
            vm.serializeUint(obj, "deployBlock", block.number);
            string memory json = vm.serializeAddress(obj, "subscriptionEscrow", subscriptionEscrow);
            vm.writeJson(json, path);
        }
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }
}
