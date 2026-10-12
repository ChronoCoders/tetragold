// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";

/**
 * @title TimelockTest
 * @notice Why the protocol has no general timelock, shown against the one it
 *         would otherwise have used (D68).
 * @dev This file used to drive the holiday list through an OpenZeppelin
 *      `TimelockController`. D68 replaced that with a delay built into the
 *      calendar, and the reason is testable: a TimelockController administers
 *      itself, so a proposer can schedule a call that grants roles, retargets
 *      anything or lowers the delay to zero. The checks below are that the
 *      calendar is not reachable that way at all, and that its own delay has
 *      no setter to reach.
 *
 *      The insurance fund used to be the other half of this file. The revision
 *      6 fund has no role and no parameter to change, so there is nothing left
 *      of it to delay.
 */
contract TimelockTest is Test {
    uint256 internal constant DELAY = 48 hours;
    /// @dev 2026-12-25 17:00 UTC, inside the Eastern day of a full closure.
    uint64 internal constant CHRISTMAS = 1_798_650_000;
    bytes32 internal constant NO_PREDECESSOR = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes32 internal constant SALT = keccak256("add");
    /// @dev The edit the call would make, named so the literal is not mistaken
    ///      for a condition.
    bool internal constant CLOSE_THE_DAY = true;

    TimelockController internal timelock;
    TradingCalendar internal calendar;

    address internal admin;
    address internal proposerRole;
    address internal executor;
    address internal multisig;

    function setUp() public {
        admin = makeAddr("admin");
        proposerRole = makeAddr("proposer role");
        executor = makeAddr("executor");
        multisig = makeAddr("multisig");

        address[] memory proposers = new address[](1);
        proposers[0] = proposerRole;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        calendar = new TradingCalendar(multisig);
    }

    /// @dev The calendar's proposer is the multisig, fixed at construction, so
    ///      a TimelockController holds no power over the list even with its own
    ///      delay served.
    function test_ATimelockControllerCannotEditTheList() public {
        bytes memory data = abi.encodeCall(TradingCalendar.scheduleHoliday, (CHRISTMAS, CLOSE_THE_DAY));

        vm.prank(proposerRole);
        timelock.schedule(address(calendar), 0, data, NO_PREDECESSOR, SALT, DELAY);
        vm.warp(block.timestamp + DELAY);

        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(calendar), 0, data, NO_PREDECESSOR, SALT);

        assertFalse(calendar.isHoliday(CHRISTMAS), "a timelock reached the holiday list");
        assertEq(calendar.holidayCount(), 0);
    }

    /// @dev The delay is a constant with no setter, which is the half of D68's
    ///      reason that a self administering timelock fails: there is no call
    ///      that lowers it, from any account.
    function test_TheCalendarDelayCannotBeChanged() public {
        assertEq(calendar.DELAY(), DELAY, "the calendar does not carry the 48 hour delay");

        string[2] memory gone = ["setDelay(uint256)", "updateDelay(uint256)"];
        for (uint256 i = 0; i < gone.length; i++) {
            // One call per absent selector is the test, and a raw call is the
            // only way to reach a function the type does not have.
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(calendar).call(abi.encodeWithSignature(gone[i], uint256(0)));
            assertFalse(ok, gone[i]);
        }
    }

    /// @dev And the proposer is immutable, so the multisig cannot hand the
    ///      power to a timelock later either.
    function test_TheProposerCannotBeHandedOver() public {
        assertEq(calendar.PROPOSER(), multisig, "the proposer is not the multisig");

        string[2] memory gone = ["setProposer(address)", "transferOwnership(address)"];
        for (uint256 i = 0; i < gone.length; i++) {
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(calendar).call(abi.encodeWithSignature(gone[i], address(timelock)));
            assertFalse(ok, gone[i]);
        }
    }
}
