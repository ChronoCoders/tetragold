// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title OracleAggregator
 * @dev Multi-oracle price aggregator for gold (XAU/USD) with TWAP and circuit breaker
 *
 * Features:
 * - Aggregates prices from Chainlink, Band Protocol, and API3
 * - Time-Weighted Average Price (TWAP) with 10-minute window
 * - Price deviation detection (>2% triggers median calculation)
 * - Circuit breaker (>5% price movement pauses system)
 * - Price staleness validation (max 2-hour age)
 * - Emergency pause functionality
 * - 8 decimal precision for USD prices
 */
contract OracleAggregator is AccessControl, Pausable {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Oracle interfaces
    IAggregatorV3 public chainlinkOracle;
    IBandOracle public bandOracle;
    IAPI3Oracle public api3Oracle;

    // TWAP configuration
    uint256 public constant TWAP_WINDOW = 600; // 10 minutes
    uint256 public constant MAX_PRICE_AGE = 7200; // 2 hours
    uint256 public constant DECIMALS = 8; // Price precision (8 decimals)

    // Thresholds (in basis points: 1% = 100 bp)
    uint256 public priceDeviationThreshold = 200; // 2%
    uint256 public circuitBreakerThreshold = 500; // 5%

    // TWAP state
    struct PricePoint {
        uint256 price;
        uint256 timestamp;
    }

    PricePoint[] public priceHistory;
    uint256 public lastPrice;
    uint256 public lastUpdateTime;

    // Events
    event PriceUpdated(uint256 price, uint256 timestamp);
    event CircuitBreakerTriggered(uint256 oldPrice, uint256 newPrice, uint256 deviation);
    event OracleFailed(string oracleName, string reason);
    event ThresholdUpdated(string thresholdType, uint256 oldValue, uint256 newValue);
    event OracleAddressUpdated(string oracleName, address newAddress);

    /**
     * @dev Constructor
     * @param _admin Address to receive ADMIN_ROLE
     * @param _chainlinkOracle Chainlink XAU/USD feed address
     * @param _bandOracle Band Protocol gold price feed address
     * @param _api3Oracle API3 gold price feed address
     */
    constructor(
        address _admin,
        address _chainlinkOracle,
        address _bandOracle,
        address _api3Oracle
    ) {
        require(_admin != address(0), "OracleAggregator: admin cannot be zero");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        chainlinkOracle = IAggregatorV3(_chainlinkOracle);
        bandOracle = IBandOracle(_bandOracle);
        api3Oracle = IAPI3Oracle(_api3Oracle);
    }

    /**
     * @dev Get current aggregated gold price in USD (8 decimals)
     * @return price Current gold price
     * @return timestamp Time of price aggregation
     */
    function getGoldPrice() external view whenNotPaused returns (uint256 price, uint256 timestamp) {
        require(lastPrice > 0, "OracleAggregator: no price data available");
        return (lastPrice, lastUpdateTime);
    }

    /**
     * @dev Update TWAP and aggregate price from multiple oracles
     * @notice Must have at least 2 working oracles to succeed
     */
    function updateTwap() external whenNotPaused {
        // Fetch prices from all oracles
        (uint256[] memory prices, bool[] memory validity) = _fetchOraclePrices();

        // Count valid oracles
        uint256 validCount = 0;
        for (uint256 i = 0; i < validity.length; i++) {
            if (validity[i]) validCount++;
        }

        require(validCount >= 2, "OracleAggregator: insufficient valid oracles");

        // Calculate aggregated price
        uint256 aggregatedPrice = _aggregatePrices(prices, validity);

        // Check circuit breaker before updating
        if (lastPrice > 0) {
            _checkCircuitBreaker(aggregatedPrice);
        }

        // Update price history for TWAP
        _updatePriceHistory(aggregatedPrice);

        // Calculate TWAP
        uint256 twapPrice = _calculateTwap();

        // Update state
        lastPrice = twapPrice;
        lastUpdateTime = block.timestamp;

        emit PriceUpdated(twapPrice, block.timestamp);
    }

    /**
     * @dev Fetch prices from all oracle sources
     * @return prices Array of prices from each oracle
     * @return validity Array indicating which prices are valid
     */
    function _fetchOraclePrices() internal returns (uint256[] memory prices, bool[] memory validity) {
        prices = new uint256[](3);
        validity = new bool[](3);

        // Chainlink
        try chainlinkOracle.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (price > 0 && block.timestamp - updatedAt <= MAX_PRICE_AGE) {
                prices[0] = _normalizePrice(SafeCast.toUint256(price), chainlinkOracle.decimals());
                validity[0] = true;
            } else {
                emit OracleFailed("Chainlink", "Stale or invalid price");
            }
        } catch Error(string memory reason) {
            emit OracleFailed("Chainlink", reason);
        } catch {
            emit OracleFailed("Chainlink", "Unknown error");
        }

        // Band Protocol
        try bandOracle.getReferenceData("XAU", "USD") returns (uint256 rate, uint256 lastUpdatedBase, uint256 lastUpdatedQuote) {
            uint256 lastUpdated = lastUpdatedBase < lastUpdatedQuote ? lastUpdatedBase : lastUpdatedQuote;
            if (rate > 0 && block.timestamp - lastUpdated <= MAX_PRICE_AGE) {
                prices[1] = _normalizePrice(rate, 18); // Band uses 18 decimals
                validity[1] = true;
            } else {
                emit OracleFailed("Band", "Stale or invalid price");
            }
        } catch Error(string memory reason) {
            emit OracleFailed("Band", reason);
        } catch {
            emit OracleFailed("Band", "Unknown error");
        }

        // API3
        try api3Oracle.read() returns (int224 value, uint32 timestamp) {
            if (value > 0 && block.timestamp - timestamp <= MAX_PRICE_AGE) {
                // Safe cast: value > 0 checked above, int224 fits in int256, then safely convert to uint256
                int256 valueInt256 = int256(value);
                prices[2] = _normalizePrice(SafeCast.toUint256(valueInt256), 18); // API3 uses 18 decimals
                validity[2] = true;
            } else {
                emit OracleFailed("API3", "Stale or invalid price");
            }
        } catch Error(string memory reason) {
            emit OracleFailed("API3", reason);
        } catch {
            emit OracleFailed("API3", "Unknown error");
        }

        return (prices, validity);
    }

    /**
     * @dev Aggregate prices from valid oracles
     * @param prices Array of prices
     * @param validity Array indicating valid prices
     * @return aggregatedPrice Final aggregated price
     */
    function _aggregatePrices(uint256[] memory prices, bool[] memory validity) internal view returns (uint256) {
        // Collect valid prices
        uint256[] memory validPrices = new uint256[](3);
        uint256 validCount = 0;

        for (uint256 i = 0; i < prices.length; i++) {
            if (validity[i]) {
                validPrices[validCount] = prices[i];
                validCount++;
            }
        }

        // Calculate average
        uint256 sum = 0;
        uint256 min = type(uint256).max;
        uint256 max = 0;

        for (uint256 i = 0; i < validCount; i++) {
            sum += validPrices[i];
            if (validPrices[i] < min) min = validPrices[i];
            if (validPrices[i] > max) max = validPrices[i];
        }

        uint256 average = sum / validCount;

        // Check for price deviation
        uint256 deviation = max > min ? ((max - min) * 10000) / average : 0;

        if (deviation > priceDeviationThreshold) {
            // Use median if deviation exceeds threshold
            return _calculateMedian(validPrices, validCount);
        }

        return average;
    }

    /**
     * @dev Calculate median of valid prices
     * @param prices Array of prices
     * @param length Number of valid prices
     * @return median Median price
     */
    function _calculateMedian(uint256[] memory prices, uint256 length) internal pure returns (uint256) {
        // Sort prices (bubble sort for small arrays)
        for (uint256 i = 0; i < length - 1; i++) {
            for (uint256 j = 0; j < length - i - 1; j++) {
                if (prices[j] > prices[j + 1]) {
                    (prices[j], prices[j + 1]) = (prices[j + 1], prices[j]);
                }
            }
        }

        // Return median
        if (length % 2 == 0) {
            return (prices[length / 2 - 1] + prices[length / 2]) / 2;
        } else {
            return prices[length / 2];
        }
    }

    /**
     * @dev Update price history for TWAP calculation
     * @param price New price to add
     */
    function _updatePriceHistory(uint256 price) internal {
        priceHistory.push(PricePoint({
            price: price,
            timestamp: block.timestamp
        }));

        // Remove old entries outside TWAP window
        if (block.timestamp > TWAP_WINDOW) {
            uint256 cutoffTime = block.timestamp - TWAP_WINDOW;
            while (priceHistory.length > 0 && priceHistory[0].timestamp < cutoffTime) {
                // Shift array left
                for (uint256 i = 0; i < priceHistory.length - 1; i++) {
                    priceHistory[i] = priceHistory[i + 1];
                }
                priceHistory.pop();
            }
        }
    }

    /**
     * @dev Calculate Time-Weighted Average Price
     * @return twap Time-weighted average price
     */
    function _calculateTwap() internal view returns (uint256) {
        if (priceHistory.length == 0) return 0;
        if (priceHistory.length == 1) return priceHistory[0].price;

        uint256 weightedSum = 0;
        uint256 totalTime = 0;

        for (uint256 i = 0; i < priceHistory.length - 1; i++) {
            uint256 timeDelta = priceHistory[i + 1].timestamp - priceHistory[i].timestamp;
            weightedSum += priceHistory[i].price * timeDelta;
            totalTime += timeDelta;
        }

        // Add the last price point weighted by time until now
        uint256 lastTimeDelta = block.timestamp - priceHistory[priceHistory.length - 1].timestamp;
        weightedSum += priceHistory[priceHistory.length - 1].price * lastTimeDelta;
        totalTime += lastTimeDelta;

        return totalTime > 0 ? weightedSum / totalTime : priceHistory[priceHistory.length - 1].price;
    }

    /**
     * @dev Check if price movement exceeds circuit breaker threshold
     * @param newPrice New price to check
     */
    function _checkCircuitBreaker(uint256 newPrice) internal {
        uint256 priceDiff = newPrice > lastPrice ? newPrice - lastPrice : lastPrice - newPrice;
        uint256 deviationBps = (priceDiff * 10000) / lastPrice;

        if (deviationBps > circuitBreakerThreshold) {
            _pause();
            emit CircuitBreakerTriggered(lastPrice, newPrice, deviationBps);
        }
    }

    /**
     * @dev Normalize price to 8 decimals
     * @param price Price to normalize
     * @param decimals Current decimals of the price
     * @return Normalized price with 8 decimals
     */
    function _normalizePrice(uint256 price, uint8 decimals) internal pure returns (uint256) {
        if (decimals == DECIMALS) {
            return price;
        } else if (decimals > DECIMALS) {
            return price / (10 ** (decimals - DECIMALS));
        } else {
            return price * (10 ** (DECIMALS - decimals));
        }
    }

    /**
     * @dev Set price deviation threshold
     * @param newThreshold New threshold in basis points (1% = 100 bp)
     */
    function setPriceDeviation(uint256 newThreshold) external onlyRole(ADMIN_ROLE) {
        require(newThreshold <= 1000, "OracleAggregator: threshold too high"); // Max 10%
        uint256 oldThreshold = priceDeviationThreshold;
        priceDeviationThreshold = newThreshold;
        emit ThresholdUpdated("PriceDeviation", oldThreshold, newThreshold);
    }

    /**
     * @dev Set circuit breaker threshold
     * @param newThreshold New threshold in basis points (1% = 100 bp)
     */
    function setCircuitBreakerThreshold(uint256 newThreshold) external onlyRole(ADMIN_ROLE) {
        require(newThreshold <= 2000, "OracleAggregator: threshold too high"); // Max 20%
        uint256 oldThreshold = circuitBreakerThreshold;
        circuitBreakerThreshold = newThreshold;
        emit ThresholdUpdated("CircuitBreaker", oldThreshold, newThreshold);
    }

    /**
     * @dev Update oracle addresses
     * @param oracleType Type of oracle (0=Chainlink, 1=Band, 2=API3)
     * @param newAddress New oracle address
     */
    function updateOracleAddress(uint8 oracleType, address newAddress) external onlyRole(ADMIN_ROLE) {
        require(newAddress != address(0), "OracleAggregator: invalid address");

        if (oracleType == 0) {
            chainlinkOracle = IAggregatorV3(newAddress);
            emit OracleAddressUpdated("Chainlink", newAddress);
        } else if (oracleType == 1) {
            bandOracle = IBandOracle(newAddress);
            emit OracleAddressUpdated("Band", newAddress);
        } else if (oracleType == 2) {
            api3Oracle = IAPI3Oracle(newAddress);
            emit OracleAddressUpdated("API3", newAddress);
        } else {
            revert("OracleAggregator: invalid oracle type");
        }
    }

    /**
     * @dev Pause the contract (ADMIN only)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract (ADMIN only)
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Get price history length
     */
    function getPriceHistoryLength() external view returns (uint256) {
        return priceHistory.length;
    }

    /**
     * @dev Get price history entry
     * @param index Index in price history
     */
    function getPriceHistory(uint256 index) external view returns (uint256 price, uint256 timestamp) {
        require(index < priceHistory.length, "OracleAggregator: index out of bounds");
        PricePoint memory point = priceHistory[index];
        return (point.price, point.timestamp);
    }
}

/**
 * @dev Chainlink Aggregator V3 Interface
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

/**
 * @dev Band Protocol Oracle Interface
 */
interface IBandOracle {
    function getReferenceData(string memory base, string memory quote) external view returns (
        uint256 rate,
        uint256 lastUpdatedBase,
        uint256 lastUpdatedQuote
    );
}

/**
 * @dev API3 Oracle Interface
 */
interface IAPI3Oracle {
    function read() external view returns (int224 value, uint32 timestamp);
}
