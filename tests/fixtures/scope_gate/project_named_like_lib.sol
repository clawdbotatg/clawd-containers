// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library SafeCast {
    function x() internal pure returns (uint256) { return 1; }
}

contract Math {
    uint256 public total;

    function add(uint256 a) external {
        total += a;
    }
}
