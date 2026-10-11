// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {TradingCalendar} from "./TradingCalendar.sol";

/**
 * @title PushFallbackPrice
 * @notice The price half of the D22 keeper fallback: the current Chainlink
 *         push round, refused unless it is fresh and the market is open.
 * @dev This reads the single current round, so it offers no choice of price,
 *         which is what lets the fallback be permissionless (D22). It reports
 *         a price and the round's own timestamp; the flag lifecycle, the
 *         fallback delay and the flag expiry live in the liquidation contract.
 *
 *      The age bound exists because neither the feed's deviation threshold nor
 *      its heartbeat is enforced on chain. D22 sets it at 6 hours, above the
 *      p99 open market update interval of 344 minutes and below the maximum of
 *      790 minutes (11.10), so the fallback is unavailable in the longest quiet
 *      spells and that cost is accepted.
 *
 *      Nothing here reads `block.timestamp`. The caller passes the instant it
 *      is acting at, so what this returns is a function of its argument, the
 *      feed and the calendar.
 */
contract PushFallbackPrice {
    uint256 private constant TARGET_DECIMALS = 18;

    /// @notice The Chainlink push feed, XAU/USD on Ethereum (11.4).
    IChainlinkAggregator public immutable FEED;

    /// @notice The market hours this fallback obeys.
    TradingCalendar public immutable CALENDAR;

    /// @notice How old the round may be, 6 hours under D22.
    uint256 public immutable MAX_AGE;

    /// @notice Multiplier that takes the feed's decimals to 18.
    uint256 public immutable SCALE;

    error ZeroAddress();
    error ZeroMaxAge();
    error UnsupportedDecimals(uint8 feedDecimals);
    error MarketClosed(uint256 asOf);
    error IncompleteRound();
    error RoundInTheFuture(uint256 updatedAt, uint256 asOf);
    error RoundTooOld(uint256 updatedAt, uint256 asOf, uint256 maxAge);
    error NonPositivePrice(int256 answer);

    constructor(address feed, address calendar, uint256 maxAge) {
        if (feed == address(0) || calendar == address(0)) {
            revert ZeroAddress();
        }
        if (maxAge == 0) {
            revert ZeroMaxAge();
        }
        uint8 feedDecimals = IChainlinkAggregator(feed).decimals();
        if (feedDecimals > TARGET_DECIMALS) {
            revert UnsupportedDecimals(feedDecimals);
        }

        FEED = IChainlinkAggregator(feed);
        CALENDAR = TradingCalendar(calendar);
        MAX_AGE = maxAge;
        SCALE = 10 ** (TARGET_DECIMALS - feedDecimals);
    }

    /// @notice The current push price now, or a refusal.
    /// @return price18 The price scaled to 18 decimals.
    /// @return updatedAt The round's own timestamp, which the caller records.
    function price() external view returns (uint256 price18, uint256 updatedAt) {
        // Post merge Ethereum fixes block.timestamp to slot time, so it is the
        // clock a fallback can be held to, and the only one no caller picks
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        uint256 asOf = block.timestamp;
        if (!CALENDAR.isOpen(asOf)) {
            revert MarketClosed(asOf);
        }

        // Only the answer and its timestamp carry a rule here; the round id,
        // the start time and the answered round do not appear in D22.
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,, uint256 roundUpdatedAt,) = FEED.latestRoundData();
        if (roundUpdatedAt == 0) {
            revert IncompleteRound();
        }
        // A round dated after the block is a broken feed, and the comparison
        // has to be against the chain's clock for that to mean anything
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (roundUpdatedAt > asOf) {
            revert RoundInTheFuture(roundUpdatedAt, asOf);
        }
        // The age bound of D22 is a statement about now, so the clock is the
        // only reference that cannot be chosen by a caller (same citation).
        // forge-lint: disable-next-line(block-timestamp)
        if (asOf - roundUpdatedAt > MAX_AGE) {
            revert RoundTooOld(roundUpdatedAt, asOf, MAX_AGE);
        }
        if (answer <= 0) {
            revert NonPositivePrice(answer);
        }

        // The cast is reached only for a positive answer, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        price18 = uint256(answer) * SCALE;
        updatedAt = roundUpdatedAt;
    }
}
