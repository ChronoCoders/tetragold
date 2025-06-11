// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ICircuitBreaker
 * @dev Interface for circuit breaker functionality to prevent extreme price movements
 */
interface ICircuitBreaker {
    struct CircuitBreakerConfig {
        uint256 priceDeviationThreshold; // Maximum allowed price deviation (basis points)
        uint256 timeWindow; // Time window for price change calculation
        uint256 cooldownPeriod; // Cooldown period after trigger
        bool isActive;
    }

    event CircuitBreakerTriggered(
        uint256 indexed oldPrice,
        uint256 indexed newPrice,
        uint256 deviation,
        uint256 timestamp
    );
    
    event CircuitBreakerReset(uint256 timestamp);
    
    event ConfigUpdated(
        uint256 priceDeviationThreshold,
        uint256 timeWindow,
        uint256 cooldownPeriod
    );

    /**
     * @dev Check if circuit breaker is currently triggered
     * @return triggered True if circuit breaker is active
     */
    function isTriggered() external view returns (bool triggered);

    /**
     * @dev Check price against circuit breaker rules
     * @param newPrice New price to validate
     * @return allowed True if price change is within limits
     * @return deviation Actual price deviation percentage
     */
    function checkPrice(uint256 newPrice) external returns (bool allowed, uint256 deviation);

    /**
     * @dev Get current circuit breaker configuration
     * @return config Current configuration struct
     */
    function getConfig() external view returns (CircuitBreakerConfig memory config);

    /**
     * @dev Update circuit breaker configuration
     * @param priceDeviationThreshold New deviation threshold (basis points)
     * @param timeWindow New time window in seconds
     * @param cooldownPeriod New cooldown period in seconds
     */
    function updateConfig(
        uint256 priceDeviationThreshold,
        uint256 timeWindow,
        uint256 cooldownPeriod
    ) external;

    /**
     * @dev Manually reset circuit breaker (emergency function)
     */
    function emergencyReset() external;

    /**
     * @dev Get time remaining until circuit breaker can be reset
     * @return timeRemaining Seconds until reset is allowed
     */
    function getTimeUntilReset() external view returns (uint256 timeRemaining);

    /**
     * @dev Get last price and timestamp
     * @return price Last recorded price
     * @return timestamp Timestamp of last price update
     */
    function getLastPrice() external view returns (uint256 price, uint256 timestamp);
}