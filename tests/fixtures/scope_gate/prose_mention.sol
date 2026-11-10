// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Vault core. Relies on the OpenZeppelin defence against the
///         first-depositor / donation attack; see solady for the math idea.
contract VaultCore {
    uint256 public a;
    uint256 public b;
}

/// @title Helper built with OpenZeppelin in mind.
contract VaultHelper {
    uint256 public c;
}
