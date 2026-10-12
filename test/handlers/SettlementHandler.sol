// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../../src/oracle/interfaces/IPyth.sol";
import {ReportV8} from "../../src/oracle/ReportV8.sol";
import {SettlementOracle} from "../../src/oracle/SettlementOracle.sol";

/// @notice Puts reports and updates of every shape in front of the settlement
///         oracle: market status open, closed and unknown, report windows that
///         cover the target time and windows that miss it, Pyth updates before
///         the target, inside the delay and past it, and prices inside and
///         outside the band.
/// @dev Every property is computed here from what this handler built, not from
///      what the call returned, so a contract that checked the wrong thing
///      cannot hide behind its own answer. The clock walks forward in hours so
///      a campaign crosses the daily break and the weekend.
contract SettlementHandler is Test {
    uint32 private constant MIN_JUMP = 1 minutes;
    uint32 private constant JUMP_SPAN = 30 hours;
    uint32 private constant WINDOW_SPAN = 61;
    uint32 private constant STATUS_SPAN = 3;
    uint32 private constant EXPIRY_AHEAD = 86_400;
    /// @dev Tight enough that the accepting path is reached often, wide enough
    ///      that updates before the target and past the delay both appear.
    uint64 private constant PUBLISH_BEFORE = 30;
    uint64 private constant PUBLISH_SPAN = 91;
    int192 private constant BASE_PRICE = 4100e18;
    int64 private constant BASE_PYTH_PRICE = 4100e8;
    int64 private constant SKEW_SPAN = 101;
    int64 private constant BPS_SIGNED = 10_000;
    int32 private constant PYTH_EXPO = -8;
    uint256 private constant FEE_HEADROOM = 3;
    uint32 private constant MARKET_OPEN = 2;
    uint32 private constant MISS_BELOW_EVERY = 4;
    uint32 private constant MISS_ABOVE_EVERY = 5;
    uint32 private constant AFTER_MIXER = 7;

    SettlementOracle public immutable ORACLE;
    bytes32 public immutable FEED_ID;
    bytes32 public immutable PYTH_ID;
    uint256 public immutable FEE;

    uint32 public cursor;

    uint256 public attempts;
    uint256 public successes;
    uint256 public successesWithReportClosed;
    uint256 public successesOutsideReportWindow;
    uint256 public successesWithPythBeforeTarget;
    uint256 public successesWithPythPastDelay;
    uint256 public successesOutsideBand;

    constructor(SettlementOracle oracle, uint32 start, uint256 fee) {
        ORACLE = oracle;
        FEED_ID = oracle.FEED_ID();
        PYTH_ID = oracle.PYTH_PRICE_ID();
        FEE = fee;
        cursor = start;
    }

    /// @dev The seeds are narrow types and the ranges are taken with a modulo
    ///      rather than with `bound`, which works in uint256 and would need a
    ///      truncating cast at every field the report declares narrower.
    function settle(uint32 jumpSeed, uint32 statusSeed, uint32 windowSeed, uint64 publishSeed, int64 skewSeed)
        external
    {
        uint32 target = cursor + MIN_JUMP + (jumpSeed % JUMP_SPAN);
        cursor = target;
        vm.warp(target);

        uint32 status = statusSeed % STATUS_SPAN;
        uint32 before = windowSeed % WINDOW_SPAN;
        uint32 after_ = (windowSeed / AFTER_MIXER) % WINDOW_SPAN;
        uint64 publishTime = target - PUBLISH_BEFORE + (publishSeed % PUBLISH_SPAN);
        int64 skewBps = skewSeed % SKEW_SPAN;
        if (skewBps < 0) {
            skewBps = -skewBps;
        }
        int64 pythPrice = BASE_PYTH_PRICE + (BASE_PYTH_PRICE * skewBps) / BPS_SIGNED;

        ReportV8 memory report = ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: target - before,
            observationsTimestamp: target + after_,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: target + EXPIRY_AHEAD,
            lastUpdateTimestamp: target,
            midPrice: BASE_PRICE,
            marketStatus: status
        });

        // Windows that miss the target on purpose, on both sides. Without the
        // second branch the report window's upper bound is never tested: every
        // other window this builds ends at or after the target, so dropping
        // that bound from the contract changed nothing a campaign could see.
        if (windowSeed % MISS_BELOW_EVERY == 0) {
            report.validFromTimestamp = target + 1;
            report.observationsTimestamp = target + 1 + after_;
        } else if (windowSeed % MISS_ABOVE_EVERY == 0) {
            report.validFromTimestamp = target - before - 1;
            report.observationsTimestamp = target - 1;
        }

        bytes[] memory update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: PYTH_ID,
                price: IPyth.Price({price: pythPrice, conf: 0, expo: PYTH_EXPO, publishTime: publishTime}),
                emaPrice: IPyth.Price({price: pythPrice, conf: 0, expo: PYTH_EXPO, publishTime: publishTime})
            })
        );

        attempts++;
        // The destination is the oracle under test, and the extra wei makes
        // the refund path run on every accepted call.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        try ORACLE.settlePrice{value: FEE + FEE_HEADROOM}(target, abi.encode(report), update) returns (
            uint256 price18, uint256 deviationBps
        ) {
            successes++;
            assertGt(price18, 0, "a settled price was not positive");

            if (status != MARKET_OPEN) {
                successesWithReportClosed++;
            }
            if (target < report.validFromTimestamp || target > report.observationsTimestamp) {
                successesOutsideReportWindow++;
            }
            if (publishTime < target) {
                successesWithPythBeforeTarget++;
            }
            if (publishTime > target + ORACLE.MAX_PYTH_PUBLISH_DELAY()) {
                successesWithPythPastDelay++;
            }
            if (deviationBps > ORACLE.DEVIATION_BAND_BPS()) {
                successesOutsideBand++;
            }
        } catch {
            // Every refusal is expected: the point is which ones get through.
        }
    }

    receive() external payable {}
}
