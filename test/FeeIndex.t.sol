// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeIndex} from "../src/libraries/FeeIndex.sol";
import {FeeIndexHarness} from "./mocks/FeeIndexHarness.sol";

/// @notice The holding fee curve and index of D53.
/// @dev The curve is checked against a reference computed at one extra unit of
///      scale, 1e36 rather than 1e18, floored at every step. That reference is
///      under the exact curve by at most a handful of units of 1e-36, which is
///      far below one wei at 1e18, so asserting the library is at or above it
///      is the D29 claim that the rate never understates what is owed.
///
///      The bound on the other side is stated rather than guessed: `u` and the
///      curve's input each round up by at most one wei, and the power rounds up
///      once per exponent, so the rate can sit at most `n + 4` wei above exact.
///      A wei of `u` moves the result by less than a wei, because the span
///      between the floor and the cap is under one unit of scale.
///
///      No value here is a proposal: the parameters are open under O5 and these
///      are test figures. The floor is written as the D42 placeholder so the
///      numbers in the assertions are recognisable.
contract FeeIndexTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant SCALE = 1e36;
    uint256 private constant YEAR = 365 * 86_400;
    uint256 private constant NOTHING = 0;
    uint256 private constant ONE_WEI = 1;

    /// @dev 8.94% a year, the D42 placeholder floor, and 30% as a test cap.
    uint256 private constant FLOOR = 0.0894e18;
    uint256 private constant CAP = 0.3e18;
    uint256 private constant U_MAX = 0.8e18;
    uint256 private constant EXPONENT = 2;
    uint256 private constant MAX_EXPONENT = 4;
    /// @dev A square curve at half of u_max leaves a quarter of the span, and
    ///      the same number is the quarter year the linearity test steps by.
    uint256 private constant QUARTER = 4;
    /// @dev The bound of the test's own NatSpec, per exponent.
    uint256 private constant SLACK_PER_EXPONENT = 4;

    uint256 private constant START = 1_783_900_800;
    uint256 private constant POOL = 1000 ether;
    uint256 private constant SIZE = 10 ether;
    uint256 private constant HALF_U = 500 ether;

    FeeIndexHarness private book;

    function setUp() public {
        book = new FeeIndexHarness(_params(EXPONENT), START);
    }

    function test_ConstructorValidatesTheCurve() public {
        FeeIndex.Params memory bad = _params(EXPONENT);

        bad.floorRate = NOTHING;
        vm.expectRevert(FeeIndex.ZeroFloorRate.selector);
        new FeeIndexHarness(bad, START);

        bad = _params(EXPONENT);
        bad.capRate = FLOOR - ONE_WEI;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.CapBelowFloor.selector, FLOOR - ONE_WEI, FLOOR));
        new FeeIndexHarness(bad, START);

        bad = _params(EXPONENT);
        bad.uMax = NOTHING;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.UMaxOutOfRange.selector, NOTHING));
        new FeeIndexHarness(bad, START);

        bad = _params(EXPONENT);
        bad.uMax = WAD + ONE_WEI;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.UMaxOutOfRange.selector, WAD + ONE_WEI));
        new FeeIndexHarness(bad, START);

        bad = _params(EXPONENT);
        bad.exponent = NOTHING;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.ExponentOutOfRange.selector, NOTHING));
        new FeeIndexHarness(bad, START);

        bad = _params(EXPONENT);
        bad.exponent = MAX_EXPONENT + 1;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.ExponentOutOfRange.selector, MAX_EXPONENT + 1));
        new FeeIndexHarness(bad, START);
    }

    /// @dev A cap equal to the floor is a flat curve, which is allowed: it is
    ///      the D42 floor with no rise, and the owner may choose it.
    function test_AFlatCurveIsAllowed() public {
        FeeIndex.Params memory flat = _params(EXPONENT);
        flat.capRate = FLOOR;
        FeeIndexHarness level = new FeeIndexHarness(flat, START);

        assertEq(level.rate(NOTHING, POOL), FLOOR, "a flat curve did not start at the floor");
        assertEq(level.rate(POOL, POOL), FLOOR, "a flat curve rose above the floor");
    }

    function test_TheCurveStartsAtTheFloorAndStopsAtTheCap() public view {
        assertEq(book.rate(NOTHING, POOL), FLOOR, "the rate at no reservation was not the floor");
        assertEq(book.rate(NOTHING, NOTHING), FLOOR, "an empty pool did not read as the floor");

        uint256 atUMax = (POOL * U_MAX) / WAD;
        assertEq(book.rate(atUMax, POOL), CAP, "the rate at u_max was not the cap");
        assertEq(book.rate(POOL, POOL), CAP, "the rate at full utilisation was not the cap");
        assertEq(book.rate(POOL * 2, POOL), CAP, "the rate above u_max left the cap");
    }

    /// @dev I19 at the two ends of a single step, with the exact midpoint of a
    ///      square curve worked out by hand: at half of u_max the squared term
    ///      is a quarter, so the rate is the floor plus a quarter of the span.
    function test_TheCurveRisesWithUtilisation() public view {
        uint256 halfOfUMax = (POOL * U_MAX) / WAD / 2;
        uint256 expected = FLOOR + (CAP - FLOOR) / QUARTER;

        assertEq(book.rate(halfOfUMax, POOL), expected, "the square curve missed its own midpoint");
        assertGt(book.rate(halfOfUMax, POOL), book.rate(NOTHING, POOL), "the rate did not rise off the floor");
        assertLt(book.rate(halfOfUMax, POOL), CAP, "the rate reached the cap early");
    }

    function testFuzz_TheRateNeverFallsAsUtilisationRises(uint256 lowSeed, uint256 highSeed, uint8 exponentSeed)
        public
    {
        uint256 exponent = bound(exponentSeed, 1, MAX_EXPONENT);
        FeeIndexHarness curve = new FeeIndexHarness(_params(exponent), START);

        uint256 low = bound(lowSeed, NOTHING, POOL);
        uint256 high = bound(highSeed, low, POOL);

        assertLe(curve.rate(low, POOL), curve.rate(high, POOL), "I19: the rate fell as utilisation rose");
        assertGe(curve.rate(low, POOL), FLOOR, "the rate fell under the floor");
        assertLe(curve.rate(high, POOL), CAP, "the rate rose above the cap");
    }

    function testFuzz_TheRateIsAtOrAboveTheExactCurve(uint256 reservedSeed, uint8 exponentSeed) public {
        uint256 exponent = bound(exponentSeed, 1, MAX_EXPONENT);
        FeeIndexHarness curve = new FeeIndexHarness(_params(exponent), START);
        uint256 reserved = bound(reservedSeed, NOTHING, POOL * 2);

        uint256 computed = curve.rate(reserved, POOL);
        uint256 exact = _exactRate(reserved, POOL, exponent);
        uint256 slack = (exponent + SLACK_PER_EXPONENT) * WAD;

        assertGe(computed * WAD, exact, "the rate fell under its exact value");
        assertLe(computed * WAD, exact + slack, "the rate rose further above exact than the bound");
    }

    function test_TheIndexStartsWhereItIsToldAndNeverFallsBack() public {
        assertEq(book.lastAdvance(), START, "the index did not start at the timestamp it was given");
        assertEq(book.value(), NOTHING);

        uint256 afterYear = book.advance(HALF_U, POOL, START + YEAR);
        assertGt(afterYear, NOTHING, "a year of accrual added nothing");
        assertEq(book.value(), afterYear, "the advance returned something other than the new index");

        assertEq(
            book.advance(HALF_U, POOL, START + YEAR), afterYear, "an advance to the same timestamp moved the index"
        );

        vm.expectRevert(abi.encodeWithSelector(FeeIndex.TimeWentBackwards.selector, START, START + YEAR));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        book.advance(HALF_U, POOL, START);
    }

    /// @dev One year at a constant utilisation accrues exactly the yearly rate,
    ///      so the fee on a position is its size times that rate.
    function test_AYearAtOneUtilisationCostsTheYearlyRate() public {
        uint256 rateAtHalf = book.rate(HALF_U, POOL);

        assertEq(book.advance(HALF_U, POOL, START + YEAR), rateAtHalf, "a year did not accrue the yearly rate");
        assertEq((SIZE * book.value()) / WAD, (SIZE * rateAtHalf) / WAD, "the fee was not size times the rate");
    }

    function test_AccrualIsLinearInElapsedTime() public {
        uint256 step = YEAR / QUARTER;
        uint256 afterOne = book.advance(HALF_U, POOL, START + step);
        // The step is a quarter of a year by construction, so dividing before
        // multiplying is what makes the two legs equal. Multiplying first would
        // compare a half year against two unequal quarters.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 afterTwo = book.advance(HALF_U, POOL, START + step * 2);

        assertApproxEqAbs(afterTwo, afterOne * 2, ONE_WEI, "two equal steps were not twice one step");
    }

    /// @dev Splitting an interval cannot lose the protocol anything: the split
    ///      path is at or above the single path, by at most the one wei each
    ///      extra rounding adds, and never under the exact accrual.
    function test_SplittingAnIntervalNeverAccruesLess() public {
        uint256 first = YEAR / 3;
        uint256 whole = YEAR / 2;

        FeeIndexHarness single = new FeeIndexHarness(_params(EXPONENT), START);
        uint256 once = single.advance(HALF_U, POOL, START + whole);

        // The first leg's value is not the claim; the value after both is.
        // forge-lint: disable-next-line(unused-return)
        book.advance(HALF_U, POOL, START + first);
        uint256 split = book.advance(HALF_U, POOL, START + whole);

        uint256 rateAtHalf = book.rate(HALF_U, POOL);
        assertGe(split, once, "the split path accrued less than the single path");
        assertLe(split, once + ONE_WEI, "the split path drifted past one wei");
        // Both sides are multiplied out, which is how the exact accrual is
        // compared without dividing: the interval itself was defined as a
        // fraction of a year, and that is the division the rule sees.
        // forge-lint: disable-next-line(divide-before-multiply)
        assertGe(split * YEAR, rateAtHalf * whole, "the split path fell under the exact accrual");
        // forge-lint: disable-next-line(divide-before-multiply)
        assertGe(once * YEAR, rateAtHalf * whole, "the single path fell under the exact accrual");
    }

    /// @dev The arithmetic limits the library states, at the limits themselves.
    ///      The rate multiplies the reservation by one unit of scale, and the
    ///      index multiplies the rate by the elapsed seconds.
    function test_TheStatedArithmeticLimitsHold() public {
        uint256 widestReserved = type(uint256).max / WAD;
        assertEq(book.rate(widestReserved, ONE_WEI), CAP, "the widest reservation did not read as the cap");

        uint256 longestElapsed = type(uint256).max / CAP;
        FeeIndexHarness long = new FeeIndexHarness(_params(EXPONENT), NOTHING);

        // The elapsed time is the widest the cap allows, which is itself a
        // division by the cap, and multiplying it back by the cap is the whole
        // point of the limit.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 expected = _ceilDiv(CAP * longestElapsed, YEAR);

        assertEq(long.advance(POOL, POOL, longestElapsed), expected, "the longest interval did not accrue exactly");
        assertEq(long.lastAdvance(), longestElapsed);
    }

    function _params(uint256 exponent) private pure returns (FeeIndex.Params memory) {
        return FeeIndex.Params({floorRate: FLOOR, capRate: CAP, uMax: U_MAX, exponent: exponent});
    }

    /// @dev The curve at one extra unit of scale, floored at every step, which
    ///      puts it at or just under the exact value.
    function _exactRate(uint256 reserved, uint256 poolOunces, uint256 exponent) private pure returns (uint256) {
        if (poolOunces == 0 || reserved == 0) {
            return FLOOR * WAD;
        }

        uint256 uMaxScaled = U_MAX * WAD;
        uint256 u = (reserved * SCALE) / poolOunces;
        // The curve is defined on u, so u is computed first and then scaled
        // against u_max. Folding the two divisions together would compute a
        // different curve from the one D53 states.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 x = u >= uMaxScaled ? SCALE : (u * SCALE) / uMaxScaled;

        uint256 span = (CAP - FLOOR) * WAD;
        for (uint256 i = 0; i < exponent; i++) {
            span = (span * x) / SCALE;
        }

        return FLOOR * WAD + span;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }
}
