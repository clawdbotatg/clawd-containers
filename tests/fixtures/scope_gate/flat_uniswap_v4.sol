// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library SafeCast_0 {
    function toUint128(uint256 v) internal pure returns (uint128) {
        return uint128(v);
    }
}

library StateLibrary {
    function getSlot0(bytes32 id) internal pure returns (uint160) {
        return uint160(uint256(id));
    }
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
}

interface IEIP712_v4 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface ILauncher {
    function launch() external;
}

contract Launcher is ILauncher {
    function launch() external {
        require(msg.sender != address(0));
    }
}
