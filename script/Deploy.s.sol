// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Network-agnostic deploy. Resolves USDC from env (`USDC_ADDRESS`); otherwise deploys a
///         MockUSDC (test/local chains only — Robinhood Chain mainnet refuses the mock fallback).
///         Writes `deployments/<chainId>.json` consumed by the Hub/SDK.
///
/// Env (all optional, sensible defaults):
///   PRIVATE_KEY      deployer key (falls back to the unlocked sender / anvil default)
///   USDC_ADDRESS     override the settlement token
///   TREASURY_ADDRESS commission sink (defaults to the deployer)
///   FEE_BPS          protocol commission, default 100 (1%)
///   ARB_FEE_BPS      arbitration fee as a fraction of the slashed bond, default 2000 (20%)
///   RESOLVE_TIMEOUT  absent-arbiter fallback grace period in seconds, default 7 days
contract Deploy is Script {
    function run() external returns (ObulusEscrow escrow, address usdc) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(100)));
        uint16 arbFeeBps = uint16(vm.envOr("ARB_FEE_BPS", uint256(2_000)));
        uint64 resolveTimeout = uint64(vm.envOr("RESOLVE_TIMEOUT", uint256(7 days)));

        address deployer;
        if (pk != 0) {
            deployer = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
            deployer = msg.sender;
        }
        if (treasury == address(0)) treasury = deployer;

        usdc = _resolveUsdc();
        escrow = new ObulusEscrow(usdc, treasury, feeBps, arbFeeBps, resolveTimeout);

        vm.stopBroadcast();

        _writeDeployment(address(escrow), usdc);
        console2.log("chainId        :", block.chainid);
        console2.log("ObulusEscrow         :", address(escrow));
        console2.log("USDC           :", usdc);
        console2.log("treasury       :", treasury);
        console2.log("feeBps         :", feeBps);
        console2.log("deployBlock    :", block.number);
    }

    function _resolveUsdc() internal returns (address) {
        // No canonical Circle USDC is published for Robinhood Chain yet (check
        // https://developers.circle.com/stablecoins/usdc-on-main-networks before mainnet), so USDC
        // comes from env; USE_MOCK_USDC=true / the local fallback deploy a freely-mintable MockUSDC
        // (testnet liquidity for the arena bots, local dev).
        if (vm.envOr("USE_MOCK_USDC", false)) return address(new MockUSDC());
        address fromEnv = vm.envOr("USDC_ADDRESS", address(0));
        if (fromEnv != address(0)) return fromEnv;
        require(block.chainid != 4663, "Robinhood mainnet: set USDC_ADDRESS (no MockUSDC fallback)");
        return address(new MockUSDC());
    }

    function _writeDeployment(address escrow, address usdc) internal {
        // mkdir -p: a fresh clone has no deployments/ and vm.writeJson refuses to create parents.
        if (!vm.exists("deployments")) vm.createDir("deployments", true);
        string memory obj = "deployment";
        vm.serializeAddress(obj, "escrow", escrow);
        vm.serializeAddress(obj, "usdc", usdc);
        vm.serializeUint(obj, "chainId", block.chainid);
        string memory json = vm.serializeUint(obj, "deployBlock", block.number);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
