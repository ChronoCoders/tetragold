// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @dev Mock Band Protocol Oracle for testing
 */
contract MockBandOracle {
    uint256 private _rate;
    uint256 private _lastUpdatedBase;
    uint256 private _lastUpdatedQuote;
    bool private _shouldFail;

    constructor() {
        _lastUpdatedBase = block.timestamp;
        _lastUpdatedQuote = block.timestamp;
    }

    function getReferenceData(string memory, string memory)
        external
        view
        returns (uint256 rate, uint256 lastUpdatedBase, uint256 lastUpdatedQuote)
    {
        require(!_shouldFail, "Mock: Oracle failure");
        return (_rate, _lastUpdatedBase, _lastUpdatedQuote);
    }

    function setReferenceData(uint256 rate) external {
        _rate = rate;
        _lastUpdatedBase = block.timestamp;
        _lastUpdatedQuote = block.timestamp;
    }

    function setLastUpdated(uint256 lastUpdatedBase, uint256 lastUpdatedQuote) external {
        _lastUpdatedBase = lastUpdatedBase;
        _lastUpdatedQuote = lastUpdatedQuote;
    }

    function setShouldFail(bool shouldFail) external {
        _shouldFail = shouldFail;
    }
}
