// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Obscura.sol)
library Obscura {
    function noop() internal pure returns (bool) { return true; }
}

contract RealTarget {
    uint256 public v;
}
