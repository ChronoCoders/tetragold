// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeIndex} from "../src/libraries/FeeIndex.sol";
import {FeeIndexHandler} from "./handlers/FeeIndexHandler.sol";
import {FeeIndexHarness} from "./mocks/FeeIndexHarness.sol";

/// @notice The fee index against an exact shadow, and I19 over every rate the
///         campaign saw (D53, D29).
/// @dev The handler returns early rather than reverting, so a revert in a
///      sequence is a defect.
/// forge-config: default.invariant.fail-on-revert = true
contract FeeIndexInvariantTest is Test {
    uint256 private constant NOTHING = 0;
    uint256 private constant SELECTORS = 3;
    uint256 private constant FLOOR = 0.0894e18;
    uint256 private constant CAP = 0.3e18;
    uint256 private constant U_MAX = 0.8e18;
    uint256 private constant EXPONENT = 3;
    uint256 private constant START = 1_783_900_800;
    uint256 private constant DRIVE_STEP = 30 days;
    uint256 private constant DRIVE_POOL = 2000 ether;

    FeeIndexHarness public harness;
    FeeIndexHandler public handler;

    function setUp() public {
        harness = new FeeIndexHarness(
            FeeIndex.Params({floorRate: FLOOR, capRate: CAP, uMax: U_MAX, exponent: EXPONENT}), START
        );
        handler = new FeeIndexHandler(harness);

        bytes4[] memory selectors = new bytes4[](SELECTORS);
        selectors[0] = FeeIndexHandler.passTime.selector;
        selectors[1] = FeeIndexHandler.moveReserved.selector;
        selectors[2] = FeeIndexHandler.movePool.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice D29: the index is never under the exact accrual.
    function invariant_IndexNeverUnderTheExactAccrual() public view {
        assertEq(handler.indexBelowShadow(), NOTHING, "the index fell under its exact value");
    }

    /// @notice D53: a cumulative index only rises.
    function invariant_IndexNeverFallsBack() public view {
        assertEq(handler.indexWentBackwards(), NOTHING, "the index fell back");
        assertGe(harness.value(), NOTHING);
    }

    /// @notice I19: the rate never falls as utilisation rises, over every pair
    ///         of observations the campaign made.
    function invariant_I19_RateIsMonotonicInUtilisation() public view {
        assertEq(handler.rateInversions(), NOTHING, "I19: the rate fell as utilisation rose");
    }

    /// @notice D42 and D53: the rate stays between the floor and the cap.
    function invariant_RateStaysInsideTheBand() public view {
        assertEq(handler.rateOutOfBand(), NOTHING, "the rate left the band between the floor and the cap");
    }

    /// @dev The assertions above hold on a campaign that did nothing, so this
    ///      drives each step by hand first.
    function test_HandlerReachesEveryStep() public {
        handler.passTime(DRIVE_STEP);
        assertGt(harness.value(), NOTHING, "no time accrued");

        handler.moveReserved(type(uint256).max);
        assertGt(handler.reserved(), NOTHING, "the reservation never moved");

        handler.movePool(DRIVE_POOL);
        assertEq(handler.poolOunces(), DRIVE_POOL, "the pool never moved");

        handler.passTime(DRIVE_STEP);

        assertGt(handler.advances(), 1, "the index advanced only once");
        assertGt(handler.seenCount(), 1, "the campaign saw only one rate");
        assertEq(handler.indexBelowShadow(), NOTHING, "the index fell under exact during the drive");
        assertEq(handler.rateInversions(), NOTHING, "I19 broke during the drive");
    }
}
