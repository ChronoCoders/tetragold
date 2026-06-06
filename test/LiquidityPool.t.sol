// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockVaultManager {
    LiquidityPool public pool;

    constructor(address _pool) {
        pool = LiquidityPool(_pool);
    }

    function borrow(uint256 amount, address token) external returns (LiquidityPool.PoolType) {
        return pool.borrow(amount, token);
    }

    function repay(uint256 principal, uint256 interest, address token, LiquidityPool.PoolType poolType)
        external
        returns (bool)
    {
        // Approve first
        IERC20(token).approve(address(pool), principal + interest);
        return pool.repay(principal, interest, token, poolType);
    }
}

contract LiquidityPoolTest is Test {
    LiquidityPool public pool;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockVaultManager public vaultManager;

    address public admin;
    address public lp1;
    address public lp2;

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_DEPOSIT = 100e6;

    event LPDeposit(
        address indexed user,
        uint256 amount,
        LiquidityPool.PoolType indexed poolType,
        uint256 lpTokens,
        address indexed token
    );

    event LPWithdrawal(
        address indexed user,
        uint256 amount,
        LiquidityPool.PoolType indexed poolType,
        uint256 lpTokens,
        address indexed token
    );

    event Borrowed(uint256 amount, address indexed token, LiquidityPool.PoolType indexed poolType);
    event Repaid(uint256 amount, address indexed token, LiquidityPool.PoolType indexed poolType);
    event UtilizationUpdated(LiquidityPool.PoolType indexed poolType, uint256 newRate);

    function setUp() public {
        admin = vm.addr(1);
        lp1 = vm.addr(2);
        lp2 = vm.addr(3);

        vm.startPrank(admin);

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy liquidity pool
        pool = new LiquidityPool(address(usdc), address(usdt));

        // Deploy mock vault manager
        vaultManager = new MockVaultManager(address(pool));

        // Grant VAULT_MANAGER_ROLE to mock vault manager
        pool.grantRole(pool.VAULT_MANAGER_ROLE(), address(vaultManager));

        vm.stopPrank();

        // Mint tokens to LPs
        usdc.mint(lp1, 1000000e6); // 1M USDC
        usdt.mint(lp1, 1000000e6); // 1M USDT
        usdc.mint(lp2, 1000000e6);
        usdt.mint(lp2, 1000000e6);

        // Mint tokens to vault manager for repayments
        usdc.mint(address(vaultManager), 1000000e6);
        usdt.mint(address(vaultManager), 1000000e6);
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertEq(pool.usdc(), address(usdc));
        assertEq(pool.usdt(), address(usdt));

        // Check LP tokens created
        (,,, address conservativeLpToken,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        (,,, address aggressiveLpToken,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);

        assertTrue(conservativeLpToken != address(0));
        assertTrue(aggressiveLpToken != address(0));

        // Check roles
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pool.hasRole(pool.VAULT_MANAGER_ROLE(), address(vaultManager)));
    }

    /* ============ Deposit Tests ============ */

    function test_DepositLP() public {
        uint256 amount = 1000e6; // 1000 USDC

        vm.startPrank(lp1);
        usdc.approve(address(pool), amount);

        vm.expectEmit(true, true, true, true);
        emit LPDeposit(lp1, amount, LiquidityPool.PoolType.CONSERVATIVE, amount, address(usdc));

        uint256 lpTokens = pool.depositLP(amount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // First deposit should be 1:1
        assertEq(lpTokens, amount);

        // Check pool state
        (uint256 totalDeposits, uint256 totalBorrowed, uint256 utilizationRate,,) =
            pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);

        assertEq(totalDeposits, amount);
        assertEq(totalBorrowed, 0);
        assertEq(utilizationRate, 0);

        // Check LP token balance
        (,,, address lpToken,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(IERC20(lpToken).balanceOf(lp1), lpTokens);
    }

    function test_DepositLPMultipleUsers() public {
        uint256 amount1 = 1000e6;
        uint256 amount2 = 2000e6;

        // First deposit
        vm.startPrank(lp1);
        usdc.approve(address(pool), amount1);
        uint256 lpTokens1 = pool.depositLP(amount1, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Second deposit
        vm.startPrank(lp2);
        usdc.approve(address(pool), amount2);
        uint256 lpTokens2 = pool.depositLP(amount2, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Check proportional LP tokens
        assertEq(lpTokens1, amount1);
        assertEq(lpTokens2, amount2);

        // Check total deposits
        (uint256 totalDeposits,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(totalDeposits, amount1 + amount2);
    }

    function test_DepositLPRevertsWhenBelowMinimum() public {
        uint256 amount = 50e6; // Below MIN_DEPOSIT

        vm.startPrank(lp1);
        usdc.approve(address(pool), amount);

        vm.expectRevert(LiquidityPool.LiquidityPool__InsufficientDeposit.selector);
        pool.depositLP(amount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();
    }

    function test_DepositLPRevertsWhenPaused() public {
        vm.prank(admin);
        pool.pause();

        vm.startPrank(lp1);
        usdc.approve(address(pool), 1000e6);

        vm.expectRevert();
        pool.depositLP(1000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();
    }

    function test_DepositLPAggressivePool() public {
        uint256 amount = 5000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), amount);
        uint256 lpTokens = pool.depositLP(amount, LiquidityPool.PoolType.AGGRESSIVE, address(usdc));
        vm.stopPrank();

        assertEq(lpTokens, amount);

        (uint256 totalDeposits,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);
        assertEq(totalDeposits, amount);
    }

    /* ============ Withdrawal Tests ============ */

    function test_WithdrawLP() public {
        uint256 depositAmount = 1000e6;

        // Deposit first
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        uint256 lpTokens = pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));

        // Withdraw half
        uint256 withdrawLpTokens = lpTokens / 2;
        uint256 balanceBefore = usdc.balanceOf(lp1);

        vm.expectEmit(true, true, true, false);
        emit LPWithdrawal(lp1, 0, LiquidityPool.PoolType.CONSERVATIVE, withdrawLpTokens, address(usdc));

        uint256 amountReturned = pool.withdrawLP(withdrawLpTokens, LiquidityPool.PoolType.CONSERVATIVE);
        vm.stopPrank();

        // Check amount returned
        assertApproxEqAbs(amountReturned, depositAmount / 2, 1);

        // Check balance
        assertEq(usdc.balanceOf(lp1), balanceBefore + amountReturned);

        // Check pool state
        (uint256 totalDeposits,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertApproxEqAbs(totalDeposits, depositAmount / 2, 1);
    }

    function test_WithdrawLPRevertsWhenInsufficientLiquidity() public {
        uint256 depositAmount = 1000e6;

        // Deposit
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        uint256 lpTokens = pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Borrow most of the liquidity
        vm.prank(address(vaultManager));
        pool.borrow(900e6, address(usdc));

        // Try to withdraw all
        vm.startPrank(lp1);
        vm.expectRevert(LiquidityPool.LiquidityPool__InsufficientLiquidity.selector);
        pool.withdrawLP(lpTokens, LiquidityPool.PoolType.CONSERVATIVE);
        vm.stopPrank();
    }

    function test_WithdrawLPRevertsWhenZeroAmount() public {
        vm.startPrank(lp1);
        vm.expectRevert(LiquidityPool.LiquidityPool__InvalidAmount.selector);
        pool.withdrawLP(0, LiquidityPool.PoolType.CONSERVATIVE);
        vm.stopPrank();
    }

    /* ============ Borrow/Repay Tests ============ */

    function test_Borrow() public {
        uint256 depositAmount = 10000e6;
        uint256 borrowAmount = 5000e6;

        // Deposit liquidity
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Borrow
        vm.expectEmit(true, true, true, true);
        emit Borrowed(borrowAmount, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        vm.prank(address(vaultManager));
        LiquidityPool.PoolType poolType = pool.borrow(borrowAmount, address(usdc));

        assertEq(uint8(poolType), uint8(LiquidityPool.PoolType.CONSERVATIVE));

        // Check pool state
        (uint256 totalDeposits, uint256 totalBorrowed, uint256 utilizationRate,,) =
            pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);

        assertEq(totalDeposits, depositAmount);
        assertEq(totalBorrowed, borrowAmount);
        assertEq(utilizationRate, 5000); // 50%
    }

    function test_BorrowRevertsWhenNotVaultManager() public {
        vm.expectRevert();
        pool.borrow(1000e6, address(usdc));
    }

    function test_BorrowRevertsWhenInsufficientLiquidity() public {
        uint256 depositAmount = 1000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        vm.prank(address(vaultManager));
        vm.expectRevert(LiquidityPool.LiquidityPool__InsufficientLiquidity.selector);
        pool.borrow(2000e6, address(usdc));
    }

    function test_Repay() public {
        uint256 depositAmount = 10000e6;
        uint256 borrowAmount = 5000e6;

        // Deposit and borrow
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        vm.prank(address(vaultManager));
        pool.borrow(borrowAmount, address(usdc));

        // Repay
        vm.expectEmit(true, true, true, true);
        emit Repaid(borrowAmount, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        vm.prank(address(vaultManager));
        bool success = vaultManager.repay(borrowAmount, 0, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        assertTrue(success);

        // Check pool state
        (, uint256 totalBorrowed, uint256 utilizationRate,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);

        assertEq(totalBorrowed, 0);
        assertEq(utilizationRate, 0);
    }

    function test_RepayRevertsWhenNotVaultManager() public {
        vm.expectRevert();
        pool.repay(1000e6, 0, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);
    }

    /// @dev Repay accounting regression: with multiple borrows outstanding, one
    ///      position's interest payment must NOT be misclassified as another
    ///      position's principal — totalBorrowed decreases only by the declared
    ///      principal, and the interest is credited to depositors
    function test_RepayWithInterestCreditsDepositorsNotPrincipal() public {
        uint256 depositAmount = 50_000e6;
        uint256 borrowA = 5_000e6;
        uint256 borrowB = 7_000e6;
        uint256 interest = 25e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Two outstanding borrows (e.g., two positions)
        vm.startPrank(address(vaultManager));
        pool.borrow(borrowA, address(usdc));
        pool.borrow(borrowB, address(usdc));
        vm.stopPrank();

        (uint256 depositsBefore, uint256 borrowedBefore,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(borrowedBefore, borrowA + borrowB);

        // Repay position A's principal plus interest
        usdc.mint(address(vaultManager), interest); // fund the interest portion
        vm.prank(address(vaultManager));
        vaultManager.repay(borrowA, interest, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        (uint256 depositsAfter, uint256 borrowedAfter,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);

        // Only the declared principal reduces totalBorrowed — position B's
        // debt record is untouched
        assertEq(borrowedAfter, borrowB);
        // The interest is credited to depositors
        assertEq(depositsAfter, depositsBefore + interest);
    }

    /// @dev Cross-pool routing regression: when the same token is borrowed from
    ///      BOTH pools, repaying the AGGRESSIVE borrow must decrement AGGRESSIVE
    ///      accounting and credit AGGRESSIVE depositors — not CONSERVATIVE
    ///      (the old scan-by-order lookup always hit CONSERVATIVE first)
    function test_RepayRoutesToOriginPoolWhenBothPoolsHaveBorrows() public {
        // Seed CONSERVATIVE with little liquidity, AGGRESSIVE with plenty
        vm.startPrank(lp1);
        usdc.approve(address(pool), 1_000e6);
        pool.depositLP(1_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        vm.startPrank(lp2);
        usdc.approve(address(pool), 20_000e6);
        pool.depositLP(20_000e6, LiquidityPool.PoolType.AGGRESSIVE, address(usdc));
        vm.stopPrank();

        // First borrow drains CONSERVATIVE, second spills into AGGRESSIVE
        vm.startPrank(address(vaultManager));
        LiquidityPool.PoolType poolA = pool.borrow(1_000e6, address(usdc));
        LiquidityPool.PoolType poolB = pool.borrow(5_000e6, address(usdc));
        vm.stopPrank();

        assertEq(uint8(poolA), uint8(LiquidityPool.PoolType.CONSERVATIVE));
        assertEq(uint8(poolB), uint8(LiquidityPool.PoolType.AGGRESSIVE));

        uint256 interest = 50e6;
        usdc.mint(address(vaultManager), interest);
        (uint256 aggDepositsBefore,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);

        // Repay the AGGRESSIVE borrow with interest
        vm.prank(address(vaultManager));
        vaultManager.repay(5_000e6, interest, address(usdc), poolB);

        // AGGRESSIVE accounting cleared and its depositors got the interest
        (uint256 aggDepositsAfter, uint256 aggBorrowed,,,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);
        assertEq(aggBorrowed, 0);
        assertEq(pool.borrowedByToken(LiquidityPool.PoolType.AGGRESSIVE, address(usdc)), 0);
        assertEq(aggDepositsAfter, aggDepositsBefore + interest);

        // CONSERVATIVE untouched
        (, uint256 consBorrowed,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(consBorrowed, 1_000e6);
        assertEq(pool.borrowedByToken(LiquidityPool.PoolType.CONSERVATIVE, address(usdc)), 1_000e6);
    }

    /// @dev Repaying more principal than the declared pool has outstanding must
    ///      revert instead of silently corrupting another pool's accounting
    function test_RepayRevertsWhenPrincipalExceedsPoolBorrow() public {
        vm.startPrank(lp1);
        usdc.approve(address(pool), 10_000e6);
        pool.depositLP(10_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        vm.prank(address(vaultManager));
        pool.borrow(1_000e6, address(usdc));

        // AGGRESSIVE has no borrow of this token
        vm.startPrank(address(vaultManager));
        usdc.approve(address(pool), 1_000e6);
        vm.expectRevert(LiquidityPool.LiquidityPool__RepayExceedsBorrowed.selector);
        pool.repay(1_000e6, 0, address(usdc), LiquidityPool.PoolType.AGGRESSIVE);
        vm.stopPrank();
    }

    /* ============ APY Calculation Tests ============ */

    function test_CalculateBorrowAPY() public {
        uint256 depositAmount = 10000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // 0% utilization: 5% APY
        uint256 apy = pool.calculateBorrowAPY(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(apy, 500); // 5%

        // 40% utilization: ~10% APY
        vm.prank(address(vaultManager));
        pool.borrow(4000e6, address(usdc));

        apy = pool.calculateBorrowAPY(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(apy, 1000); // 10%

        // Repay and borrow to 80% utilization: 15% APY
        vm.prank(address(vaultManager));
        vaultManager.repay(4000e6, 0, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        vm.prank(address(vaultManager));
        pool.borrow(8000e6, address(usdc));

        apy = pool.calculateBorrowAPY(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(apy, 1500); // 15%

        // 90% utilization: 40% APY
        vm.prank(address(vaultManager));
        vaultManager.repay(8000e6, 0, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        vm.prank(address(vaultManager));
        pool.borrow(9000e6, address(usdc));

        apy = pool.calculateBorrowAPY(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(apy, 4000); // 40%
    }

    function test_CalculateLPAPY() public {
        uint256 depositAmount = 10000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // 50% utilization
        vm.prank(address(vaultManager));
        pool.borrow(5000e6, address(usdc));

        uint256 lpApy = pool.calculateLPAPY(LiquidityPool.PoolType.CONSERVATIVE);

        // Borrow APY at 50% utilization should be ~12.5%
        // LP APY = 12.5% × 50% = 6.25% = 625 basis points
        assertApproxEqAbs(lpApy, 625, 100);
    }

    /* ============ LP Token Pricing Tests ============ */

    function test_CalculateLPTokenPrice() public {
        // Initial price should be 1:1
        uint256 price = pool.calculateLPTokenPrice(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(price, 1e18);

        // After deposit, still 1:1 (no interest accrued)
        vm.startPrank(lp1);
        usdc.approve(address(pool), 1000e6);
        pool.depositLP(1000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        price = pool.calculateLPTokenPrice(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(price, 1e18);
    }

    function test_LPTokenPriceWithInterest() public {
        uint256 depositAmount = 10000e6;

        // Deposit
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Borrow 50%
        vm.prank(address(vaultManager));
        pool.borrow(5000e6, address(usdc));

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Trigger interest accrual
        vm.startPrank(lp2);
        usdc.approve(address(pool), MIN_DEPOSIT);
        pool.depositLP(MIN_DEPOSIT, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // LP token price should have increased due to accrued interest
        uint256 price = pool.calculateLPTokenPrice(LiquidityPool.PoolType.CONSERVATIVE);
        assertTrue(price > 1e18);
    }

    /* ============ Utilization Tests ============ */

    function test_GetAvailableLiquidity() public {
        uint256 depositAmount = 10000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        uint256 available = pool.getAvailableLiquidity(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(available, depositAmount);

        // Borrow some
        vm.prank(address(vaultManager));
        pool.borrow(3000e6, address(usdc));

        available = pool.getAvailableLiquidity(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(available, depositAmount - 3000e6);
    }

    function test_UtilizationUpdates() public {
        uint256 depositAmount = 10000e6;

        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);

        vm.expectEmit(true, true, true, true);
        emit UtilizationUpdated(LiquidityPool.PoolType.CONSERVATIVE, 0);

        pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // Borrow 50%
        vm.expectEmit(true, true, true, true);
        emit UtilizationUpdated(LiquidityPool.PoolType.CONSERVATIVE, 5000);

        vm.prank(address(vaultManager));
        pool.borrow(5000e6, address(usdc));

        (,, uint256 utilization,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(utilization, 5000); // 50%
    }

    /* ============ Access Control Tests ============ */

    function test_PauseUnpause() public {
        vm.prank(admin);
        pool.pause();

        assertTrue(pool.paused());

        vm.prank(admin);
        pool.unpause();

        assertFalse(pool.paused());
    }

    function test_PauseRevertsWhenNotAdmin() public {
        vm.expectRevert();
        pool.pause();
    }

    /* ============ Multi-Token Tests ============ */

    function test_DepositWithUSDT() public {
        uint256 amount = 1000e6;

        vm.startPrank(lp1);
        usdt.approve(address(pool), amount);
        uint256 lpTokens = pool.depositLP(amount, LiquidityPool.PoolType.CONSERVATIVE, address(usdt));
        vm.stopPrank();

        assertEq(lpTokens, amount);
    }

    function test_BorrowMultipleTokens() public {
        // Deposit both USDC and USDT
        vm.startPrank(lp1);
        usdc.approve(address(pool), 5000e6);
        pool.depositLP(5000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));

        usdt.approve(address(pool), 5000e6);
        pool.depositLP(5000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdt));
        vm.stopPrank();

        // Borrow USDC
        vm.prank(address(vaultManager));
        pool.borrow(2000e6, address(usdc));

        // Borrow USDT
        vm.prank(address(vaultManager));
        pool.borrow(2000e6, address(usdt));

        (uint256 totalDeposits, uint256 totalBorrowed,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);

        assertEq(totalDeposits, 10000e6);
        assertEq(totalBorrowed, 4000e6);
    }

    /* ============ Edge Case Tests ============ */

    function test_CompleteLifecycle() public {
        uint256 depositAmount = 10000e6;

        // 1. Deposit
        vm.startPrank(lp1);
        usdc.approve(address(pool), depositAmount);
        uint256 lpTokens = pool.depositLP(depositAmount, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        // 2. Borrow
        uint256 borrowAmount = 5000e6;
        vm.prank(address(vaultManager));
        pool.borrow(borrowAmount, address(usdc));

        // 3. Repay immediately (no interest)
        vm.prank(address(vaultManager));
        vaultManager.repay(borrowAmount, 0, address(usdc), LiquidityPool.PoolType.CONSERVATIVE);

        // 4. Withdraw
        vm.startPrank(lp1);
        uint256 amountReturned = pool.withdrawLP(lpTokens, LiquidityPool.PoolType.CONSERVATIVE);
        vm.stopPrank();

        // Should get back approximately what was deposited (no interest in this scenario)
        assertApproxEqAbs(amountReturned, depositAmount, 1);
    }

    function test_MultipleDepositsAndWithdrawals() public {
        // Multiple deposits
        vm.startPrank(lp1);
        usdc.approve(address(pool), 3000e6);
        pool.depositLP(1000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        pool.depositLP(1000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        pool.depositLP(1000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();

        (uint256 totalDeposits,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertEq(totalDeposits, 3000e6);

        // Get LP token balance
        (,,, address lpToken,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        uint256 lpBalance = IERC20(lpToken).balanceOf(lp1);

        // Withdraw in parts
        vm.startPrank(lp1);
        pool.withdrawLP(lpBalance / 3, LiquidityPool.PoolType.CONSERVATIVE);
        pool.withdrawLP(lpBalance / 3, LiquidityPool.PoolType.CONSERVATIVE);
        vm.stopPrank();

        (totalDeposits,,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        assertApproxEqAbs(totalDeposits, 1000e6, 2); // Allow small rounding
    }
}
