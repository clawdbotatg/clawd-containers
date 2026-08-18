// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

abstract contract Context {
    function _msgSender() internal view returns (address) {
        return msg.sender;
    }
}

library SafeCast {
    function toUint128(uint256 v) internal pure returns (uint128) {
        require(v <= type(uint128).max);
        return uint128(v);
    }
}

interface IFeeSink {
    function recordFee(uint256 amount) external;
}

contract FixedFeeSink is Context, IFeeSink {
    address public treasury;

    function recordFee(uint256 amount) external {
        require(amount > 0);
    }
}
