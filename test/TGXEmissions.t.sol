// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGX} from "../src/TGX.sol";
import {TGXEmissions} from "../src/TGXEmissions.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TGXEmissionsTest is Test {
    TGX public tgx;
    TGXEmissions public emissions;
    MockERC20 public lpConservative;
    MockERC20 public lpAggressive;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 constant EMISSIONS_SUPPLY = 65_000_000e18;

    function setUp() public {
        tgx = new TGX(admin, treasury);
        lpConservative = new MockERC20("TGLP Conservative", "TGLP-C", 18);
        lpAggressive = new MockERC20("TGLP Aggressive", "TGLP-A", 18);

        emissions = new TGXEmissions(admin, address(tgx), address(lpConservative), address(lpAggressive));

        // Fund emissions contract with 65M TGX
        vm.startPrank(treasury);
        tgx.transfer(address(emissions), EMISSIONS_SUPPLY);
        vm.stopPrank();

        // Mint LP tokens to users
        lpConservative.mint(user1, 1_000e18);
        lpConservative.mint(user2, 1_000e18);
        lpAggressive.mint(user1, 1_000e18);

        // Approve
        vm.prank(user1);
        lpConservative.approve(address(emissions), type(uint256).max);
        vm.prank(user1);
        lpAggressive.approve(address(emissions), type(uint256).max);
        vm.prank(user2);
        lpConservative.approve(address(emissions), type(uint256).max);
    }

    // ============ Constructor ============

    function test_Constructor() public view {
        assertEq(address(emissions.tgx()), address(tgx));
        assertTrue(emissions.hasRole(emissions.DEFAULT_ADMIN_ROLE(), admin));
        (, uint256 allocC,,,) = emissions.pools(0);
        (, uint256 allocA,,,) = emissions.pools(1);
        assertEq(allocC, 80);
        assertEq(allocA, 20);
    }

    function test_Constants() public view {
        assertEq(emissions.YEAR_SECONDS(), 365 days);
        assertEq(emissions.TOTAL_ALLOC_POINTS(), 100);

        // Each yearly rate must reproduce the annual total with < 1 TGX rounding loss
        assertApproxEqAbs(emissions.YEAR1_RATE() * 31_536_000, 25_000_000e18, 1e18);
        assertApproxEqAbs(emissions.YEAR2_RATE() * 31_536_000, 15_000_000e18, 1e18);
        assertApproxEqAbs(emissions.YEAR3_RATE() * 31_536_000, 7_500_000e18, 1e18);
        assertApproxEqAbs(emissions.YEAR4_RATE() * 31_536_000, 2_500_000e18, 1e18);

        // Rates must strictly decrease (decay)
        assertGt(emissions.YEAR1_RATE(), emissions.YEAR2_RATE());
        assertGt(emissions.YEAR2_RATE(), emissions.YEAR3_RATE());
        assertGt(emissions.YEAR3_RATE(), emissions.YEAR4_RATE());
    }

    // ============ Stake / Unstake ============

    function test_Stake() public {
        uint256 amount = 100e18;
        vm.prank(user1);
        emissions.stake(0, amount);

        (uint256 staked,) = emissions.userInfo(0, user1);
        assertEq(staked, amount);
        assertEq(lpConservative.balanceOf(address(emissions)), amount);
    }

    function test_StakeRevertsOnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAmount.selector);
        emissions.stake(0, 0);
    }

    function test_StakeRevertsOnInvalidPool() public {
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__InvalidPool.selector);
        emissions.stake(2, 100e18);
    }

    function test_Unstake() public {
        uint256 amount = 100e18;
        vm.startPrank(user1);
        emissions.stake(0, amount);

        uint256 balBefore = lpConservative.balanceOf(user1);
        emissions.unstake(0, amount);
        vm.stopPrank();

        (uint256 staked,) = emissions.userInfo(0, user1);
        assertEq(staked, 0);
        assertEq(lpConservative.balanceOf(user1), balBefore + amount);
    }

    function test_UnstakeRevertsOnInsufficientBalance() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__InsufficientBalance.selector);
        emissions.unstake(0, 200e18);
    }

    // ============ Reward accrual ============

    function test_PendingTGXAccruesToSingleStaker() public {
        uint256 stakeAmount = 100e18;
        vm.prank(user1);
        emissions.stake(0, stakeAmount);

        // Warp 1 day
        vm.warp(block.timestamp + 1 days);

        // Pool 0 gets 80% of emissions
        uint256 expectedDay = emissions.YEAR1_RATE() * 86_400 * 80 / 100;
        uint256 pending = emissions.pendingTGX(0, user1);
        assertApproxEqAbs(pending, expectedDay, expectedDay / 1000); // within 0.1%
    }

    function test_RewardsProportionalToStake() public {
        // user1 stakes 300, user2 stakes 100 in pool 0 (total 400)
        vm.prank(user1);
        emissions.stake(0, 300e18);
        vm.prank(user2);
        emissions.stake(0, 100e18);

        vm.warp(block.timestamp + 1 days);

        uint256 pending1 = emissions.pendingTGX(0, user1);
        uint256 pending2 = emissions.pendingTGX(0, user2);

        // user1 should earn 3x user2
        assertApproxEqAbs(pending1, pending2 * 3, pending2 / 100);
    }

    function test_PoolWeightsSplit8020() public {
        // Same amount staked in both pools
        vm.prank(user1);
        emissions.stake(0, 100e18); // conservative (80%)
        vm.prank(user1);
        emissions.stake(1, 100e18); // aggressive (20%)

        vm.warp(block.timestamp + 1 days);

        uint256 pendingC = emissions.pendingTGX(0, user1);
        uint256 pendingA = emissions.pendingTGX(1, user1);

        // Conservative should earn 4x aggressive
        assertApproxEqAbs(pendingC, pendingA * 4, pendingA / 100);
    }

    function test_ClaimRewards() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        vm.warp(block.timestamp + 7 days);

        uint256 pending = emissions.pendingTGX(0, user1);
        assertGt(pending, 0);

        uint256 balBefore = tgx.balanceOf(user1);
        vm.prank(user1);
        emissions.claim(0);

        assertApproxEqAbs(tgx.balanceOf(user1), balBefore + pending, pending / 1000);
    }

    function test_ClaimRevertsWhenNothingPending() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        // No time has passed
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__NothingToClaim.selector);
        emissions.claim(0);
    }

    function test_UnstakeAutoClaimsRewards() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        vm.warp(block.timestamp + 7 days);

        uint256 pending = emissions.pendingTGX(0, user1);
        uint256 balBefore = tgx.balanceOf(user1);

        vm.prank(user1);
        emissions.unstake(0, 100e18);

        assertApproxEqAbs(tgx.balanceOf(user1), balBefore + pending, pending / 1000);
    }

    // ============ Cross-year boundary handling ============

    function test_CrossYearBoundaryYear1ToYear2() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        uint256 start = emissions.startTime();

        // Warp to 6 months before year end
        vm.warp(start + 365 days - 180 days);
        uint256 pendingMid = emissions.pendingTGX(0, user1);

        // Warp past year boundary by 180 days
        vm.warp(start + 365 days + 180 days);
        uint256 pendingCross = emissions.pendingTGX(0, user1);

        // The additional 360 days spans the year boundary:
        // 180 days at Year 1 rate + 180 days at Year 2 rate (both at 80% pool weight)
        uint256 expectedYear1Portion = emissions.YEAR1_RATE() * (180 days) * 80 / 100;
        uint256 expectedYear2Portion = emissions.YEAR2_RATE() * (180 days) * 80 / 100;
        uint256 expectedAdditional = expectedYear1Portion + expectedYear2Portion;

        uint256 actualAdditional = pendingCross - pendingMid;
        assertApproxEqAbs(actualAdditional, expectedAdditional, expectedAdditional / 1000);
    }

    function test_NoEmissionsAfterYear4() public {
        uint256 start = emissions.startTime();
        vm.prank(user1);
        emissions.stake(0, 100e18);

        // Jump to end of year 4
        vm.warp(start + 4 * 365 days);
        uint256 pendingAtEnd = emissions.pendingTGX(0, user1);

        // Jump 1 more year (should not earn anything more)
        vm.warp(start + 5 * 365 days);
        uint256 pendingAfterEnd = emissions.pendingTGX(0, user1);

        assertEq(pendingAtEnd, pendingAfterEnd);
    }

    function test_Year1TotalApproximately25M() public {
        // Single staker in each pool, check total emissions after 1 year
        vm.prank(user1);
        emissions.stake(0, 100e18);
        vm.prank(user1);
        emissions.stake(1, 100e18);

        uint256 start = emissions.startTime();
        vm.warp(start + 365 days);

        uint256 pendingC = emissions.pendingTGX(0, user1); // 80%
        uint256 pendingA = emissions.pendingTGX(1, user1); // 20%
        uint256 totalYear1 = pendingC + pendingA;

        // Should be approximately 25,000,000 TGX
        assertApproxEqAbs(totalYear1, 25_000_000e18, 25_000_000e18 / 1000); // within 0.1%
    }

    function test_Year2RateLowerThanYear1() public {
        uint256 start = emissions.startTime();
        vm.prank(user1);
        emissions.stake(0, 100e18);

        // End of year 1
        vm.warp(start + 365 days);
        emissions.updatePool(0);

        uint256 pendingY1End = emissions.pendingTGX(0, user1);

        // 1 day into year 2
        vm.warp(start + 365 days + 1 days);
        uint256 pendingY2Day1 = emissions.pendingTGX(0, user1);

        uint256 year1DailyRate = emissions.YEAR1_RATE() * 86_400 * 80 / 100;
        uint256 year2DailyRate = emissions.YEAR2_RATE() * 86_400 * 80 / 100;
        uint256 dayGain = pendingY2Day1 - pendingY1End;

        assertApproxEqAbs(dayGain, year2DailyRate, year2DailyRate / 1000);
        assertLt(dayGain, year1DailyRate);
    }

    // ============ Sweep ============

    function test_SweepRevertsBeforeEmissionsEnd() public {
        vm.prank(admin);
        vm.expectRevert(TGXEmissions.TGXEmissions__EmissionsNotEnded.selector);
        emissions.sweepUndistributed(treasury);
    }

    function test_SweepAfterEmissionsEnd() public {
        uint256 start = emissions.startTime();
        vm.warp(start + 4 * 365 days + 1);

        uint256 remaining = tgx.balanceOf(address(emissions));
        uint256 treasuryBefore = tgx.balanceOf(treasury);
        assertGt(remaining, 0);

        vm.prank(admin);
        emissions.sweepUndistributed(treasury);

        assertEq(tgx.balanceOf(treasury), treasuryBefore + remaining);
        assertEq(tgx.balanceOf(address(emissions)), 0);
    }

    function test_SweepExcludesAccruedStakerRewards() public {
        // user1 stakes through the full emission period and never claims
        vm.prank(user1);
        emissions.stake(0, 100e18);

        uint256 start = emissions.startTime();
        vm.warp(start + 4 * 365 days + 1);

        vm.prank(admin);
        emissions.sweepUndistributed(treasury);

        // Sweep must leave the user's accrued rewards claimable
        uint256 pending = emissions.pendingTGX(0, user1);
        assertGt(pending, 0);
        assertGe(tgx.balanceOf(address(emissions)), pending);

        // Unstake (which auto-claims) must still work after the sweep
        vm.prank(user1);
        emissions.unstake(0, 100e18);

        assertEq(lpConservative.balanceOf(user1), 1_000e18);
        assertEq(tgx.balanceOf(user1), pending);
    }

    function test_SweepRevertsOnZeroAddress() public {
        uint256 start = emissions.startTime();
        vm.warp(start + 4 * 365 days + 1);

        vm.prank(admin);
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAddress.selector);
        emissions.sweepUndistributed(address(0));
    }

    function test_SweepRevertsWhenNotAdmin() public {
        uint256 start = emissions.startTime();
        vm.warp(start + 4 * 365 days + 1);

        vm.prank(user1);
        vm.expectRevert();
        emissions.sweepUndistributed(treasury);
    }

    /* ============ Branch coverage: constructor guards ============ */

    function test_ConstructorRevertsZeroAdmin() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAddress.selector);
        new TGXEmissions(address(0), address(tgx), address(lpConservative), address(lpAggressive));
    }

    function test_ConstructorRevertsZeroTgx() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAddress.selector);
        new TGXEmissions(admin, address(0), address(lpConservative), address(lpAggressive));
    }

    function test_ConstructorRevertsZeroConservativeLp() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAddress.selector);
        new TGXEmissions(admin, address(tgx), address(0), address(lpAggressive));
    }

    function test_ConstructorRevertsZeroAggressiveLp() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__ZeroAddress.selector);
        new TGXEmissions(admin, address(tgx), address(lpConservative), address(0));
    }

    /* ============ Branch coverage: invalid pool / amount guards ============ */

    function test_UnstakeRevertsInvalidPool() public {
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__InvalidPool.selector);
        emissions.unstake(2, 1);
    }

    function test_UnstakeRevertsInsufficientBalance() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__InsufficientBalance.selector);
        emissions.unstake(0, 200e18);
    }

    function test_ClaimRevertsInvalidPool() public {
        vm.prank(user1);
        vm.expectRevert(TGXEmissions.TGXEmissions__InvalidPool.selector);
        emissions.claim(2);
    }

    function test_UpdatePoolRevertsInvalidPool() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__InvalidPool.selector);
        emissions.updatePool(2);
    }

    function test_PendingTGXRevertsInvalidPool() public {
        vm.expectRevert(TGXEmissions.TGXEmissions__InvalidPool.selector);
        emissions.pendingTGX(2, user1);
    }

    /* ============ Branch coverage: stake auto-claims pending ============ */

    function test_StakeAutoClaimsExistingPending() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);

        vm.warp(block.timestamp + 30 days);
        uint256 pending = emissions.pendingTGX(0, user1);
        assertGt(pending, 0);

        // Staking again while a balance exists triggers the pending payout path.
        uint256 balBefore = tgx.balanceOf(user1);
        vm.prank(user1);
        emissions.stake(0, 100e18);
        assertGe(tgx.balanceOf(user1) - balBefore, pending);
    }

    /* ============ Branch coverage: sweep / emission-end edges ============ */

    function test_SweepRevertsNothingToSweep() public {
        // An unfunded emissions contract has zero balance and zero owed, so after
        // the emission window there is nothing to sweep.
        TGXEmissions empty = new TGXEmissions(admin, address(tgx), address(lpConservative), address(lpAggressive));
        vm.warp(empty.startTime() + 4 * 365 days + 1);
        vm.prank(admin);
        vm.expectRevert(TGXEmissions.TGXEmissions__NothingToSweep.selector);
        empty.sweepUndistributed(treasury);
    }

    function test_UpdatePoolAfterEmissionEndAddsNoRewards() public {
        vm.prank(user1);
        emissions.stake(0, 100e18);
        uint256 start = emissions.startTime();

        // First update right at end captures the full schedule.
        vm.warp(start + 4 * 365 days);
        emissions.updatePool(0);
        (,,, uint256 accAfterEnd,) = emissions.pools(0);

        // A later update past the end adds nothing (fromTime >= emissionEnd).
        vm.warp(start + 5 * 365 days);
        emissions.updatePool(0);
        (,,, uint256 accLater,) = emissions.pools(0);
        assertEq(accLater, accAfterEnd);
    }
}
