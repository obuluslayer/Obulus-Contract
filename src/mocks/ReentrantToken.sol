// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A malicious 6-decimal ERC20 that attempts to re-enter a target contract on every transfer.
///         Used to prove the escrow's `nonReentrant` guard + checks-effects-interactions hold.
/// @custom:landing        https://obuluslayer.xyz/
/// @custom:dapp           https://app.obuluslayer.xyz/
/// @custom:documentation  https://gitbook.obuluslayer.xyz/
/// @custom:github         https://github.com/obuluslayer
/// @custom:x              https://x.com/obuluslayer
/// @custom:telegram       https://t.me/obuluslayer
contract ReentrantToken is ERC20 {
    address public target;
    bytes public attackCalldata;
    bool public attacking;

    constructor() ERC20("Reentrant", "RE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @param target_ Contract to call back into (the escrow).
    /// @param attackCalldata_ Encoded call to attempt during a transfer (e.g. withdraw()/confirm(id)).
    function setAttack(address target_, bytes calldata attackCalldata_) external {
        target = target_;
        attackCalldata = attackCalldata_;
    }

    function _reenter() private {
        if (target != address(0) && !attacking && attackCalldata.length != 0) {
            attacking = true;
            // Swallow the revert so the assertion surfaces as "no double payout" rather than a bubbled error.
            (bool ok,) = target.call(attackCalldata);
            ok; // ignored on purpose
            attacking = false;
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _reenter();
        return super.transferFrom(from, to, amount);
    }
}
