// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @dev Mock Chainlink Aggregator for testing
 */
contract MockChainlinkOracle {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    bool private _shouldFail;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_shouldFail, "Mock: Oracle failure");
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function setLatestAnswer(int256 answer) external {
        _answer = answer;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function setShouldFail(bool shouldFail) external {
        _shouldFail = shouldFail;
    }
}
