// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract OracleAggregatorTest is Test {
    OracleAggregator public aggregator;
    MockChainlinkOracle public chainlinkOracle;
    MockBandOracle public bandOracle;
    MockAPI3Oracle public api3Oracle;

    address public admin;
    address public user;

    // Constants
    uint256 constant GOLD_PRICE = 200000000000; // $2000.00 with 8 decimals
    uint256 constant DECIMALS = 8;

    // Events
    event PriceUpdated(uint256 price, uint256 timestamp);
    event CircuitBreakerTriggered(uint256 oldPrice, uint256 newPrice, uint256 deviation);
    event OracleFailed(string oracleName, string reason);
    event ThresholdUpdated(string thresholdType, uint256 oldValue, uint256 newValue);

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");

        // Deploy mock oracles
        chainlinkOracle = new MockChainlinkOracle(8);
        bandOracle = new MockBandOracle();
        api3Oracle = new MockAPI3Oracle();

        // Deploy aggregator
        vm.prank(admin);
        aggregator = new OracleAggregator(admin, address(chainlinkOracle), address(bandOracle), address(api3Oracle));

        // Set initial prices (all $2000)
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE)); // 8 decimals
        bandOracle.setReferenceData(GOLD_PRICE * 1e10); // 18 decimals
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10))); // 18 decimals
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertTrue(aggregator.hasRole(aggregator.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(aggregator.hasRole(aggregator.ADMIN_ROLE(), admin));
        assertEq(address(aggregator.chainlinkOracle()), address(chainlinkOracle));
        assertEq(address(aggregator.bandOracle()), address(bandOracle));
        assertEq(address(aggregator.api3Oracle()), address(api3Oracle));
    }

    function test_ConstructorRevertsWithZeroAdmin() public {
        vm.expectRevert("OracleAggregator: admin cannot be zero");
        new OracleAggregator(address(0), address(chainlinkOracle), address(bandOracle), address(api3Oracle));
    }

    /* ============ Price Aggregation Tests ============ */

    function test_UpdateTWAPWithAllOracles() public {
        vm.expectEmit(false, false, false, false);
        emit PriceUpdated(0, 0);

        aggregator.updateTwap();

        (uint256 price, uint256 timestamp) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
        assertEq(timestamp, block.timestamp);
        assertEq(aggregator.lastPrice(), GOLD_PRICE);
    }

    function test_UpdateTWAPWithTwoOracles() public {
        // Disable one oracle
        api3Oracle.setShouldFail(true);

        aggregator.updateTwap();

        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE); // Should still work with 2 oracles
    }

    function test_UpdateTWAPRevertsWithOneOracle() public {
        // Disable two oracles
        bandOracle.setShouldFail(true);
        api3Oracle.setShouldFail(true);

        vm.expectRevert("OracleAggregator: insufficient valid oracles");
        aggregator.updateTwap();
    }

    function test_UpdateTWAPWithDifferentPrices() public {
        // Set slightly different prices
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE)); // $2000
        bandOracle.setReferenceData(199000000000 * 1e10); // $1990
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(201000000000 * 1e10))); // $2010

        aggregator.updateTwap();

        (uint256 price,) = aggregator.getGoldPrice();
        // Should be average: (2000 + 1990 + 2010) / 3 = 2000
        assertEq(price, GOLD_PRICE);
    }

    /* ============ TWAP Tests ============ */

    function test_TWAPCalculationOverTime() public {
        // First update
        aggregator.updateTwap();
        (uint256 price1,) = aggregator.getGoldPrice();

        // Wait 5 minutes and update again with different price
        vm.warp(block.timestamp + 300);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE + 1000000000)); // $2010
        bandOracle.setReferenceData((GOLD_PRICE + 1000000000) * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256((GOLD_PRICE + 1000000000) * 1e10)));

        aggregator.updateTwap();

        // Wait a bit more so the new price has weight in TWAP
        vm.warp(block.timestamp + 100);
        aggregator.updateTwap();
        (uint256 price2,) = aggregator.getGoldPrice();

        // Price should be between 2000 and 2010 due to TWAP
        assertGt(price2, price1);
        assertLt(price2, GOLD_PRICE + 1000000000);
    }

    function test_TWAPWindowMaintenance() public {
        // Add multiple price points
        for (uint256 i = 0; i < 5; i++) {
            aggregator.updateTwap();
            vm.warp(block.timestamp + 100); // 100 seconds between updates
        }

        // All should be within TWAP window
        uint256 historyLength = aggregator.getPriceHistoryLength();
        assertEq(historyLength, 5);

        // Warp past TWAP window (10 minutes)
        vm.warp(block.timestamp + 600);
        aggregator.updateTwap();

        // Old entries should be removed
        uint256 newHistoryLength = aggregator.getPriceHistoryLength();
        assertLt(newHistoryLength, historyLength + 1);
    }

    /* ============ Circuit Breaker Tests ============ */

    function test_CircuitBreakerTriggersOnLargeIncrease() public {
        // Initial update
        aggregator.updateTwap();

        // Set price 6% higher (exceeds 5% threshold)
        uint256 newPrice = GOLD_PRICE * 106 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));

        vm.warp(block.timestamp + 60);
        vm.expectEmit(true, true, true, false);
        emit CircuitBreakerTriggered(GOLD_PRICE, newPrice, 0);

        aggregator.updateTwap();

        // Should be paused
        assertTrue(aggregator.paused());
    }

    function test_CircuitBreakerTriggersOnLargeDecrease() public {
        // Initial update
        aggregator.updateTwap();

        // Set price 6% lower (exceeds 5% threshold)
        uint256 newPrice = GOLD_PRICE * 94 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));

        vm.warp(block.timestamp + 60);
        vm.expectEmit(true, true, true, false);
        emit CircuitBreakerTriggered(GOLD_PRICE, newPrice, 0);

        aggregator.updateTwap();

        // Should be paused
        assertTrue(aggregator.paused());
    }

    function test_CircuitBreakerDoesNotTriggerWithinThreshold() public {
        // Initial update
        aggregator.updateTwap();

        // Set price 4% higher (within 5% threshold)
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));

        vm.warp(block.timestamp + 60);
        aggregator.updateTwap();

        // Should not be paused
        assertFalse(aggregator.paused());
    }

    /* ============ Staleness / Rate-limit Tests ============ */

    /// @dev H-01 regression: getGoldPrice must revert once the cached TWAP
    ///      is older than MAX_PRICE_AGE
    function test_GetGoldPriceRevertsWhenStale() public {
        aggregator.updateTwap();

        vm.warp(block.timestamp + aggregator.MAX_PRICE_AGE() + 1);

        vm.expectRevert("OracleAggregator: price is stale");
        aggregator.getGoldPrice();
    }

    function test_GetGoldPriceWorksAtMaxAgeBoundary() public {
        aggregator.updateTwap();

        vm.warp(block.timestamp + aggregator.MAX_PRICE_AGE());

        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    /// @dev L-01 regression: updateTwap must enforce a minimum interval between calls
    function test_UpdateTwapRevertsWhenTooFrequent() public {
        aggregator.updateTwap();

        vm.warp(block.timestamp + aggregator.MIN_UPDATE_INTERVAL() - 1);

        vm.expectRevert("OracleAggregator: update too frequent");
        aggregator.updateTwap();
    }

    function test_UpdateTwapWorksAtMinIntervalBoundary() public {
        aggregator.updateTwap();

        vm.warp(block.timestamp + aggregator.MIN_UPDATE_INTERVAL());

        aggregator.updateTwap();
        assertEq(aggregator.lastUpdateTime(), block.timestamp);
    }

    /* ============ Price Deviation Tests ============ */

    function test_PriceDeviationTriggersMedian() public {
        // Set prices with >2% deviation
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE)); // $2000
        bandOracle.setReferenceData(210000000000 * 1e10); // $2100 (5% higher)
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(205000000000 * 1e10))); // $2050

        aggregator.updateTwap();

        (uint256 price,) = aggregator.getGoldPrice();
        // Should use median: 2050
        assertEq(price, 205000000000);
    }

    function test_PriceDeviationUsesAverageWhenSmall() public {
        // Set prices with <2% deviation
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE)); // $2000
        bandOracle.setReferenceData(200100000000 * 1e10); // $2001
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(199900000000 * 1e10))); // $1999

        aggregator.updateTwap();

        (uint256 price,) = aggregator.getGoldPrice();
        // Should use average: 2000
        assertEq(price, GOLD_PRICE);
    }

    /* ============ Staleness Tests ============ */

    function test_RejectsStaleChainlinkPrice() public {
        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 20000);

        // Update Band and API3 to current time (keep them fresh)
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        // Set Chainlink price to be 3 hours old
        chainlinkOracle.setUpdatedAt(block.timestamp - 10800);

        aggregator.updateTwap();

        // Should still work with Band and API3
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_RejectsStaleBandPrice() public {
        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 20000);

        // Update Chainlink and API3 to current time (keep them fresh)
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        // Set Band price to be 3 hours old
        bandOracle.setLastUpdated(block.timestamp - 10800, block.timestamp - 10800);

        aggregator.updateTwap();

        // Should still work with Chainlink and API3
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_RejectsStaleAPI3Price() public {
        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 20000);

        // Update Chainlink and Band to current time (keep them fresh)
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);

        // Set API3 price to be 3 hours old
        api3Oracle.setTimestamp(uint32(block.timestamp - 10800));

        aggregator.updateTwap();

        // Should still work with Chainlink and Band
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_RevertsWhenAllPricesStale() public {
        // Warp time forward to avoid underflow
        vm.warp(block.timestamp + 20000);

        // Make all prices stale
        chainlinkOracle.setUpdatedAt(block.timestamp - 10800);
        bandOracle.setLastUpdated(block.timestamp - 10800, block.timestamp - 10800);
        api3Oracle.setTimestamp(uint32(block.timestamp - 10800));

        vm.expectRevert("OracleAggregator: insufficient valid oracles");
        aggregator.updateTwap();
    }

    /* ============ Oracle Failure Tests ============ */

    function test_HandlesChainlinkFailure() public {
        chainlinkOracle.setShouldFail(true);

        vm.expectEmit(true, true, true, true);
        emit OracleFailed("Chainlink", "Mock: Oracle failure");

        aggregator.updateTwap();

        // Should still work with Band and API3
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_HandlesBandFailure() public {
        bandOracle.setShouldFail(true);

        vm.expectEmit(true, true, true, true);
        emit OracleFailed("Band", "Mock: Oracle failure");

        aggregator.updateTwap();

        // Should still work with Chainlink and API3
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_HandlesAPI3Failure() public {
        api3Oracle.setShouldFail(true);

        vm.expectEmit(true, true, true, true);
        emit OracleFailed("API3", "Mock: Oracle failure");

        aggregator.updateTwap();

        // Should still work with Chainlink and Band
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    /* ============ Admin Functions Tests ============ */

    function test_SetPriceDeviation() public {
        uint256 newThreshold = 300; // 3%

        vm.expectEmit(true, true, true, true);
        emit ThresholdUpdated("PriceDeviation", 200, 300);

        vm.prank(admin);
        aggregator.setPriceDeviation(newThreshold);

        assertEq(aggregator.priceDeviationThreshold(), newThreshold);
    }

    function test_SetPriceDeviationRevertsIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("OracleAggregator: threshold too high");
        aggregator.setPriceDeviation(1100); // >10%
    }

    function test_SetPriceDeviationRevertsIfNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        aggregator.setPriceDeviation(300);
    }

    function test_SetCircuitBreakerThreshold() public {
        uint256 newThreshold = 1000; // 10%

        vm.expectEmit(true, true, true, true);
        emit ThresholdUpdated("CircuitBreaker", 500, 1000);

        vm.prank(admin);
        aggregator.setCircuitBreakerThreshold(newThreshold);

        assertEq(aggregator.circuitBreakerThreshold(), newThreshold);
    }

    function test_SetCircuitBreakerThresholdRevertsIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert("OracleAggregator: threshold too high");
        aggregator.setCircuitBreakerThreshold(2100); // >20%
    }

    function test_SetCircuitBreakerThresholdRevertsIfNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        aggregator.setCircuitBreakerThreshold(1000);
    }

    function test_UpdateChainlinkOracleAddress() public {
        MockChainlinkOracle newOracle = new MockChainlinkOracle(8);

        vm.prank(admin);
        aggregator.updateOracleAddress(0, address(newOracle));

        assertEq(address(aggregator.chainlinkOracle()), address(newOracle));
    }

    function test_UpdateBandOracleAddress() public {
        MockBandOracle newOracle = new MockBandOracle();

        vm.prank(admin);
        aggregator.updateOracleAddress(1, address(newOracle));

        assertEq(address(aggregator.bandOracle()), address(newOracle));
    }

    function test_UpdateAPI3OracleAddress() public {
        MockAPI3Oracle newOracle = new MockAPI3Oracle();

        vm.prank(admin);
        aggregator.updateOracleAddress(2, address(newOracle));

        assertEq(address(aggregator.api3Oracle()), address(newOracle));
    }

    function test_UpdateOracleAddressRevertsWithInvalidType() public {
        vm.prank(admin);
        vm.expectRevert("OracleAggregator: invalid oracle type");
        aggregator.updateOracleAddress(3, address(0x123));
    }

    function test_UpdateOracleAddressRevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("OracleAggregator: invalid address");
        aggregator.updateOracleAddress(0, address(0));
    }

    function test_UpdateOracleAddressRevertsIfNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        aggregator.updateOracleAddress(0, address(0x123));
    }

    /* ============ Pause/Unpause Tests ============ */

    function test_PauseByAdmin() public {
        vm.prank(admin);
        aggregator.pause();

        assertTrue(aggregator.paused());
    }

    function test_PauseRevertsIfNotAdmin() public {
        vm.prank(user);
        vm.expectRevert();
        aggregator.pause();
    }

    function test_UnpauseByAdmin() public {
        vm.startPrank(admin);
        aggregator.pause();
        aggregator.unpause();
        vm.stopPrank();

        assertFalse(aggregator.paused());
    }

    function test_UnpauseRevertsIfNotAdmin() public {
        vm.prank(admin);
        aggregator.pause();

        vm.prank(user);
        vm.expectRevert();
        aggregator.unpause();
    }

    function test_UpdateTWAPRevertsWhenPaused() public {
        vm.prank(admin);
        aggregator.pause();

        vm.expectRevert();
        aggregator.updateTwap();
    }

    function test_GetGoldPriceRevertsWhenPaused() public {
        // First set a price
        aggregator.updateTwap();

        vm.prank(admin);
        aggregator.pause();

        vm.expectRevert();
        aggregator.getGoldPrice();
    }

    function test_GetGoldPriceRevertsWithNoData() public {
        vm.expectRevert("OracleAggregator: no price data available");
        aggregator.getGoldPrice();
    }

    /* ============ Price History Tests ============ */

    function test_GetPriceHistoryLength() public {
        assertEq(aggregator.getPriceHistoryLength(), 0);

        aggregator.updateTwap();
        assertEq(aggregator.getPriceHistoryLength(), 1);

        vm.warp(block.timestamp + 100);
        aggregator.updateTwap();
        assertEq(aggregator.getPriceHistoryLength(), 2);
    }

    function test_GetPriceHistory() public {
        aggregator.updateTwap();

        (uint256 price, uint256 timestamp) = aggregator.getPriceHistory(0);
        assertEq(price, GOLD_PRICE);
        assertEq(timestamp, block.timestamp);
    }

    function test_GetPriceHistoryRevertsOutOfBounds() public {
        vm.expectRevert("OracleAggregator: index out of bounds");
        aggregator.getPriceHistory(0);
    }

    /* ============ Integration Tests ============ */

    function test_CompleteWorkflow() public {
        // 1. Initial price update
        aggregator.updateTwap();
        (uint256 price1,) = aggregator.getGoldPrice();
        assertEq(price1, GOLD_PRICE);

        // 2. Wait and update with small price change
        vm.warp(block.timestamp + 300);
        uint256 newPrice = GOLD_PRICE * 102 / 100; // 2% increase
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));

        aggregator.updateTwap();

        // Wait a bit more so the new price has weight in TWAP
        vm.warp(block.timestamp + 100);
        aggregator.updateTwap();
        (uint256 price2,) = aggregator.getGoldPrice();
        assertGt(price2, price1);

        // 3. Admin adjusts thresholds
        vm.prank(admin);
        aggregator.setPriceDeviation(300);

        // 4. Continue updating
        vm.warp(block.timestamp + 300);
        aggregator.updateTwap();

        // Should work without issues
        assertFalse(aggregator.paused());
    }

    /* ============ Price Normalization Tests ============ */

    function test_PriceNormalizationChainlink() public {
        // Chainlink uses 8 decimals - should not change
        aggregator.updateTwap();
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    function test_PriceNormalizationBandAndAPI3() public {
        // Band and API3 use 18 decimals - should normalize to 8
        // Disable Chainlink to test only Band and API3
        chainlinkOracle.setShouldFail(true);

        aggregator.updateTwap();
        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }

    /* ============ Fuzz Tests ============ */

    function _setAllFeeds(uint256 p1, uint256 p2, uint256 p3) internal {
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(p1));
        bandOracle.setReferenceData(p2 * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(p3 * 1e10)));
    }

    /// @dev With all sources within the 2% deviation threshold, the aggregated
    ///      price must be the arithmetic mean of the three normalized feeds
    function testFuzz_AggregationIsAverageWithinDeviation(uint256 base, uint256 d1, uint256 d2) public {
        base = bound(base, 1_000e8, 5_000e8);
        // Keep total spread well under the 2% deviation threshold
        d1 = bound(d1, 0, base / 200); // +0.5% max
        d2 = bound(d2, 0, base / 200);

        _setAllFeeds(base, base + d1, base + d2);
        aggregator.updateTwap();

        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, (base + (base + d1) + (base + d2)) / 3);
    }

    /// @dev Any single-update move strictly above the 5% circuit breaker
    ///      threshold must pause the aggregator; moves at or below must not
    function testFuzz_CircuitBreakerBoundary(uint256 movePctBps, bool up) public {
        // 0..2000 bps (0-20%) move
        movePctBps = bound(movePctBps, 0, 2000);

        aggregator.updateTwap(); // seed at GOLD_PRICE

        uint256 newPrice =
            up ? GOLD_PRICE * (10_000 + movePctBps) / 10_000 : GOLD_PRICE * (10_000 - movePctBps) / 10_000;

        _setAllFeeds(newPrice, newPrice, newPrice);
        vm.warp(block.timestamp + 601);
        aggregator.updateTwap();

        if (movePctBps > 500) {
            assertTrue(aggregator.paused());
        } else {
            assertFalse(aggregator.paused());
        }
    }

    /// @dev A constant price across any sequence of update intervals must leave
    ///      the TWAP exactly at that price (no drift from window maintenance)
    function testFuzz_TwapStableUnderConstantPrice(uint256 interval, uint8 updates) public {
        interval = bound(interval, 60, 2 hours);
        uint256 n = bound(updates, 1, 10);

        for (uint256 i = 0; i < n; i++) {
            vm.warp(block.timestamp + interval);
            _setAllFeeds(GOLD_PRICE, GOLD_PRICE, GOLD_PRICE);
            aggregator.updateTwap();
        }

        (uint256 price,) = aggregator.getGoldPrice();
        assertEq(price, GOLD_PRICE);
    }
}
