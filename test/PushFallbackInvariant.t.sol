// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PushFallbackPrice} from "../src/oracle/PushFallbackPrice.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {PushFallbackHandler} from "./handlers/PushFallbackHandler.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";

/// @notice The price half of I24: a fallback price comes only from a round
///         inside the age bound, with the market open (D22, section 8).
/// @dev The flag half of I24, the flag age window and the void on a market
///      close between flag and liquidation, lives in the liquidation contract
///      and is not testable here.
/// @dev The handler catches every refusal, so a revert inside a sequence is a
///      defect rather than a bounds miss.
/// forge-config: default.invariant.fail-on-revert = true
contract PushFallbackInvariantTest is Test {
    uint8 private constant FEED_DECIMALS = 8;
    uint64 private constant MAX_AGE = 6 hours;
    /// @dev 2026-07-13 00:00 UTC, a Monday, so a campaign walks forward from
    ///      inside open hours through the daily break and the weekend.
    uint64 private constant START = 1_783_900_800;
    int256 private constant ANSWER = 4100e8;
    /// @dev 2026-07-18 12:00 UTC, a Saturday.
    uint64 private constant SATURDAY_MIDDAY = 1_784_376_000;

    PushFallbackPrice public fallbackPrice;
    TradingCalendar public calendar;
    MockChainlinkOracle public feed;
    PushFallbackHandler public handler;

    function setUp() public {
        calendar = new TradingCalendar(makeAddr("timelock"));
        feed = new MockChainlinkOracle(FEED_DECIMALS);
        fallbackPrice = new PushFallbackPrice(address(feed), address(calendar), MAX_AGE);

        vm.warp(START);
        feed.setLatestAnswer(ANSWER);

        handler = new PushFallbackHandler(fallbackPrice, feed);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PushFallbackHandler.poke.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_I24_FallbackPriceIsFreshAndOpen() public view {
        assertLe(handler.maxObservedAge(), MAX_AGE, "I24: a price came from a round past the age bound");
        assertEq(handler.successesWhileClosed(), 0, "I24: a price came back while the market was closed");
        assertEq(handler.successesFromAFutureRound(), 0, "I24: a price came from a round dated later");
    }

    /// @dev Every assertion above holds on a campaign that was refused every
    ///      time, so this drives the three outcomes by hand: accepted inside
    ///      the bound, refused past it, refused while closed.
    function test_HandlerReachesEveryOutcome() public {
        uint64 open = START + 1 hours;
        vm.warp(open);
        feed.setLatestAnswer(ANSWER);
        (uint256 price18, uint256 updatedAt) = fallbackPrice.price(open);
        assertGt(price18, 0, "the open and fresh case did not return a price");
        assertEq(updatedAt, open);

        uint64 stale = open + MAX_AGE + 1;
        vm.warp(stale);
        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.RoundTooOld.selector, open, stale, MAX_AGE));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price(stale);

        uint64 closed = SATURDAY_MIDDAY;
        vm.warp(closed);
        feed.setLatestAnswer(ANSWER);
        vm.expectRevert(abi.encodeWithSelector(PushFallbackPrice.MarketClosed.selector, closed));
        // Same here: the refusal is the assertion.
        // forge-lint: disable-next-line(unused-return)
        fallbackPrice.price(closed);
    }
}
