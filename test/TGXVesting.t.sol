// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGX} from "../src/TGX.sol";
import {TGXVesting} from "../src/TGXVesting.sol";

contract TGXVestingTest is Test {
    TGX public tgx;
    TGXVesting public vesting;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public teamMember = makeAddr("teamMember");
    address public teamMember2 = makeAddr("teamMember2");

    uint64 public constant CLIFF = 365 days;
    uint64 public constant DURATION = 1095 days; // 3 years after cliff

    uint256 public constant SCHEDULE_AMOUNT = 1_000_000e18;

    function setUp() public {
        tgx = new TGX(admin, treasury);
        vesting = new TGXVesting(admin, address(tgx));

        // Transfer tokens to admin for schedule creation
        vm.prank(treasury);
        tgx.transfer(admin, 15_000_000e18);

        // Admin approves vesting contract
        vm.prank(admin);
        tgx.approve(address(vesting), type(uint256).max);
    }

    // ============ Constructor ============

    function test_Constructor() public view {
        assertEq(address(vesting.tgx()), address(tgx));
        assertTrue(vesting.hasRole(vesting.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorRevertsOnZeroAddresses() public {
        vm.expectRevert(TGXVesting.TGXVesting__ZeroAddress.selector);
        new TGXVesting(address(0), address(tgx));

        vm.expectRevert(TGXVesting.TGXVesting__ZeroAddress.selector);
        new TGXVesting(admin, address(0));
    }

    // ============ createSchedule ============

    function test_CreateSchedule() public {
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        (uint256 total,,,, uint256 released, bool revoked,) = vesting.schedules(teamMember);
        assertEq(total, SCHEDULE_AMOUNT);
        assertEq(released, 0);
        assertFalse(revoked);

        assertEq(tgx.balanceOf(address(vesting)), SCHEDULE_AMOUNT);
    }

    function test_CreateScheduleRevertsOnDuplicateBeneficiary() public {
        vm.startPrank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        vm.expectRevert(TGXVesting.TGXVesting__ScheduleExists.selector);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);
        vm.stopPrank();
    }

    function test_CreateScheduleRevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(TGXVesting.TGXVesting__ZeroAddress.selector);
        vesting.createSchedule(address(0), SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);
    }

    function test_CreateScheduleRevertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(TGXVesting.TGXVesting__ZeroAmount.selector);
        vesting.createSchedule(teamMember, 0, block.timestamp, CLIFF, DURATION);
    }

    function test_CreateScheduleRevertsWhenNotAdmin() public {
        vm.prank(teamMember);
        vm.expectRevert();
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);
    }

    // ============ Vesting math ============

    function test_NothingVestedBeforeCliff() public {
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF - 1);
        assertEq(vesting.vested(teamMember), 0);
        assertEq(vesting.releasable(teamMember), 0);
    }

    function test_NothingReleasableAtExactCliff() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        vm.warp(start + CLIFF);
        assertEq(vesting.vested(teamMember), 0);
    }

    function test_LinearVestingAfterCliff() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        // Warp to halfway through linear vesting (cliff + DURATION/2)
        vm.warp(start + CLIFF + DURATION / 2);

        uint256 expectedVested = SCHEDULE_AMOUNT / 2;
        assertApproxEqAbs(vesting.vested(teamMember), expectedVested, 1e12);
        assertApproxEqAbs(vesting.releasable(teamMember), expectedVested, 1e12);
    }

    function test_FullyVestedAfterDuration() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        vm.warp(start + CLIFF + DURATION + 1);
        assertEq(vesting.vested(teamMember), SCHEDULE_AMOUNT);
        assertEq(vesting.releasable(teamMember), SCHEDULE_AMOUNT);
    }

    // ============ release ============

    function test_Release() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        vm.warp(start + CLIFF + DURATION);

        vm.prank(teamMember);
        vesting.release();

        assertEq(tgx.balanceOf(teamMember), SCHEDULE_AMOUNT);
        assertEq(vesting.releasable(teamMember), 0);
    }

    function test_PartialReleaseThenMoreVestsAndReleasesAgain() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        // Release at 1/3 through linear vesting
        vm.warp(start + CLIFF + DURATION / 3);
        vm.prank(teamMember);
        vesting.release();
        uint256 firstRelease = tgx.balanceOf(teamMember);
        assertGt(firstRelease, 0);

        // Warp to full vest
        vm.warp(start + CLIFF + DURATION);
        vm.prank(teamMember);
        vesting.release();
        uint256 totalReceived = tgx.balanceOf(teamMember);
        assertApproxEqAbs(totalReceived, SCHEDULE_AMOUNT, 1e12);
    }

    function test_ReleaseRevertsBeforeCliff() public {
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        vm.prank(teamMember);
        vm.expectRevert(TGXVesting.TGXVesting__NothingToRelease.selector);
        vesting.release();
    }

    function test_ReleaseRevertsWithNoSchedule() public {
        vm.prank(teamMember);
        vm.expectRevert(TGXVesting.TGXVesting__NoSchedule.selector);
        vesting.release();
    }

    // ============ revokeSchedule ============

    function test_RevokeBeforeAnyVesting() public {
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        uint256 treasuryBefore = tgx.balanceOf(treasury);
        vm.prank(admin);
        vesting.revokeSchedule(teamMember, treasury);

        // All tokens returned (nothing vested yet)
        assertEq(tgx.balanceOf(treasury), treasuryBefore + SCHEDULE_AMOUNT);
        assertEq(vesting.releasable(teamMember), 0);
    }

    function test_RevokeAfterPartialVesting() public {
        uint256 start = block.timestamp;
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);

        // Warp to halfway through linear period
        vm.warp(start + CLIFF + DURATION / 2);

        uint256 vestedAtRevoke = vesting.vested(teamMember);
        assertGt(vestedAtRevoke, 0);

        uint256 treasuryBefore = tgx.balanceOf(treasury);
        vm.prank(admin);
        vesting.revokeSchedule(teamMember, treasury);

        // Unvested tokens returned to treasury
        assertApproxEqAbs(tgx.balanceOf(treasury), treasuryBefore + SCHEDULE_AMOUNT - vestedAtRevoke, 1e12);

        // Beneficiary can still claim vested portion
        vm.prank(teamMember);
        vesting.release();
        assertApproxEqAbs(tgx.balanceOf(teamMember), vestedAtRevoke, 1e12);
    }

    function test_RevokeRevertsIfAlreadyRevoked() public {
        vm.prank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, block.timestamp, CLIFF, DURATION);

        vm.startPrank(admin);
        vesting.revokeSchedule(teamMember, treasury);

        vm.expectRevert(TGXVesting.TGXVesting__AlreadyRevoked.selector);
        vesting.revokeSchedule(teamMember, treasury);
        vm.stopPrank();
    }

    function test_RevokeRevertsWithNoSchedule() public {
        vm.prank(admin);
        vm.expectRevert(TGXVesting.TGXVesting__NoSchedule.selector);
        vesting.revokeSchedule(teamMember, treasury);
    }

    // ============ Multiple beneficiaries ============

    function test_MultipleIndependentSchedules() public {
        uint256 start = block.timestamp;
        vm.startPrank(admin);
        vesting.createSchedule(teamMember, SCHEDULE_AMOUNT, start, CLIFF, DURATION);
        vesting.createSchedule(teamMember2, SCHEDULE_AMOUNT * 2, start, CLIFF, DURATION);
        vm.stopPrank();

        vm.warp(start + CLIFF + DURATION);

        vm.prank(teamMember);
        vesting.release();
        vm.prank(teamMember2);
        vesting.release();

        assertEq(tgx.balanceOf(teamMember), SCHEDULE_AMOUNT);
        assertEq(tgx.balanceOf(teamMember2), SCHEDULE_AMOUNT * 2);
    }
}
