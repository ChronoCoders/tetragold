// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LPToken} from "./LPToken.sol";

/**
 * @title LiquidityPool
 * @dev Manages liquidity pools for leveraged positions in Tetra Gold protocol
 */
contract LiquidityPool is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ============ Constants ============ */

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_DEPOSIT = 100e6; // 100 USDC/USDT (6 decimals)

    // Interest rate model parameters (in basis points)
    uint256 public constant BASE_RATE = 500; // 5%
    uint256 public constant SLOPE1 = 1000; // 10%
    uint256 public constant SLOPE2 = 5000; // 50%
    uint256 public constant OPTIMAL_UTILIZATION = 8000; // 80%

    /* ============ Enums ============ */

    enum PoolType {
        CONSERVATIVE,
        AGGRESSIVE
    }

    /* ============ Structs ============ */

    struct Pool {
        uint256 totalDeposits; // Total LP deposits in underlying token
        uint256 totalBorrowed; // Currently borrowed amount
        uint256 utilizationRate; // Borrowed / Deposits (basis points)
        uint256 lastUpdateTimestamp; // Last time interest was accrued
        uint256 accruedInterest; // Total interest accrued
        address lpToken; // LP token address
        mapping(address => bool) supportedTokens; // Supported collateral tokens
    }

    /* ============ State Variables ============ */

    mapping(PoolType => Pool) public pools;
    mapping(PoolType => mapping(address => uint256)) public poolBalances; // poolType => token => balance
    mapping(PoolType => mapping(address => uint256)) public borrowedByToken; // poolType => token => borrowed

    address public immutable usdc;
    address public immutable usdt;

    /* ============ Events ============ */

    event LPDeposit(
        address indexed user, uint256 amount, PoolType indexed poolType, uint256 lpTokens, address indexed token
    );

    event LPWithdrawal(
        address indexed user, uint256 amount, PoolType indexed poolType, uint256 lpTokens, address indexed token
    );

    event Borrowed(uint256 amount, address indexed token, PoolType indexed poolType);
    event Repaid(uint256 amount, address indexed token, PoolType indexed poolType);
    event UtilizationUpdated(PoolType indexed poolType, uint256 newRate);

    /* ============ Errors ============ */

    error LiquidityPool__InsufficientDeposit();
    error LiquidityPool__InsufficientLiquidity();
    error LiquidityPool__UnsupportedToken();
    error LiquidityPool__InvalidAmount();

    /* ============ Constructor ============ */

    constructor(address _usdc, address _usdt) {
        require(_usdc != address(0), "LiquidityPool: zero usdc address");
        require(_usdt != address(0), "LiquidityPool: zero usdt address");

        usdc = _usdc;
        usdt = _usdt;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Initialize Conservative Pool
        pools[PoolType.CONSERVATIVE].lpToken = address(new LPToken("Tetra Gold LP Conservative", "TGLP-C"));
        pools[PoolType.CONSERVATIVE].supportedTokens[_usdc] = true;
        pools[PoolType.CONSERVATIVE].supportedTokens[_usdt] = true;
        pools[PoolType.CONSERVATIVE].lastUpdateTimestamp = block.timestamp;

        // Initialize Aggressive Pool
        pools[PoolType.AGGRESSIVE].lpToken = address(new LPToken("Tetra Gold LP Aggressive", "TGLP-A"));
        pools[PoolType.AGGRESSIVE].supportedTokens[_usdc] = true;
        pools[PoolType.AGGRESSIVE].supportedTokens[_usdt] = true;
        pools[PoolType.AGGRESSIVE].lastUpdateTimestamp = block.timestamp;
    }

    /* ============ External Functions ============ */

    /**
     * @dev Deposit tokens to become a liquidity provider
     * @param amount Amount of tokens to deposit
     * @param poolType Type of pool (Conservative or Aggressive)
     * @param token Token address (USDC or USDT)
     * @return lpTokens Amount of LP tokens minted
     */
    function depositLP(uint256 amount, PoolType poolType, address token)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 lpTokens)
    {
        if (amount < MIN_DEPOSIT) revert LiquidityPool__InsufficientDeposit();
        if (!pools[poolType].supportedTokens[token]) revert LiquidityPool__UnsupportedToken();

        Pool storage pool = pools[poolType];

        // Accrue interest before deposit
        _accrueInterest(poolType);

        // Calculate LP tokens to mint
        uint256 lpTokenPrice = calculateLPTokenPrice(poolType);
        lpTokens = (amount * 1e18) / lpTokenPrice;

        // Transfer tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // slither-disable-next-line reentrancy-eth
        // Update pool state
        pool.totalDeposits += amount;
        poolBalances[poolType][token] += amount;

        // Mint LP tokens
        LPToken(pool.lpToken).mint(msg.sender, lpTokens);

        // Update utilization
        _updateUtilization(poolType);

        emit LPDeposit(msg.sender, amount, poolType, lpTokens, token);
    }

    /**
     * @dev Withdraw tokens by burning LP tokens
     * @param lpTokenAmount Amount of LP tokens to burn
     * @param poolType Type of pool
     * @return amount Amount of underlying tokens returned
     */
    function withdrawLP(uint256 lpTokenAmount, PoolType poolType)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        if (lpTokenAmount == 0) revert LiquidityPool__InvalidAmount();

        Pool storage pool = pools[poolType];

        // Accrue interest before withdrawal
        _accrueInterest(poolType);

        // Calculate amount to return
        uint256 lpTokenPrice = calculateLPTokenPrice(poolType);
        amount = (lpTokenAmount * lpTokenPrice) / 1e18;

        // Check available liquidity
        uint256 availableLiquidity = getAvailableLiquidity(poolType);
        if (amount > availableLiquidity) revert LiquidityPool__InsufficientLiquidity();

        // Burn LP tokens
        LPToken(pool.lpToken).burn(msg.sender, lpTokenAmount);

        // Determine which token to return (prioritize USDC)
        address tokenToReturn;
        if (poolBalances[poolType][usdc] >= amount) {
            tokenToReturn = usdc;
        } else if (poolBalances[poolType][usdt] >= amount) {
            tokenToReturn = usdt;
        } else {
            revert LiquidityPool__InsufficientLiquidity();
        }

        // slither-disable-next-line reentrancy-eth
        // Update pool state
        pool.totalDeposits -= amount;
        poolBalances[poolType][tokenToReturn] -= amount;

        // Transfer tokens to user
        IERC20(tokenToReturn).safeTransfer(msg.sender, amount);

        // Update utilization
        _updateUtilization(poolType);

        emit LPWithdrawal(msg.sender, amount, poolType, lpTokenAmount, tokenToReturn);
    }

    /**
     * @dev Borrow tokens from the pool (only VaultManager)
     * @param amount Amount to borrow
     * @param token Token address
     * @return success True if borrow succeeded
     */
    function borrow(uint256 amount, address token)
        external
        onlyRole(VAULT_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
        returns (bool success)
    {
        if (amount == 0) revert LiquidityPool__InvalidAmount();

        // Determine pool type based on caller's context
        // For now, check both pools for availability
        PoolType poolType = _selectPoolForBorrow(amount, token);

        Pool storage pool = pools[poolType];

        if (!pool.supportedTokens[token]) revert LiquidityPool__UnsupportedToken();

        // Accrue interest before borrow
        _accrueInterest(poolType);

        // Check available liquidity
        if (poolBalances[poolType][token] < amount) revert LiquidityPool__InsufficientLiquidity();

        // slither-disable-next-line reentrancy-eth
        // Update pool state
        pool.totalBorrowed += amount;
        poolBalances[poolType][token] -= amount;
        borrowedByToken[poolType][token] += amount;

        // Transfer tokens to VaultManager
        IERC20(token).safeTransfer(msg.sender, amount);

        // Update utilization
        _updateUtilization(poolType);

        emit Borrowed(amount, token, poolType);

        return true;
    }

    /**
     * @dev Repay borrowed tokens (only VaultManager)
     * @param principal Principal amount being repaid (reduces totalBorrowed)
     * @param interest Interest amount being paid (credited to depositors)
     * @param token Token address
     * @return success True if repay succeeded
     *
     * The caller declares the principal/interest split explicitly. Inferring it
     * from pool.totalBorrowed (as previously done) misclassified one position's
     * interest as another position's principal whenever other borrows were
     * outstanding, draining totalBorrowed and silently denying LPs their
     * interest credit.
     */
    function repay(uint256 principal, uint256 interest, address token)
        external
        onlyRole(VAULT_MANAGER_ROLE)
        nonReentrant
        whenNotPaused
        returns (bool success)
    {
        if (principal == 0) revert LiquidityPool__InvalidAmount();

        // Find which pool has the borrow
        PoolType poolType = _findPoolWithBorrow(token);

        Pool storage pool = pools[poolType];

        // Accrue interest before repay
        _accrueInterest(poolType);

        // Transfer principal + interest from VaultManager
        uint256 amount = principal + interest;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // slither-disable-next-line reentrancy-eth
        // Update pool state
        pool.totalBorrowed -= principal;
        borrowedByToken[poolType][token] -= principal;
        poolBalances[poolType][token] += amount;

        // Add interest to total deposits (makes it available for withdrawal)
        if (interest > 0) {
            pool.totalDeposits += interest;
            uint256 reduce = interest > pool.accruedInterest ? pool.accruedInterest : interest;
            pool.accruedInterest -= reduce; // Reduce accrued since it's now paid
        }

        // Update utilization
        _updateUtilization(poolType);

        emit Repaid(amount, token, poolType);

        return true;
    }

    /**
     * @dev Pause the contract (admin only)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract (admin only)
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /* ============ Public View Functions ============ */

    /**
     * @dev Calculate current borrow APY for a pool
     * @param poolType Type of pool
     * @return apy Annual percentage yield in basis points
     */
    function calculateBorrowAPY(PoolType poolType) public view returns (uint256 apy) {
        Pool storage pool = pools[poolType];
        uint256 utilization = pool.utilizationRate;

        if (utilization <= OPTIMAL_UTILIZATION) {
            // Below optimal: APY = baseRate + (utilization / optimal) × slope1
            apy = BASE_RATE + (utilization * SLOPE1) / OPTIMAL_UTILIZATION;
        } else {
            // Above optimal: APY = baseRate + slope1 + ((utilization - optimal) / (100% - optimal)) × slope2
            uint256 excessUtilization = utilization - OPTIMAL_UTILIZATION;
            uint256 excessRate = (excessUtilization * SLOPE2) / (BASIS_POINTS - OPTIMAL_UTILIZATION);
            apy = BASE_RATE + SLOPE1 + excessRate;
        }
    }

    /**
     * @dev Calculate current LP APY (returns after fees)
     * @param poolType Type of pool
     * @return apy Annual percentage yield for LPs in basis points
     */
    function calculateLPAPY(PoolType poolType) public view returns (uint256 apy) {
        uint256 borrowAPY = calculateBorrowAPY(poolType);
        uint256 utilization = pools[poolType].utilizationRate;

        // LP APY = Borrow APY × Utilization Rate
        apy = (borrowAPY * utilization) / BASIS_POINTS;
    }

    /**
     * @dev Get available liquidity in a pool
     * @param poolType Type of pool
     * @return available Available liquidity
     */
    function getAvailableLiquidity(PoolType poolType) public view returns (uint256 available) {
        Pool storage pool = pools[poolType];
        available = pool.totalDeposits - pool.totalBorrowed;
    }

    /**
     * @dev Calculate LP token price
     * @param poolType Type of pool
     * @return price Price of 1 LP token in underlying (18 decimals)
     */
    function calculateLPTokenPrice(PoolType poolType) public view returns (uint256 price) {
        Pool storage pool = pools[poolType];
        uint256 totalSupply = IERC20(pool.lpToken).totalSupply();

        if (totalSupply == 0) {
            return 1e18; // 1:1 on first deposit
        }

        // Price = (totalDeposits + accruedInterest) / totalSupply
        uint256 totalValue = pool.totalDeposits + pool.accruedInterest;
        price = (totalValue * 1e18) / totalSupply;
    }

    /**
     * @dev Get pool info
     * @param poolType Type of pool
     * @return totalDeposits Total deposits
     * @return totalBorrowed Total borrowed
     * @return utilizationRate Utilization rate
     * @return lpToken LP token address
     * @return accruedInterest Accrued interest
     */
    function getPoolInfo(PoolType poolType)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 totalBorrowed,
            uint256 utilizationRate,
            address lpToken,
            uint256 accruedInterest
        )
    {
        Pool storage pool = pools[poolType];
        return (pool.totalDeposits, pool.totalBorrowed, pool.utilizationRate, pool.lpToken, pool.accruedInterest);
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev Update utilization rate for a pool
     * @param poolType Type of pool
     */
    function _updateUtilization(PoolType poolType) internal {
        Pool storage pool = pools[poolType];

        if (pool.totalDeposits == 0) {
            pool.utilizationRate = 0;
        } else {
            pool.utilizationRate = (pool.totalBorrowed * BASIS_POINTS) / pool.totalDeposits;
        }

        emit UtilizationUpdated(poolType, pool.utilizationRate);
    }

    /**
     * @dev Accrue interest for a pool
     * @param poolType Type of pool
     */
    function _accrueInterest(PoolType poolType) internal {
        Pool storage pool = pools[poolType];

        uint256 timeDelta = block.timestamp - pool.lastUpdateTimestamp;

        // slither-disable-next-line incorrect-equality
        if (timeDelta == 0 || pool.totalBorrowed == 0) {
            // Intentional: early exit for edge cases
            pool.lastUpdateTimestamp = block.timestamp;
            return;
        }

        // Calculate interest: borrowed × APY × time / year
        uint256 borrowAPY = calculateBorrowAPY(poolType);
        uint256 interest = (pool.totalBorrowed * borrowAPY * timeDelta) / (BASIS_POINTS * 365 days);

        pool.accruedInterest += interest;
        pool.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @dev Select pool for borrowing based on leverage
     * @param amount Amount to borrow
     * @param token Token address
     * @return poolType Selected pool type
     */
    function _selectPoolForBorrow(uint256 amount, address token) internal view returns (PoolType poolType) {
        // Check conservative pool first
        if (poolBalances[PoolType.CONSERVATIVE][token] >= amount) {
            return PoolType.CONSERVATIVE;
        }
        return PoolType.AGGRESSIVE;
    }

    /**
     * @dev Find which pool has active borrows
     * @param token Token address
     * @return poolType Pool type with borrows
     */
    function _findPoolWithBorrow(address token) internal view returns (PoolType poolType) {
        if (borrowedByToken[PoolType.CONSERVATIVE][token] > 0) {
            return PoolType.CONSERVATIVE;
        }
        return PoolType.AGGRESSIVE;
    }
}
