// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal ERC-1271 smart-account wallet: validates signatures against a single owner EOA.
///         Used to prove the escrow accepts agent smart-account signatures (not just EOAs) via
///         OpenZeppelin's SignatureChecker.
contract MockERC1271 is IERC1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e; // IERC1271.isValidSignature selector
    address public immutable owner;
    bool public alwaysReject;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAlwaysReject(bool v) external {
        alwaysReject = v;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (alwaysReject) return 0xffffffff;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == owner) return MAGIC;
        return 0xffffffff;
    }
}
