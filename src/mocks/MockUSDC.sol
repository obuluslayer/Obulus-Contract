// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only 6-decimal ERC20 standing in for native USDC. Freely mintable.
/// @custom:landing        https://obuluslayer.xyz/
/// @custom:dapp           https://app.obuluslayer.xyz/
/// @custom:documentation  https://gitbook.obuluslayer.xyz/
/// @custom:github         https://github.com/obuluslayer
/// @custom:x              https://x.com/obuluslayer
/// @custom:telegram       https://t.me/obuluslayer
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
