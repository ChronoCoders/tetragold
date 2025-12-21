// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FeeDistributor
 * @notice Manages protocol revenue distribution across InsuranceFund, Treasury, and TGX stakers
 * @dev Collects fees from VaultManager and distributes according to fixed allocation
 */
contract FeeDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant INSURANCE_SHARE = 3000; // 30%
    uint256 public constant TREASURY_SHARE = 4000; // 40%
    uint256 public constant STAKER_SHARE = 3000; // 30%

    // ============ Roles ============

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");

    // ============ Structs ============

    struct Distribution {
        uint256 toInsurance;
        uint256 toTreasury;
        uint256 toStakers;
    }

    struct FeeStats {
        uint256 totalCollected;
        uint256 toInsurance;
        uint256 toTreasury;
        uint256 toStakers;
    }

    struct StakerInfo {
        uint256 staked;
        uint256 sharePercentage; // in basis points
    }

    // ============ State Variables ============

    address public immutable tgxToken;
    address public insuranceFund;
    address public treasury;

    // Staking state
    mapping(address => uint256) public stakedTGX;
    uint256 public totalStakedTGX;

    // Reward accounting (MasterChef style)
    uint256 private constant PRECISION = 1e18;
    mapping(address => uint256) public accRewardPerShare; // token => accumulated reward per share
    mapping(address => mapping(address => uint256)) public rewardDebt; // user => token => reward debt
    mapping(address => mapping(address => uint256)) public claimableRewards; // user => token => claimable
    mapping(address => uint256) public stakerPools; // token => total rewards for stakers

    // Stats tracking
    mapping(address => FeeStats) public feeStats;

    // Supported tokens
    address[] private supportedTokens;
    mapping(address => bool) private isTokenSupported;

    // ============ Events ============

    event FeesCollected(
        address indexed token,
        uint256 total,
        uint256 toInsurance,
        uint256 toTreasury,
        uint256 toStakers
    );
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event InsuranceFundUpdated(address indexed oldFund, address indexed newFund);
    event TokenAdded(address indexed token);

    // ============ Errors ============

    error FeeDistributor__ZeroAddress();
    error FeeDistributor__ZeroAmount();
    error FeeDistributor__InsufficientStake();
    error FeeDistributor__NoRewards();
    error FeeDistributor__TokenNotSupported();

    // ============ Constructor ============

    constructor(
        address _admin,
        address _tgxToken,
        address _insuranceFund,
        address _treasury
    ) {
        if (_admin == address(0)) revert FeeDistributor__ZeroAddress();
        if (_tgxToken == address(0)) revert FeeDistributor__ZeroAddress();
        if (_insuranceFund == address(0)) revert FeeDistributor__ZeroAddress();
        if (_treasury == address(0)) revert FeeDistributor__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        tgxToken = _tgxToken;
        insuranceFund = _insuranceFund;
        treasury = _treasury;
    }

    // ============ Fee Collection Functions ============

    /**
     * @notice Collect and distribute fees from VaultManager
     * @param token Token address
     * @return collected Total amount collected
     */
    function collectFees(address token, uint256 amount)
        external
        onlyRole(VAULT_MANAGER_ROLE)
        whenNotPaused
        returns (uint256 collected)
    {
        if (amount == 0) revert FeeDistributor__ZeroAmount();
        if (!isTokenSupported[token]) revert FeeDistributor__TokenNotSupported();

        // Transfer fees from VaultManager
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Distribute fees
        _distributeFees(token, amount);

        return amount;
    }

    /**
     * @notice Internal function to distribute fees
     * @param token Token address
     * @param amount Total amount to distribute
     */
    function _distributeFees(address token, uint256 amount) internal {
        // Calculate distribution
        uint256 insuranceAmount = (amount * INSURANCE_SHARE) / BASIS_POINTS;
        uint256 treasuryAmount = (amount * TREASURY_SHARE) / BASIS_POINTS;
        uint256 stakerAmount = (amount * STAKER_SHARE) / BASIS_POINTS;

        // Transfer to InsuranceFund
        IERC20(token).safeIncreaseAllowance(insuranceFund, insuranceAmount);
        IInsuranceFund(insuranceFund).depositFromFees(insuranceAmount, token);

        // Transfer to Treasury
        IERC20(token).safeTransfer(treasury, treasuryAmount);

        // Update accumulated rewards per share for stakers
        if (totalStakedTGX > 0) {
            // Combine calculations to multiply before dividing (prevents precision loss)
            accRewardPerShare[token] += (amount * STAKER_SHARE * PRECISION) / (BASIS_POINTS * totalStakedTGX);
        }
        stakerPools[token] += stakerAmount;

        // Update stats
        feeStats[token].totalCollected += amount;
        feeStats[token].toInsurance += insuranceAmount;
        feeStats[token].toTreasury += treasuryAmount;
        feeStats[token].toStakers += stakerAmount;

        emit FeesCollected(token, amount, insuranceAmount, treasuryAmount, stakerAmount);
    }

    // ============ Staking Functions ============

    /**
     * @notice Stake TGX tokens to earn fee share
     * @param amount Amount of TGX to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert FeeDistributor__ZeroAmount();

        // Update rewards before changing stake
        _updateRewards(msg.sender);

        // Transfer TGX from user
        IERC20(tgxToken).safeTransferFrom(msg.sender, address(this), amount);

        // Update stakes
        stakedTGX[msg.sender] += amount;
        totalStakedTGX += amount;

        // Reset debt based on new stake to prevent claiming old rewards
        _resetDebt(msg.sender);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake TGX tokens
     * @param amount Amount of TGX to unstake
     */
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert FeeDistributor__ZeroAmount();
        if (stakedTGX[msg.sender] < amount) revert FeeDistributor__InsufficientStake();

        // Update rewards before changing stake
        _updateRewards(msg.sender);

        // Update stakes
        stakedTGX[msg.sender] -= amount;
        totalStakedTGX -= amount;

        // Reset debt based on new stake
        _resetDebt(msg.sender);

        // Return TGX to user
        IERC20(tgxToken).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ============ Reward Functions ============

    /**
     * @notice Update user reward debt when stake changes
     * @param user User address
     */
    function _updateRewards(address user) internal {
        uint256 userStake = stakedTGX[user];
        uint256 tokensLength = supportedTokens.length;

        // Save pending rewards before updating debt
        for (uint256 i = 0; i < tokensLength; i++) {
            address token = supportedTokens[i];
            uint256 accumulatedReward = (userStake * accRewardPerShare[token]) / PRECISION;
            uint256 debt = rewardDebt[user][token];

            // Calculate pending (handle case where debt > accumulated due to unstaking)
            uint256 pending = accumulatedReward >= debt ? accumulatedReward - debt : 0;

            if (pending > 0) {
                claimableRewards[user][token] += pending;
                stakerPools[token] -= pending; // Deduct from pool when saving
            }

            // CRITICAL: Always reset debt to current accumulated amount
            // This ensures debt stays in sync with stake changes
            rewardDebt[user][token] = accumulatedReward;
        }
    }

    /**
     * @notice Reset reward debt based on current stake
     * @dev Called after stake changes to prevent claiming unearned rewards
     * @param user User address
     */
    function _resetDebt(address user) internal {
        uint256 userStake = stakedTGX[user];
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            rewardDebt[user][token] = (userStake * accRewardPerShare[token]) / PRECISION;
        }
    }

    /**
     * @notice Claim accumulated rewards for a specific token
     * @param token Token to claim rewards for
     * @return amount Amount claimed
     */
    function claimRewards(address token)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        if (!isTokenSupported[token]) revert FeeDistributor__TokenNotSupported();

        uint256 userStake = stakedTGX[msg.sender];
        uint256 accumulatedReward = (userStake * accRewardPerShare[token]) / PRECISION;
        uint256 debt = rewardDebt[msg.sender][token];

        // Calculate pending (handle case where accumulated < debt due to unstaking)
        uint256 pending = accumulatedReward >= debt ? accumulatedReward - debt : 0;

        // Total claimable = saved claimable + current pending
        amount = claimableRewards[msg.sender][token] + pending;

        if (amount == 0) revert FeeDistributor__NoRewards();

        claimableRewards[msg.sender][token] = 0;
        rewardDebt[msg.sender][token] = accumulatedReward;

        // Only deduct pending from pool (claimable was already deducted when saved)
        if (pending > 0) {
            stakerPools[token] -= pending;
        }

        IERC20(token).safeTransfer(msg.sender, amount);

        emit RewardsClaimed(msg.sender, token, amount);
    }

    /**
     * @notice Claim rewards for all supported tokens
     * @return amounts Array of amounts claimed per token
     */
    function claimAllRewards() external nonReentrant whenNotPaused returns (uint256[] memory amounts) {
        uint256 userStake = stakedTGX[msg.sender];
        uint256 tokensLength = supportedTokens.length;
        amounts = new uint256[](tokensLength);

        for (uint256 i = 0; i < tokensLength; i++) {
            address token = supportedTokens[i];
            uint256 accumulatedReward = (userStake * accRewardPerShare[token]) / PRECISION;
            uint256 debt = rewardDebt[msg.sender][token];

            // Calculate pending (handle case where accumulated < debt due to unstaking)
            uint256 pending = accumulatedReward >= debt ? accumulatedReward - debt : 0;
            uint256 amount = claimableRewards[msg.sender][token] + pending;

            if (amount > 0) {
                claimableRewards[msg.sender][token] = 0;
                rewardDebt[msg.sender][token] = accumulatedReward;

                // Only deduct pending from pool (claimable was already deducted when saved)
                if (pending > 0) {
                    stakerPools[token] -= pending;
                }

                IERC20(token).safeTransfer(msg.sender, amount);
                amounts[i] = amount;
                emit RewardsClaimed(msg.sender, token, amount);
            }
        }
    }

    // ============ Query Functions ============

    /**
     * @notice Get pending rewards for a user and token
     * @param user User address
     * @param token Token address
     * @return Pending rewards amount
     */
    function getPendingRewards(address user, address token) external view returns (uint256) {
        uint256 userStake = stakedTGX[user];
        uint256 accumulatedReward = (userStake * accRewardPerShare[token]) / PRECISION;
        uint256 debt = rewardDebt[user][token];

        // If accumulated >= debt, calculate pending normally
        // If accumulated < debt (due to unstake), pending is 0 (rewards were saved to claimable)
        uint256 pending = accumulatedReward >= debt ? accumulatedReward - debt : 0;

        return claimableRewards[user][token] + pending;
    }

    /**
     * @notice Get staker information
     * @param user User address
     * @return info Staker info (staked amount and share percentage)
     */
    function getStakerInfo(address user) external view returns (StakerInfo memory info) {
        info.staked = stakedTGX[user];
        info.sharePercentage = totalStakedTGX > 0
            ? (stakedTGX[user] * BASIS_POINTS) / totalStakedTGX
            : 0;
    }

    /**
     * @notice Get fee statistics for a token
     * @param token Token address
     * @return Fee statistics
     */
    function getFeeStats(address token) external view returns (FeeStats memory) {
        return feeStats[token];
    }

    /**
     * @notice Get distribution amounts for a given fee amount
     * @param amount Total fee amount
     * @return distribution Distribution breakdown
     */
    function getDistribution(uint256 amount) external pure returns (Distribution memory distribution) {
        distribution.toInsurance = (amount * INSURANCE_SHARE) / BASIS_POINTS;
        distribution.toTreasury = (amount * TREASURY_SHARE) / BASIS_POINTS;
        distribution.toStakers = (amount * STAKER_SHARE) / BASIS_POINTS;
    }

    /**
     * @notice Get list of supported tokens
     * @return Array of supported token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    /**
     * @notice Check if a token is supported
     * @param token Token address
     * @return True if supported
     */
    function isSupported(address token) external view returns (bool) {
        return isTokenSupported[token];
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a supported token
     * @param token Token to add
     */
    function addSupportedToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert FeeDistributor__ZeroAddress();
        require(!isTokenSupported[token], "FeeDistributor: token already supported");

        supportedTokens.push(token);
        isTokenSupported[token] = true;

        emit TokenAdded(token);
    }

    /**
     * @notice Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert FeeDistributor__ZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Update insurance fund address
     * @param newFund New insurance fund address
     */
    function updateInsuranceFund(address newFund) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFund == address(0)) revert FeeDistributor__ZeroAddress();
        address oldFund = insuranceFund;
        insuranceFund = newFund;
        emit InsuranceFundUpdated(oldFund, newFund);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}

// ============ Interfaces ============

interface IInsuranceFund {
    function depositFromFees(uint256 amount, address token) external;
}
