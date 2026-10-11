// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PushFallbackPrice} from "../../src/oracle/PushFallbackPrice.sol";
import {TradingCalendar} from "../../src/oracle/TradingCalendar.sol";
import {MockChainlinkOracle} from "../mocks/MockChainlinkOracle.sol";

/// @notice Drives the push fallback across open hours, closed hours and round
///         ages on both sides of the bound, and records what came back.
/// @dev The invariant cannot see a refusal, only the state after it, so the
///      ghosts here carry what each call returned: the widest age ever
///      accepted, and whether anything was ever accepted while the calendar
///      said closed or from a round dated after the call.
contract PushFallbackHandler is Test {
    uint256 private constant MIN_JUMP = 1 minutes;
    uint256 private constant MAX_JUMP = 30 hours;
    uint256 private constant MAX_PLANTED_AGE = 12 hours;
    int256 private constant MIN_ANSWER = 1;
    int256 private constant MAX_ANSWER = 1e13;

    PushFallbackPrice public immutable FALLBACK;
    TradingCalendar public immutable CALENDAR;
    MockChainlinkOracle public immutable FEED;

    uint256 public successes;
    uint256 public refusals;
    uint256 public maxObservedAge;
    uint256 public successesWhileClosed;
    uint256 public successesFromAFutureRound;
    uint256 public successesWhileOpen;

    constructor(PushFallbackPrice fallbackPrice, MockChainlinkOracle feed) {
        FALLBACK = fallbackPrice;
        CALENDAR = fallbackPrice.CALENDAR();
        FEED = feed;
    }

    function poke(int256 answerSeed, uint256 ageSeed, uint256 jumpSeed) external {
        vm.warp(block.timestamp + bound(jumpSeed, MIN_JUMP, MAX_JUMP));

        int256 answer = bound(answerSeed, MIN_ANSWER, MAX_ANSWER);
        uint256 age = bound(ageSeed, 0, MAX_PLANTED_AGE);
        FEED.setLatestAnswer(answer);
        FEED.setUpdatedAt(block.timestamp - age);

        // The campaign starts in 2026 and walks forward in hours, so the clock
        // stays far below what a uint64 holds.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 asOf = uint64(block.timestamp);
        try FALLBACK.price(asOf) returns (uint256 price18, uint256 updatedAt) {
            successes++;
            assertGt(price18, 0, "a non positive price was returned");
            if (updatedAt > asOf) {
                successesFromAFutureRound++;
            } else if (asOf - updatedAt > maxObservedAge) {
                maxObservedAge = asOf - updatedAt;
            }
            if (CALENDAR.isOpen(asOf)) {
                successesWhileOpen++;
            } else {
                successesWhileClosed++;
            }
        } catch {
            refusals++;
        }
    }
}
