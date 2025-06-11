# Oracle Integration Guide

## Overview

TetraGold's oracle system aggregates gold price data from multiple trusted sources to ensure accurate, reliable, and manipulation-resistant price feeds. This document details the oracle architecture, integration procedures, and operational guidelines.

## Architecture

### Multi-Source Aggregation

The oracle system combines data from multiple sources to create a robust, tamper-resistant price feed:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Chainlink     │    │  Band Protocol  │    │  Custom Oracle  │
│   Gold/USD      │    │   Gold/USD      │    │    Gold/USD     │
└─────────┬───────┘    └─────────┬───────┘    └─────────┬───────┘
          │                      │                      │
          │                      │                      │
          └──────────────────────┼──────────────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │    Oracle Aggregator     │
                    │   Weighted Average       │
                    │   Deviation Checks       │
                    │   Staleness Validation   │
                    └─────────────┬─────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │    Circuit Breaker       │
                    │   Price Movement Limits  │
                    │   Time Window Analysis   │
                    └─────────────┬─────────────┘
                                 │
                    ┌─────────────▼─────────────┐
                    │      TGAUx Token         │
                    │   Mint/Redeem Logic      │
                    └─────────────────────────┘
```

### Oracle Configuration

Each oracle source is configured with specific parameters:

```solidity
struct OracleConfig {
    address oracle;        // Oracle contract address
    uint256 weight;        // Weight in aggregation (basis points)
    uint256 maxStaleness;  // Maximum age of price data (seconds)
    bool isActive;         // Enable/disable this oracle
}
```

## Supported Oracle Sources

### 1. Chainlink Price Feeds

**Primary Source**: Chainlink's decentralized oracle network provides high-quality, tamper-resistant price data.

#### Integration Details
- **Feed Address**: `0x214eD9Da11D2fbe465a6fc601a91E62EbEc1a0D6` (Gold/USD on Ethereum)
- **Update Frequency**: Every 1% price deviation or 24 hours
- **Decimals**: 8
- **Heartbeat**: 86400 seconds (24 hours)

#### Implementation
```solidity
interface IChainlinkOracle {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 price,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}
```

### 2. Band Protocol

**Secondary Source**: Band Protocol provides additional price validation through their decentralized oracle network.

#### Integration Details
- **Symbol**: `XAU/USD`
- **Update Frequency**: Every 0.5% price deviation or 12 hours
- **Decimals**: 18
- **Data Sources**: Multiple traditional financial data providers

#### Implementation
```solidity
interface IBandOracle {
    function getReferenceData(string memory base, string memory quote)
        external view returns (ReferenceData memory);
}
```

### 3. Custom Oracle Sources

**Tertiary Sources**: Additional oracle providers for enhanced redundancy.

#### Supported Providers
- **API3**: dAPI for gold prices
- **DIA**: Crowd-sourced price data
- **Tellor**: Decentralized oracle protocol
- **Umbrella Network**: Community-driven oracle network

## Price Aggregation Logic

### Weighted Average Calculation

The aggregator calculates a weighted average of all valid oracle prices:

```solidity
function calculateWeightedAverage(PriceData[] memory prices) 
    internal view returns (uint256 weightedPrice, uint256 totalConfidence) {
    
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
```

### Validation Rules

#### Staleness Check
```solidity
function isStale(uint256 timestamp, uint256 maxStaleness) 
    internal view returns (bool) {
    return block.timestamp - timestamp > maxStaleness;
}
```

#### Deviation Check
```solidity
function checkDeviation(uint256 newPrice, uint256 lastPrice) 
    internal view returns (bool exceeded, uint256 deviation) {
    
    uint256 priceDiff = newPrice > lastPrice 
        ? newPrice - lastPrice 
        : lastPrice - newPrice;
    
    deviation = (priceDiff * 10000) / lastPrice;
    exceeded = deviation > deviationThreshold;
}
```

#### Confidence Threshold
```solidity
function hasMinimumConfidence(uint256 confidence) 
    internal pure returns (bool) {
    return confidence >= MIN_CONFIDENCE; // 80%
}
```

## Circuit Breaker Integration

### Price Movement Limits

The circuit breaker monitors price movements and triggers protective measures:

```solidity
struct CircuitBreakerConfig {
    uint256 priceDeviationThreshold; // 5% maximum movement
    uint256 timeWindow;              // 5-minute observation window
    uint256 cooldownPeriod;          // 1-hour recovery period
    bool isActive;                   // Enable/disable functionality
}
```

### Trigger Conditions

1. **Single Price Jump**: >5% price change in one update
2. **Rapid Movement**: >5% cumulative change within 5 minutes
3. **Oracle Failure**: <2 active oracles providing data
4. **Low Confidence**: <80% average confidence score

### Recovery Process

1. **Automatic Reset**: After cooldown period expires
2. **Manual Reset**: Emergency role can force reset
3. **Gradual Resumption**: Reduced limits during recovery
4. **Full Operation**: Normal limits after stability period

## Oracle Management

### Adding New Oracles

```solidity
function addOracle(
    address oracle,
    uint256 weight,
    uint256 maxStaleness
) external onlyRole(ORACLE_MANAGER_ROLE) {
    require(oracleList.length < MAX_ORACLES, "Too many oracles");
    require(weight > 0 && weight <= TOTAL_WEIGHT, "Invalid weight");
    
    oracles[oracle] = OracleConfig({
        oracle: oracle,
        weight: weight,
        maxStaleness: maxStaleness,
        isActive: true
    });
    
    oracleList.push(oracle);
    emit OracleAdded(oracle, weight);
}
```

### Updating Oracle Weights

```solidity
function updateOracleWeight(address oracle, uint256 newWeight) 
    external onlyRole(ORACLE_MANAGER_ROLE) {
    
    require(oracles[oracle].oracle != address(0), "Oracle not found");
    require(newWeight > 0 && newWeight <= TOTAL_WEIGHT, "Invalid weight");
    
    uint256 oldWeight = oracles[oracle].weight;
    uint256 totalWeight = calculateTotalWeight() - oldWeight + newWeight;
    require(totalWeight <= TOTAL_WEIGHT, "Total weight exceeds limit");
    
    oracles[oracle].weight = newWeight;
    emit OracleWeightUpdated(oracle, newWeight);
}
```

### Removing Oracles

```solidity
function removeOracle(address oracle) 
    external onlyRole(ORACLE_MANAGER_ROLE) {
    
    require(oracles[oracle].oracle != address(0), "Oracle not found");
    require(oracleList.length > MIN_ORACLES, "Insufficient oracles");
    
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
```

## Monitoring and Alerting

### Health Checks

#### Oracle Availability
```javascript
async function checkOracleHealth() {
    const oracles = await oracleAggregator.getAllPrices();
    const activeCount = oracles.filter(o => o.timestamp > Date.now() - 3600000).length;
    
    if (activeCount < MIN_ORACLES) {
        alert('CRITICAL: Insufficient active oracles');
    }
}
```

#### Price Deviation Monitoring
```javascript
async function monitorPriceDeviation() {
    const [currentPrice] = await oracleAggregator.getLatestPrice();
    const marketPrice = await getExternalMarketPrice();
    
    const deviation = Math.abs(currentPrice - marketPrice) / marketPrice;
    
    if (deviation > 0.02) { // 2% threshold
        alert('WARNING: Price deviation detected');
    }
}
```

#### Circuit Breaker Status
```javascript
async function checkCircuitBreaker() {
    const isTriggered = await circuitBreaker.isTriggered();
    const timeUntilReset = await circuitBreaker.getTimeUntilReset();
    
    if (isTriggered) {
        alert(`ALERT: Circuit breaker active. Reset in ${timeUntilReset} seconds`);
    }
}
```

### Alert Thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| Oracle Count | <3 active | <2 active |
| Price Deviation | >2% | >5% |
| Data Staleness | >30 min | >60 min |
| Confidence Score | <85% | <80% |
| Circuit Breaker | Triggered | >2 triggers/day |

## Emergency Procedures

### Oracle Failure Response

1. **Immediate Actions**
   - Disable failed oracle
   - Increase weights of remaining oracles
   - Activate backup oracle sources
   - Notify operations team

2. **Investigation**
   - Analyze failure cause
   - Check oracle provider status
   - Verify data integrity
   - Document incident

3. **Recovery**
   - Restore oracle service
   - Gradually increase weight
   - Monitor for stability
   - Update procedures if needed

### Price Manipulation Detection

1. **Detection Indicators**
   - Sudden large price movements
   - Divergence from market prices
   - Unusual trading volumes
   - Oracle data inconsistencies

2. **Response Actions**
   - Trigger circuit breaker
   - Pause trading operations
   - Investigate data sources
   - Coordinate with oracle providers

3. **Recovery Process**
   - Verify price accuracy
   - Reset circuit breaker
   - Resume operations gradually
   - Implement additional safeguards

## Testing and Validation

### Unit Tests

```javascript
describe("Oracle Aggregator", function() {
    it("Should aggregate prices correctly", async function() {
        // Test weighted average calculation
        // Test deviation detection
        // Test staleness validation
    });
    
    it("Should handle oracle failures", async function() {
        // Test with failed oracles
        // Test minimum oracle requirements
        // Test fallback mechanisms
    });
});
```

### Integration Tests

```javascript
describe("Circuit Breaker Integration", function() {
    it("Should trigger on extreme price movements", async function() {
        // Test price movement detection
        // Test automatic triggering
        // Test recovery process
    });
});
```

### Stress Tests

```javascript
describe("Oracle Stress Tests", function() {
    it("Should handle high-frequency updates", async function() {
        // Test rapid price updates
        // Test gas optimization
        // Test system stability
    });
});
```

## Deployment Checklist

### Pre-Deployment
- [ ] Oracle contracts deployed and verified
- [ ] Price feeds configured and tested
- [ ] Circuit breaker parameters set
- [ ] Access controls configured
- [ ] Monitoring systems ready

### Deployment
- [ ] Deploy oracle aggregator
- [ ] Configure initial oracles
- [ ] Set up circuit breaker
- [ ] Grant necessary roles
- [ ] Verify all connections

### Post-Deployment
- [ ] Monitor price feeds
- [ ] Test emergency procedures
- [ ] Validate aggregation logic
- [ ] Check circuit breaker functionality
- [ ] Document configuration

## Maintenance

### Regular Tasks
- **Daily**: Monitor oracle health and price accuracy
- **Weekly**: Review deviation alerts and circuit breaker logs
- **Monthly**: Analyze oracle performance and update weights
- **Quarterly**: Comprehensive system review and optimization

### Updates
- **Oracle Addition**: Follow governance process for new sources
- **Weight Adjustment**: Based on performance metrics
- **Parameter Tuning**: Optimize thresholds and timeouts
- **Emergency Updates**: Immediate response to critical issues

---

**Last Updated**: January 2025  
**Version**: 1.0.0  
**Next Review**: April 2025