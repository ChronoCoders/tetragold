// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PushFallbackPrice} from "../src/oracle/PushFallbackPrice.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";

contract PushFallbackPriceTest is Test {
    uint8 private constant FEED_DECIMALS = 8;
    uint8 private constant TOO_MANY_DECIMALS = 19;
    uint64 private constant MAX_AGE = 6 hours;
    /// @dev 2026-07-15 12:00 UTC, a Wednesday with the market open.
    uint64 private constant OPEN_INSTANT = 1_784_116_800;
    /// @dev 2026-03-14 12:00 UTC, a Saturday.
    uint64 private constant CLOSED_INSTANT = 1_773_489_600;
    int256 private constant ANSWER = 4100e8;
    uint256 private constant ANSWER_18 = 4100 ether;
    uint256 private constant NOTHING = 0;

    PushFallbackPrice public fallbackPrice;
    TradingCalendar public calendar;
    MockChainlinkOracle public feed;

    address public timelock;

    function setUp() public {
        timelock = makeAddr("timelock");
        calendar = new TradingCalendar(timelock);
        feed = new MockChainlinkOracle(FEED_DECIMALS);
        fallbackPrice = new PushFallbackPrice(address(feed), address(calendar), MAX_AGE);

        vm.warp(OPEN_INSTANT);
        feed.setLatestAnswer(ANSWER);
    }

    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(PushFallbackPrice.ZeroAddress.selector);
        new PushFallbackPrice(address(0), address(calendar), MAX_AGE);

        vm.expectRevert(PushFallbackPrice.ZeroAddress.selector);
        new PushFallbackPrice(address(feed), address(0), MAX_AGE);

        vm.expectRevert(PushFallbackPrice.ZeroMaxAge.selector);
        new PushFallbackPrice(address(feed), address(calendar), NOTHING);
    }

    function test_ConstructorRejectsAFeedWithMoreThan18Decimals() public {
        MockChainlinkOracle wide = new MockChainlinkOracle(TOO_MANY_DECIMALS);
        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.UnsupportedDecimals.selector, TOO_MANY_DECIMALS));
        new PushFallbackPrice(address(wide), address(calendar), MAX_AGE);
    }

    function test_FreshRoundInOpenHoursScalesTo18Decimals() public view {
        (uint256 price18, uint256 updatedAt) = fallbackPrice.price();

        assertEq(price18, ANSWER_18, "the 8 decimal answer did not scale to 18");
        assertEq(updatedAt, OPEN_INSTANT);
    }

    function test_RoundAtTheAgeBoundIsAccepted() public {
        vm.warp(OPEN_INSTANT + MAX_AGE);

        (uint256 price18, uint256 updatedAt) = fallbackPrice.price();

        assertEq(price18, ANSWER_18, "a round exactly at the bound was refused");
        assertEq(updatedAt, OPEN_INSTANT);
    }

    function test_RoundOneSecondPastTheBoundIsRefused() public {
        uint64 asOf = OPEN_INSTANT + MAX_AGE + 1;
        vm.warp(asOf);

        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.RoundTooOld.selector, OPEN_INSTANT, asOf, MAX_AGE));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }

    function test_ClosedMarketIsRefusedEvenWithAFreshRound() public {
        vm.warp(CLOSED_INSTANT);
        feed.setLatestAnswer(ANSWER);

        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.MarketClosed.selector, uint256(CLOSED_INSTANT)));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }

    function test_HolidayIsRefusedEvenWithAFreshRound() public {
        vm.prank(timelock);
        calendar.addHoliday(OPEN_INSTANT);

        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.MarketClosed.selector, uint256(OPEN_INSTANT)));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }

    function test_IncompleteRoundIsRefused() public {
        feed.setUpdatedAt(NOTHING);

        vm.expectRevert(PushFallbackPrice.IncompleteRound.selector);
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }

    function test_RoundInTheFutureIsRefused() public {
        uint256 ahead = uint256(OPEN_INSTANT) + 1;
        feed.setUpdatedAt(ahead);

        vm.expectRevert(
            abi.encodeWithSelector(PushFallbackPrice.RoundInTheFuture.selector, ahead, uint256(OPEN_INSTANT))
        );
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }

    function test_NonPositiveAnswerIsRefused() public {
        feed.setLatestAnswer(0);

        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.NonPositivePrice.selector, int256(0)));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();

        feed.setLatestAnswer(-1);

        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.NonPositivePrice.selector, int256(-1)));
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price();
    }
}
