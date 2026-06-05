// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TGXEmissions
 * @dev MasterChef-style TGX distributor for LiquidityPool LP token stakers.
 *
 * Two pools with fixed weight:
 * - Pool 0: TGLP-C (Conservative LP token) - 80% of emissions
 * - Pool 1: TGLP-A (Aggressive LP token)   - 20% of emissions
 *
 * Step-based yearly emission schedule (total 50,000,000 TGX over 4 years):
 * - Year 1: 25,000,000 TGX  (68,493 TGX/day)
 * - Year 2: 15,000,000 TGX  (41,096 TGX/day)
 * - Year 3:  7,500,000 TGX  (20,548 TGX/day)
 * - Year 4:  2,500,000 TGX  ( 6,849 TGX/day)
 *
 * The remaining 15,000,000 TGX of the 65,000,000 TGX reserve stays in the contract
 * as a buffer, sweepable by admin to treasury after emissions end.
 *
 * Cross-year boundary handling: _calculateRewards() splits any time delta
 * at epoch boundaries so rates are applied correctly regardless of when
 * updatePool() is called.
 *
 * User flow:
 * 1. Provide liquidity to LiquidityPool -> receive TGLP-C or TGLP-A
 * 2. stake(pid, amount) -> accrue TGX rewards
 * 3. claim(pid) or unstake(pid, amount) -> receive TGX
 * 4. Stake TGX in FeeDistributor -> earn protocol fee revenue
 */
contract TGXEmissions is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant YEAR_SECONDS = 365 days; // 31,536,000
    uint256 public constant TOTAL_ALLOC_POINTS = 100;

    // TGX per second for each year epoch.
    // Pre-computed as floor(annualTGX * 1e18 / 31_536_000); rounding loss < 1e-9 TGX per year.
    // Year 1: 25M TGX -> 68,493.15 TGX/day
    // Year 2: 15M TGX -> 41,095.89 TGX/day
    // Year 3: 7.5M TGX -> 20,547.95 TGX/day
    // Year 4: 2.5M TGX ->  6,849.32 TGX/day
    uint256 public constant YEAR1_RATE = 792_744_799_594_114_662;
    uint256 public constant YEAR2_RATE = 475_646_879_756_468_797;
    uint256 public constant YEAR3_RATE = 237_823_439_878_234_398;
    uint256 public constant YEAR4_RATE = 79_274_479_959_411_466;

    // Precision multiplier for accTGXPerShare (standard MasterChef v2 value)
    uint256 private constant PRECISION = 1e12;

    // ============ Structs ============

    struct Pool {
        IERC20 stakingToken; // TGLP-C or TGLP-A
        uint256 allocPoint; // weight: 80 or 20
        uint256 lastUpdateTime;
        uint256 accTGXPerShare; // accumulated TGX per staked token * PRECISION
        uint256 totalStaked;
    }

    struct UserInfo {
        uint256 amount; // staked LP token amount
        uint256 rewardDebt; // amount already accounted for
    }

    // ============ State ============

    IERC20 public immutable tgx;
    uint256 public immutable startTime;

    Pool[2] public pools;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @notice TGX accrued to stakers (via updatePool) but not yet paid out.
    ///         Sweeping is limited to balance minus this amount so claims and
    ///         auto-claiming unstakes keep working after emissions end.
    uint256 public totalOwed;

    // ============ Events ============

    event Staked(address indexed user, uint256 indexed pid, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed pid, uint256 amount);
    event Claimed(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolUpdated(uint256 indexed pid, uint256 accTGXPerShare, uint256 timestamp);
    event EmissionsSweep(address indexed to, uint256 amount);

    // ============ Errors ============

    error TGXEmissions__ZeroAmount();
    error TGXEmissions__InsufficientBalance();
    error TGXEmissions__NothingToClaim();
    error TGXEmissions__EmissionsNotEnded();
    error TGXEmissions__ZeroAddress();
    error TGXEmissions__NothingToSweep();
    error TGXEmissions__InvalidPool();

    // ============ Constructor ============

    /**
     * @param defaultAdmin         Company multisig address
     * @param _tgx                 TGX token address
     * @param conservativeLPToken  TGLP-C token (from LiquidityPool)
     * @param aggressiveLPToken    TGLP-A token (from LiquidityPool)
     */
    constructor(address defaultAdmin, address _tgx, address conservativeLPToken, address aggressiveLPToken) {
        if (defaultAdmin == address(0)) revert TGXEmissions__ZeroAddress();
        if (_tgx == address(0)) revert TGXEmissions__ZeroAddress();
        if (conservativeLPToken == address(0)) revert TGXEmissions__ZeroAddress();
        if (aggressiveLPToken == address(0)) revert TGXEmissions__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        tgx = IERC20(_tgx);
        startTime = block.timestamp;

        // Pool 0: Conservative LP (80%)
        pools[0] = Pool({
            stakingToken: IERC20(conservativeLPToken),
            allocPoint: 80,
            lastUpdateTime: block.timestamp,
            accTGXPerShare: 0,
            totalStaked: 0
        });

        // Pool 1: Aggressive LP (20%)
        pools[1] = Pool({
            stakingToken: IERC20(aggressiveLPToken),
            allocPoint: 20,
            lastUpdateTime: block.timestamp,
            accTGXPerShare: 0,
            totalStaked: 0
        });
    }

    // ============ Public / External ============

    /**
     * @notice Stake LP tokens into a pool to earn TGX emissions.
     * @param pid    Pool index (0 = Conservative, 1 = Aggressive)
     * @param amount Amount of LP tokens to stake
     */
    function stake(uint256 pid, uint256 amount) external nonReentrant {
        if (pid >= 2) revert TGXEmissions__InvalidPool();
        if (amount == 0) revert TGXEmissions__ZeroAmount();

        updatePool(pid);

        Pool storage pool = pools[pid];
        UserInfo storage info = userInfo[pid][msg.sender];

        // Auto-claim pending before updating stake
        if (info.amount > 0) {
            uint256 pending = _pending(info, pool);
            if (pending > 0) {
                totalOwed -= pending;
                tgx.safeTransfer(msg.sender, pending);
                emit Claimed(msg.sender, pid, pending);
            }
        }

        pool.stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        info.amount += amount;
        pool.totalStaked += amount;
        info.rewardDebt = _calcDebt(info.amount, pool.accTGXPerShare);

        emit Staked(msg.sender, pid, amount);
    }

    /**
     * @notice Unstake LP tokens. Pending TGX rewards are automatically claimed.
     * @param pid    Pool index
     * @param amount Amount of LP tokens to withdraw
     */
    function unstake(uint256 pid, uint256 amount) external nonReentrant {
        if (pid >= 2) revert TGXEmissions__InvalidPool();
        if (amount == 0) revert TGXEmissions__ZeroAmount();

        UserInfo storage info = userInfo[pid][msg.sender];
        if (info.amount < amount) revert TGXEmissions__InsufficientBalance();

        updatePool(pid);
        Pool storage pool = pools[pid];

        uint256 pending = _pending(info, pool);
        if (pending > 0) {
            totalOwed -= pending;
            tgx.safeTransfer(msg.sender, pending);
            emit Claimed(msg.sender, pid, pending);
        }

        pool.stakingToken.safeTransfer(msg.sender, amount);
        info.amount -= amount;
        pool.totalStaked -= amount;
        info.rewardDebt = _calcDebt(info.amount, pool.accTGXPerShare);

        emit Unstaked(msg.sender, pid, amount);
    }

    /**
     * @notice Claim pending TGX rewards without changing stake.
     * @param pid Pool index
     */
    function claim(uint256 pid) external nonReentrant {
        if (pid >= 2) revert TGXEmissions__InvalidPool();

        updatePool(pid);
        Pool storage pool = pools[pid];
        UserInfo storage info = userInfo[pid][msg.sender];

        uint256 pending = _pending(info, pool);
        if (pending == 0) revert TGXEmissions__NothingToClaim();

        info.rewardDebt = _calcDebt(info.amount, pool.accTGXPerShare);
        totalOwed -= pending;
        tgx.safeTransfer(msg.sender, pending);

        emit Claimed(msg.sender, pid, pending);
    }

    /**
     * @notice Refresh a pool's accTGXPerShare. Called automatically by stake/unstake/claim.
     *         Can also be called externally to keep the pool state current.
     */
    function updatePool(uint256 pid) public {
        if (pid >= 2) revert TGXEmissions__InvalidPool();
        Pool storage pool = pools[pid];
        uint256 now_ = block.timestamp;

        if (now_ <= pool.lastUpdateTime) return;

        if (pool.totalStaked > 0) {
            uint256 totalRewards = _calculateRewards(pool.lastUpdateTime, now_);
            uint256 poolRewards = totalRewards * pool.allocPoint / TOTAL_ALLOC_POINTS;
            pool.accTGXPerShare += poolRewards * PRECISION / pool.totalStaked;
            totalOwed += poolRewards;
        }

        pool.lastUpdateTime = now_;
        emit PoolUpdated(pid, pool.accTGXPerShare, now_);
    }

    /**
     * @notice Pending TGX rewards for a user in a given pool (view only).
     */
    function pendingTGX(uint256 pid, address user) external view returns (uint256) {
        if (pid >= 2) revert TGXEmissions__InvalidPool();
        Pool storage pool = pools[pid];
        UserInfo storage info = userInfo[pid][user];
        uint256 now_ = block.timestamp;

        uint256 accTGXPerShare = pool.accTGXPerShare;
        if (now_ > pool.lastUpdateTime && pool.totalStaked > 0) {
            uint256 totalRewards = _calculateRewards(pool.lastUpdateTime, now_);
            uint256 poolRewards = totalRewards * pool.allocPoint / TOTAL_ALLOC_POINTS;
            accTGXPerShare += poolRewards * PRECISION / pool.totalStaked;
        }

        return info.amount * accTGXPerShare / PRECISION - info.rewardDebt;
    }

    /**
     * @notice Sweep undistributed TGX to treasury after emissions end.
     * @dev Callable only after the 4-year emission period has elapsed.
     *      Recovers the 15M TGX buffer not emitted during active distribution.
     *      Rewards already accrued to stakers (totalOwed) are excluded so
     *      claim() and the auto-claim in unstake() keep working after the sweep.
     */
    function sweepUndistributed(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert TGXEmissions__ZeroAddress();
        if (block.timestamp < startTime + 4 * YEAR_SECONDS) {
            revert TGXEmissions__EmissionsNotEnded();
        }

        // Accrue any rewards earned since the last interaction so totalOwed is current
        updatePool(0);
        updatePool(1);

        uint256 balance = tgx.balanceOf(address(this));
        if (balance <= totalOwed) revert TGXEmissions__NothingToSweep();
        uint256 sweepable = balance - totalOwed;

        tgx.safeTransfer(to, sweepable);
        emit EmissionsSweep(to, sweepable);
    }

    // ============ Internal ============

    /**
     * @dev Calculate total TGX emitted across all pools between two timestamps.
     *      Handles cross-year boundary correctly by splitting the delta at epoch edges.
     */
    function _calculateRewards(uint256 fromTime, uint256 toTime) internal view returns (uint256 rewards) {
        uint256 emissionEnd = startTime + 4 * YEAR_SECONDS;
        if (fromTime >= emissionEnd || fromTime >= toTime) return 0;
        if (toTime > emissionEnd) toTime = emissionEnd;

        // Year epoch boundaries
        uint256[5] memory bounds;
        bounds[0] = startTime;
        bounds[1] = startTime + YEAR_SECONDS;
        bounds[2] = startTime + 2 * YEAR_SECONDS;
        bounds[3] = startTime + 3 * YEAR_SECONDS;
        bounds[4] = emissionEnd;

        uint256[4] memory rates;
        rates[0] = YEAR1_RATE;
        rates[1] = YEAR2_RATE;
        rates[2] = YEAR3_RATE;
        rates[3] = YEAR4_RATE;

        for (uint256 i = 0; i < 4; i++) {
            if (fromTime >= bounds[i + 1]) continue; // before this epoch
            if (toTime <= bounds[i]) break; // after this epoch

            uint256 segFrom = fromTime > bounds[i] ? fromTime : bounds[i];
            uint256 segTo = toTime < bounds[i + 1] ? toTime : bounds[i + 1];

            rewards += rates[i] * (segTo - segFrom);
        }
    }

    function _pending(UserInfo storage info, Pool storage pool) internal view returns (uint256) {
        return info.amount * pool.accTGXPerShare / PRECISION - info.rewardDebt;
    }

    function _calcDebt(uint256 amount, uint256 accTGXPerShare) internal pure returns (uint256) {
        return amount * accTGXPerShare / PRECISION;
    }
}
