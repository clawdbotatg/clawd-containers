// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Hooks {
    function isValid(address h) internal pure returns (bool) {
        return h != address(0);
    }
}

contract Lock {
    uint256 public unlockTime;
    function withdraw() external {
        require(block.timestamp >= unlockTime);
    }
}

contract Launcher is Lock {
    function launch() external {}
}
