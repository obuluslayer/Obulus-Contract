// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ObulusYieldVault} from "../../src/ObulusYieldVault.sol";
import {IYieldSource} from "../../src/interfaces/IYieldSource.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice A LOSSY + ILLIQUID yield source the fuzzer can drive into adverse states. It books principal as
///         on-paper value (`booked`), but the fuzzer can (a) INFLICT a realized loss (drop booked value AND
///         physically remove that USDC) and (b) cap how much it will pay out per withdraw (illiquidity). This
///         is exactly the shape that triggered the over-burn bug: valuation can exceed payable liquidity.
contract LossyIlliquidSource is IYieldSource {
    MockUSDC internal immutable usdc;
    address internal immutable vault;
    uint256 public booked;
    uint256 public payableCap = type(uint256).max;

    constructor(address usdg_, address vault_) {
        usdc = MockUSDC(usdg_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(usdc);
    }

    function deposit(uint256 assets) external {
        require(msg.sender == vault, "only vault");
        booked += assets;
    }

    function withdraw(uint256 assets, address to) external returns (uint256 sent) {
        require(msg.sender == vault, "only vault");
        uint256 want = assets < payableCap ? assets : payableCap;
        uint256 bal = usdc.balanceOf(address(this));
        sent = want < bal ? want : bal;
        booked = sent < booked ? booked - sent : 0;
        if (sent != 0) usdc.transfer(to, sent);
    }

    function totalAssets() external view returns (uint256) {
        return booked;
    }

    function maxWithdraw() external view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 cap = payableCap < bal ? payableCap : bal;
        return cap < booked ? cap : booked;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function setPayable(uint256 cap) external {
        payableCap = cap;
    }

    /// @notice Realize a loss: drop booked value and physically remove the USDC. Returns the amount removed.
    function inflict(uint256 amount) external returns (uint256 removed) {
        removed = amount < booked ? amount : booked;
        booked -= removed;
        uint256 bal = usdc.balanceOf(address(this));
        uint256 move = removed < bal ? removed : bal;
        if (move != 0) usdc.transfer(address(0xdead), move);
        // Reflect the burned USDC in `removed` as exactly what physically left.
        removed = move;
    }
}

/// @notice Bounded action driver for the LOSSY-source solvency invariant. Drives deposits/redeems/withdraws
///         against a `LossyIlliquidSource` the fuzzer can also push into adverse states via `inflict` (realized
///         loss) and `setLossy` (illiquidity cap). The headline guarantee under test: NO over-burn ever breaks
///         solvency — across any interleaving of normal ops AND value losses / illiquidity, every depositor's
///         redeemable value stays covered by what the vault can actually recover (Σ redeemable <= totalAssets),
///         and physical USDC is conserved (nothing is created; the only sink is the `inflict` loss, tracked).
contract YieldVaultLossyHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ObulusYieldVault public immutable vault;
    LossyIlliquidSource public immutable source;
    MockUSDC public immutable usdc;
    address public immutable treasury;
    address public immutable owner;

    address[] public depositors;

    // --- ghost accounting ------------------------------------------------------------------------
    uint256 public ghostMinted; // every wei ever minted into the system
    uint256 public ghostWithdrawnNet; // USDC paid out to depositors (net of fee)
    uint256 public ghostFees; // USDC that left to the treasury
    uint256 public ghostLost; // USDC physically destroyed by inflicted losses (sent to 0xdead)

    constructor(ObulusYieldVault _vault, LossyIlliquidSource _source, MockUSDC _usdc, address _treasury, address _owner) {
        vault = _vault;
        source = _source;
        usdc = _usdc;
        treasury = _treasury;
        owner = _owner;

        for (uint256 i; i < 4; i++) {
            address d = address(uint160(uint256(keccak256(abi.encodePacked("yv-lossy-dep-", i)))));
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
        usdc.mint(d, amt);
        ghostMinted += amt;
        vm.prank(d);
        try vault.deposit(amt, d) returns (uint256) {} catch {}
    }

    function redeem(uint256 dSeed, uint256 shareFrac) public {
        address d = depositors[dSeed % depositors.length];
        uint256 bal = vault.balanceOf(d);
        if (bal == 0) return;
        uint256 shares = _bound(shareFrac, 1, bal);
        uint256 treBefore = usdc.balanceOf(treasury);
        vm.prank(d);
        try vault.redeem(shares, d, 0) returns (uint256 net) {
            ghostWithdrawnNet += net;
            ghostFees += (usdc.balanceOf(treasury) - treBefore);
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

    /// @dev Drive the source into a LOSSY state: realize a loss of up to ~half its current booked value.
    function inflict(uint256 amount) public {
        uint256 booked = source.booked();
        if (booked == 0) return;
        uint256 loss = _bound(amount, 0, booked / 2 + 1);
        uint256 removed = source.inflict(loss);
        ghostLost += removed;
    }

    /// @dev Drive the source into an ILLIQUID state: cap how much it can pay out per withdraw. Cycling the cap
    ///      between tight and unlimited exercises partial-delivery (over-burn-prone) and full-delivery paths.
    function setLossy(uint256 cap, bool unlimited) public {
        if (unlimited) {
            source.setPayable(type(uint256).max);
        } else {
            source.setPayable(_bound(cap, 0, 1_000e6));
        }
    }

    function setFee(uint256 bps) public {
        vm.prank(owner);
        try vault.setWithdrawFeeBps(uint16(_bound(bps, 0, vault.MAX_WITHDRAW_FEE_BPS()))) {} catch {}
    }

    // --- views -----------------------------------------------------------------------------------

    function depositorsLength() external view returns (uint256) {
        return depositors.length;
    }

    function depositorsList(uint256 i) external view returns (address) {
        return depositors[i];
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) (lo, hi) = (hi, lo);
        if (hi == lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
}
