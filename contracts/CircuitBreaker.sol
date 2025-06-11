// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICircuitBreaker.sol";

/**
 * @title CircuitBreaker
 * @dev Circuit breaker implementation to prevent extreme price movements
 */
contract CircuitBreaker is ICircuitBreaker, AccessControl {
    bytes32 public constant CIRCUIT_MANAGER_ROLE = keccak256("CIRCUIT_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Configuration
    CircuitBreakerConfig public config;
    
    // State variables
    uint256 public lastPrice;
    uint256 public lastPriceTimestamp;
    uint256 public triggerTimestamp;
    bool public isCurrentlyTriggered;
    
    // Price history for time window analysis
    struct PricePoint {
        uint256 price;
        uint256 timestamp;
    }
    
    PricePoint[] public priceHistory;
    uint256 public constant MAX_HISTORY_LENGTH = 100;

    constructor(
        uint256 _priceDeviationThreshold,
        uint256 _timeWindow,
        uint256 _cooldownPeriod
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CIRCUIT_MANAGER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        config = CircuitBreakerConfig({
            priceDeviationThreshold: _priceDeviationThreshold,
            timeWindow: _timeWindow,
            cooldownPeriod: _cooldownPeriod,
            isActive: true
        });
    }

    /**
     * @dev Check if circuit breaker is currently triggered
     */
    function isTriggered() external view override returns (bool triggered) {
        if (!isCurrentlyTriggered) return false;
        
        // Check if cooldown period has passed
        return block.timestamp < triggerTimestamp + config.cooldownPeriod;
    }

    /**
     * @dev Check price against circuit breaker rules
     */
    function checkPrice(uint256 newPrice) external override onlyRole(CIRCUIT_MANAGER_ROLE) returns (bool allowed, uint256 deviation) {
        if (!config.isActive) return (true, 0);
        
        // If currently triggered and cooldown not expired, reject
        if (this.isTriggered()) {
            return (false, 0);
        }

        // Reset trigger state if cooldown has passed
        if (isCurrentlyTriggered && block.timestamp >= triggerTimestamp + config.cooldownPeriod) {
            isCurrentlyTriggered = false;
            emit CircuitBreakerReset(block.timestamp);
        }

        // Calculate deviation from last price
        if (lastPrice > 0) {
            deviation = _calculateDeviation(lastPrice, newPrice);
            
            // Check if deviation exceeds threshold
            if (deviation > config.priceDeviationThreshold) {
                // Check time window for rapid price changes
                if (_isRapidPriceChange(newPrice)) {
                    isCurrentlyTriggered = true;
                    triggerTimestamp = block.timestamp;
                    
                    emit CircuitBreakerTriggered(lastPrice, newPrice, deviation, block.timestamp);
                    return (false, deviation);
                }
            }
        }

        // Update price history
        _updatePriceHistory(newPrice);
        lastPrice = newPrice;
        lastPriceTimestamp = block.timestamp;

        return (true, deviation);
    }

    /**
     * @dev Get current circuit breaker configuration
     */
    function getConfig() external view override returns (CircuitBreakerConfig memory) {
        return config;
    }

    /**
     * @dev Update circuit breaker configuration
     */
    function updateConfig(
        uint256 priceDeviationThreshold,
        uint256 timeWindow,
        uint256 cooldownPeriod
    ) external override onlyRole(CIRCUIT_MANAGER_ROLE) {
        require(priceDeviationThreshold <= 2000, "Threshold too high"); // Max 20%
        require(timeWindow >= 60, "Time window too short"); // Min 1 minute
        require(cooldownPeriod >= 300, "Cooldown too short"); // Min 5 minutes

        config.priceDeviationThreshold = priceDeviationThreshold;
        config.timeWindow = timeWindow;
        config.cooldownPeriod = cooldownPeriod;

        emit ConfigUpdated(priceDeviationThreshold, timeWindow, cooldownPeriod);
    }

    /**
     * @dev Manually reset circuit breaker (emergency function)
     */
    function emergencyReset() external override onlyRole(EMERGENCY_ROLE) {
        isCurrentlyTriggered = false;
        triggerTimestamp = 0;
        emit CircuitBreakerReset(block.timestamp);
    }

    /**
     * @dev Get time remaining until circuit breaker can be reset
     */
    function getTimeUntilReset() external view override returns (uint256 timeRemaining) {
        if (!isCurrentlyTriggered) return 0;
        
        uint256 resetTime = triggerTimestamp + config.cooldownPeriod;
        if (block.timestamp >= resetTime) return 0;
        
        return resetTime - block.timestamp;
    }

    /**
     * @dev Get last price and timestamp
     */
    function getLastPrice() external view override returns (uint256 price, uint256 timestamp) {
        return (lastPrice, lastPriceTimestamp);
    }

    /**
     * @dev Activate or deactivate circuit breaker
     */
    function setActive(bool active) external onlyRole(CIRCUIT_MANAGER_ROLE) {
        config.isActive = active;
    }

    /**
     * @dev Calculate price deviation percentage
     */
    function _calculateDeviation(uint256 oldPrice, uint256 newPrice) internal pure returns (uint256) {
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        return (priceDiff * 10000) / oldPrice; // Return in basis points
    }

    /**
     * @dev Check if price change is happening too rapidly
     */
    function _isRapidPriceChange(uint256 newPrice) internal view returns (bool) {
        if (priceHistory.length == 0) return false;

        uint256 windowStart = block.timestamp - config.timeWindow;
        uint256 oldestValidPrice = newPrice;

        // Find the oldest price within the time window
        for (uint256 i = priceHistory.length; i > 0; i--) {
            if (priceHistory[i - 1].timestamp >= windowStart) {
                oldestValidPrice = priceHistory[i - 1].price;
            } else {
                break;
            }
        }

        // Calculate deviation over the time window
        uint256 windowDeviation = _calculateDeviation(oldestValidPrice, newPrice);
        return windowDeviation > config.priceDeviationThreshold;
    }

    /**
     * @dev Update price history array
     */
    function _updatePriceHistory(uint256 newPrice) internal {
        priceHistory.push(PricePoint({
            price: newPrice,
            timestamp: block.timestamp
        }));

        // Keep history within bounds
        if (priceHistory.length > MAX_HISTORY_LENGTH) {
            // Remove oldest entries
            for (uint256 i = 0; i < priceHistory.length - MAX_HISTORY_LENGTH; i++) {
                priceHistory[i] = priceHistory[i + 1];
            }
            priceHistory.pop();
        }
    }

    /**
     * @dev Get price history length
     */
    function getPriceHistoryLength() external view returns (uint256) {
        return priceHistory.length;
    }

    /**
     * @dev Get price history entry
     */
    function getPriceHistoryEntry(uint256 index) external view returns (uint256 price, uint256 timestamp) {
        require(index < priceHistory.length, "Index out of bounds");
        PricePoint memory point = priceHistory[index];
        return (point.price, point.timestamp);
    }
}