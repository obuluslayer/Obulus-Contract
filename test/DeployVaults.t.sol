// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployVaults} from "../script/DeployVaults.s.sol";
import {ObulusEscrow} from "../src/ObulusEscrow.sol";
import {ObulusStakingVault} from "../src/ObulusStakingVault.sol";
import {ObulusYieldVault} from "../src/ObulusYieldVault.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Smoke tests for the OPT-IN DeployVaults script: the gates default off, the staking-delay fail-fast
///         assert fires on a misconfig, the ObulusYieldVault is deployed source-less (safe 1:1), and the
///         deployments/<chainId>.json is EXTENDED additively (new vault keys added, existing keys preserved).
///
/// We drive the script via its PARAM-DRIVEN `deploy(VaultConfig)` core rather than `run()`'s env path, because
/// Foundry does not isolate `vm.setEnv` between tests. Each test also pins a UNIQUE chainId so its
/// deployments/<id>.json never collides with another test's file, and removes the file at the end.
contract DeployVaultsTest is Test {
    MockUSDC internal usdc;
    ObulusEscrow internal escrow;
    DeployVaults internal script;

    address internal treasury = makeAddr("dv-treasury");
    uint64 internal constant RESOLVE_TIMEOUT = 7 days;

    string internal path;

    function setUp() public {
        usdc = new MockUSDC();
        // feeBps=100 (1%), arbFeeBps=2000 (20%), resolveTimeout=7d.
        escrow = new ObulusEscrow(address(usdc), treasury, 100, 2_000, RESOLVE_TIMEOUT);
        script = new DeployVaults();
    }

    /// @dev Pin a unique chainId (→ unique file path) for this test and point `path` at it.
    function _useChain(uint256 chainId) internal {
        vm.chainId(chainId);
        path = string.concat("deployments/", vm.toString(chainId), ".json");
    }

    function _cfg(bool deployStaking, bool deployYield, uint64 delay)
        internal
        view
        returns (DeployVaults.VaultConfig memory)
    {
        return DeployVaults.VaultConfig({
            escrow: address(escrow),
            treasury: treasury,
            deployStaking: deployStaking,
            deployYield: deployYield,
            stakingWithdrawalDelay: delay,
            stakingSlashCapBps: 1_000,
            broadcast: false
        });
    }

    function _writeBaseDeployment() internal {
        // Mirror Deploy.s.sol's output so we test the REAL extension path (preserve existing keys).
        if (!vm.exists("deployments")) vm.createDir("deployments", true);
        string memory obj = "base";
        vm.serializeAddress(obj, "escrow", address(escrow));
        vm.serializeAddress(obj, "usdc", address(usdc));
        vm.serializeUint(obj, "chainId", block.chainid);
        string memory json = vm.serializeUint(obj, "deployBlock", 12345);
        vm.writeJson(json, path);
    }

    function _clear() internal {
        if (vm.exists(path)) vm.removeFile(path);
    }

    // =============================================================================================
    // gates default OFF
    // =============================================================================================

    function test_gates_default_off_deploys_nothing() public {
        _useChain(70001);
        _writeBaseDeployment();

        (address sv, address yv) = script.deploy(_cfg(false, false, 8 days));
        assertEq(sv, address(0), "staking gate off => no ObulusStakingVault");
        assertEq(yv, address(0), "yield gate off => no ObulusYieldVault");

        // Existing keys untouched; no vault keys added.
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".escrow"), address(escrow), "escrow preserved");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "usdc preserved");
        assertFalse(vm.keyExistsJson(json, ".stakingVault"), "no stakingVault key when gate off");
        assertFalse(vm.keyExistsJson(json, ".yieldVault"), "no yieldVault key when gate off");
        _clear();
    }

    // =============================================================================================
    // ObulusYieldVault: deployed source-less (safe 1:1), JSON extended additively
    // =============================================================================================

    function test_deploy_yield_only_is_sourceless_and_extends_json() public {
        _useChain(70002);
        _writeBaseDeployment();

        (address sv, address yv) = script.deploy(_cfg(false, true, 8 days));
        assertEq(sv, address(0), "staking gate off");
        assertTrue(yv != address(0), "ObulusYieldVault deployed");

        ObulusYieldVault deployed = ObulusYieldVault(yv);
        assertEq(address(deployed.asset()), address(usdc), "yield vault settles in escrow's USDC");
        assertEq(address(deployed.yieldSource()), address(0), "NO yield source - safe 1:1 pass-through");
        assertEq(deployed.treasury(), treasury, "treasury wired");

        // JSON extended: yieldVault added, existing keys preserved.
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".yieldVault"), yv, "yieldVault serialized");
        assertEq(vm.parseJsonAddress(json, ".escrow"), address(escrow), "escrow preserved");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "usdc preserved");
        assertEq(vm.parseJsonUint(json, ".deployBlock"), 12345, "deployBlock preserved");
        assertFalse(vm.keyExistsJson(json, ".stakingVault"), "no stakingVault key (gate off)");
        _clear();
    }

    // =============================================================================================
    // ObulusStakingVault: fail-fast on a delay <= resolveTimeout
    // =============================================================================================

    function test_deploy_staking_reverts_fast_when_delay_not_above_resolveTimeout() public {
        _useChain(70003);
        _writeBaseDeployment();
        // delay == resolveTimeout (NOT strictly greater) → fail-fast assert in the script.
        vm.expectRevert(bytes("DeployVaults: STAKING_WITHDRAWAL_DELAY must be > escrow.resolveTimeout()"));
        script.deploy(_cfg(true, false, RESOLVE_TIMEOUT));
        _clear();
    }

    function test_deploy_staking_succeeds_with_valid_delay_and_extends_json() public {
        _useChain(70004);
        _writeBaseDeployment();

        DeployVaults.VaultConfig memory cfg = _cfg(true, false, RESOLVE_TIMEOUT + 1 days);
        cfg.stakingSlashCapBps = 1_500;
        (address sv, address yv) = script.deploy(cfg);
        assertTrue(sv != address(0), "ObulusStakingVault deployed");
        assertEq(yv, address(0), "yield gate off");

        ObulusStakingVault deployed = ObulusStakingVault(sv);
        assertEq(address(deployed.usdc()), address(usdc), "staking vault uses escrow's USDC");
        assertEq(address(deployed.escrow()), address(escrow), "wired to the escrow");
        assertEq(deployed.treasury(), treasury, "treasury wired");
        assertEq(deployed.withdrawalDelay(), RESOLVE_TIMEOUT + 1 days, "withdrawalDelay set");
        assertEq(deployed.slashCapBps(), 1_500, "slashCapBps set");
        assertGt(deployed.withdrawalDelay(), escrow.resolveTimeout(), "delay strictly > resolveTimeout");

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".stakingVault"), sv, "stakingVault serialized");
        assertEq(vm.parseJsonAddress(json, ".escrow"), address(escrow), "escrow preserved");
        _clear();
    }

    // =============================================================================================
    // both gates on: both deployed, both keys added, existing keys intact
    // =============================================================================================

    function test_deploy_both_extends_json_with_both_and_preserves_existing() public {
        _useChain(70005);
        _writeBaseDeployment();

        (address sv, address yv) = script.deploy(_cfg(true, true, RESOLVE_TIMEOUT + 2 days));
        assertTrue(sv != address(0) && yv != address(0), "both deployed");

        string memory json = vm.readFile(path);
        // New keys.
        assertEq(vm.parseJsonAddress(json, ".stakingVault"), sv, "stakingVault key");
        assertEq(vm.parseJsonAddress(json, ".yieldVault"), yv, "yieldVault key");
        // Existing keys all preserved.
        assertEq(vm.parseJsonAddress(json, ".escrow"), address(escrow), "escrow preserved");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "usdc preserved");
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "chainId preserved");
        assertEq(vm.parseJsonUint(json, ".deployBlock"), 12345, "deployBlock preserved");
        _clear();
    }

    // =============================================================================================
    // create-from-scratch path: no pre-existing JSON (escrow passed explicitly via cfg)
    // =============================================================================================

    function test_creates_json_when_absent() public {
        _useChain(70006);
        _clear(); // ensure no pre-existing file → the script must CREATE it from scratch

        (, address yv) = script.deploy(_cfg(false, true, 8 days));
        assertTrue(yv != address(0), "yield deployed");

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonAddress(json, ".escrow"), address(escrow), "escrow written");
        assertEq(vm.parseJsonAddress(json, ".usdc"), address(usdc), "usdc written from escrow.usdc()");
        assertEq(vm.parseJsonAddress(json, ".yieldVault"), yv, "yieldVault written");
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid, "chainId written");
        _clear();
    }
}
