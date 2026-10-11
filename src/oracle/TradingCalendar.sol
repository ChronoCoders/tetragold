// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title TradingCalendar
 * @notice When the precious metals market is open, on chain (D22).
 * @dev Sunday 18:00 to Friday 17:00 America/New_York, with a break every day
 *      from 17:00 to 18:00, plus a holiday list. Chainlink documents those
 *      hours and the three full closures, January 1, Good Friday and
 *      December 25 (11.4). The weekly shape and the United States daylight
 *      saving rule are in code because they never change; the holidays move
 *      and are a list, which only the timelock may edit.
 *
 *      Daylight saving: Eastern time is UTC minus 5 hours, and UTC minus 4
 *      from 02:00 local on the second Sunday in March until 02:00 local on the
 *      first Sunday in November. Those two instants are 07:00 and 06:00 UTC,
 *      which is what this compares against.
 *
 *      A holiday closes the whole Eastern day. That is wider than the venue's
 *      own schedule around a holiday, and wider in the safe direction: a
 *      closed calendar refuses to settle a price.
 *
 *      Nothing here reads `block.timestamp`. The caller passes the instant it
 *      cares about, which is the target time of a request, so the answer is a
 *      pure function of its argument and the holiday list.
 */
contract TradingCalendar {
    uint256 private constant SECONDS_PER_DAY = 86_400;
    uint256 private constant STANDARD_OFFSET = 5 hours;
    uint256 private constant DAYLIGHT_OFFSET = 4 hours;
    uint256 private constant DST_START_UTC_HOUR = 7 hours;
    uint256 private constant DST_END_UTC_HOUR = 6 hours;
    uint256 private constant BREAK_START = 17 hours;
    uint256 private constant BREAK_END = 18 hours;
    uint256 private constant MARCH = 3;
    uint256 private constant NOVEMBER = 11;
    uint256 private constant SECOND_SUNDAY = 2;
    uint256 private constant FIRST_SUNDAY = 1;
    uint256 private constant DAYS_PER_WEEK = 7;
    /// @dev Day 0 of the Unix epoch was a Thursday, so adding 4 puts Sunday at 0.
    uint256 private constant EPOCH_DOW_SHIFT = 4;
    uint256 private constant SUNDAY = 0;
    uint256 private constant FRIDAY = 5;
    uint256 private constant SATURDAY = 6;
    /// @dev Civil date arithmetic after Howard Hinnant's algorithms.
    uint256 private constant ERA_DAY_SHIFT = 719_468;
    uint256 private constant DAYS_PER_ERA = 146_097;
    uint256 private constant DAYS_PER_ERA_LAST = 146_096;
    uint256 private constant DAYS_PER_4_YEARS = 1460;
    uint256 private constant DAYS_PER_CENTURY = 36_524;
    uint256 private constant DAYS_PER_YEAR = 365;
    uint256 private constant YEARS_PER_ERA = 400;
    uint256 private constant MONTH_SHIFT = 153;
    uint256 private constant LEAP_CYCLE = 4;
    uint256 private constant CENTURY = 100;
    uint256 private constant FEBRUARY = 2;
    uint256 private constant MARCH_PIVOT = 3;
    uint256 private constant MONTHS_AFTER_FEBRUARY = 9;
    uint256 private constant MONTH_DIVISOR = 5;
    uint256 private constant MONTH_BIAS = 2;
    uint256 private constant MONTHS_BEFORE_JANUARY = 10;

    /// @notice The only account that may edit the holiday list (D22).
    address public immutable TIMELOCK;

    /// @notice Eastern days the market is closed for, keyed by `etDayOf`.
    mapping(uint256 etDay => bool closed) public closedDays;

    /// @notice How many Eastern days the list holds.
    uint256 public holidayCount;

    event HolidayAdded(uint256 indexed etDay, uint64 timestamp);
    event HolidayRemoved(uint256 indexed etDay, uint64 timestamp);

    error NotTimelock(address caller);
    error AlreadyListed(uint256 etDay);
    error NotListed(uint256 etDay);
    error ZeroAddress();

    constructor(address timelock) {
        if (timelock == address(0)) {
            revert ZeroAddress();
        }
        TIMELOCK = timelock;
    }

    /// @notice Whether the market is open at `timestamp`.
    function isOpen(uint64 timestamp) external view returns (bool) {
        uint256 eastern = _easternSeconds(timestamp);
        if (closedDays[eastern / SECONDS_PER_DAY]) {
            return false;
        }

        uint256 dayOfWeek = (eastern / SECONDS_PER_DAY + EPOCH_DOW_SHIFT) % DAYS_PER_WEEK;
        uint256 secondOfDay = eastern % SECONDS_PER_DAY;

        if (dayOfWeek == SATURDAY) {
            return false;
        }
        if (dayOfWeek == SUNDAY) {
            return secondOfDay >= BREAK_END;
        }
        if (dayOfWeek == FRIDAY) {
            return secondOfDay < BREAK_START;
        }
        return secondOfDay < BREAK_START || secondOfDay >= BREAK_END;
    }

    /// @notice Whether `timestamp` falls on a listed holiday.
    function isHoliday(uint64 timestamp) external view returns (bool) {
        return closedDays[etDayOf(timestamp)];
    }

    /// @notice The Eastern day `timestamp` falls in, which is the holiday key.
    function etDayOf(uint64 timestamp) public pure returns (uint256) {
        return _easternSeconds(timestamp) / SECONDS_PER_DAY;
    }

    /// @notice Close the Eastern day that `timestamp` falls in.
    function addHoliday(uint64 timestamp) external {
        if (msg.sender != TIMELOCK) {
            revert NotTimelock(msg.sender);
        }
        uint256 day = etDayOf(timestamp);
        if (closedDays[day]) {
            revert AlreadyListed(day);
        }
        closedDays[day] = true;
        holidayCount += 1;
        emit HolidayAdded(day, timestamp);
    }

    /// @notice Reopen the Eastern day that `timestamp` falls in.
    function removeHoliday(uint64 timestamp) external {
        if (msg.sender != TIMELOCK) {
            revert NotTimelock(msg.sender);
        }
        uint256 day = etDayOf(timestamp);
        if (!closedDays[day]) {
            revert NotListed(day);
        }
        closedDays[day] = false;
        holidayCount -= 1;
        emit HolidayRemoved(day, timestamp);
    }

    /// @dev Seconds since the epoch shifted into Eastern time.
    function _easternSeconds(uint64 timestamp) private pure returns (uint256) {
        return uint256(timestamp) - (_isDaylightSaving(timestamp) ? DAYLIGHT_OFFSET : STANDARD_OFFSET);
    }

    /// @dev Both transition instants are fixed in UTC: 02:00 standard time is
    ///      07:00 UTC and 02:00 daylight time is 06:00 UTC.
    function _isDaylightSaving(uint64 timestamp) private pure returns (bool) {
        uint256 year = _yearFromDays(uint256(timestamp) / SECONDS_PER_DAY);
        uint256 start = _nthSunday(year, MARCH, SECOND_SUNDAY) * SECONDS_PER_DAY + DST_START_UTC_HOUR;
        uint256 end = _nthSunday(year, NOVEMBER, FIRST_SUNDAY) * SECONDS_PER_DAY + DST_END_UTC_HOUR;
        return timestamp >= start && timestamp < end;
    }

    /// @dev Days since the epoch for the `n`th Sunday of a month.
    function _nthSunday(uint256 year, uint256 month, uint256 n) private pure returns (uint256) {
        uint256 first = _daysFromCivil(year, month, 1);
        uint256 dayOfWeek = (first + EPOCH_DOW_SHIFT) % DAYS_PER_WEEK;
        uint256 firstSunday = first + (DAYS_PER_WEEK - dayOfWeek) % DAYS_PER_WEEK;
        return firstSunday + DAYS_PER_WEEK * (n - 1);
    }

    function _daysFromCivil(uint256 year, uint256 month, uint256 day) private pure returns (uint256) {
        uint256 y = month <= FEBRUARY ? year - 1 : year;
        uint256 era = y / YEARS_PER_ERA;
        // Every division here is exact for the inputs this contract builds,
        // which is why the algorithm divides before it multiplies.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 yearOfEra = y - era * YEARS_PER_ERA;
        uint256 monthPrime = month > FEBRUARY ? month - MARCH_PIVOT : month + MONTHS_AFTER_FEBRUARY;
        uint256 dayOfYear = (MONTH_SHIFT * monthPrime + MONTH_BIAS) / MONTH_DIVISOR + day - 1;
        // The leap day terms are counts of whole days, so the order of the
        // divisions and the multiplication cannot lose a fraction.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 dayOfEra = yearOfEra * DAYS_PER_YEAR + yearOfEra / LEAP_CYCLE - yearOfEra / CENTURY + dayOfYear;
        // era is a whole count of 400 year cycles, so this product is exact.
        // forge-lint: disable-next-line(divide-before-multiply)
        return era * DAYS_PER_ERA + dayOfEra - ERA_DAY_SHIFT;
    }

    function _yearFromDays(uint256 dayCount) private pure returns (uint256) {
        uint256 z = dayCount + ERA_DAY_SHIFT;
        uint256 era = z / DAYS_PER_ERA;
        // era counts whole 400 year cycles, so the product is exact.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 dayOfEra = z - era * DAYS_PER_ERA;
        uint256 yearOfEra =
            (dayOfEra - dayOfEra / DAYS_PER_4_YEARS + dayOfEra / DAYS_PER_CENTURY - dayOfEra / DAYS_PER_ERA_LAST)
                / DAYS_PER_YEAR;
        // Same again: the leap day terms are whole days, not fractions.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 dayOfYear = dayOfEra - (DAYS_PER_YEAR * yearOfEra + yearOfEra / LEAP_CYCLE - yearOfEra / CENTURY);
        uint256 monthPrime = (MONTH_DIVISOR * dayOfYear + MONTH_BIAS) / MONTH_SHIFT;
        // era is the whole number of 400 year cycles taken out above, so
        // putting it back is exact.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 year = yearOfEra + era * YEARS_PER_ERA;
        return monthPrime < MONTHS_BEFORE_JANUARY ? year : year + 1;
    }
}
