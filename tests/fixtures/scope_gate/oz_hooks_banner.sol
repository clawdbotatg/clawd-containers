// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// OpenZeppelin Uniswap Hooks (last updated v1.2.0) (src/base/BaseHook.sol)
abstract contract BaseHook {
    function noop() internal pure returns (bool) { return true; }
}

/// @title FeeHook — venue fee (OpenZeppelin BaseHook)
contract FeeHook is BaseHook {
    uint256 public v;
}
