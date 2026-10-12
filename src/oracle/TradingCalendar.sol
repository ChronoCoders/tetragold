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
 *      and are a list.
 *
 *      Editing that list waits 48 hours (D68). The proposer multisig schedules
 *      an edit, anyone may execute it once the delay has passed, and the
 *      proposer may cancel it before then. Both the proposer and the delay are
 *      fixed at construction, the delay as a constant, so neither can be
 *      changed and no account can shorten the wait.
 *
 *      There is no general timelock, and that is the point of building the
 *      delay in here. OpenZeppelin's TimelockController administers itself, so
 *      a proposer can, with the delay, grant new roles, call any target and
 *      lower the delay to zero (`TimelockController.sol:115-137`, `:449-456`,
 *      OpenZeppelin 5.0.0 in lib). That is a general key, which D58 rules out.
 *      A delay built into one contract can do only its one job.
 *
 *      What the list can reach is narrow as well: settlement does not read this
 *      calendar at all, so a holiday edit touches only the D22 push fallback
 *      (D61). A bad edit can at most disable the fallback; it cannot stop a
 *      close or a liquidation.
 *
 *      Daylight saving: Eastern time is UTC minus 5 hours, and UTC minus 4
 *      from 02:00 local on the second Sunday in March until 02:00 local on the
 *      first Sunday in November. Those two instants are 07:00 and 06:00 UTC,
 *      which is what this compares against.
 *
 *      A holiday closes the whole Eastern day. That is wider than the venue's
 *      own schedule around a holiday, and wider in the safe direction: a
 *      closed calendar refuses the D22 push fallback a price. It cannot refuse
 *      a settlement, which reads no calendar at all (D61).
 *
 *      The reading side takes the instant it is asked about, which is the
 *      target time of a request, so `isOpen` and `isHoliday` are pure
 *      functions of their argument and the holiday list. The scheduling side
 *      is the only part that reads the clock, for the delay of D68.
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

    /// @notice How long a scheduled edit waits before anyone may execute it
    ///         (D68). A constant rather than a parameter, so no deployment can
    ///         choose a shorter wait.
    uint256 public constant DELAY = 48 hours;

    /// @notice The multisig that may schedule and cancel an edit (D68).
    address public immutable PROPOSER;

    /// @notice Eastern days the market is closed for, keyed by `etDayOf`.
    mapping(uint256 etDay => bool closed) public closedDays;

    /// @notice How many Eastern days the list holds.
    uint256 public holidayCount;

    /// @notice Identifier of the next scheduled edit, so zero is never one.
    uint256 public nextEditId = 1;

    mapping(uint256 editId => Edit edit) private _edits;

    /// @notice What a scheduled edit does to the list.
    enum Action {
        Add,
        Remove
    }

    /// @notice Where a scheduled edit is in its lifecycle. An edit leaves
    ///         `Pending` exactly once, which is what stops a second execution.
    enum State {
        None,
        Pending,
        Executed,
        Cancelled
    }

    /// @notice One scheduled edit.
    struct Edit {
        uint256 etDay;
        uint256 executableAt;
        Action action;
        State state;
    }

    event HolidayEditScheduled(
        uint256 indexed editId, uint256 indexed etDay, Action action, uint256 executableAt, uint256 timestamp
    );
    event HolidayEditCancelled(uint256 indexed editId, uint256 indexed etDay, Action action);
    event HolidayEditExecuted(uint256 indexed editId, uint256 indexed etDay, Action action, uint256 holidayCount);

    error NotProposer(address caller);
    error AlreadyListed(uint256 etDay);
    error NotListed(uint256 etDay);
    error ZeroAddress();
    error NoSuchEdit(uint256 editId);
    error TooEarly(uint256 executableAt);

    constructor(address proposer) {
        if (proposer == address(0)) {
            revert ZeroAddress();
        }
        PROPOSER = proposer;
    }

    /// @notice Whether the market is open at `timestamp`.
    function isOpen(uint256 timestamp) external view returns (bool) {
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
    function isHoliday(uint256 timestamp) external view returns (bool) {
        return closedDays[etDayOf(timestamp)];
    }

    /// @notice The Eastern day `timestamp` falls in, which is the holiday key.
    function etDayOf(uint256 timestamp) public pure returns (uint256) {
        return _easternSeconds(timestamp) / SECONDS_PER_DAY;
    }

    /// @notice Read a scheduled edit, for anyone deciding whether to execute
    ///         it and for the D55 dashboard.
    function editAt(uint256 editId)
        external
        view
        returns (uint256 etDay, uint256 executableAt, Action action, State state)
    {
        Edit storage edit = _edits[editId];
        return (edit.etDay, edit.executableAt, edit.action, edit.state);
    }

    /// @notice Schedule closing or reopening the Eastern day that `timestamp`
    ///         falls in. Executable by anyone once `DELAY` has passed.
    /// @param timestamp Any instant inside the Eastern day to edit.
    /// @param add True to close the day, false to reopen it.
    /// @return editId Identifier of the scheduled edit.
    function scheduleHoliday(uint256 timestamp, bool add) external returns (uint256 editId) {
        if (msg.sender != PROPOSER) {
            revert NotProposer(msg.sender);
        }

        uint256 day = etDayOf(timestamp);
        Action action = add ? Action.Add : Action.Remove;
        // The delay runs from now in slot time, which post merge Ethereum
        // fixes (consensus-specs specs/bellatrix/beacon-chain.md:446 at
        // 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        uint256 executableAt = block.timestamp + DELAY;

        editId = nextEditId;
        nextEditId = editId + 1;
        _edits[editId] = Edit({etDay: day, executableAt: executableAt, action: action, state: State.Pending});

        emit HolidayEditScheduled(editId, day, action, executableAt, timestamp);
    }

    /// @notice Drop a scheduled edit before it is executed.
    /// @dev Only the proposer cancels. Cancelling moves the edit out of
    ///      `Pending`, so it can never be executed afterwards.
    function cancelHoliday(uint256 editId) external {
        if (msg.sender != PROPOSER) {
            revert NotProposer(msg.sender);
        }
        Edit storage edit = _edits[editId];
        if (edit.state != State.Pending) {
            revert NoSuchEdit(editId);
        }

        edit.state = State.Cancelled;
        emit HolidayEditCancelled(editId, edit.etDay, edit.action);
    }

    /// @notice Apply a scheduled edit once its delay has passed.
    /// @dev Anyone may call this: the edit was fixed when it was scheduled, so
    ///      the caller chooses nothing, and leaving execution to one account
    ///      would be a key that could sit on a scheduled edit (D62, D68). The
    ///      list rules are unchanged, so an add of a listed day and a removal
    ///      of an unlisted one both still revert.
    function executeHoliday(uint256 editId) external {
        Edit storage edit = _edits[editId];
        if (edit.state != State.Pending) {
            revert NoSuchEdit(editId);
        }
        // The deadline is slot time as above.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < edit.executableAt) {
            revert TooEarly(edit.executableAt);
        }

        uint256 day = edit.etDay;
        if (edit.action == Action.Add) {
            if (closedDays[day]) {
                revert AlreadyListed(day);
            }
            closedDays[day] = true;
            holidayCount += 1;
        } else {
            if (!closedDays[day]) {
                revert NotListed(day);
            }
            closedDays[day] = false;
            holidayCount -= 1;
        }

        edit.state = State.Executed;
        emit HolidayEditExecuted(editId, day, edit.action, holidayCount);
    }

    /// @dev Seconds since the epoch shifted into Eastern time.
    function _easternSeconds(uint256 timestamp) private pure returns (uint256) {
        return timestamp - (_isDaylightSaving(timestamp) ? DAYLIGHT_OFFSET : STANDARD_OFFSET);
    }

    /// @dev Both transition instants are fixed in UTC: 02:00 standard time is
    ///      07:00 UTC and 02:00 daylight time is 06:00 UTC.
    function _isDaylightSaving(uint256 timestamp) private pure returns (bool) {
        uint256 year = _yearFromDays(timestamp / SECONDS_PER_DAY);
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
