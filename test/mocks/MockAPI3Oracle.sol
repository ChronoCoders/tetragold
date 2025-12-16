// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Mock API3 Oracle for testing
 */
contract MockAPI3Oracle {
    int224 private _value;
    uint32 private _timestamp;
    bool private _shouldFail;

    constructor() {
        _timestamp = uint32(block.timestamp);
    }

    function read() external view returns (int224 value, uint32 timestamp) {
        require(!_shouldFail, "Mock: Oracle failure");
        return (_value, _timestamp);
    }

    function setValue(int224 value) external {
        _value = value;
        _timestamp = uint32(block.timestamp);
    }

    function setTimestamp(uint32 timestamp) external {
        _timestamp = timestamp;
    }

    function setShouldFail(bool shouldFail) external {
        _shouldFail = shouldFail;
    }
}
