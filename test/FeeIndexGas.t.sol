// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {FeeIndex} from "../src/libraries/FeeIndex.sol";
import {FeeIndexHarness} from "./mocks/FeeIndexHarness.sol";

/// @notice What one fee index operation costs (D53, O5).
/// @dev Same conditions as the claim book table: foundry runs with isolation
///      on, so every call is its own transaction, no access list carries over
///      and every read is a cold read. The first advance writes the index and
///      the timestamp into slots that were written once at construction, so it
///      pays the lower price for a slot that already holds a value; the figures
///      are reported for n of one and n of four, which is the whole range the
///      exponent may take.
contract FeeIndexGasTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant YEAR = 365 * 86_400;
    uint256 private constant FLOOR = 0.0894e18;
    uint256 private constant CAP = 0.3e18;
    uint256 private constant U_MAX = 0.8e18;
    uint256 private constant START = 1_783_900_800;
    uint256 private constant POOL = 1000 ether;
    uint256 private constant HALF_U = 500 ether;
    uint256 private constant LINEAR = 1;
    uint256 private constant QUARTIC = 4;

    /// @dev The first advance writes the index from zero, so it pays for one
    ///      fresh slot at 20000 where a later one pays 5000 for a slot that
    ///      already holds a value. The ceiling is stated above the measured
    ///      first advance rather than fitted to it.
    uint256 private constant ADVANCE_CEILING = 70_000;
    uint256 private constant RATE_CEILING = 20_000;

    function test_GasForEveryOperation() public {
        FeeIndexHarness linear = new FeeIndexHarness(_params(LINEAR), START);
        FeeIndexHarness quartic = new FeeIndexHarness(_params(QUARTIC), START);

        uint256 rateLinear = _rate(linear, HALF_U, POOL);
        uint256 rateQuartic = _rate(quartic, HALF_U, POOL);
        uint256 rateAtCap = _rate(quartic, POOL, POOL);
        uint256 rateAtFloor = _rate(quartic, 0, POOL);

        uint256 firstLinear = _advance(linear, HALF_U, POOL, START + YEAR);
        uint256 laterLinear = _advance(linear, HALF_U, POOL, START + YEAR * 2);
        uint256 firstQuartic = _advance(quartic, HALF_U, POOL, START + YEAR);
        uint256 laterQuartic = _advance(quartic, HALF_U, POOL, START + YEAR * 2);
        uint256 noMove = _advance(quartic, HALF_U, POOL, START + YEAR * 2);

        console2.log("rate     n = 1, u under u_max   ", rateLinear);
        console2.log("rate     n = 4, u under u_max   ", rateQuartic);
        console2.log("rate     n = 4, u above u_max   ", rateAtCap);
        console2.log("rate     n = 4, nothing reserved", rateAtFloor);
        console2.log("advance  n = 1, first           ", firstLinear);
        console2.log("advance  n = 1, later           ", laterLinear);
        console2.log("advance  n = 4, first           ", firstQuartic);
        console2.log("advance  n = 4, later           ", laterQuartic);
        console2.log("advance  n = 4, same timestamp  ", noMove);

        assertLt(firstQuartic, ADVANCE_CEILING, "an advance cost more than the stated ceiling");
        assertLt(rateQuartic, RATE_CEILING, "a rate read cost more than the stated ceiling");
        assertLt(noMove, laterQuartic, "an advance that changed nothing cost as much as one that did");
        assertLt(rateLinear, rateQuartic, "the linear curve was not cheaper than the quartic one");
    }

    function _params(uint256 exponent) private pure returns (FeeIndex.Params memory) {
        return FeeIndex.Params({floorRate: FLOOR, capRate: CAP, uMax: U_MAX, exponent: exponent});
    }

    function _rate(FeeIndexHarness book, uint256 reserved, uint256 poolOunces) private view returns (uint256) {
        uint256 before = gasleft();
        // The measurement is the point of the call, so the value it returns is
        // read and dropped on purpose.
        // forge-lint: disable-next-line(unused-return)
        book.rate(reserved, poolOunces);
        return before - gasleft();
    }

    function _advance(FeeIndexHarness book, uint256 reserved, uint256 poolOunces, uint256 asOf)
        private
        returns (uint256)
    {
        uint256 before = gasleft();
        // forge-lint: disable-next-line(unused-return)
        book.advance(reserved, poolOunces, asOf);
        return before - gasleft();
    }
}
