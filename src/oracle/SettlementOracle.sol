// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPyth} from "./interfaces/IPyth.sol";
import {IVerifierProxy} from "./interfaces/IVerifierProxy.sol";
import {ReportV8} from "./ReportV8.sol";

/**
 * @title SettlementOracle
 * @notice Settles one price for one target time from two sources (section 7).
 * @dev Rule 2: the Data Streams report must span the target time, and the Pyth
 *      update must be the first at or after it. Report windows are contiguous
 *      and `parsePriceFeedUpdatesUnique` takes the first update at or after
 *      `minPublishTime`, so neither side leaves the caller a choice of price.
 *
 *      Rule 3: the market test is the report's `marketStatus` alone, and the
 *      two prices must agree inside the deviation band. The band is measured
 *      against the Data Streams price, and that price is what settles, because
 *      D10 makes it primary.
 *
 *      This contract does not read the trading calendar (D61). The holiday list
 *      is edited through the timelock, so a settlement that read it would give
 *      that key the power to stop a close or a liquidation, which D58 denies to
 *      every key. The calendar now gates the D22 push fallback alone, where a
 *      bad edit can at most disable the fallback. The Pyth side needs no market
 *      flag of its own: an update published at or after T cannot settle while
 *      the market was closed at T, because the report for T fails its own
 *      market test first.
 *
 *      Rule 7: the report's own `expiresAt` is checked here, because the
 *      verifier checks expiry only inside a fee manager it may not have.
 *
 *      Rule 8: the caller pays both verification fees and this contract holds
 *      no balance. Anything the two calls do not take goes back to the caller.
 *
 *      The deviation is returned as well as the price, because the circuit
 *      breaker of rule 6 lives in the position and LP contracts and needs it.
 *
 *      There is no setter and no owner. The band, the Pyth delay and the
 *      stream's decimals are constructor arguments: the first two are open in
 *      O5, and the third is per stream because the v8 schema does not carry it.
 */
contract SettlementOracle is ReentrancyGuard {
    /// @notice Denominator for the deviation band, in basis points.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The `marketStatus` value that means open in schema v8.
    uint32 public constant MARKET_OPEN = 2;

    uint256 private constant TARGET_DECIMALS = 18;
    int256 private constant TARGET_DECIMALS_SIGNED = 18;
    uint256 private constant DECIMAL_BASE = 10;
    uint256 private constant ROUND_UP = 1;
    int32 private constant MIN_PYTH_EXPO = -18;
    int32 private constant MAX_PYTH_EXPO = 18;
    uint256 private constant PYTH_FEEDS_REQUESTED = 1;

    IVerifierProxy public immutable VERIFIER;
    IPyth public immutable PYTH;

    /// @notice The Data Streams stream id this settles, whose first two bytes
    ///         are the report version (v8 for an RWA stream).
    bytes32 public immutable FEED_ID;

    /// @notice The Pyth price id for the same asset.
    bytes32 public immutable PYTH_PRICE_ID;

    /// @notice How far the two sources may disagree, in basis points (O5).
    uint256 public immutable DEVIATION_BAND_BPS;

    /// @notice How long after the target time a Pyth update may be published
    ///         and still settle it (O5).
    uint64 public immutable MAX_PYTH_PUBLISH_DELAY;

    /// @notice Multiplier that takes the stream's decimals to 18.
    uint256 public immutable STREAM_SCALE;

    event PriceSettled(uint64 targetTime, uint256 price18, uint256 pythPrice18, uint256 deviationBps);

    error ZeroAddress();
    error ZeroId();
    error UnsupportedDecimals(uint8 streamDecimals);
    error BandTooWide(uint256 bps);
    error ZeroPythDelay();
    error FeeNotPaid(uint256 provided, uint256 pythFee);
    error WrongFeed(bytes32 reported, bytes32 expected);
    error ReportExpired(uint32 expiresAt, uint256 at);
    error ReportNotForTarget(uint32 validFrom, uint32 observations, uint64 targetTime);
    error MarketClosedByReport(uint32 marketStatus);
    error NonPositivePrice(int256 price);
    error UnsupportedExponent(int32 expo);
    error WrongPythFeed(bytes32 reported, bytes32 expected);
    error PythOutsideWindow(uint256 publishTime, uint64 minPublishTime, uint64 maxPublishTime);
    error NoPythFeedReturned();
    error DeviationTooWide(uint256 deviationBps, uint256 band);
    error RefundFailed(address to, uint256 amount);

    constructor(
        address verifier,
        address pyth,
        bytes32 feedId,
        bytes32 pythPriceId,
        uint8 streamDecimals,
        uint256 deviationBandBps,
        uint64 maxPythPublishDelay
    ) {
        if (verifier == address(0) || pyth == address(0)) {
            revert ZeroAddress();
        }
        if (feedId == bytes32(0) || pythPriceId == bytes32(0)) {
            revert ZeroId();
        }
        if (streamDecimals > TARGET_DECIMALS) {
            revert UnsupportedDecimals(streamDecimals);
        }
        // A band of the whole price would accept any disagreement, which is the
        // one value that makes the second source pointless.
        if (deviationBandBps >= BPS_DENOMINATOR) {
            revert BandTooWide(deviationBandBps);
        }
        if (maxPythPublishDelay == 0) {
            revert ZeroPythDelay();
        }

        VERIFIER = IVerifierProxy(verifier);
        PYTH = IPyth(pyth);
        FEED_ID = feedId;
        PYTH_PRICE_ID = pythPriceId;
        DEVIATION_BAND_BPS = deviationBandBps;
        MAX_PYTH_PUBLISH_DELAY = maxPythPublishDelay;
        STREAM_SCALE = DECIMAL_BASE ** (TARGET_DECIMALS - streamDecimals);
    }

    /// @notice Settle the price for `targetTime` from both sources.
    /// @param targetTime The request's target time, T in section 7.
    /// @param streamsPayload The signed Data Streams report for T.
    /// @param pythUpdate The Pyth update data covering T.
    /// @return price18 The settled price, 18 decimals, from Data Streams.
    /// @return deviationBps How far the two sources differed, rounded up.
    function settlePrice(uint64 targetTime, bytes calldata streamsPayload, bytes[] calldata pythUpdate)
        external
        payable
        nonReentrant
        returns (uint256 price18, uint256 deviationBps, uint256 pythPaid)
    {
        uint256 pythFee = PYTH.getUpdateFee(pythUpdate);
        if (msg.value < pythFee) {
            revert FeeNotPaid(msg.value, pythFee);
        }

        ReportV8 memory report = _report(streamsPayload);

        if (report.feedId != FEED_ID) {
            revert WrongFeed(report.feedId, FEED_ID);
        }
        // Rule 7. The verifier's own expiry check sits inside a fee manager it
        // may not have, and the chain's clock is the only reference for expiry
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (report.expiresAt < block.timestamp) {
            // forge-lint: disable-next-line(block-timestamp)
            revert ReportExpired(report.expiresAt, block.timestamp);
        }
        // Rule 2: exactly one report spans T, and this is the test for it.
        if (targetTime < report.validFromTimestamp || targetTime > report.observationsTimestamp) {
            revert ReportNotForTarget(report.validFromTimestamp, report.observationsTimestamp, targetTime);
        }
        // Rule 3, and the whole of the market test (D61).
        if (report.marketStatus != MARKET_OPEN) {
            revert MarketClosedByReport(report.marketStatus);
        }
        if (report.midPrice <= 0) {
            revert NonPositivePrice(report.midPrice);
        }

        // The cast is reached only for a positive price, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        price18 = uint256(int256(report.midPrice)) * STREAM_SCALE;

        uint256 pythPrice18 = _pythPrice18(pythUpdate, targetTime, pythFee);
        deviationBps = _deviationBps(price18, pythPrice18);
        if (deviationBps > DEVIATION_BAND_BPS) {
            revert DeviationTooWide(deviationBps, DEVIATION_BAND_BPS);
        }

        // The event has to follow both verifications, because their prices are
        // what it reports. Nothing reads it on chain, and the guard is held.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PriceSettled(targetTime, price18, pythPrice18, deviationBps);

        // Rule 8: this contract keeps nothing of what the caller put up.
        // Whatever is left of msg.value after the Pyth fee goes back to the
        // caller, and the figure comes from msg.value rather than from this
        // contract's balance. ETH can be forced in with SELFDESTRUCT, and a
        // refund of the balance would then hand the caller more than it sent,
        // which breaks any caller that measures the fee as the fall in its own
        // balance. Stray ETH stays here, where there is no state for it to
        // reach and no code path that reads the balance, and no sweep exists to
        // move it out (D58).
        pythPaid = pythFee;
        uint256 residual = msg.value - pythFee;
        if (residual != 0) {
            // The recipient is the caller, not an address anyone chose, the
            // contract holds no state for a reentrant call to reach, and a raw
            // call is the only way to return value to an address that may be a
            // contract with a receive hook.
            // forge-lint: disable-next-line(arbitrary-send-eth,low-level-calls,reentrancy-eth)
            (bool sent,) = msg.sender.call{value: residual}("");
            if (!sent) {
                revert RefundFailed(msg.sender, residual);
            }
        }
    }

    /// @dev Verify the payload and decode it as a v8 report. No value and no
    ///      parameter bytes: Data Streams bills by subscription, so there is no
    ///      fee to quote and no fee token to name.
    function _report(bytes calldata payload) private returns (ReportV8 memory) {
        // The guard is held across this call, and the verifier is the address
        // this contract was deployed against.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bytes memory response = VERIFIER.verify(payload, "");
        return abi.decode(response, (ReportV8));
    }

    /// @dev The Pyth price for T, scaled to 18 decimals.
    function _pythPrice18(bytes[] calldata updateData, uint64 targetTime, uint256 fee) private returns (uint256) {
        bytes32[] memory ids = new bytes32[](PYTH_FEEDS_REQUESTED);
        ids[0] = PYTH_PRICE_ID;
        uint64 maxPublishTime = targetTime + MAX_PYTH_PUBLISH_DELAY;

        // The guard is held across this call as well, and Pyth's own
        // uniqueness check is what makes the update for T the only one.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IPyth.PriceFeed[] memory feeds =
            PYTH.parsePriceFeedUpdatesUnique{value: fee}(updateData, ids, targetTime, maxPublishTime);
        if (feeds.length != PYTH_FEEDS_REQUESTED) {
            revert NoPythFeedReturned();
        }

        IPyth.Price memory price = feeds[0].price;
        if (feeds[0].id != PYTH_PRICE_ID) {
            revert WrongPythFeed(feeds[0].id, PYTH_PRICE_ID);
        }
        // Pyth enforces this window itself. Checking it again states the rule
        // here rather than leaving it to a dependency, which is what rule 2
        // asks of the consumer.
        if (price.publishTime < targetTime || price.publishTime > maxPublishTime) {
            revert PythOutsideWindow(price.publishTime, targetTime, maxPublishTime);
        }
        if (price.price <= 0) {
            revert NonPositivePrice(price.price);
        }

        return _toWad(price.price, price.expo);
    }

    /// @dev A Pyth price is `price * 10 ** expo`; this restates it at 18
    ///      decimals. The exponent is bounded so the shift cannot need
    ///      rounding, which would lose a part of the price.
    function _toWad(int64 price, int32 expo) private pure returns (uint256) {
        if (expo < MIN_PYTH_EXPO || expo > MAX_PYTH_EXPO) {
            revert UnsupportedExponent(expo);
        }
        int256 shift = int256(expo) + TARGET_DECIMALS_SIGNED;
        // Both casts are reached only for a positive price and a shift the
        // bound above holds between 0 and 36.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(int256(price)) * DECIMAL_BASE ** uint256(shift);
    }

    /// @dev The gap between the two prices against the Data Streams price,
    ///      rounded up, so a deviation on the boundary is refused rather than
    ///      accepted.
    function _deviationBps(uint256 streamsPrice18, uint256 pythPrice18) private pure returns (uint256) {
        uint256 gap = streamsPrice18 > pythPrice18 ? streamsPrice18 - pythPrice18 : pythPrice18 - streamsPrice18;
        return (gap * BPS_DENOMINATOR + streamsPrice18 - ROUND_UP) / streamsPrice18;
    }
}
