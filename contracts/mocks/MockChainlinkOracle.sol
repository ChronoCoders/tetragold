// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockChainlinkOracle
 * @dev Mock implementation of Chainlink price feed for testing
 */
contract MockChainlinkOracle {
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    uint8 public decimals;
    string public description;
    uint256 public version = 1;

    RoundData private latestRound;
    mapping(uint80 => RoundData) private rounds;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    constructor(
        int256 _initialPrice,
        uint8 _decimals,
        string memory _description
    ) {
        decimals = _decimals;
        description = _description;
        
        latestRound = RoundData({
            roundId: 1,
            answer: _initialPrice,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: 1
        });
        
        rounds[1] = latestRound;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            latestRound.roundId,
            latestRound.answer,
            latestRound.startedAt,
            latestRound.updatedAt,
            latestRound.answeredInRound
        );
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        RoundData memory round = rounds[_roundId];
        return (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        );
    }

    // Test helper functions
    function updatePrice(int256 _newPrice) external {
        uint80 newRoundId = latestRound.roundId + 1;
        
        latestRound = RoundData({
            roundId: newRoundId,
            answer: _newPrice,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: newRoundId
        });
        
        rounds[newRoundId] = latestRound;
        
        emit AnswerUpdated(_newPrice, newRoundId, block.timestamp);
    }

    function simulatePriceMovement(int256 _basePrice, int256 _maxVariation) external {
        // Generate pseudo-random price movement
        int256 variation = int256(uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty))) % uint256(_maxVariation * 2)) - _maxVariation;
        int256 newPrice = _basePrice + variation;
        
        updatePrice(newPrice);
    }
}