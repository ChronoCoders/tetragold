// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../interfaces/IOracleAggregator.sol";
import "./MockChainlinkOracle.sol";
import "./MockBandOracle.sol";

/**
 * @title PriceUpdaterBot
 * @dev Automated price updater for testnet mock oracles
 */
contract PriceUpdaterBot {
    IOracleAggregator public immutable oracleAggregator;
    MockChainlinkOracle public immutable chainlinkOracle;
    MockBandOracle public immutable bandOracle;
    
    uint256 public updateInterval;
    uint256 public lastUpdateTime;
    uint256 public basePrice;
    uint256 public maxVariation;
    
    bool public isActive;
    address public owner;
    
    event PriceUpdated(uint256 newPrice, uint256 timestamp);
    event BotConfigured(uint256 interval, uint256 basePrice, uint256 variation);
    event BotStatusChanged(bool active);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
    constructor(
        address _oracleAggregator,
        address _chainlinkOracle,
        address _bandOracle,
        uint256 _updateInterval
    ) {
        oracleAggregator = IOracleAggregator(_oracleAggregator);
        chainlinkOracle = MockChainlinkOracle(_chainlinkOracle);
        bandOracle = MockBandOracle(_bandOracle);
        
        updateInterval = _updateInterval;
        basePrice = 3350 * 1e18; // $3350 base price
        maxVariation = 50 * 1e18;  // ±$50 variation
        
        owner = msg.sender;
        isActive = true;
        lastUpdateTime = block.timestamp;
        
        emit BotConfigured(_updateInterval, basePrice, maxVariation);
    }
    
    /**
     * @dev Update prices if enough time has passed
     */
    function updatePrices() external {
        require(isActive, "Bot is not active");
        require(block.timestamp >= lastUpdateTime + updateInterval, "Too early to update");
        
        // Generate new prices with realistic movement
        uint256 chainlinkPrice = _generateNewPrice(basePrice, maxVariation);
        uint256 bandPrice = _generateNewPrice(basePrice, maxVariation / 2); // Band has less variation
        
        // Update mock oracles
        chainlinkOracle.updatePrice(int256(chainlinkPrice));
        bandOracle.updateReferenceData("XAU", "USD", bandPrice);
        
        // Update aggregated price
        oracleAggregator.updateAggregatedPrice();
        
        lastUpdateTime = block.timestamp;
        
        emit PriceUpdated((chainlinkPrice + bandPrice) / 2, block.timestamp);
    }
    
    /**
     * @dev Check if update is needed
     */
    function needsUpdate() external view returns (bool) {
        return isActive && block.timestamp >= lastUpdateTime + updateInterval;
    }
    
    /**
     * @dev Get time until next update
     */
    function timeUntilNextUpdate() external view returns (uint256) {
        if (!isActive) return type(uint256).max;
        
        uint256 nextUpdateTime = lastUpdateTime + updateInterval;
        if (block.timestamp >= nextUpdateTime) return 0;
        
        return nextUpdateTime - block.timestamp;
    }
    
    /**
     * @dev Configure bot parameters
     */
    function configure(
        uint256 _updateInterval,
        uint256 _basePrice,
        uint256 _maxVariation
    ) external onlyOwner {
        updateInterval = _updateInterval;
        basePrice = _basePrice;
        maxVariation = _maxVariation;
        
        emit BotConfigured(_updateInterval, _basePrice, _maxVariation);
    }
    
    /**
     * @dev Start/stop the bot
     */
    function setActive(bool _active) external onlyOwner {
        isActive = _active;
        emit BotStatusChanged(_active);
    }
    
    /**
     * @dev Transfer ownership
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }
    
    /**
     * @dev Generate realistic price movement
     */
    function _generateNewPrice(uint256 _basePrice, uint256 _maxVariation) internal view returns (uint256) {
        // Use block properties for pseudo-randomness (not secure, but fine for testing)
        uint256 seed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.difficulty,
            block.number,
            msg.sender
        )));
        
        // Generate variation between -maxVariation and +maxVariation
        uint256 variation = seed % (_maxVariation * 2);
        
        if (variation > _maxVariation) {
            // Positive variation
            return _basePrice + (variation - _maxVariation);
        } else {
            // Negative variation
            uint256 decrease = _maxVariation - variation;
            return _basePrice > decrease ? _basePrice - decrease : _basePrice / 2;
        }
    }
    
    /**
     * @dev Simulate extreme price movement for testing circuit breaker
     */
    function simulateExtremeMovement(bool increase) external onlyOwner {
        uint256 extremePrice;
        
        if (increase) {
            extremePrice = basePrice * 110 / 100; // 10% increase
        } else {
            extremePrice = basePrice * 90 / 100;  // 10% decrease
        }
        
        chainlinkOracle.updatePrice(int256(extremePrice));
        bandOracle.updateReferenceData("XAU", "USD", extremePrice);
        
        // This should trigger circuit breaker
        try oracleAggregator.updateAggregatedPrice() {
            emit PriceUpdated(extremePrice, block.timestamp);
        } catch {
            // Circuit breaker likely triggered
        }
        
        lastUpdateTime = block.timestamp;
    }
    
    /**
     * @dev Get current bot status
     */
    function getStatus() external view returns (
        bool active,
        uint256 lastUpdate,
        uint256 nextUpdate,
        uint256 currentBasePrice,
        uint256 currentVariation
    ) {
        return (
            isActive,
            lastUpdateTime,
            lastUpdateTime + updateInterval,
            basePrice,
            maxVariation
        );
    }
}