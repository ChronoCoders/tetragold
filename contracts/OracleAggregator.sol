// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IOracleAggregator.sol";
import "./interfaces/IChainlinkOracle.sol";
import "./interfaces/IBandOracle.sol";

/**
 * @title OracleAggregator
 * @dev Multi-source oracle aggregator for gold price feeds
 */
contract OracleAggregator is IOracleAggregator, AccessControl, ReentrancyGuard {
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");

    // Configuration
    uint256 public constant MAX_ORACLES = 10;
    uint256 public constant MIN_ORACLES = 2;
    uint256 public constant TOTAL_WEIGHT = 10000; // 100% in basis points
    uint256 public constant MAX_DEVIATION = 500; // 5% max deviation
    uint256 public constant MIN_CONFIDENCE = 8000; // 80% minimum confidence

    // State variables
    mapping(address => OracleConfig) public oracles;
    address[] public oracleList;
    uint256 public deviationThreshold;
    uint256 public lastAggregatedPrice;
    uint256 public lastUpdateTimestamp;
    uint256 public aggregatedConfidence;

    // Events
    event PriceAggregated(
        uint256 indexed price,
        uint256 timestamp,
        uint256 confidence,
        uint256 oracleCount
    );

    // Errors
    error TooManyOracles();
    error InsufficientOracles();
    error InvalidWeight();
    error OracleNotFound();
    error InvalidDeviation();
    error StalePrice();
    error LowConfidence();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_MANAGER_ROLE, msg.sender);
        _grantRole(PRICE_UPDATER_ROLE, msg.sender);
        
        deviationThreshold = 300; // 3% default deviation threshold
    }

    /**
     * @dev Add a new oracle to the aggregation
     */
    function addOracle(
        address oracle,
        uint256 weight,
        uint256 maxStaleness
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (oracleList.length >= MAX_ORACLES) revert TooManyOracles();
        if (weight == 0 || weight > TOTAL_WEIGHT) revert InvalidWeight();
        if (oracles[oracle].oracle != address(0)) revert("Oracle already exists");

        // Validate total weight doesn't exceed 100%
        uint256 totalWeight = _calculateTotalWeight() + weight;
        if (totalWeight > TOTAL_WEIGHT) revert InvalidWeight();

        oracles[oracle] = OracleConfig({
            oracle: oracle,
            weight: weight,
            maxStaleness: maxStaleness,
            isActive: true
        });

        oracleList.push(oracle);
        emit OracleAdded(oracle, weight);
    }

    /**
     * @dev Remove an oracle from aggregation
     */
    function removeOracle(address oracle) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (oracles[oracle].oracle == address(0)) revert OracleNotFound();
        if (oracleList.length <= MIN_ORACLES) revert InsufficientOracles();

        // Remove from array
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracleList[i] == oracle) {
                oracleList[i] = oracleList[oracleList.length - 1];
                oracleList.pop();
                break;
            }
        }

        delete oracles[oracle];
        emit OracleRemoved(oracle);
    }

    /**
     * @dev Update oracle weight
     */
    function updateOracleWeight(
        address oracle,
        uint256 newWeight
    ) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (oracles[oracle].oracle == address(0)) revert OracleNotFound();
        if (newWeight == 0 || newWeight > TOTAL_WEIGHT) revert InvalidWeight();

        uint256 oldWeight = oracles[oracle].weight;
        uint256 totalWeight = _calculateTotalWeight() - oldWeight + newWeight;
        if (totalWeight > TOTAL_WEIGHT) revert InvalidWeight();

        oracles[oracle].weight = newWeight;
        emit OracleWeightUpdated(oracle, newWeight);
    }

    /**
     * @dev Get the latest aggregated price
     */
    function getLatestPrice() external view override returns (uint256 price, uint256 timestamp) {
        return (lastAggregatedPrice, lastUpdateTimestamp);
    }

    /**
     * @dev Update aggregated price from all oracles
     */
    function updateAggregatedPrice() external onlyRole(PRICE_UPDATER_ROLE) nonReentrant {
        PriceData[] memory prices = _getAllValidPrices();
        
        if (prices.length < MIN_ORACLES) revert InsufficientOracles();

        (uint256 aggregatedPrice, uint256 confidence) = _calculateWeightedAverage(prices);
        
        if (confidence < MIN_CONFIDENCE) revert LowConfidence();

        // Check for extreme deviation
        if (lastAggregatedPrice > 0) {
            (bool exceeded,) = checkDeviation(aggregatedPrice);
            if (exceeded) revert InvalidDeviation();
        }

        lastAggregatedPrice = aggregatedPrice;
        lastUpdateTimestamp = block.timestamp;
        aggregatedConfidence = confidence;

        emit PriceAggregated(aggregatedPrice, block.timestamp, confidence, prices.length);
    }

    /**
     * @dev Get price data from all active oracles
     */
    function getAllPrices() external view override returns (PriceData[] memory priceData) {
        return _getAllValidPrices();
    }

    /**
     * @dev Check if price deviation exceeds threshold
     */
    function checkDeviation(uint256 newPrice) public view override returns (bool exceeded, uint256 deviation) {
        if (lastAggregatedPrice == 0) return (false, 0);

        uint256 priceDiff = newPrice > lastAggregatedPrice 
            ? newPrice - lastAggregatedPrice 
            : lastAggregatedPrice - newPrice;
        
        deviation = (priceDiff * 10000) / lastAggregatedPrice;
        exceeded = deviation > deviationThreshold;
    }

    /**
     * @dev Get oracle configuration
     */
    function getOracleConfig(address oracle) external view override returns (OracleConfig memory config) {
        return oracles[oracle];
    }

    /**
     * @dev Get number of active oracles
     */
    function getActiveOracleCount() external view override returns (uint256 count) {
        return oracleList.length;
    }

    /**
     * @dev Update deviation threshold
     */
    function updateDeviationThreshold(uint256 newThreshold) external onlyRole(ORACLE_MANAGER_ROLE) {
        if (newThreshold > MAX_DEVIATION) revert InvalidDeviation();
        deviationThreshold = newThreshold;
        emit DeviationThresholdUpdated(newThreshold);
    }

    /**
     * @dev Get all valid prices from active oracles
     */
    function _getAllValidPrices() internal view returns (PriceData[] memory) {
        PriceData[] memory validPrices = new PriceData[](oracleList.length);
        uint256 validCount = 0;

        for (uint256 i = 0; i < oracleList.length; i++) {
            address oracleAddr = oracleList[i];
            OracleConfig memory config = oracles[oracleAddr];
            
            if (!config.isActive) continue;

            try this._getPriceFromOracle(oracleAddr, config.maxStaleness) returns (
                uint256 price,
                uint256 timestamp,
                uint256 confidence
            ) {
                validPrices[validCount] = PriceData({
                    price: price,
                    timestamp: timestamp,
                    confidence: confidence,
                    source: oracleAddr
                });
                validCount++;
            } catch {
                // Oracle failed, skip it
                continue;
            }
        }

        // Resize array to actual valid count
        PriceData[] memory result = new PriceData[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            result[i] = validPrices[i];
        }

        return result;
    }

    /**
     * @dev Get price from a specific oracle (external for try/catch)
     */
    function _getPriceFromOracle(
        address oracleAddr,
        uint256 maxStaleness
    ) external view returns (uint256 price, uint256 timestamp, uint256 confidence) {
        // This would integrate with actual oracle contracts
        // For now, return mock data
        return (3350 * 1e18, block.timestamp, 9500); // $3350 with 95% confidence
    }

    /**
     * @dev Calculate weighted average of prices
     */
    function _calculateWeightedAverage(
        PriceData[] memory prices
    ) internal view returns (uint256 weightedPrice, uint256 totalConfidence) {
        uint256 totalWeightedPrice = 0;
        uint256 totalWeight = 0;
        uint256 confidenceSum = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            address oracleAddr = prices[i].source;
            uint256 weight = oracles[oracleAddr].weight;
            
            totalWeightedPrice += prices[i].price * weight;
            totalWeight += weight;
            confidenceSum += prices[i].confidence;
        }

        weightedPrice = totalWeightedPrice / totalWeight;
        totalConfidence = confidenceSum / prices.length;
    }

    /**
     * @dev Calculate total weight of all active oracles
     */
    function _calculateTotalWeight() internal view returns (uint256 total) {
        for (uint256 i = 0; i < oracleList.length; i++) {
            if (oracles[oracleList[i]].isActive) {
                total += oracles[oracleList[i]].weight;
            }
        }
    }
}