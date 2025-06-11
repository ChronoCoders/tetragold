// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOracleAggregator
 * @dev Interface for multi-source oracle price aggregation
 */
interface IOracleAggregator {
    struct PriceData {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
        address source;
    }

    struct OracleConfig {
        address oracle;
        uint256 weight;
        uint256 maxStaleness;
        bool isActive;
    }

    event PriceUpdated(uint256 indexed price, uint256 timestamp, uint256 confidence);
    event OracleAdded(address indexed oracle, uint256 weight);
    event OracleRemoved(address indexed oracle);
    event OracleWeightUpdated(address indexed oracle, uint256 newWeight);
    event DeviationThresholdUpdated(uint256 newThreshold);

    /**
     * @dev Get the latest aggregated price
     * @return price The aggregated price in USD (18 decimals)
     * @return timestamp The timestamp of the latest update
     */
    function getLatestPrice() external view returns (uint256 price, uint256 timestamp);

    /**
     * @dev Get price data from all active oracles
     * @return priceData Array of price data from all oracles
     */
    function getAllPrices() external view returns (PriceData[] memory priceData);

    /**
     * @dev Add a new oracle to the aggregation
     * @param oracle Address of the oracle contract
     * @param weight Weight of this oracle in aggregation (basis points)
     * @param maxStaleness Maximum age of price data in seconds
     */
    function addOracle(address oracle, uint256 weight, uint256 maxStaleness) external;

    /**
     * @dev Remove an oracle from aggregation
     * @param oracle Address of the oracle to remove
     */
    function removeOracle(address oracle) external;

    /**
     * @dev Update oracle weight
     * @param oracle Address of the oracle
     * @param newWeight New weight in basis points
     */
    function updateOracleWeight(address oracle, uint256 newWeight) external;

    /**
     * @dev Check if price deviation exceeds threshold
     * @param newPrice New price to check
     * @return exceeded True if deviation threshold is exceeded
     * @return deviation The actual deviation percentage
     */
    function checkDeviation(uint256 newPrice) external view returns (bool exceeded, uint256 deviation);

    /**
     * @dev Get oracle configuration
     * @param oracle Address of the oracle
     * @return config Oracle configuration struct
     */
    function getOracleConfig(address oracle) external view returns (OracleConfig memory config);

    /**
     * @dev Get number of active oracles
     * @return count Number of active oracles
     */
    function getActiveOracleCount() external view returns (uint256 count);
}