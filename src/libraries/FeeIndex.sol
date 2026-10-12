// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title FeeIndex
 * @notice The holding fee rate curve and the cumulative index that turns it
 *         into a per position fee (D53).
 * @dev A position's fee is `s_i * (I_now - I_open,i)` in ounces, so the index
 *      is the only thing that has to be kept up to date: no position is
 *      visited when the rate changes. GMX v1 advances its cumulative funding
 *      rate the same way (`Vault.sol:864-873`, gmx-contracts fe55c4b).
 *
 *      The curve is the gTrade shape D42 names, with a floor and a cap:
 *
 *          rate(u) = floor + (cap - floor) * min(1, u / u_max) ^ n
 *
 *      yearly, with n a whole number from 1 to 4 so no fractional power is
 *      needed on chain. It never falls as u rises (I19), and above u_max,
 *      which a payout can reach by lowering pool ounces, it holds at the cap.
 *
 *      The index advances linearly, without compounding:
 *
 *          I += rate * elapsed seconds / (365 * 86400)
 *
 *      Every division rounds up, so neither the rate nor the index ever
 *      understates what a position owes (D29).
 *
 *      Units: the index and u are scaled by 1e18, the rates are yearly and
 *      scaled by 1e18, so 8.94% a year is 0.0894e18.
 *
 *      Parameters are passed in rather than held here, because the position
 *      manager will hold them as immutables. None of the four has a value in
 *      this file: the floor is the D42 floor and all four are open under O5.
 *
 *      Arithmetic limits, all from the 256 bit word rather than from a choice:
 *      `rate` multiplies reserved by one unit of scale, so reserved must stay
 *      under about 1.15e59 wei of ounces; `advance` multiplies the rate by the
 *      elapsed seconds, so with a cap of 8.94% a year the elapsed time must
 *      stay under about 1.29e59 seconds. Both bounds are tested.
 *
 *      No contract uses this yet.
 */
library FeeIndex {
    /// @notice One unit of the 1e18 scale every figure here carries.
    uint256 internal constant WAD = 1e18;

    /// @notice Seconds in the year the yearly rate is quoted against.
    uint256 internal constant YEAR = 365 * 86_400;

    /// @notice The largest exponent the curve accepts (D53).
    uint256 internal constant MAX_EXPONENT = 4;

    uint256 private constant ROUND_UP = 1;

    /// @notice The curve's parameters, all open under O5.
    /// @param floorRate Yearly rate at u of zero, the D42 floor.
    /// @param capRate Yearly rate at u_max and above.
    /// @param uMax Utilisation the cap is reached at, at most one.
    /// @param exponent n in the curve, a whole number from 1 to 4.
    struct Params {
        uint256 floorRate;
        uint256 capRate;
        uint256 uMax;
        uint256 exponent;
    }

    /// @notice The index and when it last advanced.
    struct Index {
        uint256 value;
        uint256 lastAdvance;
    }

    error ZeroFloorRate();
    error CapBelowFloor(uint256 capRate, uint256 floorRate);
    error UMaxOutOfRange(uint256 uMax);
    error ExponentOutOfRange(uint256 exponent);
    error TimeWentBackwards(uint256 asOf, uint256 lastAdvance);

    /// @notice Refuse a parameter set the curve cannot be built from.
    /// @dev The position manager's constructor calls this once. A zero floor
    ///      would put the rate under the D42 funding floor at low utilisation,
    ///      a cap under the floor would make the curve fall with u and break
    ///      I19, a u_max above one could never be reached, and an exponent
    ///      outside one to four either flattens the curve or needs a power
    ///      this library will not compute.
    ///
    ///      A library entry point whose caller is in another file, which is
    ///      what the rule about a single use counts; inlining saves nothing,
    ///      because an internal library function is compiled into the calling
    ///      contract anyway (D63).
    // forge-lint: disable-next-line(internal-function-used-once)
    function validate(Params memory params) internal pure {
        if (params.floorRate == 0) {
            revert ZeroFloorRate();
        }
        if (params.capRate < params.floorRate) {
            revert CapBelowFloor(params.capRate, params.floorRate);
        }
        if (params.uMax == 0 || params.uMax > WAD) {
            revert UMaxOutOfRange(params.uMax);
        }
        if (params.exponent == 0 || params.exponent > MAX_EXPONENT) {
            revert ExponentOutOfRange(params.exponent);
        }
    }

    /// @notice The yearly rate at the utilisation `reserved` over `poolOunces`.
    /// @dev u and the curve's input both round up, and so does every step of
    ///      the power, so the rate is never under the exact curve (D29). An
    ///      empty pool reads as u of zero and therefore as the floor: there is
    ///      nothing reserved against nothing, and the alternative would be a
    ///      division by zero on a figure the dashboard reads every block.
    /// @param reserved R in ounces.
    /// @param poolOunces Pool ounces the reservation is measured against.
    /// @param params The curve, already validated.
    ///
    ///      One use inside this file, from `advance`, which is what the rule
    ///      counts; the position manager and the D55 dashboard read it from
    ///      another file.
    // forge-lint: disable-next-line(internal-function-used-once)
    function rate(uint256 reserved, uint256 poolOunces, Params memory params) internal pure returns (uint256) {
        if (poolOunces == 0 || reserved == 0) {
            return params.floorRate;
        }

        uint256 u = _ceilDiv(reserved * WAD, poolOunces);
        // The clamp is tested before the scaling, so a utilisation far above
        // u_max cannot overflow the multiply below, and above u_max the rate
        // holds at the cap (D53).
        uint256 x = u >= params.uMax ? WAD : _ceilDiv(u * WAD, params.uMax);

        uint256 span = params.capRate - params.floorRate;
        for (uint256 i = 0; i < params.exponent; i++) {
            span = _ceilDiv(span * x, WAD);
        }

        return params.floorRate + span;
    }

    /// @notice What the index gains over `elapsed` seconds at `rateValue`.
    /// @dev Linear, without compounding, rounded up (D53, D29). One use inside
    ///      this file, from `advance`, and read from another file by anything
    ///      that wants the pending accrual without writing it.
    // forge-lint: disable-next-line(internal-function-used-once)
    function increment(uint256 rateValue, uint256 elapsed) internal pure returns (uint256) {
        return _ceilDiv(rateValue * elapsed, YEAR);
    }

    /// @notice Advance the index to `asOf` at the rate the given utilisation
    ///         implies, and return its new value.
    /// @dev The caller passes `reserved` and `poolOunces` as they stood before
    ///      the state change it is about to make, because the elapsed time was
    ///      spent at that utilisation and not at the one the change produces.
    ///      Advancing after the change would bill the whole interval at the new
    ///      rate. The library cannot check that ordering, so it is the caller's
    ///      duty and the reason every state changing path advances first.
    ///
    ///      A call at the timestamp of the last advance changes nothing, which
    ///      is what lets several operations share one block. A call before it
    ///      reverts rather than running the subtraction backwards.
    ///
    ///      A library entry point whose caller is in another file, as `validate`
    ///      above.
    // forge-lint: disable-next-line(internal-function-used-once)
    function advance(Index storage state, uint256 reserved, uint256 poolOunces, Params memory params, uint256 asOf)
        internal
        returns (uint256)
    {
        uint256 last = state.lastAdvance;
        if (asOf < last) {
            revert TimeWentBackwards(asOf, last);
        }
        if (asOf == last) {
            return state.value;
        }

        uint256 gained = increment(rate(reserved, poolOunces, params), asOf - last);
        uint256 updated = state.value + gained;

        state.value = updated;
        state.lastAdvance = asOf;

        return updated;
    }

    /// @notice Set the timestamp the first advance measures from.
    /// @dev Separate from the constructor because the library has none and the
    ///      index starts at zero, which is a valid value: without this the
    ///      first advance would bill every second since the epoch.
    ///
    ///      A library entry point whose caller is in another file, as above.
    // forge-lint: disable-next-line(internal-function-used-once)
    function start(Index storage state, uint256 asOf) internal {
        state.lastAdvance = asOf;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator + denominator - ROUND_UP) / denominator;
    }
}
