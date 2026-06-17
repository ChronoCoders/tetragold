// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AutomationCompatibleInterface} from "./interfaces/AutomationCompatibleInterface.sol";

/**
 * @title LiquidationEngine
 * @dev Automatically liquidates unhealthy positions using Chainlink Automation
 */
contract LiquidationEngine is AccessControl, Pausable, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    /* ============ Constants ============ */

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant GRACE_PERIOD = 10 minutes;
    // A mark only authorizes liquidation for this long after the grace period
    // expires. A stale mark on a still-liquidatable position is re-marked
    // WITHOUT a fresh grace period: the owner already received a full grace
    // from the original mark, and granting another on every keeper-downtime
    // cycle would let bad debt grow unboundedly. Positions that recover should
    // have their mark cleared via clearMark() — a relapse after that gets a
    // fresh mark and a fresh grace period.
    uint256 public constant MARK_VALIDITY = 1 hours;
    uint256 public constant LIQUIDATION_TRANCHE = 2500; // 25% in basis points
    uint256 public constant MAX_TRANCHES = 4;
    uint256 public constant MIN_LIQUIDATION_VALUE = 100e6; // $100 minimum

    // Penalty distribution percentages
    uint256 public constant LIQUIDATOR_SHARE = 5000; // 50%
    uint256 public constant INSURANCE_SHARE = 3000; // 30%
    uint256 public constant TREASURY_SHARE = 2000; // 20%

    uint256 public constant MAX_POSITIONS_PER_CHECK = 50;
    uint256 public constant MAX_LIQUIDATIONS_PER_UPKEEP = 10;

    /* ============ Structs ============ */

    struct LiquidationCandidate {
        uint256 positionId;
        address owner;
        uint256 currentRatio;
        uint256 liquidationRatio;
        uint256 positionValue;
    }

    struct PartialLiquidation {
        uint256 tranchesLiquidated;
        uint256 lastLiquidationTime;
        uint256 totalPenalty;
    }

    struct LiquidationInfo {
        bool isMarked;
        uint256 markedTime;
        uint256 tranchesLiquidated;
        uint256 totalPenalty;
        bool canLiquidate;
    }

    struct LiquidatorStats {
        uint256 totalLiquidations;
        uint256 totalRewards;
        uint256 pendingRewards;
        bool isRegistered;
    }

    /* ============ State Variables ============ */

    address public immutable vaultManager;
    address public insuranceFund;
    address public treasury;

    mapping(uint256 => uint256) public liquidationWarningTime;
    // Timestamp a position's mark was last cleared via clearMark(). A relapse
    // within GRACE_PERIOD + MARK_VALIDITY of a clear is treated as a
    // continuation (backdated re-mark, no fresh grace) rather than a genuine
    // recovery, so clear-then-relapse oscillation cannot earn endless graces.
    mapping(uint256 => uint256) public markClearedAt;
    mapping(uint256 => PartialLiquidation) public partialLiquidations;
    mapping(address => LiquidatorStats) public liquidators;
    mapping(address => mapping(address => uint256)) public pendingTokenRewards;

    uint256 public totalLiquidations;
    uint256 public totalPenaltiesCollected;

    /* ============ Events ============ */

    event PositionMarkedForLiquidation(uint256 indexed positionId, uint256 timestamp);
    event LiquidationMarkCleared(uint256 indexed positionId);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 penalty, uint256 portion);
    event LiquidationRewardPaid(address indexed liquidator, uint256 amount);
    event GracePeriodExpired(uint256 indexed positionId);
    event LiquidatorRegistered(address indexed liquidator);
    event InsuranceFundUpdated(address indexed oldFund, address indexed newFund);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /* ============ Errors ============ */

    error LiquidationEngine__InvalidAddress();
    error LiquidationEngine__PositionNotLiquidatable();
    error LiquidationEngine__GracePeriodActive();
    error LiquidationEngine__PositionFullyLiquidated();
    error LiquidationEngine__InsufficientValue();
    error LiquidationEngine__NoRewardsToClaim();
    error LiquidationEngine__InvalidPercentage();
    error LiquidationEngine__AlreadyMarked();
    error LiquidationEngine__StillLiquidatable();
    error LiquidationEngine__NotMarked();
    error LiquidationEngine__NotPositionOwner();

    /* ============ Constructor ============ */

    constructor(address _admin, address _vaultManager, address _insuranceFund, address _treasury) {
        if (
            _admin == address(0) || _vaultManager == address(0) || _insuranceFund == address(0)
                || _treasury == address(0)
        ) {
            revert LiquidationEngine__InvalidAddress();
        }

        vaultManager = _vaultManager;
        insuranceFund = _insuranceFund;
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /* ============ External Functions ============ */

    /**
     * @dev Mark a position for liquidation (starts grace period)
     * @param positionId ID of the position to mark
     */
    function markForLiquidation(uint256 positionId) external whenNotPaused {
        // Check if position is liquidatable
        if (!_isPositionLiquidatable(positionId)) {
            revert LiquidationEngine__PositionNotLiquidatable();
        }

        // A live mark cannot be overwritten — otherwise the owner could re-mark
        // repeatedly to reset their own grace period and never be liquidatable.
        // Only unmarked positions or stale marks can be (re-)marked.
        if (!_needsMark(positionId)) {
            revert LiquidationEngine__AlreadyMarked();
        }

        // Mark position. A stale re-mark grants no fresh grace period (the
        // owner already received one and never cleared the mark while healthy),
        // so the owner cannot front-run keeper recovery to buy another grace.
        uint256 markTime = _remarkTime(positionId);
        liquidationWarningTime[positionId] = markTime;
        delete markClearedAt[positionId];

        emit PositionMarkedForLiquidation(positionId, markTime);
    }

    /**
     * @dev Clear the liquidation mark of a position that has genuinely
     *      recovered. OWNER-ONLY: a permissionless clear would let a griefer
     *      delete a legitimate mark during a transient healthy price wick and
     *      restart the keeper's grace clock, delaying liquidation of a still-
     *      underwater position. Records the clear time so that a relapse soon
     *      after (within GRACE_PERIOD + MARK_VALIDITY) is re-marked backdated
     *      rather than earning a fresh grace — only a sustained recovery past
     *      that window grants a new full grace period on the next mark.
     * @param positionId ID of the position to clear
     */
    function clearMark(uint256 positionId) external {
        if (liquidationWarningTime[positionId] == 0) {
            revert LiquidationEngine__NotMarked();
        }
        if (msg.sender != IVaultManager(vaultManager).getPosition(positionId).owner) {
            revert LiquidationEngine__NotPositionOwner();
        }
        if (_isPositionLiquidatable(positionId)) {
            revert LiquidationEngine__StillLiquidatable();
        }

        delete liquidationWarningTime[positionId];
        markClearedAt[positionId] = block.timestamp;

        emit LiquidationMarkCleared(positionId);
    }

    /**
     * @dev Liquidate a position (25% at a time)
     * @param positionId ID of the position to liquidate
     * @return penalty Penalty amount collected
     */
    function liquidatePosition(uint256 positionId) external nonReentrant whenNotPaused returns (uint256 penalty) {
        return _liquidatePosition(positionId, msg.sender);
    }

    /**
     * @dev Liquidate multiple positions in a batch
     * @param positionIds Array of position IDs to liquidate
     * @return totalPenalty Total penalty collected
     */
    function batchLiquidate(uint256[] calldata positionIds)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 totalPenalty)
    {
        uint256 length = positionIds.length;
        if (length > MAX_LIQUIDATIONS_PER_UPKEEP) {
            length = MAX_LIQUIDATIONS_PER_UPKEEP;
        }

        for (uint256 i = 0; i < length; i++) {
            // slither-disable-next-line unused-return
            try this.liquidatePositionInternal(positionIds[i], msg.sender) returns (uint256 penalty) {
                totalPenalty += penalty;
            } catch {
                // Skip positions that can't be liquidated
                continue;
            }
        }
    }

    /**
     * @dev Register as a liquidator
     */
    function registerAsLiquidator() external {
        liquidators[msg.sender].isRegistered = true;
        emit LiquidatorRegistered(msg.sender);
    }

    /**
     * @dev Claim liquidation rewards for a specific token
     * @param token Token address to claim rewards in
     * @return amount Amount claimed
     */
    function claimRewards(address token) external nonReentrant returns (uint256 amount) {
        amount = pendingTokenRewards[msg.sender][token];
        if (amount == 0) revert LiquidationEngine__NoRewardsToClaim();
        pendingTokenRewards[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit LiquidationRewardPaid(msg.sender, amount);
        return amount;
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

    /**
     * @dev Update insurance fund address
     * @param newInsuranceFund New insurance fund address
     */
    function updateInsuranceFund(address newInsuranceFund) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newInsuranceFund == address(0)) revert LiquidationEngine__InvalidAddress();

        address oldFund = insuranceFund;
        insuranceFund = newInsuranceFund;

        emit InsuranceFundUpdated(oldFund, newInsuranceFund);
    }

    /**
     * @dev Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert LiquidationEngine__InvalidAddress();

        address oldTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /* ============ Chainlink Automation Functions ============ */

    /**
     * @dev Check if upkeep is needed (Chainlink Automation)
     * @param checkData Data passed for checking (can specify range)
     * @return upkeepNeeded True if liquidations are needed
     * @return performData Encoded position IDs to liquidate
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        (uint256 startIndex, uint256 count) =
            checkData.length == 0 ? (0, MAX_POSITIONS_PER_CHECK) : abi.decode(checkData, (uint256, uint256));

        uint256[] memory liquidatablePositions = _getLiquidatablePositions(startIndex, count);

        upkeepNeeded = liquidatablePositions.length > 0;
        performData = abi.encode(liquidatablePositions);
    }

    /**
     * @dev Perform upkeep (Chainlink Automation)
     * @param performData Encoded position IDs to liquidate
     */
    function performUpkeep(bytes calldata performData) external override whenNotPaused {
        uint256[] memory positionIds = abi.decode(performData, (uint256[]));

        uint256 length = positionIds.length;
        if (length > MAX_LIQUIDATIONS_PER_UPKEEP) {
            length = MAX_LIQUIDATIONS_PER_UPKEEP;
        }

        for (uint256 i = 0; i < length; i++) {
            // slither-disable-next-line unused-return
            try this.liquidatePositionInternal(positionIds[i], msg.sender) returns (
                uint256
            ) {
            // Liquidation succeeded
            }
            catch {
                // Skip positions that can't be liquidated
                continue;
            }
        }
    }

    /* ============ View Functions ============ */

    /**
     * @dev Get liquidatable positions in a range
     * @return positionIds Array of liquidatable position IDs
     */
    function getLiquidatablePositions() external view returns (uint256[] memory positionIds) {
        return _getLiquidatablePositions(0, MAX_POSITIONS_PER_CHECK);
    }

    /**
     * @dev Check positions in a range for liquidation candidates
     * @param startIndex Starting index
     * @param count Number of positions to check
     * @return candidates Array of liquidation candidates
     */
    function checkPositions(uint256 startIndex, uint256 count)
        external
        view
        returns (LiquidationCandidate[] memory candidates)
    {
        (uint256[] memory activeIds,) = IVaultManager(vaultManager).getActivePositionIds(startIndex, count);

        // Count liquidatable positions
        uint256 liquidatableCount = 0;
        for (uint256 i = 0; i < activeIds.length; i++) {
            if (_isPositionLiquidatable(activeIds[i])) {
                liquidatableCount++;
            }
        }

        // Build candidates array
        candidates = new LiquidationCandidate[](liquidatableCount);
        uint256 candidateIndex = 0;

        for (uint256 i = 0; i < activeIds.length; i++) {
            uint256 positionId = activeIds[i];
            if (_isPositionLiquidatable(positionId)) {
                IVaultManager.Position memory position = IVaultManager(vaultManager).getPosition(positionId);
                uint256 health = IVaultManager(vaultManager).getPositionHealth(positionId);

                candidates[candidateIndex] = LiquidationCandidate({
                    positionId: positionId,
                    owner: position.owner,
                    currentRatio: health,
                    liquidationRatio: _getLiquidationThreshold(position.leverage),
                    positionValue: _getPositionValue(positionId, position)
                });
                candidateIndex++;
            }
        }
    }

    /**
     * @dev Get liquidation info for a position
     * @param positionId Position ID
     * @return info Liquidation information
     */
    function getPositionLiquidationInfo(uint256 positionId) external view returns (LiquidationInfo memory info) {
        info.isMarked = liquidationWarningTime[positionId] != 0;
        info.markedTime = liquidationWarningTime[positionId];
        info.tranchesLiquidated = partialLiquidations[positionId].tranchesLiquidated;
        info.totalPenalty = partialLiquidations[positionId].totalPenalty;
        info.canLiquidate = _canLiquidateNow(positionId);
    }

    /**
     * @dev Get liquidator statistics
     * @param liquidator Liquidator address
     * @return stats Liquidator statistics
     */
    function getLiquidatorStats(address liquidator) external view returns (LiquidatorStats memory stats) {
        return liquidators[liquidator];
    }

    /**
     * @dev Calculate liquidation penalty for a leverage level
     * @param leverage Leverage level
     * @return penalty Penalty in basis points
     */
    function calculatePenalty(uint256 leverage) public pure returns (uint256 penalty) {
        if (leverage <= 2) {
            return 500; // 5%
        } else if (leverage == 3) {
            return 700; // 7%
        } else if (leverage == 5) {
            return 1000; // 10%
        } else if (leverage >= 10) {
            return 1500; // 15%
        }
        return 500; // Default 5%
    }

    /* ============ Internal Functions ============ */

    /**
     * @dev Internal function to liquidate a position (exposed for try/catch)
     * @param positionId Position ID
     * @param liquidator Liquidator address
     * @return penalty Penalty collected
     */
    function liquidatePositionInternal(uint256 positionId, address liquidator) external returns (uint256 penalty) {
        require(msg.sender == address(this), "LiquidationEngine: internal only");
        return _liquidatePosition(positionId, liquidator);
    }

    /**
     * @dev Liquidate a position
     * @param positionId Position ID
     * @param liquidator Liquidator address
     * @return penalty Penalty collected
     */
    // slither-disable-start reentrancy-eth
    function _liquidatePosition(uint256 positionId, address liquidator) internal returns (uint256 penalty) {
        // Auto-mark: a liquidatable position that is unmarked gets a fresh
        // grace period before any tranche is taken. A STALE mark (set, but
        // older than GRACE_PERIOD + MARK_VALIDITY) is re-marked with the grace
        // already elapsed — the owner received a full grace from the original
        // mark and could have cleared it via clearMark() while healthy, so
        // keeper downtime must not keep granting new grace periods while bad
        // debt grows. Liquidation then proceeds in this same call.
        if (_needsMark(positionId) && _isPositionLiquidatable(positionId)) {
            uint256 markTime = _remarkTime(positionId);
            liquidationWarningTime[positionId] = markTime;
            delete markClearedAt[positionId];
            emit PositionMarkedForLiquidation(positionId, markTime);
            if (markTime == block.timestamp) {
                // Fresh mark: grant the grace period and stop here
                return 0;
            }
            // Stale or recently-cleared re-mark: fall through and liquidate now
        }

        // Check if can liquidate
        if (!_canLiquidateNow(positionId)) {
            revert LiquidationEngine__GracePeriodActive();
        }

        PartialLiquidation storage partialLiq = partialLiquidations[positionId];

        // Check if already fully liquidated
        if (partialLiq.tranchesLiquidated >= MAX_TRANCHES) {
            revert LiquidationEngine__PositionFullyLiquidated();
        }

        IVaultManager.Position memory position = IVaultManager(vaultManager).getPosition(positionId);

        // Minimum-value gate applies only to STARTING a liquidation: it skips
        // dust positions not worth the gas. Once a liquidation is underway, the
        // position's equity shrinks ~25% per tranche, so re-checking it here
        // would revert mid-sequence and strand the position with residual
        // principal — never reaching the final settling tranche.
        if (partialLiq.tranchesLiquidated == 0) {
            uint256 positionValue = _getPositionValue(positionId, position);
            if (positionValue < MIN_LIQUIDATION_VALUE) {
                revert LiquidationEngine__InsufficientValue();
            }
        }

        // Liquidate 25% of the position, except the final tranche closes the
        // whole remainder (25% of remaining never reaches zero, so without
        // this the position would be left active with residual principal and
        // uncollected interest after MAX_TRANCHES)
        uint256 tranchePercentage =
            partialLiq.tranchesLiquidated + 1 >= MAX_TRANCHES ? BASIS_POINTS : LIQUIDATION_TRANCHE;
        penalty = IVaultManager(vaultManager).liquidatePosition(positionId, tranchePercentage);

        // Update partial liquidation tracking
        partialLiq.tranchesLiquidated++;
        partialLiq.lastLiquidationTime = block.timestamp;
        partialLiq.totalPenalty += penalty;

        // Distribute penalty
        _distributePenalty(penalty, liquidator, position.collateralToken);

        // Update stats
        totalLiquidations++;
        totalPenaltiesCollected += penalty;

        LiquidatorStats storage stats = liquidators[liquidator];
        stats.totalLiquidations++;
        stats.totalRewards += (penalty * LIQUIDATOR_SHARE) / BASIS_POINTS;

        emit PositionLiquidated(positionId, liquidator, penalty, LIQUIDATION_TRANCHE);

        return penalty;
    }

    // slither-disable-end reentrancy-eth

    /**
     * @dev Distribute liquidation penalty
     * @param penalty Total penalty amount
     * @param liquidator Liquidator address
     * @param token Collateral token address
     */
    function _distributePenalty(uint256 penalty, address liquidator, address token) internal {
        if (penalty == 0) return;
        uint256 liquidatorReward = (penalty * LIQUIDATOR_SHARE) / BASIS_POINTS;
        uint256 insuranceAmount = (penalty * INSURANCE_SHARE) / BASIS_POINTS;
        uint256 treasuryAmount = penalty - liquidatorReward - insuranceAmount;

        pendingTokenRewards[liquidator][token] += liquidatorReward;
        liquidators[liquidator].pendingRewards += liquidatorReward;

        if (insuranceAmount > 0) {
            IERC20(token).safeIncreaseAllowance(insuranceFund, insuranceAmount);
            IInsuranceFund(insuranceFund).depositFromLiquidation(insuranceAmount, token);
        }
        if (treasuryAmount > 0) IERC20(token).safeTransfer(treasury, treasuryAmount);
    }

    /**
     * @dev Check if a position is liquidatable
     * @param positionId Position ID
     * @return True if liquidatable
     */
    function _isPositionLiquidatable(uint256 positionId) internal view returns (bool) {
        try IVaultManager(vaultManager).isLiquidatable(positionId) returns (bool liquidatable) {
            return liquidatable;
        } catch {
            return false;
        }
    }

    /**
     * @dev Check if a position can be liquidated now (grace period check)
     * @param positionId Position ID
     * @return True if can liquidate now
     */
    function _canLiquidateNow(uint256 positionId) internal view returns (bool) {
        if (!_isPositionLiquidatable(positionId)) {
            return false;
        }

        uint256 markedTime = liquidationWarningTime[positionId];

        // Unmarked positions cannot be liquidated yet — the grace period starts
        // at the first mark (explicit or auto-mark in _liquidatePosition)
        if (markedTime == 0) {
            return false;
        }

        // Liquidation is only authorized inside the mark's validity window:
        // after the grace period and before the mark goes stale. A stale mark
        // (position may have recovered and relapsed since) requires re-marking.
        return
            block.timestamp >= markedTime + GRACE_PERIOD && block.timestamp <= markedTime + GRACE_PERIOD + MARK_VALIDITY;
    }

    /**
     * @dev Check whether a position needs keeper action: either an auto-mark
     *      (liquidatable but unmarked) or an actual liquidation (grace expired)
     * @param positionId Position ID
     * @return True if performUpkeep should process this position
     */
    function _needsAction(uint256 positionId) internal view returns (bool) {
        if (!_isPositionLiquidatable(positionId)) {
            return false;
        }
        uint256 markedTime = liquidationWarningTime[positionId];
        // Action needed when unmarked, mark gone stale (re-mark), or inside
        // the liquidation window (liquidate)
        return markedTime == 0 || block.timestamp >= markedTime + GRACE_PERIOD;
    }

    /**
     * @dev True when a position's mark is missing or has expired and a
     *      re-mark is required before liquidation
     */
    function _needsMark(uint256 positionId) internal view returns (bool) {
        uint256 markedTime = liquidationWarningTime[positionId];
        return markedTime == 0 || block.timestamp > markedTime + GRACE_PERIOD + MARK_VALIDITY;
    }

    /**
     * @dev Timestamp to record for a (re-)mark. Backdated by GRACE_PERIOD (so
     *      the position is immediately liquidatable, no fresh grace) when:
     *        - a stale live mark is being refreshed (owner already had a grace
     *          from the original mark and never cleared it while healthy), or
     *        - the mark was cleared less than GRACE_PERIOD + MARK_VALIDITY ago
     *          (a clear-then-relapse oscillation, not a sustained recovery).
     *      Otherwise — first-ever mark, or a relapse long after a genuine
     *      recovery — the full grace period starts now.
     */
    function _remarkTime(uint256 positionId) internal view returns (uint256) {
        if (liquidationWarningTime[positionId] != 0) {
            return block.timestamp - GRACE_PERIOD;
        }
        uint256 cleared = markClearedAt[positionId];
        if (cleared != 0 && block.timestamp <= cleared + GRACE_PERIOD + MARK_VALIDITY) {
            return block.timestamp - GRACE_PERIOD;
        }
        return block.timestamp;
    }

    /**
     * @dev Get liquidatable positions in a range
     * @param startIndex Starting index
     * @param count Number of positions to check
     * @return liquidatableIds Array of liquidatable position IDs
     */
    function _getLiquidatablePositions(uint256 startIndex, uint256 count)
        internal
        view
        returns (uint256[] memory liquidatableIds)
    {
        (uint256[] memory activeIds,) = IVaultManager(vaultManager).getActivePositionIds(startIndex, count);

        // Count positions needing keeper action (auto-mark or liquidate)
        uint256 liquidatableCount = 0;
        for (uint256 i = 0; i < activeIds.length; i++) {
            if (_needsAction(activeIds[i])) {
                liquidatableCount++;
            }
        }

        // Build array
        liquidatableIds = new uint256[](liquidatableCount);
        uint256 liquidatableIndex = 0;

        for (uint256 i = 0; i < activeIds.length; i++) {
            uint256 positionId = activeIds[i];
            if (_needsAction(positionId)) {
                liquidatableIds[liquidatableIndex] = positionId;
                liquidatableIndex++;
            }
        }
    }

    /**
     * @dev Get liquidation threshold for a leverage level
     * @param leverage Leverage level
     * @return threshold Liquidation threshold in basis points
     */
    function _getLiquidationThreshold(uint256 leverage) internal pure returns (uint256 threshold) {
        if (leverage == 1) {
            return 12500; // 125%
        } else if (leverage == 2) {
            return 9000; // 90%
        } else if (leverage == 3) {
            return 4500; // 45%
        } else if (leverage == 5) {
            return 2250; // 22.5%
        } else if (leverage == 10) {
            return 1000; // 10%
        }
        return 10000; // Default 100%
    }

    /**
     * @dev Get position value
     * @param position Position struct
     * @return value Position value
     */
    function _getPositionValue(uint256 positionId, IVaultManager.Position memory position)
        internal
        view
        returns (uint256 value)
    {
        // Economic value = notional exposure at current gold price minus total debt.
        // tgauxMinted (18 dec) * goldPrice (8 dec) / 1e20 -> 6 decimals, matching collateral.
        (uint256 goldPrice,) = IOracleAggregator(IVaultManager(vaultManager).oracle()).getGoldPrice();
        uint256 notional = (position.tgauxMinted * goldPrice) / 1e20;
        uint256 totalOwed = position.borrowedAmount + IVaultManager(vaultManager).calculateInterest(positionId);
        return notional > totalOwed ? notional - totalOwed : 0;
    }
}

/* ============ Interfaces ============ */

interface IVaultManager {
    struct Position {
        address owner;
        uint256 collateralAmount;
        address collateralToken;
        uint256 tgauxMinted;
        uint256 borrowedAmount;
        uint256 leverage;
        uint256 openPrice;
        uint256 lastUpdateTimestamp;
        bool isActive;
    }

    function getPosition(uint256 positionId) external view returns (Position memory);
    function getPositionHealth(uint256 positionId) external view returns (uint256);
    function liquidatePosition(uint256 positionId, uint256 percentage) external returns (uint256);
    function isLiquidatable(uint256 positionId) external view returns (bool);
    function getActivePositionIds() external view returns (uint256[] memory);
    function getActivePositionIds(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total);
    function oracle() external view returns (address);
    function calculateInterest(uint256 positionId) external view returns (uint256);
}

interface IOracleAggregator {
    function getGoldPrice() external view returns (uint256 price, uint256 timestamp);
}

interface IInsuranceFund {
    function depositFromLiquidation(uint256 amount, address token) external;
}
