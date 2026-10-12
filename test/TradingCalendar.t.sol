// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";

/// @notice Holds the calendar to the precious metals hours in D22 and 11.4.
/// @dev The expected answers are generated from the IANA time zone database
///      for America/New_York, not from a second copy of the contract's own
///      arithmetic, so the daylight saving rule is checked against an
///      independent source. Each vector names the Eastern wall clock time it
///      stands for in the comment beside it.
contract TradingCalendarTest is Test {
    uint256 private constant VECTORS = 20;
    uint256 private constant DELAY = 48 hours;
    uint256 private constant FIRST_EDIT = 1;
    uint256 private constant UNKNOWN_EDIT = 999;
    uint64 private constant WEDNESDAY_MIDDAY = 1_784_116_800;
    uint64 private constant NEXT_DAY = WEDNESDAY_MIDDAY + 1 days;
    uint64 private constant LATE_SAME_EASTERN_DAY = WEDNESDAY_MIDDAY + 10 hours;
    /// @dev 2026-07-15 04:00 UTC, which is 2026-07-15 00:00 EDT.
    uint64 private constant EASTERN_MIDNIGHT = 1_784_088_000;

    TradingCalendar public calendar;
    address public proposer;
    address public stranger;

    function setUp() public {
        proposer = makeAddr("proposer");
        stranger = makeAddr("stranger");
        calendar = new TradingCalendar(proposer);
    }

    function test_ConstructorRejectsZeroProposer() public {
        vm.expectRevert(TradingCalendar.ZeroAddress.selector);
        new TradingCalendar(address(0));
    }

    function test_TheDelayIsFixedAtFortyEightHours() public view {
        assertEq(calendar.DELAY(), DELAY, "the delay is not 48 hours");
        assertEq(calendar.PROPOSER(), proposer);
        assertEq(calendar.nextEditId(), FIRST_EDIT);
    }

    function test_OpenAndClosedVectors() public view {
        uint64[VECTORS] memory stamps = [
            uint64(1_772_830_800), // Friday 16:00 EST, before the close
            1_773_435_600, // Friday 17:00 EDT, at the close
            1_773_611_940, // Sunday 17:59 EDT, one second before the open
            1_773_612_000, // Sunday 18:00 EDT, at the open
            1_773_489_600, // Saturday 08:00 EDT
            1_773_694_740, // Monday 16:59 EDT, before the break
            1_773_694_800, // Monday 17:00 EDT, in the break
            1_773_698_340, // Monday 17:59 EDT, still in the break
            1_773_698_400, // Monday 18:00 EDT, after the break
            1_793_394_000, // Friday 17:00 EDT, at the close
            1_793_998_800, // Friday 16:00 EST, before the close
            1_793_512_740, // Sunday 01:59 EDT, before the autumn change
            1_793_512_800, // Sunday 01:00 EST, after the autumn change
            1_804_885_200, // Friday 16:00 EST 2027
            1_805_490_000, // Friday 17:00 EDT 2027
            1_825_448_400, // Friday 17:00 EDT 2027
            1_826_053_200, // Friday 16:00 EST 2027
            1_784_116_800, // Wednesday 08:00 EDT
            1_767_355_200, // Friday 07:00 EST
            1_798_500_600 // Monday 18:30 EST
        ];
        bool[VECTORS] memory expected = [
            true,
            false,
            false,
            true,
            false,
            true,
            false,
            false,
            true,
            false,
            true,
            false,
            false,
            true,
            false,
            false,
            true,
            true,
            true,
            true
        ];

        for (uint256 i = 0; i < VECTORS; i++) {
            // The table is the test, so the call has to sit inside the loop.
            // forge-lint: disable-next-line(calls-loop)
            bool open = calendar.isOpen(stamps[i]);
            // vm.toString is a cheat code rather than a protocol call, and the
            // index is what tells you which vector failed.
            // forge-lint: disable-next-line(calls-loop)
            string memory which = string.concat("vector ", vm.toString(i));
            assertEq(open, expected[i], which);
        }
    }

    /// @dev A holiday closes the Eastern day, not a window inside it.
    function test_HolidayClosesTheWholeEasternDay() public {
        assertTrue(calendar.isOpen(WEDNESDAY_MIDDAY));
        assertTrue(calendar.isOpen(LATE_SAME_EASTERN_DAY));

        _listHoliday(WEDNESDAY_MIDDAY);

        assertFalse(calendar.isOpen(WEDNESDAY_MIDDAY), "the holiday did not close the day");
        assertFalse(calendar.isOpen(LATE_SAME_EASTERN_DAY), "the holiday closed only part of the day");
        assertTrue(calendar.isHoliday(WEDNESDAY_MIDDAY));
        assertTrue(calendar.isOpen(NEXT_DAY), "the holiday leaked into the next day");
    }

    /// @dev D68: only the proposer schedules, and the list rules still apply
    ///      at execution, which is where they are now checked.
    function test_OnlyTheProposerSchedulesAndTheListRulesStillApply() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NotProposer.selector, stranger));
        // This call reverts by design, so no identifier comes back.
        // forge-lint: disable-next-line(unused-return)
        calendar.scheduleHoliday(WEDNESDAY_MIDDAY, true);

        _listHoliday(WEDNESDAY_MIDDAY);
        assertEq(calendar.holidayCount(), 1);

        uint256 day = calendar.etDayOf(WEDNESDAY_MIDDAY);
        uint256 again = _schedule(LATE_SAME_EASTERN_DAY, true);
        // forge-lint: disable-next-line(unused-return)
        (, uint256 againAt,,) = calendar.editAt(again);
        vm.warp(againAt);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.AlreadyListed.selector, day));
        calendar.executeHoliday(again);

        _unlistHoliday(WEDNESDAY_MIDDAY);
        assertEq(calendar.holidayCount(), 0);
        assertTrue(calendar.isOpen(WEDNESDAY_MIDDAY), "the day did not reopen");

        uint256 third = _schedule(WEDNESDAY_MIDDAY, false);
        // forge-lint: disable-next-line(unused-return)
        (, uint256 thirdAt,,) = calendar.editAt(third);
        vm.warp(thirdAt);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NotListed.selector, day));
        calendar.executeHoliday(third);
    }

    /// @dev D68: the wait is 48 hours to the second. One second early is early.
    function test_AnEditWaitsTheWholeDelay() public {
        uint256 editId = _schedule(WEDNESDAY_MIDDAY, true);
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 executableAt,) = _edit(editId);

        vm.warp(executableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.TooEarly.selector, executableAt));
        calendar.executeHoliday(editId);

        vm.warp(executableAt);
        calendar.executeHoliday(editId);

        assertTrue(calendar.isHoliday(WEDNESDAY_MIDDAY), "the edit did not land at the delay");
    }

    /// @dev D62 and D68: the edit was fixed when it was scheduled, so the
    ///      caller of the execution chooses nothing and anyone may be it.
    function test_AnyoneExecutesAScheduledEdit() public {
        uint256 editId = _schedule(WEDNESDAY_MIDDAY, true);
        // forge-lint: disable-next-line(unused-return)
        (, uint256 executableAt,,) = calendar.editAt(editId);
        vm.warp(executableAt);

        vm.prank(stranger);
        calendar.executeHoliday(editId);

        assertTrue(calendar.isHoliday(WEDNESDAY_MIDDAY), "a stranger could not execute a due edit");
    }

    /// @dev An edit leaves the pending state exactly once, whichever way it
    ///      leaves, so neither a cancelled nor an executed edit can be applied.
    function test_AnEditLeavesPendingExactlyOnce() public {
        uint256 executed = _schedule(WEDNESDAY_MIDDAY, true);
        _executeAfterTheWait(executed);

        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NoSuchEdit.selector, executed));
        calendar.executeHoliday(executed);

        uint256 cancelled = _schedule(NEXT_DAY, true);
        // forge-lint: disable-next-line(unused-return)
        (, uint256 cancelledAt,,) = calendar.editAt(cancelled);
        vm.prank(proposer);
        calendar.cancelHoliday(cancelled);
        vm.warp(cancelledAt);

        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NoSuchEdit.selector, cancelled));
        calendar.executeHoliday(cancelled);
        assertFalse(calendar.isHoliday(NEXT_DAY), "a cancelled edit still landed");

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NoSuchEdit.selector, cancelled));
        calendar.cancelHoliday(cancelled);

        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NoSuchEdit.selector, UNKNOWN_EDIT));
        calendar.executeHoliday(UNKNOWN_EDIT);
    }

    function test_OnlyTheProposerCancels() public {
        uint256 editId = _schedule(WEDNESDAY_MIDDAY, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NotProposer.selector, stranger));
        calendar.cancelHoliday(editId);

        vm.prank(proposer);
        calendar.cancelHoliday(editId);
        // forge-lint: disable-next-line(unused-return)
        (,,, TradingCalendar.State state) = _edit(editId);
        assertEq(uint256(state), uint256(TradingCalendar.State.Cancelled), "the edit was not cancelled");
    }

    function _schedule(uint256 timestamp, bool add) private returns (uint256 editId) {
        vm.prank(proposer);
        editId = calendar.scheduleHoliday(timestamp, add);
    }

    /// @dev The clock moves to the instant the contract itself recorded, not to
    ///      a second reading of the clock, so the wait under test is the one the
    ///      edit carries.
    function _listHoliday(uint256 timestamp) private {
        _executeAfterTheWait(_schedule(timestamp, true));
    }

    function _unlistHoliday(uint256 timestamp) private {
        _executeAfterTheWait(_schedule(timestamp, false));
    }

    function _executeAfterTheWait(uint256 editId) private {
        // forge-lint: disable-next-line(unused-return)
        (, uint256 executableAt,,) = calendar.editAt(editId);
        vm.warp(executableAt);
        calendar.executeHoliday(editId);
    }

    function _edit(uint256 editId)
        private
        view
        returns (uint256 etDay, TradingCalendar.Action action, uint256 executableAt, TradingCalendar.State state)
    {
        (etDay, executableAt, action, state) = calendar.editAt(editId);
    }

    /// @dev The holiday key is an Eastern day, so it turns over at Eastern
    ///      midnight rather than at UTC midnight.
    function test_EasternDayTurnsOverAtEasternMidnight() public view {
        // 2026-07-15 03:59 UTC is 2026-07-14 23:59 EDT, the day before.
        uint64 beforeMidnight = EASTERN_MIDNIGHT - 1 minutes;
        uint64 afterMidnight = EASTERN_MIDNIGHT;

        assertEq(calendar.etDayOf(beforeMidnight) + 1, calendar.etDayOf(afterMidnight));
    }
}
