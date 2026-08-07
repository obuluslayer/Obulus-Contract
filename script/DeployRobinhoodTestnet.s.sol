// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Deploy} from "./Deploy.s.sol";

/// @notice Thin guard: deploy to Robinhood Chain testnet (chain 46630), refusing any other chain to avoid mistakes.
contract DeployRobinhoodTestnet is Deploy {
    function setUp() public view {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
    }
}
