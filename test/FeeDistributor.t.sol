// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTGX} from "./mocks/MockTGX.sol";

contract MockInsuranceFund {
    mapping(address => uint256) public depositsReceived;

    function depositFromFees(uint256 amount, address token) external {
        depositsReceived[token] += amount;
    }

    function getDeposits(address token) external view returns (uint256) {
        return depositsReceived[token];
    }
}

contract FeeDistributorTest is Test {
    FeeDistributor public distributor;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockTGX public tgx;
    MockInsuranceFund public insuranceFund;

    address public admin = address(1);
    address public vaultManager = address(2);
    address public treasury = address(3);
    address public staker1 = address(4);
    address public staker2 = address(5);
    address public staker3 = address(6);

    function setUp() public {
        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        tgx = new MockTGX();

        // Deploy insurance fund mock
        insuranceFund = new MockInsuranceFund();

        // Deploy FeeDistributor
        vm.prank(admin);
        distributor = new FeeDistributor(
            admin,
            address(tgx),
            address(insuranceFund),
            treasury
        );

        // Setup roles and tokens
        vm.startPrank(admin);
        distributor.grantRole(distributor.VAULT_MANAGER_ROLE(), vaultManager);
        distributor.addSupportedToken(address(usdc));
        distributor.addSupportedToken(address(usdt));
        vm.stopPrank();

        // Mint tokens for testing
        usdc.mint(vaultManager, 1000000e6);
        usdt.mint(vaultManager, 1000000e6);
        tgx.mint(staker1, 10000e18);
        tgx.mint(staker2, 20000e18);
        tgx.mint(staker3, 30000e18);
    }

    // ============ Constructor Tests ============

    function test_Constructor() public view {
        assertEq(distributor.tgxToken(), address(tgx));
        assertEq(distributor.insuranceFund(), address(insuranceFund));
        assertEq(distributor.treasury(), treasury);
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorRevertsWithZeroAddresses() public {
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        new FeeDistributor(address(0), address(tgx), address(insuranceFund), treasury);

        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        new FeeDistributor(admin, address(0), address(insuranceFund), treasury);

        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        new FeeDistributor(admin, address(tgx), address(0), treasury);

        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        new FeeDistributor(admin, address(tgx), address(insuranceFund), address(0));
    }

    // ============ Fee Collection & Distribution Tests (8 tests) ============

    function test_CollectFees() public {
        uint256 feeAmount = 10000e6;

        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), feeAmount);
        uint256 collected = distributor.collectFees(address(usdc), feeAmount);
        vm.stopPrank();

        assertEq(collected, feeAmount);

        // Check distribution (30% insurance, 40% treasury, 30% stakers)
        uint256 expectedInsurance = (feeAmount * 3000) / 10000; // 3000e6
        uint256 expectedTreasury = (feeAmount * 4000) / 10000; // 4000e6
        uint256 expectedStakers = (feeAmount * 3000) / 10000; // 3000e6

        assertEq(insuranceFund.getDeposits(address(usdc)), expectedInsurance);
        assertEq(usdc.balanceOf(treasury), expectedTreasury);
        assertEq(distributor.stakerPools(address(usdc)), expectedStakers);
    }

    function test_CollectFeesMultipleTokens() public {
        uint256 usdcFees = 10000e6;
        uint256 usdtFees = 5000e6;

        // Collect USDC fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), usdcFees);
        distributor.collectFees(address(usdc), usdcFees);
        vm.stopPrank();

        // Collect USDT fees
        vm.startPrank(vaultManager);
        usdt.approve(address(distributor), usdtFees);
        distributor.collectFees(address(usdt), usdtFees);
        vm.stopPrank();

        assertEq(distributor.stakerPools(address(usdc)), 3000e6);
        assertEq(distributor.stakerPools(address(usdt)), 1500e6);
    }

    function test_CollectFeesRevertsWhenNotVaultManager() public {
        vm.prank(staker1);
        vm.expectRevert();
        distributor.collectFees(address(usdc), 1000e6);
    }

    function test_CollectFeesRevertsWithZeroAmount() public {
        vm.prank(vaultManager);
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAmount.selector);
        distributor.collectFees(address(usdc), 0);
    }

    function test_CollectFeesRevertsWithUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18);

        vm.prank(vaultManager);
        vm.expectRevert(FeeDistributor.FeeDistributor__TokenNotSupported.selector);
        distributor.collectFees(address(unsupportedToken), 1000e18);
    }

    function test_FeeStatsTracking() public {
        uint256 feeAmount = 10000e6;

        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), feeAmount);
        distributor.collectFees(address(usdc), feeAmount);
        vm.stopPrank();

        FeeDistributor.FeeStats memory stats = distributor.getFeeStats(address(usdc));
        assertEq(stats.totalCollected, feeAmount);
        assertEq(stats.toInsurance, 3000e6);
        assertEq(stats.toTreasury, 4000e6);
        assertEq(stats.toStakers, 3000e6);
    }

    function test_GetDistribution() public view {
        uint256 amount = 10000e6;
        FeeDistributor.Distribution memory dist = distributor.getDistribution(amount);

        assertEq(dist.toInsurance, 3000e6);
        assertEq(dist.toTreasury, 4000e6);
        assertEq(dist.toStakers, 3000e6);
    }

    function test_MultipleFeeCollections() public {
        vm.startPrank(vaultManager);

        // First collection
        usdc.approve(address(distributor), 5000e6);
        distributor.collectFees(address(usdc), 5000e6);

        // Second collection
        usdc.approve(address(distributor), 3000e6);
        distributor.collectFees(address(usdc), 3000e6);

        vm.stopPrank();

        FeeDistributor.FeeStats memory stats = distributor.getFeeStats(address(usdc));
        assertEq(stats.totalCollected, 8000e6);
        assertEq(stats.toInsurance, 2400e6);
        assertEq(stats.toTreasury, 3200e6);
        assertEq(stats.toStakers, 2400e6);
    }

    // ============ TGX Staking Tests (8 tests) ============

    function test_Stake() public {
        uint256 stakeAmount = 1000e18;

        vm.startPrank(staker1);
        tgx.approve(address(distributor), stakeAmount);
        distributor.stake(stakeAmount);
        vm.stopPrank();

        assertEq(distributor.stakedTGX(staker1), stakeAmount);
        assertEq(distributor.totalStakedTGX(), stakeAmount);
        assertEq(tgx.balanceOf(address(distributor)), stakeAmount);
    }

    function test_StakeMultipleUsers() public {
        // Staker1 stakes 1000 TGX
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Staker2 stakes 2000 TGX
        vm.startPrank(staker2);
        tgx.approve(address(distributor), 2000e18);
        distributor.stake(2000e18);
        vm.stopPrank();

        assertEq(distributor.totalStakedTGX(), 3000e18);
        assertEq(distributor.stakedTGX(staker1), 1000e18);
        assertEq(distributor.stakedTGX(staker2), 2000e18);
    }

    function test_StakeRevertsWithZeroAmount() public {
        vm.prank(staker1);
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAmount.selector);
        distributor.stake(0);
    }

    function test_Unstake() public {
        // Stake first
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);

        // Then unstake
        distributor.unstake(500e18);
        vm.stopPrank();

        assertEq(distributor.stakedTGX(staker1), 500e18);
        assertEq(distributor.totalStakedTGX(), 500e18);
        assertEq(tgx.balanceOf(staker1), 9500e18);
    }

    function test_UnstakeAll() public {
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        distributor.unstake(1000e18);
        vm.stopPrank();

        assertEq(distributor.stakedTGX(staker1), 0);
        assertEq(distributor.totalStakedTGX(), 0);
        assertEq(tgx.balanceOf(staker1), 10000e18);
    }

    function test_UnstakeRevertsWithInsufficientStake() public {
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);

        vm.expectRevert(FeeDistributor.FeeDistributor__InsufficientStake.selector);
        distributor.unstake(2000e18);
        vm.stopPrank();
    }

    function test_UnstakeRevertsWithZeroAmount() public {
        vm.prank(staker1);
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAmount.selector);
        distributor.unstake(0);
    }

    function test_GetStakerInfo() public {
        // Staker1 stakes 1000, Staker2 stakes 2000 (total 3000)
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        tgx.approve(address(distributor), 2000e18);
        distributor.stake(2000e18);
        vm.stopPrank();

        FeeDistributor.StakerInfo memory info1 = distributor.getStakerInfo(staker1);
        assertEq(info1.staked, 1000e18);
        assertEq(info1.sharePercentage, 3333); // 33.33%

        FeeDistributor.StakerInfo memory info2 = distributor.getStakerInfo(staker2);
        assertEq(info2.staked, 2000e18);
        assertEq(info2.sharePercentage, 6666); // 66.66%
    }

    // ============ Reward System Tests (8 tests) ============

    function test_RewardCalculation() public {
        // Setup: Staker1 stakes 1000 TGX (100% of total)
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Collect fees (staker gets 30% = 3000 USDC)
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Check pending rewards
        uint256 pending = distributor.getPendingRewards(staker1, address(usdc));
        assertEq(pending, 3000e6);
    }

    function test_RewardCalculationMultipleStakers() public {
        // Staker1: 1000 TGX (25%), Staker2: 3000 TGX (75%)
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        tgx.approve(address(distributor), 3000e18);
        distributor.stake(3000e18);
        vm.stopPrank();

        // Collect 10000 USDC fees (3000 to stakers)
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        uint256 pending1 = distributor.getPendingRewards(staker1, address(usdc));
        uint256 pending2 = distributor.getPendingRewards(staker2, address(usdc));

        assertEq(pending1, 750e6); // 25% of 3000
        assertEq(pending2, 2250e6); // 75% of 3000
    }

    function test_ClaimRewards() public {
        // Setup staking
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Collect fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Claim rewards
        uint256 balanceBefore = usdc.balanceOf(staker1);
        vm.prank(staker1);
        uint256 claimed = distributor.claimRewards(address(usdc));

        assertEq(claimed, 3000e6);
        assertEq(usdc.balanceOf(staker1), balanceBefore + 3000e6);
        // Rewards claimed, pending should be 0
        assertEq(distributor.getPendingRewards(staker1, address(usdc)), 0);
    }

    function test_ClaimRewardsRevertsWhenNoRewards() public {
        vm.prank(staker1);
        vm.expectRevert(FeeDistributor.FeeDistributor__NoRewards.selector);
        distributor.claimRewards(address(usdc));
    }

    function test_ClaimRewardsRevertsWithUnsupportedToken() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18);

        vm.prank(staker1);
        vm.expectRevert(FeeDistributor.FeeDistributor__TokenNotSupported.selector);
        distributor.claimRewards(address(unsupportedToken));
    }

    function test_ClaimAllRewards() public {
        // Setup staking
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Collect fees for both tokens
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);

        usdt.approve(address(distributor), 5000e6);
        distributor.collectFees(address(usdt), 5000e6);
        vm.stopPrank();

        // Claim all rewards
        vm.prank(staker1);
        uint256[] memory amounts = distributor.claimAllRewards();

        assertEq(amounts[0], 3000e6); // USDC
        assertEq(amounts[1], 1500e6); // USDT
    }

    function test_RewardsAfterStakeChange() public {
        // Initial stake
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Collect fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Staker2 joins
        vm.startPrank(staker2);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Staker1 should still have full first period rewards
        uint256 pending1 = distributor.getPendingRewards(staker1, address(usdc));
        assertEq(pending1, 3000e6);

        // Collect more fees (should split 50/50)
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        uint256 pending1After = distributor.getPendingRewards(staker1, address(usdc));
        uint256 pending2After = distributor.getPendingRewards(staker2, address(usdc));

        assertEq(pending1After, 4500e6); // 3000 + 1500
        assertEq(pending2After, 1500e6); // 1500
    }

    function test_RewardsWithUnstake() public {
        // Stake
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Collect fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Unstake (should preserve rewards)
        vm.prank(staker1);
        distributor.unstake(1000e18);

        // Check rewards still claimable
        uint256 pending = distributor.getPendingRewards(staker1, address(usdc));
        assertEq(pending, 3000e6);

        vm.prank(staker1);
        uint256 claimed = distributor.claimRewards(address(usdc));
        assertEq(claimed, 3000e6);
    }

    // ============ Admin Function Tests (4 tests) ============

    function test_UpdateTreasury() public {
        address newTreasury = address(999);

        vm.prank(admin);
        distributor.updateTreasury(newTreasury);

        assertEq(distributor.treasury(), newTreasury);
    }

    function test_UpdateTreasuryRevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        distributor.updateTreasury(address(0));
    }

    function test_UpdateInsuranceFund() public {
        address newFund = address(888);

        vm.prank(admin);
        distributor.updateInsuranceFund(newFund);

        assertEq(distributor.insuranceFund(), newFund);
    }

    function test_UpdateInsuranceFundRevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(FeeDistributor.FeeDistributor__ZeroAddress.selector);
        distributor.updateInsuranceFund(address(0));
    }

    function test_AddSupportedToken() public {
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);

        vm.prank(admin);
        distributor.addSupportedToken(address(newToken));

        assertTrue(distributor.isSupported(address(newToken)));
    }

    function test_PauseUnpause() public {
        vm.prank(admin);
        distributor.pause();
        assertTrue(distributor.paused());

        // Cannot stake when paused
        vm.prank(staker1);
        vm.expectRevert();
        distributor.stake(1000e18);

        vm.prank(admin);
        distributor.unpause();
        assertFalse(distributor.paused());
    }

    function test_PauseRevertsWhenNotAdmin() public {
        vm.prank(staker1);
        vm.expectRevert();
        distributor.pause();
    }

    function test_GetSupportedTokens() public view {
        address[] memory tokens = distributor.getSupportedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdc));
        assertEq(tokens[1], address(usdt));
    }

    // ============ Integration Tests (4 tests) ============

    function test_CompleteLifecycle() public {
        // 1. Multiple stakers stake TGX
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        tgx.approve(address(distributor), 2000e18);
        distributor.stake(2000e18);
        vm.stopPrank();

        // 2. Collect fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 30000e6);
        distributor.collectFees(address(usdc), 30000e6);
        vm.stopPrank();

        // 3. Verify distribution
        assertEq(insuranceFund.getDeposits(address(usdc)), 9000e6); // 30%
        assertEq(usdc.balanceOf(treasury), 12000e6); // 40%

        // 4. Claim rewards
        vm.prank(staker1);
        uint256 claimed1 = distributor.claimRewards(address(usdc));
        assertEq(claimed1, 3000e6); // 1/3 of 9000

        vm.prank(staker2);
        uint256 claimed2 = distributor.claimRewards(address(usdc));
        assertEq(claimed2, 6000e6); // 2/3 of 9000
    }

    function test_MultipleCollectionsOverTime() public {
        // Staker1 stakes
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // First collection
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Staker2 joins
        vm.startPrank(staker2);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        // Second collection
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Verify cumulative stats
        FeeDistributor.FeeStats memory stats = distributor.getFeeStats(address(usdc));
        assertEq(stats.totalCollected, 20000e6);
    }

    function test_ComplexMultiUserScenario() public {
        // Three stakers with different amounts
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 1000e18);
        distributor.stake(1000e18);
        vm.stopPrank();

        vm.startPrank(staker2);
        tgx.approve(address(distributor), 3000e18);
        distributor.stake(3000e18);
        vm.stopPrank();

        vm.startPrank(staker3);
        tgx.approve(address(distributor), 6000e18);
        distributor.stake(6000e18);
        vm.stopPrank();

        // Collect fees for both tokens
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 100000e6);
        distributor.collectFees(address(usdc), 100000e6);

        usdt.approve(address(distributor), 50000e6);
        distributor.collectFees(address(usdt), 50000e6);
        vm.stopPrank();

        // Total staked: 10000 TGX
        // Staker1: 10%, Staker2: 30%, Staker3: 60%
        // USDC staker pool: 30000
        // USDT staker pool: 15000

        uint256 pending1Usdc = distributor.getPendingRewards(staker1, address(usdc));
        uint256 pending2Usdc = distributor.getPendingRewards(staker2, address(usdc));
        uint256 pending3Usdc = distributor.getPendingRewards(staker3, address(usdc));

        assertEq(pending1Usdc, 3000e6); // 10% of 30000
        assertEq(pending2Usdc, 9000e6); // 30% of 30000
        assertEq(pending3Usdc, 18000e6); // 60% of 30000

        // Claim all
        vm.prank(staker1);
        distributor.claimAllRewards();

        vm.prank(staker2);
        distributor.claimAllRewards();

        vm.prank(staker3);
        uint256[] memory amounts = distributor.claimAllRewards();

        assertEq(amounts[0], 18000e6); // USDC
        assertEq(amounts[1], 9000e6); // USDT
    }

    function test_EndToEndWithUnstaking() public {
        // Initial setup
        vm.startPrank(staker1);
        tgx.approve(address(distributor), 5000e18);
        distributor.stake(5000e18);
        vm.stopPrank();

        // Collect fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Partial unstake
        vm.prank(staker1);
        distributor.unstake(2000e18);

        // Another staker joins
        vm.startPrank(staker2);
        tgx.approve(address(distributor), 3000e18);
        distributor.stake(3000e18);
        vm.stopPrank();

        // More fees
        vm.startPrank(vaultManager);
        usdc.approve(address(distributor), 10000e6);
        distributor.collectFees(address(usdc), 10000e6);
        vm.stopPrank();

        // Total staked now: 6000 (3000 staker1 + 3000 staker2)
        // First collection: staker1 got 3000 USDC
        // Second collection: 3000 USDC split 50/50 = 1500 each

        uint256 pending1 = distributor.getPendingRewards(staker1, address(usdc));
        uint256 pending2 = distributor.getPendingRewards(staker2, address(usdc));

        assertEq(pending1, 4500e6); // 3000 + 1500
        assertEq(pending2, 1500e6); // 1500
    }
}
