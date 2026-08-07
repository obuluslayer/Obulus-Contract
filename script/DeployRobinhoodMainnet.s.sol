// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/// @notice Thin guard: deploy to Robinhood Chain mainnet (chain 4663). Use a hardware/multisig owner + treasury.
contract DeployRobinhoodMainnet is Deploy {
    function setUp() public view {
        require(block.chainid == 4663, "not Robinhood Chain mainnet");
    }
}
