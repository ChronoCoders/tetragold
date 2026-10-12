// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeIndex} from "../../src/libraries/FeeIndex.sol";
import {FeeIndexHarness} from "../mocks/FeeIndexHarness.sol";

/// @notice Moves utilisation and time the way the protocol will and keeps an
///         exact shadow of the index.
/// @dev Every move advances the index first, at the utilisation that held over
///      the interval, which is the ordering D53 puts on the caller. The shadow
///      accumulates at one extra unit of scale with every division floored, so
///      it sits at or just under the exact index and the check is that the
///      library is never below it.
///
///      Each rate the campaign sees is kept with its utilisation, and every new
///      observation is compared against all of them, so I19 is checked across
///      the whole sequence rather than between neighbours.
contract FeeIndexHandler is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE = 1e36;
    uint256 private constant YEAR = 365 * 86_400;
    uint256 private constant MIN_POOL = 1 ether;
    uint256 private constant MAX_POOL = 100_000 ether;
    uint256 private constant MAX_STEP = 90 days;

    struct Seen {
        uint256 utilisation;
        uint256 rate;
    }

    FeeIndexHarness public immutable BOOK;
    uint256 public immutable FLOOR;
    uint256 public immutable CAP;
    uint256 public immutable U_MAX;
    uint256 public immutable EXPONENT;

    Seen[] private _seen;

    uint256 public reserved;
    uint256 public poolOunces = 1000 ether;

    /// @notice The index at one extra unit of scale, floored at every step.
    uint256 public shadow;

    uint256 public advances;
    uint256 public poolMoves;
    uint256 public reserveMoves;

    uint256 public indexBelowShadow;
    uint256 public indexWentBackwards;
    uint256 public rateInversions;
    uint256 public rateOutOfBand;

    constructor(FeeIndexHarness harness) {
        BOOK = harness;
        FeeIndex.Params memory curve = harness.params();
        FLOOR = curve.floorRate;
        CAP = curve.capRate;
        U_MAX = curve.uMax;
        EXPONENT = curve.exponent;
    }

    function seenCount() external view returns (uint256) {
        return _seen.length;
    }

    /// @dev Time only moves forward, as a block timestamp does.
    function passTime(uint256 seconds_) external {
        uint256 step = bound(seconds_, 1, MAX_STEP);
        _advanceTo(BOOK.lastAdvance() + step);
    }

    function moveReserved(uint256 seed) external {
        _advanceTo(BOOK.lastAdvance());
        reserved = bound(seed, 0, poolOunces);
        reserveMoves += 1;
        _observe();
    }

    /// @dev A payout can lower pool ounces under the reservation, which is how
    ///      u passes u_max (D53), so the floor here is one wei rather than the
    ///      reservation.
    function movePool(uint256 seed) external {
        _advanceTo(BOOK.lastAdvance());
        poolOunces = bound(seed, MIN_POOL, MAX_POOL);
        poolMoves += 1;
        _observe();
    }

    function _advanceTo(uint256 asOf) private {
        uint256 last = BOOK.lastAdvance();
        uint256 before = BOOK.value();
        uint256 rateNow = BOOK.rate(reserved, poolOunces);

        // The ghosts follow the call because the call is what they mirror, and
        // the harness calls nothing back.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 updated = BOOK.advance(reserved, poolOunces, asOf);
        advances += 1;

        if (updated < before) {
            indexWentBackwards += 1;
        }
        shadow += (rateNow * WAD * (asOf - last)) / YEAR;
        if (updated * WAD < shadow) {
            indexBelowShadow += 1;
        }

        _observe();
    }

    function _observe() private {
        uint256 rateNow = BOOK.rate(reserved, poolOunces);
        uint256 utilisation = poolOunces == 0 ? 0 : (reserved * WAD + poolOunces - 1) / poolOunces;

        if (rateNow < FLOOR || rateNow > CAP) {
            rateOutOfBand += 1;
        }

        for (uint256 i = 0; i < _seen.length; i++) {
            Seen memory earlier = _seen[i];
            bool higherUtilisation = utilisation > earlier.utilisation;
            bool lowerRate = rateNow < earlier.rate;
            if (higherUtilisation && lowerRate) {
                rateInversions += 1;
            }
            if (earlier.utilisation > utilisation && earlier.rate < rateNow) {
                rateInversions += 1;
            }
        }

        _seen.push(Seen({utilisation: utilisation, rate: rateNow}));
    }
}
