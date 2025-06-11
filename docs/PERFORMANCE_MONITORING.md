# Performance Monitoring Setup

## Overview

Comprehensive performance monitoring system for TetraGold testnet deployment, covering real-time metrics collection, alert thresholds, and dashboard visualization.

## Monitoring Architecture

### Core Metrics Collection
- **Blockchain Metrics**: Block times, gas prices, transaction throughput
- **Application Metrics**: Response times, error rates, user interactions
- **Oracle Metrics**: Price feed latency, deviation alerts, confidence scores
- **Security Metrics**: Circuit breaker triggers, emergency events, access violations

### Technology Stack
- **Metrics Collection**: Prometheus + Custom collectors
- **Visualization**: Grafana dashboards
- **Alerting**: PagerDuty + Slack integration
- **Log Aggregation**: ELK Stack (Elasticsearch, Logstash, Kibana)
- **APM**: Sentry for error tracking and performance monitoring

## Real-Time Metrics

### Blockchain Performance
```yaml
# Block Time Monitoring
block_time_seconds:
  description: "Average block time on Sepolia"
  target: 12-15 seconds
  alert_threshold: >20 seconds
  collection_interval: 30s

# Gas Price Tracking
gas_price_gwei:
  description: "Current gas price in gwei"
  target: 10-30 gwei
  alert_threshold: >100 gwei
  collection_interval: 60s

# Transaction Throughput
transactions_per_second:
  description: "Network transaction rate"
  target: 10-15 TPS
  alert_threshold: <5 TPS
  collection_interval: 60s
```

### Application Performance
```yaml
# Response Time Metrics
api_response_time_ms:
  description: "API endpoint response times"
  targets:
    price_feed: <500ms
    trade_execution: <2000ms
    balance_query: <300ms
  alert_thresholds:
    price_feed: >1000ms
    trade_execution: >5000ms
    balance_query: >1000ms

# Error Rate Monitoring
error_rate_percentage:
  description: "Application error rates"
  target: <1%
  alert_threshold: >5%
  collection_interval: 60s

# User Experience Metrics
page_load_time_ms:
  description: "Frontend page load times"
  target: <2000ms
  alert_threshold: >5000ms
  collection_interval: 30s
```

### Oracle System Metrics
```yaml
# Price Feed Latency
oracle_update_latency_seconds:
  description: "Time between oracle updates"
  target: 300s (5 minutes)
  alert_threshold: >600s (10 minutes)
  collection_interval: 60s

# Price Deviation Monitoring
price_deviation_percentage:
  description: "Deviation between oracle sources"
  target: <1%
  alert_threshold: >3%
  collection_interval: 30s

# Oracle Health Status
oracle_availability_percentage:
  description: "Oracle uptime and availability"
  target: >99%
  alert_threshold: <95%
  collection_interval: 60s
```

### Security Metrics
```yaml
# Circuit Breaker Events
circuit_breaker_triggers:
  description: "Circuit breaker activation count"
  target: 0 per day
  alert_threshold: >2 per day
  collection_interval: 300s

# Emergency Events
emergency_pause_events:
  description: "Emergency pause activations"
  target: 0
  alert_threshold: >0
  collection_interval: immediate

# Access Control Violations
unauthorized_access_attempts:
  description: "Failed access control attempts"
  target: <10 per hour
  alert_threshold: >50 per hour
  collection_interval: 300s
```

## Alert Configuration

### Critical Alerts (Immediate Response)
- **System Down**: Application unavailable
- **Security Breach**: Unauthorized access detected
- **Circuit Breaker**: Price protection triggered
- **Oracle Failure**: All price feeds down
- **Emergency Pause**: System emergency activation

### High Priority Alerts (15-minute Response)
- **Performance Degradation**: >50% slowdown
- **High Error Rate**: >5% transaction failures
- **Gas Price Spike**: >100 gwei sustained
- **Oracle Deviation**: >5% price difference
- **Network Congestion**: <5 TPS sustained

### Medium Priority Alerts (1-hour Response)
- **Moderate Performance**: 20-50% slowdown
- **Elevated Error Rate**: 2-5% failures
- **Oracle Staleness**: >10 minutes without update
- **High Gas Usage**: Unusual consumption patterns
- **User Experience**: Page load >5 seconds

### Low Priority Alerts (Daily Review)
- **Minor Performance**: <20% slowdown
- **Low Error Rate**: 1-2% failures
- **Maintenance Reminders**: Scheduled tasks
- **Capacity Planning**: Resource utilization trends
- **User Feedback**: Non-critical issues

## Dashboard Configuration

### Executive Dashboard
- **System Health**: Overall status indicator
- **Key Metrics**: Price, volume, users, transactions
- **Alert Summary**: Current issues and status
- **Performance Overview**: Response times and availability
- **Security Status**: Circuit breaker and emergency states

### Technical Dashboard
- **Blockchain Metrics**: Block times, gas prices, network status
- **Application Performance**: Response times, error rates, throughput
- **Oracle Health**: Price feeds, deviations, confidence scores
- **Infrastructure**: Server resources, database performance
- **Security Events**: Access logs, failed attempts, anomalies

### Business Dashboard
- **Trading Volume**: Daily/weekly/monthly trends
- **User Activity**: Active users, new registrations, retention
- **Revenue Metrics**: Fees collected, transaction values
- **Market Data**: Price movements, volatility, comparisons
- **Growth Indicators**: Adoption rates, feature usage

## Automated Monitoring Scripts

### Health Check Script
```javascript
// health-check.js
const { ethers } = require('ethers');
const { TESTNET_CONFIG } = require('./config/testnet');

class HealthChecker {
  constructor() {
    this.provider = new ethers.providers.JsonRpcProvider(TESTNET_CONFIG.RPC_URL);
    this.metrics = {};
  }

  async checkBlockchainHealth() {
    try {
      const blockNumber = await this.provider.getBlockNumber();
      const block = await this.provider.getBlock(blockNumber);
      const gasPrice = await this.provider.getGasPrice();

      this.metrics.blockchain = {
        blockNumber,
        blockTime: block.timestamp,
        gasPrice: ethers.utils.formatUnits(gasPrice, 'gwei'),
        status: 'healthy'
      };
    } catch (error) {
      this.metrics.blockchain = {
        status: 'error',
        error: error.message
      };
    }
  }

  async checkContractHealth() {
    try {
      const tgaux = new ethers.Contract(
        TESTNET_CONFIG.CONTRACTS.TGAUX,
        ['function version() view returns (string)'],
        this.provider
      );

      const version = await tgaux.version();
      
      this.metrics.contracts = {
        tgaux: { status: 'healthy', version },
        status: 'healthy'
      };
    } catch (error) {
      this.metrics.contracts = {
        status: 'error',
        error: error.message
      };
    }
  }

  async checkOracleHealth() {
    try {
      const oracle = new ethers.Contract(
        TESTNET_CONFIG.CONTRACTS.ORACLE_AGGREGATOR,
        ['function getLatestPrice() view returns (uint256, uint256)'],
        this.provider
      );

      const [price, timestamp] = await oracle.getLatestPrice();
      const age = Date.now() / 1000 - timestamp.toNumber();

      this.metrics.oracle = {
        price: ethers.utils.formatEther(price),
        timestamp: timestamp.toNumber(),
        age,
        status: age < 600 ? 'healthy' : 'stale'
      };
    } catch (error) {
      this.metrics.oracle = {
        status: 'error',
        error: error.message
      };
    }
  }

  async runHealthCheck() {
    await Promise.all([
      this.checkBlockchainHealth(),
      this.checkContractHealth(),
      this.checkOracleHealth()
    ]);

    const overallStatus = Object.values(this.metrics)
      .every(metric => metric.status === 'healthy') ? 'healthy' : 'degraded';

    return {
      timestamp: new Date().toISOString(),
      status: overallStatus,
      metrics: this.metrics
    };
  }
}

module.exports = HealthChecker;
```

### Performance Monitor
```javascript
// performance-monitor.js
class PerformanceMonitor {
  constructor() {
    this.metrics = new Map();
    this.startTime = Date.now();
  }

  startTimer(operation) {
    this.metrics.set(operation, Date.now());
  }

  endTimer(operation) {
    const startTime = this.metrics.get(operation);
    if (startTime) {
      const duration = Date.now() - startTime;
      this.metrics.delete(operation);
      return duration;
    }
    return null;
  }

  async measureOperation(operation, fn) {
    this.startTimer(operation);
    try {
      const result = await fn();
      const duration = this.endTimer(operation);
      
      // Log performance metric
      console.log(`${operation}: ${duration}ms`);
      
      // Send to monitoring system
      this.sendMetric(operation, duration);
      
      return result;
    } catch (error) {
      this.endTimer(operation);
      throw error;
    }
  }

  sendMetric(operation, duration) {
    // Integration with monitoring system
    // This would send metrics to Prometheus, DataDog, etc.
    const metric = {
      name: `operation_duration_ms`,
      value: duration,
      tags: { operation },
      timestamp: Date.now()
    };
    
    // Send to metrics collector
    this.postMetric(metric);
  }

  async postMetric(metric) {
    // Implementation depends on monitoring system
    // Example: POST to Prometheus pushgateway
    try {
      await fetch('/metrics', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(metric)
      });
    } catch (error) {
      console.warn('Failed to send metric:', error);
    }
  }
}

module.exports = PerformanceMonitor;
```

## Integration Points

### Frontend Integration
```typescript
// monitoring.ts
export class FrontendMonitoring {
  private performanceObserver: PerformanceObserver;
  
  constructor() {
    this.setupPerformanceMonitoring();
    this.setupErrorTracking();
    this.setupUserAnalytics();
  }

  setupPerformanceMonitoring() {
    // Web Vitals monitoring
    this.performanceObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        this.sendPerformanceMetric(entry);
      }
    });

    this.performanceObserver.observe({ entryTypes: ['navigation', 'paint', 'largest-contentful-paint'] });
  }

  setupErrorTracking() {
    window.addEventListener('error', (event) => {
      this.sendErrorMetric({
        message: event.message,
        filename: event.filename,
        lineno: event.lineno,
        colno: event.colno,
        stack: event.error?.stack
      });
    });
  }

  trackUserInteraction(action: string, data?: any) {
    this.sendUserMetric({
      action,
      data,
      timestamp: Date.now(),
      url: window.location.href
    });
  }

  private sendPerformanceMetric(entry: PerformanceEntry) {
    // Send to analytics service
  }

  private sendErrorMetric(error: any) {
    // Send to error tracking service
  }

  private sendUserMetric(interaction: any) {
    // Send to user analytics service
  }
}
```

### Backend Integration
```javascript
// monitoring-middleware.js
const prometheus = require('prom-client');

// Create metrics
const httpRequestDuration = new prometheus.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code']
});

const httpRequestTotal = new prometheus.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code']
});

function monitoringMiddleware(req, res, next) {
  const start = Date.now();
  
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    const route = req.route?.path || req.path;
    
    httpRequestDuration
      .labels(req.method, route, res.statusCode)
      .observe(duration);
    
    httpRequestTotal
      .labels(req.method, route, res.statusCode)
      .inc();
  });
  
  next();
}

module.exports = monitoringMiddleware;
```

## Incident Response

### Escalation Matrix
1. **Level 1**: Automated alerts and self-healing
2. **Level 2**: On-call engineer notification
3. **Level 3**: Team lead and security officer
4. **Level 4**: Executive team and external support

### Response Procedures
- **Immediate**: Acknowledge alert within 5 minutes
- **Assessment**: Determine severity within 15 minutes
- **Communication**: Update stakeholders within 30 minutes
- **Resolution**: Implement fix or workaround
- **Post-mortem**: Document lessons learned

## Maintenance and Updates

### Daily Tasks
- [ ] Review overnight alerts and metrics
- [ ] Check system health dashboards
- [ ] Validate oracle price feeds
- [ ] Monitor user feedback and issues
- [ ] Update performance baselines

### Weekly Tasks
- [ ] Analyze performance trends
- [ ] Review and tune alert thresholds
- [ ] Update monitoring documentation
- [ ] Capacity planning assessment
- [ ] Security metrics review

### Monthly Tasks
- [ ] Comprehensive system review
- [ ] Monitoring system updates
- [ ] Performance optimization
- [ ] Disaster recovery testing
- [ ] Stakeholder reporting

---

**Monitoring Lead**: [Name]  
**DevOps Engineer**: [Name]  
**Security Officer**: [Name]  
**On-Call Rotation**: [Schedule]

**Last Updated**: January 2025  
**Next Review**: Weekly during beta testing