// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {InsuranceFund} from "../src/InsuranceFund.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockVaultManagerTL} from "./mocks/MockVaultManagerTL.sol";

/**
 * @title TimelockTest
 * @notice Verifies that the slow governance parameters sit behind a 48 hour
 *         TimelockController: the trading calendar's holiday list (D22) and the
 *         insurance fund's target percentage. Emergency pause stays on the fast
 *         admin role.
 * @dev The calendar needs no role handover. Its timelock is immutable and set
 *      at construction, so there is no window in which an admin holds the
 *      power and has to give it up, and nothing to renounce.
 */
contract TimelockTest is Test {
    uint256 internal constant DELAY = 48 hours;
    uint256 internal constant TARGET_PERCENTAGE = 200;
    /// @dev 2026-12-25 17:00 UTC, inside the Eastern day of a full closure.
    uint64 internal constant CHRISTMAS = 1_798_650_000;
    /// @dev TimelockController reads a zero predecessor as "no predecessor".
    bytes32 internal constant NO_PREDECESSOR = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes32 internal constant SALT_ADD = keccak256("add");
    bytes32 internal constant SALT_REMOVE = keccak256("remove");
    bytes32 internal constant SALT_TARGET = keccak256("target");
    bytes32 internal constant SALT_STRANGER = keccak256("stranger");

    TimelockController internal timelock;
    TradingCalendar internal calendar;
    InsuranceFund internal fund;

    address internal admin;
    address internal proposer;
    address internal executor;
    address internal stranger;

    function setUp() public {
        admin = makeAddr("admin");
        proposer = makeAddr("proposer");
        executor = makeAddr("executor");
        stranger = makeAddr("stranger");

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        calendar = new TradingCalendar(address(timelock));

        MockAavePool aave = new MockAavePool();
        MockVaultManagerTL vault = new MockVaultManagerTL();
        vm.prank(admin);
        fund = new InsuranceFund(admin, address(vault), address(this), address(aave));

        vm.startPrank(admin);
        fund.grantRole(fund.PARAM_ROLE(), address(timelock));
        fund.renounceRole(fund.PARAM_ROLE(), admin);
        vm.stopPrank();
    }

    function test_AdminCannotEditTheHolidayListDirectly() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NotTimelock.selector, admin));
        calendar.addHoliday(CHRISTMAS);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TradingCalendar.NotTimelock.selector, stranger));
        calendar.addHoliday(CHRISTMAS);
    }

    function test_TimelockAddsAHolidayAfterDelay() public {
        bytes memory data = abi.encodeCall(TradingCalendar.addHoliday, (CHRISTMAS));

        vm.prank(proposer);
        timelock.schedule(address(calendar), 0, data, NO_PREDECESSOR, SALT_ADD, DELAY);

        // Cannot execute before the delay elapses.
        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(calendar), 0, data, NO_PREDECESSOR, SALT_ADD);

        vm.warp(block.timestamp + DELAY);

        vm.prank(executor);
        timelock.execute(address(calendar), 0, data, NO_PREDECESSOR, SALT_ADD);

        assertTrue(calendar.isHoliday(CHRISTMAS), "the holiday did not land");
        assertFalse(calendar.isOpen(CHRISTMAS), "the market stayed open on the holiday");
        assertEq(calendar.holidayCount(), 1);
    }

    function test_TimelockRemovesAHolidayAfterDelay() public {
        bytes memory add = abi.encodeCall(TradingCalendar.addHoliday, (CHRISTMAS));
        bytes memory remove = abi.encodeCall(TradingCalendar.removeHoliday, (CHRISTMAS));

        vm.prank(proposer);
        timelock.schedule(address(calendar), 0, add, NO_PREDECESSOR, SALT_ADD, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(calendar), 0, add, NO_PREDECESSOR, SALT_ADD);

        vm.prank(proposer);
        timelock.schedule(address(calendar), 0, remove, NO_PREDECESSOR, SALT_REMOVE, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(calendar), 0, remove, NO_PREDECESSOR, SALT_REMOVE);

        assertFalse(calendar.isHoliday(CHRISTMAS), "the holiday did not come off the list");
        assertEq(calendar.holidayCount(), 0);
    }

    function test_TimelockSetsTargetPercentageAfterDelay() public {
        bytes memory data = abi.encodeCall(InsuranceFund.updateTargetPercentage, (TARGET_PERCENTAGE));
        vm.prank(proposer);
        timelock.schedule(address(fund), 0, data, NO_PREDECESSOR, SALT_TARGET, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(fund), 0, data, NO_PREDECESSOR, SALT_TARGET);

        assertEq(fund.targetPercentage(), TARGET_PERCENTAGE);
    }

    function test_AdminCannotSetTargetPercentageAfterRenounce() public {
        bytes32 paramRole = fund.PARAM_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, paramRole)
        );
        fund.updateTargetPercentage(TARGET_PERCENTAGE);
    }

    function test_NonProposerCannotSchedule() public {
        bytes memory data = abi.encodeCall(TradingCalendar.addHoliday, (CHRISTMAS));
        vm.prank(stranger);
        vm.expectRevert();
        timelock.schedule(address(calendar), 0, data, NO_PREDECESSOR, SALT_STRANGER, DELAY);
    }

    function test_EmergencyPauseStaysImmediate() public {
        // Pause is on the fund's admin role, untouched by the timelock, so the
        // admin can still pause instantly without waiting out the delay.
        vm.prank(admin);
        fund.pause();
        assertTrue(fund.paused());
    }
}
