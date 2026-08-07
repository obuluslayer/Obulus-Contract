// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ObulusYieldVault} from "../../src/ObulusYieldVault.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {MockYieldSource} from "../../src/mocks/MockYieldSource.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Bounded action driver for the ObulusYieldVault conservation/solvency invariants. Every external function
///         is a randomised, state-aware action the fuzzer may call; invalid actions self-skip or revert
///         harmlessly (fail_on_revert = false). It drives a REAL MockYieldSource (principal-protected, so it
///         never loses) so the invariants assert the headline guarantee on the principal-protected path: the
///         vault is always solvent (Σ redeemable <= totalAssets) and every wei is conserved between the vault,
///         the source, and the fee-treasury.
///
/// GHOST ACCOUNTING: we track exact USDC deposited (`ghostDeposited`), withdrawn to depositors
/// (`ghostWithdrawnNet`), and taken as fees (`ghostFees`). The invariant cross-checks that
/// depositors-in == depositors-out + fees + still-held, i.e. no wei is created or destroyed.
contract YieldVaultHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ObulusYieldVault public immutable vault;
    MockYieldSource public source; // may be swapped to/from address(0) by the toggle action
    MockUSDC public immutable usdc;
    address public immutable treasury;
    address public immutable owner;

    address[] public depositors;

    // --- ghost accounting ------------------------------------------------------------------------
    uint256 public ghostDeposited; // total USDC deposited by users
    uint256 public ghostWithdrawnNet; // total USDC paid out to users (net of fee)
    uint256 public ghostFees; // total fees that left to the treasury
    uint256 public ghostYieldFunded; // total external yield funded into the source (real USDC inflow)
    uint256 public ghostHarvests;
    /// @notice EVERY wei of USDC this handler ever minted into the system (deposits' funding + yield funding +
    ///         the initial depositor endowments). Physical conservation is asserted against this exact total.
    uint256 public ghostMinted;

    uint16 internal constant APR = 1_000; // 10% APR in the source

    constructor(ObulusYieldVault _vault, MockYieldSource _source, MockUSDC _usdc, address _treasury, address _owner) {
        vault = _vault;
        source = _source;
        usdc = _usdc;
        treasury = _treasury;
        owner = _owner;

        for (uint256 i; i < 4; i++) {
            address d = address(uint160(uint256(keccak256(abi.encodePacked("yv-dep-", i)))));
            depositors.push(d);
            usdc.mint(d, 1e18);
            ghostMinted += 1e18;
            vm.prank(d);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // --- actions ---------------------------------------------------------------------------------

    function deposit(uint256 dSeed, uint256 amount) public {
        address d = depositors[dSeed % depositors.length];
        uint256 amt = _bound(amount, 1e6, 100_000e6);
        // top up so the deposit always has funds
        usdc.mint(d, amt);
        ghostMinted += amt;
        vm.prank(d);
        try vault.deposit(amt, d) returns (uint256) {
            ghostDeposited += amt;
        } catch {}
    }

    function redeem(uint256 dSeed, uint256 shareFrac) public {
        address d = depositors[dSeed % depositors.length];
        uint256 bal = vault.balanceOf(d);
        if (bal == 0) return;
        uint256 shares = _bound(shareFrac, 1, bal);
        uint256 treBefore = usdc.balanceOf(treasury);
        uint256 dBefore = usdc.balanceOf(d);
        vm.prank(d);
        try vault.redeem(shares, d, 0) returns (uint256 net) {
            ghostWithdrawnNet += net;
            ghostFees += (usdc.balanceOf(treasury) - treBefore);
            // sanity: the depositor's balance grew by exactly `net`
            require(usdc.balanceOf(d) == dBefore + net, "net mismatch");
        } catch {}
    }

    function withdrawAssets(uint256 dSeed, uint256 amount) public {
        address d = depositors[dSeed % depositors.length];
        uint256 redeemable = vault.convertToAssets(vault.balanceOf(d));
        if (redeemable == 0) return;
        uint256 amt = _bound(amount, 1, redeemable);
        uint256 treBefore = usdc.balanceOf(treasury);
        vm.prank(d);
        try vault.withdraw(amt, d, 0) returns (uint256 net) {
            ghostWithdrawnNet += net;
            ghostFees += (usdc.balanceOf(treasury) - treBefore);
        } catch {}
    }

    function harvest() public {
        try vault.harvest() returns (uint256) {
            ghostHarvests += 1;
        } catch {}
    }

    /// @dev Fund the source with REAL USDC so its accrued yield is always backed (no fictitious value), then
    ///      warp so the principal-protected APR accrues. This is the only "yield inflow" and is tracked.
    function accrueYield(uint256 amount, uint256 dt) public {
        if (address(source) == address(0)) return;
        uint256 amt = _bound(amount, 0, 10_000e6);
        if (amt != 0) {
            usdc.mint(address(this), amt);
            ghostMinted += amt;
            usdc.approve(address(source), amt);
            source.fund(amt);
            ghostYieldFunded += amt;
        }
        vm.warp(block.timestamp + _bound(dt, 0, 30 days));
    }

    function setFee(uint256 bps) public {
        vm.prank(owner);
        try vault.setWithdrawFeeBps(uint16(_bound(bps, 0, vault.MAX_WITHDRAW_FEE_BPS()))) {} catch {}
    }

    /// @dev Toggle the source between the MockYieldSource and the null pass-through, exercising both the
    ///      1:1 path and the yielding path AND the drain-on-switch logic — all must preserve solvency.
    function toggleSource(uint256 sel) public {
        vm.prank(owner);
        if (sel % 2 == 0) {
            try vault.setYieldSource(IYieldSource(address(0))) {} catch {}
        } else {
            try vault.setYieldSource(source) {} catch {}
        }
    }

    // --- views -----------------------------------------------------------------------------------

    function depositorsLength() external view returns (uint256) {
        return depositors.length;
    }

    function depositorsList(uint256 i) external view returns (address) {
        return depositors[i];
    }

    function _sourceAssets() internal view returns (uint256) {
        IYieldSource s = vault.yieldSource();
        return address(s) == address(0) ? 0 : s.totalAssets();
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) (lo, hi) = (hi, lo);
        if (hi == lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
}
