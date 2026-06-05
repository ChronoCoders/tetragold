// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title InsuranceFund
 * @notice Manages protocol insurance reserves, covering failed liquidations and generating yield
 * @dev Collects fees, deploys to Aave for yield, and provides coverage for protocol losses
 */
contract InsuranceFund is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_TARGET_PERCENTAGE = 150; // 1.5% of TVL
    uint256 public constant MINIMUM_RESERVE_PERCENTAGE = 50; // 0.5% of TVL
    uint256 public constant DEFAULT_UTILIZATION = 5000; // 50% deployed to Aave

    // ============ Roles ============

    bytes32 public constant VAULT_MANAGER_ROLE = keccak256("VAULT_MANAGER_ROLE");
    bytes32 public constant LIQUIDATION_ENGINE_ROLE = keccak256("LIQUIDATION_ENGINE_ROLE");
    bytes32 public constant COVERAGE_MANAGER_ROLE = keccak256("COVERAGE_MANAGER_ROLE");

    // ============ Enums ============

    enum CoverageReason {
        FAILED_LIQUIDATION,
        ORACLE_MANIPULATION,
        SMART_CONTRACT_BUG,
        FLASH_CRASH
    }

    enum FundHealth {
        CRITICAL,
        WARNING,
        HEALTHY,
        OVERCAPITALIZED
    }

    // ============ Structs ============

    struct FundingSources {
        uint256 fromProtocolFees;
        uint256 fromLiquidations;
        uint256 fromYield;
        uint256 totalCollected;
    }

    struct CoverageEvent {
        uint256 eventId;
        uint256 positionId;
        address token;
        uint256 amountCovered;
        uint256 timestamp;
        CoverageReason reason;
    }

    struct YieldStrategy {
        uint256 targetUtilization;
        uint256 currentDeployed;
        uint256 availableLiquidity;
        uint256 totalYieldEarned;
    }

    // ============ State Variables ============

    address public immutable vaultManager;
    address public immutable liquidityPool;
    address public aavePool;

    uint256 public targetPercentage;
    uint256 public nextEventId;

    // Token reserves
    mapping(address => uint256) public reserves; // Available reserves
    mapping(address => uint256) public deployed; // Deployed to Aave
    mapping(address => uint256) public totalCoverage; // Lifetime coverage paid
    mapping(address => address) public aTokens; // token => aToken mapping

    // Token list for getTotalReserves
    address[] private _tokenList;
    mapping(address => bool) private _inTokenList;
    mapping(address => uint8) public tokenDecimals;

    // Funding tracking (per token)
    mapping(address => FundingSources) public fundingSources;

    // Coverage history
    CoverageEvent[] public coverageHistory;

    // ============ Events ============

    event FundsDeposited(
        address indexed from, uint256 amount, address indexed token, string source
    );
    event CoverageProvided(
        uint256 indexed eventId,
        uint256 indexed positionId,
        uint256 amount,
        CoverageReason reason
    );
    event DeployedToYield(address indexed token, uint256 amount, address indexed protocol);
    event WithdrawnFromYield(
        address indexed token, uint256 amount, uint256 yieldEarned
    );
    event Rebalanced(address indexed token, uint256 deployed, uint256 available);
    event FundHealthUpdated(FundHealth oldHealth, FundHealth newHealth);
    event EmergencyWithdrawal(
        address indexed token, uint256 amount, address indexed to, string reason
    );
    event AavePoolUpdated(address indexed oldPool, address indexed newPool);
    event ATokenUpdated(address indexed token, address indexed aToken);
    event TargetPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);

    // ============ Errors ============

    error InsuranceFund__ZeroAddress();
    error InsuranceFund__ZeroAmount();
    error InsuranceFund__InsufficientFunds();
    error InsuranceFund__InvalidToken();
    error InsuranceFund__BelowMinimumReserve();
    error InsuranceFund__InvalidPercentage();

    // ============ Constructor ============

    constructor(
        address _admin,
        address _vaultManager,
        address _liquidityPool,
        address _aavePool
    ) {
        if (_admin == address(0)) revert InsuranceFund__ZeroAddress();
        if (_vaultManager == address(0)) revert InsuranceFund__ZeroAddress();
        if (_liquidityPool == address(0)) revert InsuranceFund__ZeroAddress();
        if (_aavePool == address(0)) revert InsuranceFund__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(COVERAGE_MANAGER_ROLE, _admin);

        vaultManager = _vaultManager;
        liquidityPool = _liquidityPool;
        aavePool = _aavePool;
        targetPercentage = DEFAULT_TARGET_PERCENTAGE;
        nextEventId = 1;
    }

    // ============ Deposit Functions ============

    /**
     * @notice Deposit protocol fees (30% of VaultManager fees)
     * @param amount Amount to deposit
     * @param token Token address
     */
    function depositFromFees(uint256 amount, address token)
        external
        onlyRole(VAULT_MANAGER_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (token == address(0)) revert InsuranceFund__InvalidToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        if (!_inTokenList[token]) {
            _tokenList.push(token);
            _inTokenList[token] = true;
            tokenDecimals[token] = IERC20Metadata(token).decimals();
        }

        reserves[token] += amount;
        fundingSources[token].fromProtocolFees += amount;
        fundingSources[token].totalCollected += amount;

        emit FundsDeposited(msg.sender, amount, token, "protocol_fees");
    }

    /**
     * @notice Deposit liquidation penalties (30% from LiquidationEngine)
     * @param amount Amount to deposit
     * @param token Token address
     */
    function depositFromLiquidation(uint256 amount, address token)
        external
        onlyRole(LIQUIDATION_ENGINE_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (token == address(0)) revert InsuranceFund__InvalidToken();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        if (!_inTokenList[token]) {
            _tokenList.push(token);
            _inTokenList[token] = true;
            tokenDecimals[token] = IERC20Metadata(token).decimals();
        }

        reserves[token] += amount;
        fundingSources[token].fromLiquidations += amount;
        fundingSources[token].totalCollected += amount;

        emit FundsDeposited(msg.sender, amount, token, "liquidation_penalty");
    }

    // ============ Coverage Functions ============

    /**
     * @notice Cover losses from failed liquidations or other events
     * @param positionId Position ID that needs coverage
     * @param amount Amount to cover
     * @param token Token address
     * @param reason Coverage reason
     * @return eventId Coverage event ID
     */
    function coverLoss(
        uint256 positionId,
        uint256 amount,
        address token,
        CoverageReason reason
    ) external onlyRole(COVERAGE_MANAGER_ROLE) nonReentrant whenNotPaused returns (uint256 eventId) {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (token == address(0)) revert InsuranceFund__InvalidToken();

        uint256 available = getAvailableLiquidity(token);
        if (available < amount) revert InsuranceFund__InsufficientFunds();

        // Withdraw from Aave if needed
        if (reserves[token] < amount) {
            uint256 toWithdraw = amount - reserves[token];
            _withdrawFromAave(toWithdraw, token);
        }

        // Transfer coverage to liquidity pool
        reserves[token] -= amount;
        totalCoverage[token] += amount;
        IERC20(token).safeTransfer(liquidityPool, amount);

        // Record coverage event
        eventId = nextEventId++;
        coverageHistory.push(
            CoverageEvent({
                eventId: eventId,
                positionId: positionId,
                token: token,
                amountCovered: amount,
                timestamp: block.timestamp,
                reason: reason
            })
        );

        emit CoverageProvided(eventId, positionId, amount, reason);

        // Check if below minimum reserve
        if (!checkMinimumReserve()) {
            emit FundHealthUpdated(getFundHealth(), FundHealth.CRITICAL);
        }
    }

    // ============ Yield Management Functions ============

    /**
     * @notice Deploy funds to Aave for yield generation
     * @param amount Amount to deploy
     * @param token Token address
     */
    function deployToAave(uint256 amount, address token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (token == address(0)) revert InsuranceFund__InvalidToken();
        if (reserves[token] < amount) revert InsuranceFund__InsufficientFunds();

        reserves[token] -= amount;
        deployed[token] += amount;

        IERC20(token).safeIncreaseAllowance(aavePool, amount);
        IAavePool(aavePool).supply(token, amount, address(this), 0);

        emit DeployedToYield(token, amount, aavePool);
    }

    /**
     * @notice Withdraw funds from Aave
     * @param amount Amount to withdraw
     * @param token Token address
     */
    // slither-disable-next-line reentrancy-eth
    function withdrawFromAave(uint256 amount, address token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        _withdrawFromAave(amount, token);
    }

    /**
     * @notice Internal function to withdraw from Aave
     * @param amount Amount to withdraw
     * @param token Token address
     */
    function _withdrawFromAave(uint256 amount, address token) internal {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (token == address(0)) revert InsuranceFund__InvalidToken();
        if (deployed[token] < amount) revert InsuranceFund__InsufficientFunds();

        uint256 withdrawn = IAavePool(aavePool).withdraw(token, amount, address(this));

        deployed[token] -= amount;
        reserves[token] += withdrawn;

        // Calculate yield earned
        uint256 yieldEarned = withdrawn > amount ? withdrawn - amount : 0;
        if (yieldEarned > 0) {
            fundingSources[token].fromYield += yieldEarned;
            fundingSources[token].totalCollected += yieldEarned;
        }

        emit WithdrawnFromYield(token, withdrawn, yieldEarned);
    }

    /**
     * @notice Rebalance reserves to maintain target utilization (50/50 split)
     */
    function rebalance() external whenNotPaused {
        _rebalanceToken(address(0)); // Will be set by caller or iterate through supported tokens
    }

    /**
     * @notice Rebalance a specific token
     * @param token Token to rebalance
     */
    // slither-disable-next-line reentrancy-eth
    function rebalanceToken(address token)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
    {
        _rebalanceToken(token);
    }

    /**
     * @notice Internal rebalance function
     * @param token Token to rebalance
     */
    function _rebalanceToken(address token) internal {
        if (token == address(0)) revert InsuranceFund__InvalidToken();

        uint256 total = reserves[token] + deployed[token];
        uint256 targetDeployed = (total * DEFAULT_UTILIZATION) / BASIS_POINTS;

        if (deployed[token] < targetDeployed) {
            // Deploy more
            uint256 toDeploy = targetDeployed - deployed[token];
            if (reserves[token] >= toDeploy) {
                reserves[token] -= toDeploy;
                deployed[token] += toDeploy;

                IERC20(token).safeIncreaseAllowance(aavePool, toDeploy);
                IAavePool(aavePool).supply(token, toDeploy, address(this), 0);

                emit Rebalanced(token, deployed[token], reserves[token]);
            }
        } else if (deployed[token] > targetDeployed) {
            // Withdraw excess
            uint256 toWithdraw = deployed[token] - targetDeployed;

            uint256 withdrawn = IAavePool(aavePool).withdraw(token, toWithdraw, address(this));

            deployed[token] -= toWithdraw;
            reserves[token] += withdrawn;

            // Track yield
            uint256 yieldEarned = withdrawn > toWithdraw ? withdrawn - toWithdraw : 0;
            if (yieldEarned > 0) {
                fundingSources[token].fromYield += yieldEarned;
                fundingSources[token].totalCollected += yieldEarned;
            }

            emit Rebalanced(token, deployed[token], reserves[token]);
        }
    }

    // ============ Query Functions ============

    /**
     * @notice Get total reserves normalised to 6 decimals (matching USDC/USDT TVL basis)
     * @return total Total reserves in 6-decimal USD equivalent
     */
    function getTotalReserves() public view returns (uint256 total) {
        for (uint256 i = 0; i < _tokenList.length; i++) {
            address token = _tokenList[i];
            uint256 raw = reserves[token] + deployed[token];
            uint8 dec = tokenDecimals[token];
            if (dec < 6) {
                total += raw * 10 ** (6 - dec);
            } else if (dec > 6) {
                total += raw / 10 ** (dec - 6);
            } else {
                total += raw;
            }
        }
    }

    /**
     * @notice Get total reserves for a specific token
     * @param token Token address
     * @return Total reserves (available + deployed)
     */
    function getTotalReservesForToken(address token) public view returns (uint256) {
        return reserves[token] + deployed[token];
    }

    /**
     * @notice Get available liquidity for a token
     * @param token Token address
     * @return Available liquidity (reserves + deployed)
     */
    function getAvailableLiquidity(address token) public view returns (uint256) {
        return reserves[token] + deployed[token];
    }

    /**
     * @notice Get target reserve size based on protocol TVL
     * @return Target reserve in USD
     */
    function getTargetReserve() public view returns (uint256) {
        uint256 tvl = IVaultManager(vaultManager).getTotalValueLocked();
        return (tvl * targetPercentage) / BASIS_POINTS;
    }

    /**
     * @notice Get current fund health status
     * @return Current fund health
     */
    function getFundHealth() public view returns (FundHealth) {
        uint256 current = getTotalReserves();
        uint256 target = getTargetReserve();

        if (target == 0) return FundHealth.HEALTHY; // No TVL yet

        if (current >= target * 2) return FundHealth.OVERCAPITALIZED;
        if (current >= target) return FundHealth.HEALTHY;
        if (current >= target / 2) return FundHealth.WARNING;
        return FundHealth.CRITICAL;
    }

    /**
     * @notice Check if reserves meet minimum requirement (0.5% of TVL)
     * @return True if sufficient
     */
    function checkMinimumReserve() public view returns (bool) {
        uint256 current = getTotalReserves();
        uint256 tvl = IVaultManager(vaultManager).getTotalValueLocked();
        uint256 minimum = (tvl * MINIMUM_RESERVE_PERCENTAGE) / BASIS_POINTS;
        return current >= minimum;
    }

    /**
     * @notice Get yield strategy info for a token
     * @param token Token address
     * @return strategy Yield strategy info
     */
    function getYieldStrategy(address token) external view returns (YieldStrategy memory strategy) {
        strategy.targetUtilization = DEFAULT_UTILIZATION;
        strategy.currentDeployed = deployed[token];
        strategy.availableLiquidity = reserves[token];
        strategy.totalYieldEarned = fundingSources[token].fromYield;
    }

    /**
     * @notice Get coverage history
     * @return All coverage events
     */
    function getCoverageHistory() external view returns (CoverageEvent[] memory) {
        return coverageHistory;
    }

    /**
     * @notice Get coverage event by ID
     * @param eventId Event ID
     * @return Coverage event
     */
    function getCoverageEvent(uint256 eventId) external view returns (CoverageEvent memory) {
        require(eventId > 0 && eventId < nextEventId, "InsuranceFund: invalid event ID");
        return coverageHistory[eventId - 1];
    }

    /**
     * @notice Get funding sources for a token
     * @param token Token address
     * @return Funding sources breakdown
     */
    function getFundingSources(address token) external view returns (FundingSources memory) {
        return fundingSources[token];
    }

    // ============ Admin Functions ============

    /**
     * @notice Emergency withdrawal (admin only)
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param to Recipient address
     * @param reason Reason for withdrawal
     */
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address to,
        string calldata reason
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (amount == 0) revert InsuranceFund__ZeroAmount();
        if (to == address(0)) revert InsuranceFund__ZeroAddress();
        if (token == address(0)) revert InsuranceFund__InvalidToken();

        // Withdraw from Aave if needed
        if (reserves[token] < amount) {
            uint256 toWithdraw = amount - reserves[token];
            if (deployed[token] >= toWithdraw) {
                _withdrawFromAave(toWithdraw, token);
            } else {
                revert InsuranceFund__InsufficientFunds();
            }
        }

        reserves[token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, amount, to, reason);
    }

    /**
     * @notice Update Aave pool address
     * @param newAavePool New Aave pool address
     */
    function updateAavePool(address newAavePool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAavePool == address(0)) revert InsuranceFund__ZeroAddress();
        address oldPool = aavePool;
        aavePool = newAavePool;
        emit AavePoolUpdated(oldPool, newAavePool);
    }

    /**
     * @notice Register a token so it is included in getTotalReserves() before any deposits occur
     * @param token Token address to register
     */
    function addSupportedToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InsuranceFund__InvalidToken();
        if (!_inTokenList[token]) {
            _tokenList.push(token);
            _inTokenList[token] = true;
            tokenDecimals[token] = IERC20Metadata(token).decimals();
        }
    }

    /**
     * @notice Set aToken mapping for a token
     * @param token Token address
     * @param aToken Corresponding aToken address
     */
    function setAToken(address token, address aToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InsuranceFund__InvalidToken();
        if (aToken == address(0)) revert InsuranceFund__ZeroAddress();
        aTokens[token] = aToken;
        emit ATokenUpdated(token, aToken);
    }

    /**
     * @notice Update target reserve percentage
     * @param newPercentage New target percentage (in basis points)
     */
    function updateTargetPercentage(uint256 newPercentage)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newPercentage == 0 || newPercentage > 1000) {
            revert InsuranceFund__InvalidPercentage();
        } // Max 10%
        uint256 oldPercentage = targetPercentage;
        targetPercentage = newPercentage;
        emit TargetPercentageUpdated(oldPercentage, newPercentage);
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

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IVaultManager {
    function getTotalValueLocked() external view returns (uint256);
}
