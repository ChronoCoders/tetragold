// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {TGAUX} from "./TGAUX.sol";
import {OracleAggregator} from "./OracleAggregator.sol";

/**
 * @title VaultManager
 * @dev Manages leveraged positions for gold price-tracking TGAUX tokens
 *
 * Features:
 * - Position management with 1x-10x leverage
 * - Multi-collateral support (USDC, USDT)
 * - Dynamic collateralization ratio enforcement
 * - Borrowing fee accrual (0.05% daily = 18.25% APR)
 * - Protocol fee collection
 * - Liquidation mechanism
 */
contract VaultManager is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // Role definitions
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");

    // Position structure
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

    // Leverage tier configuration
    struct LeverageTier {
        uint256 minCollateralRatio; // Basis points (10000 = 100%)
        uint256 liquidationRatio; // Basis points (10000 = 100%)
    }

    // State variables
    TGAUX public immutable tgaux;
    OracleAggregator public immutable oracle;
    address public immutable liquidityPool;

    mapping(address => bool) public supportedCollateral;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => LeverageTier) public leverageTiers;

    address public feeDistributor;

    EnumerableSet.UintSet private _activePositions;

    uint256 public nextPositionId;
    uint256 public totalValueLocked;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DAILY_BORROW_RATE = 5; // 0.05% = 5 basis points
    uint256 public constant SECONDS_PER_DAY = 86400;

    // Protocol fees (in basis points)
    uint256 public constant FEE_NO_LEVERAGE = 10; // 0.1%
    uint256 public constant FEE_WITH_LEVERAGE = 20; // 0.2%
    uint256 public constant FEE_BURN = 15; // 0.15%

    // Fee collection
    mapping(address => uint256) public collectedFees;

    // Events
    event PositionOpened(
        uint256 indexed positionId, address indexed owner, uint256 collateral, uint256 leverage, uint256 tgauxMinted
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner, uint256 returnAmount);
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event FeesCollected(uint256 amount, address indexed token);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 collateralSeized);

    /**
     * @dev Constructor
     * @param _admin Address to receive admin role
     * @param _tgaux TGAUX token address
     * @param _oracle OracleAggregator address
     * @param _liquidityPool LiquidityPool address
     * @param _usdc USDC token address
     * @param _usdt USDT token address
     */
    constructor(address _admin, address _tgaux, address _oracle, address _liquidityPool, address _usdc, address _usdt) {
        require(_admin != address(0), "VaultManager: zero admin address");
        require(_tgaux != address(0), "VaultManager: zero tgaux address");
        require(_oracle != address(0), "VaultManager: zero oracle address");
        require(_liquidityPool != address(0), "VaultManager: zero pool address");
        require(_usdc != address(0), "VaultManager: zero usdc address");
        require(_usdt != address(0), "VaultManager: zero usdt address");

        tgaux = TGAUX(_tgaux);
        oracle = OracleAggregator(_oracle);
        liquidityPool = _liquidityPool;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(FEE_COLLECTOR_ROLE, _admin);

        // Set up supported collateral
        supportedCollateral[_usdc] = true;
        supportedCollateral[_usdt] = true;

        // Configure leverage tiers
        // CR = collateral / borrowed = 1 / (leverage - 1) for leverage > 1
        leverageTiers[1] = LeverageTier(15000, 12500); // 1x: 150% CR (no borrowing), 125% liquidation
        leverageTiers[2] = LeverageTier(10000, 9000); // 2x: 100% CR (1/1), 90% liquidation
        leverageTiers[3] = LeverageTier(5000, 4500); // 3x: 50% CR (1/2), 45% liquidation
        leverageTiers[5] = LeverageTier(2500, 2250); // 5x: 25% CR (1/4), 22.5% liquidation
        leverageTiers[10] = LeverageTier(1111, 1000); // 10x: 11.1% CR (1/9), 10% liquidation

        nextPositionId = 1;
    }

    /**
     * @dev Opens a new leveraged position
     * @param collateralAmount Amount of collateral to deposit
     * @param leverage Leverage multiplier (1-10)
     * @param collateralToken Address of collateral token (USDC or USDT)
     * @return positionId The ID of the newly created position
     */
    function openPosition(uint256 collateralAmount, uint256 leverage, address collateralToken)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        require(supportedCollateral[collateralToken], "VaultManager: unsupported collateral");
        require(collateralAmount > 0, "VaultManager: zero collateral");
        require(_isValidLeverage(leverage), "VaultManager: invalid leverage");

        // Get current gold price
        // slither-disable-next-line unused-return
        (uint256 goldPrice,) = oracle.getGoldPrice();
        require(goldPrice > 0, "VaultManager: invalid gold price");

        // Apply protocol fee first
        uint256 feeRate = leverage > 1 ? FEE_WITH_LEVERAGE : FEE_NO_LEVERAGE;
        uint256 fee = (collateralAmount * feeRate) / BASIS_POINTS;
        uint256 effectiveCollateral = collateralAmount - fee;

        // Get required collateralization ratio
        uint256 requiredRatio = leverageTiers[leverage].minCollateralRatio;
        require(requiredRatio > 0, "VaultManager: invalid leverage tier");

        // Simple leverage formula
        uint256 totalValue;
        uint256 borrowedAmount;

        if (leverage == 1) {
            // 1x: over-collateralized, position = collateral / CR
            totalValue = (effectiveCollateral * BASIS_POINTS) / requiredRatio;
            borrowedAmount = 0;
        } else {
            // leverage > 1: borrow against effective (post-fee) collateral so the
            // stored collateral actually satisfies the tier's collateral ratio
            borrowedAmount = effectiveCollateral * (leverage - 1);
            totalValue = effectiveCollateral * leverage;
        }

        uint256 tgauxAmount = (totalValue * 1e20) / goldPrice;

        // Verify CR
        if (leverage == 1) {
            uint256 actualRatio = _calculateCollateralRatio(effectiveCollateral, tgauxAmount, goldPrice);
            require(actualRatio >= requiredRatio, "VaultManager: insufficient collateral");
        } else {
            // For leverage > 1, verify CR using effective (post-fee) collateral
            uint256 actualRatio = (effectiveCollateral * BASIS_POINTS) / borrowedAmount;
            require(actualRatio >= requiredRatio, "VaultManager: insufficient collateral");
        }

        // Transfer collateral
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        collectedFees[collateralToken] += fee;

        // Borrow if needed
        if (borrowedAmount > 0) {
            // slither-disable-next-line unused-return
            ILiquidityPool(liquidityPool).borrow(borrowedAmount, collateralToken);
        }

        // Create position
        positionId = nextPositionId++;
        positions[positionId] = Position({
            owner: msg.sender,
            collateralAmount: effectiveCollateral,
            collateralToken: collateralToken,
            tgauxMinted: tgauxAmount,
            borrowedAmount: borrowedAmount,
            leverage: leverage,
            openPrice: goldPrice,
            lastUpdateTimestamp: block.timestamp,
            isActive: true
        });

        // Track TVL and active set
        totalValueLocked += effectiveCollateral;
        _activePositions.add(positionId);

        // Mint TGAUX to user
        tgaux.mint(msg.sender, tgauxAmount);

        emit PositionOpened(positionId, msg.sender, effectiveCollateral, leverage, tgauxAmount);
    }

    /**
     * @dev Closes a position and returns collateral
     * @param positionId ID of the position to close
     */
    function closePosition(uint256 positionId) external nonReentrant whenNotPaused {
        Position storage position = positions[positionId];
        require(position.isActive, "VaultManager: position not active");
        require(position.owner == msg.sender, "VaultManager: not position owner");

        // Calculate accrued interest
        uint256 interest = calculateInterest(positionId);
        uint256 totalOwed = position.borrowedAmount + interest;

        // Get current gold price
        // slither-disable-next-line unused-return
        (uint256 goldPrice,) = oracle.getGoldPrice();
        require(goldPrice > 0, "VaultManager: invalid gold price");

        // Burn TGAUX from user
        tgaux.burnFrom(msg.sender, position.tgauxMinted);

        // Calculate burn fee on collateral
        uint256 burnFee = (position.collateralAmount * FEE_BURN) / BASIS_POINTS;
        collectedFees[position.collateralToken] += burnFee;

        // Repay borrowed amount and interest to liquidity pool with an explicit
        // principal/interest split so pool accounting stays exact
        if (totalOwed > 0) {
            IERC20(position.collateralToken).safeIncreaseAllowance(liquidityPool, totalOwed);
            ILiquidityPool(liquidityPool).repay(position.borrowedAmount, interest, position.collateralToken);
        }

        // Track TVL and active set
        totalValueLocked -= position.collateralAmount;
        _activePositions.remove(positionId);

        // Mark position as inactive
        position.isActive = false;

        // Return collateral minus burn fee and interest to user.
        // Interest is deducted here because it is funded from the position's collateral,
        // not from phantom funds — vault only holds collateral + borrowed principal.
        uint256 interestOwed = totalOwed > position.borrowedAmount ? totalOwed - position.borrowedAmount : 0;
        uint256 returnAmount = position.collateralAmount - burnFee;
        returnAmount = returnAmount > interestOwed ? returnAmount - interestOwed : 0;

        // slither-disable-next-line reentrancy-eth
        if (returnAmount > 0) {
            IERC20(position.collateralToken).safeTransfer(msg.sender, returnAmount);
        }

        emit PositionClosed(positionId, msg.sender, returnAmount);
    }

    /**
     * @dev Adds collateral to an existing position
     * @param positionId ID of the position
     * @param amount Amount of collateral to add
     */
    function addCollateral(uint256 positionId, uint256 amount) external nonReentrant whenNotPaused {
        Position storage position = positions[positionId];
        require(position.isActive, "VaultManager: position not active");
        require(position.owner == msg.sender, "VaultManager: not position owner");
        require(amount > 0, "VaultManager: zero amount");

        // Transfer collateral from user
        IERC20(position.collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        // slither-disable-next-line reentrancy-eth
        // Update position. Do NOT reset lastUpdateTimestamp here: calculateInterest
        // accrues from it, and resetting would let owners wipe accrued interest by
        // adding dust collateral before closing.
        position.collateralAmount += amount;

        // Track TVL
        totalValueLocked += amount;

        emit CollateralAdded(positionId, amount);
    }

    /**
     * @dev Liquidates an undercollateralized position
     * @param positionId ID of the position to liquidate
     */
    function liquidate(uint256 positionId) external nonReentrant onlyRole(LIQUIDATOR_ROLE) {
        require(isLiquidatable(positionId), "VaultManager: position not liquidatable");

        Position storage position = positions[positionId];

        // Calculate accrued interest
        uint256 interest = calculateInterest(positionId);
        uint256 totalOwed = position.borrowedAmount + interest;

        // Burn TGAUX from the position owner (no allowance needed), consistent
        // with liquidatePosition() — liquidators do not need to hold TGAUX
        tgaux.vaultBurn(position.owner, position.tgauxMinted);

        // Repay liquidity pool via repay() to keep pool accounting correct.
        // Principal is funded by the borrowed tokens the vault already holds;
        // only the interest portion comes out of the position's collateral.
        if (totalOwed > 0) {
            IERC20(position.collateralToken).safeIncreaseAllowance(liquidityPool, totalOwed);
            ILiquidityPool(liquidityPool).repay(position.borrowedAmount, interest, position.collateralToken);
        }

        // Collateral remaining after the interest deduction
        uint256 remainingCollateral = position.collateralAmount > interest ? position.collateralAmount - interest : 0;

        // Apply liquidation penalty — accrued as protocol fees, consistent with liquidatePosition()
        uint256 penaltyRate = _calculateLiquidationPenalty(position.leverage);
        uint256 penalty = (remainingCollateral * penaltyRate) / BASIS_POINTS;
        uint256 returnToOwner = remainingCollateral - penalty;

        if (penalty > 0) {
            collectedFees[position.collateralToken] += penalty;
        }

        // Track TVL and active set
        totalValueLocked -= position.collateralAmount;
        _activePositions.remove(positionId);

        // Mark position as inactive
        position.isActive = false;

        // Return remaining collateral (after interest + penalty) to the position
        // owner, consistent with liquidatePosition(). The liquidator commits no
        // capital and must not receive the owner's residual equity.
        if (returnToOwner > 0) {
            IERC20(position.collateralToken).safeTransfer(position.owner, returnToOwner);
        }

        emit PositionLiquidated(positionId, msg.sender, returnToOwner);
    }

    /**
     * @dev Collects protocol fees
     * @param token Address of the token to collect fees for
     */
    function collectFees(address token) external onlyRole(FEE_COLLECTOR_ROLE) {
        uint256 amount = collectedFees[token];
        require(amount > 0, "VaultManager: no fees to collect");

        collectedFees[token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit FeesCollected(amount, token);
    }

    /**
     * @dev Sets the FeeDistributor address. Must be called before pushFeesToDistributor can be used.
     */
    function setFeeDistributor(address _feeDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeDistributor != address(0), "VaultManager: zero address");
        feeDistributor = _feeDistributor;
    }

    /**
     * @dev Approves FeeDistributor to pull collected fees and calls collectFees() on it,
     *      which distributes to insurance (30%), treasury (40%), and stakers (30%).
     *      Caller must hold FEE_COLLECTOR_ROLE. feeDistributor must be set first.
     */
    function pushFeesToDistributor(address token) external onlyRole(FEE_COLLECTOR_ROLE) {
        require(feeDistributor != address(0), "VaultManager: fee distributor not set");
        uint256 amount = collectedFees[token];
        require(amount > 0, "VaultManager: no fees to collect");

        collectedFees[token] = 0;
        IERC20(token).safeIncreaseAllowance(feeDistributor, amount);
        IFeeDistributor(feeDistributor).collectFees(token, amount);

        emit FeesCollected(amount, token);
    }

    /**
     * @dev Pauses the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // View functions

    /**
     * @dev Gets the health of a position (collateralization ratio)
     * @param positionId ID of the position
     * @return ratio Current collateralization ratio in basis points
     */
    function getPositionHealth(uint256 positionId) external view returns (uint256 ratio) {
        Position storage position = positions[positionId];
        require(position.isActive, "VaultManager: position not active");

        ratio = _positionHealthRatio(positionId);
    }

    /**
     * @dev Current health ratio for a position, matching the leverage tier semantics:
     *      - 1x (no borrow): collateral / TGAUX value (synthetic backing ratio)
     *      - leveraged: equity / borrowed (margin ratio), where equity is collateral
     *        adjusted for unrealized PnL against the open price and accrued interest.
     *        At open this equals collateral/borrowed = 1/(leverage-1), matching the
     *        tier table (2x: 100% open / 90% liquidation, 10x: 11.1% / 10%).
     */
    function _positionHealthRatio(uint256 positionId) internal view returns (uint256 ratio) {
        Position storage position = positions[positionId];

        // slither-disable-next-line unused-return
        (uint256 goldPrice,) = oracle.getGoldPrice();

        if (position.borrowedAmount == 0) {
            return _calculateCollateralRatio(position.collateralAmount, position.tgauxMinted, goldPrice);
        }

        // TGAUX liability now vs at open, in collateral (6-decimal) terms
        uint256 valueNow = (position.tgauxMinted * goldPrice) / 1e20;
        uint256 valueAtOpen = (position.tgauxMinted * position.openPrice) / 1e20;

        // equity = collateral - (valueNow - valueAtOpen) - interest, computed
        // without underflow: gains (valueNow < valueAtOpen) increase equity
        uint256 assets = position.collateralAmount + valueAtOpen;
        uint256 liabilities = valueNow + calculateInterest(positionId);
        if (assets <= liabilities) {
            return 0;
        }

        ratio = ((assets - liabilities) * BASIS_POINTS) / position.borrowedAmount;
    }

    /**
     * @dev Calculates accrued borrowing fees for a position
     * @param positionId ID of the position
     * @return interest Amount of interest accrued
     */
    function calculateInterest(uint256 positionId) public view returns (uint256 interest) {
        Position storage position = positions[positionId];

        if (position.borrowedAmount == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp - position.lastUpdateTimestamp;

        // Interest = borrowedAmount * rate * timeElapsed / (BASIS_POINTS * SECONDS_PER_DAY)
        // Multiply first to avoid precision loss from intermediate division
        interest = (position.borrowedAmount * DAILY_BORROW_RATE * timeElapsed) / (BASIS_POINTS * SECONDS_PER_DAY);
    }

    /**
     * @dev Checks if a position can be liquidated
     * @param positionId ID of the position
     * @return liquidatable True if position is liquidatable
     */
    function isLiquidatable(uint256 positionId) public view returns (bool liquidatable) {
        Position storage position = positions[positionId];

        if (!position.isActive) {
            return false;
        }

        uint256 currentRatio = _positionHealthRatio(positionId);

        uint256 liquidationRatio = leverageTiers[position.leverage].liquidationRatio;
        liquidatable = currentRatio < liquidationRatio;
    }

    /**
     * @dev Gets position details
     * @param positionId ID of the position
     * @return position The position struct
     */
    function getPosition(uint256 positionId) external view returns (Position memory position) {
        position = positions[positionId];
    }

    /**
     * @dev Liquidate a position with a specific percentage
     * @param positionId ID of the position to liquidate
     * @param percentage Percentage to liquidate in basis points (e.g., 2500 = 25%)
     * @return penalty Penalty amount collected
     */
    function liquidatePosition(uint256 positionId, uint256 percentage)
        external
        onlyRole(LIQUIDATOR_ROLE)
        nonReentrant
        returns (uint256 penalty)
    {
        Position storage position = positions[positionId];
        require(position.isActive, "VaultManager: position not active");
        require(isLiquidatable(positionId), "VaultManager: position not liquidatable");

        // Calculate amounts to liquidate
        uint256 tgauxToLiquidate = (position.tgauxMinted * percentage) / BASIS_POINTS;
        uint256 collateralToReturn = (position.collateralAmount * percentage) / BASIS_POINTS;
        uint256 borrowedToRepay = (position.borrowedAmount * percentage) / BASIS_POINTS;

        // Calculate penalty (5-15% based on leverage)
        // Combine multiplications to avoid precision loss
        uint256 penaltyRate = _calculateLiquidationPenalty(position.leverage);
        penalty = (position.collateralAmount * percentage * penaltyRate) / (BASIS_POINTS * BASIS_POINTS);

        // Burn TGAUX from owner (no allowance needed — owner cannot block
        // liquidation by revoking approval)
        tgaux.vaultBurn(position.owner, tgauxToLiquidate);

        // Repay borrowed amount to liquidity pool via repay() so pool accounting
        // (totalBorrowed / borrowedByToken) is decremented, matching closePosition/liquidate
        if (borrowedToRepay > 0) {
            IERC20(position.collateralToken).safeIncreaseAllowance(liquidityPool, borrowedToRepay);
            ILiquidityPool(liquidityPool).repay(borrowedToRepay, 0, position.collateralToken);
        }

        // Deduct penalty from collateral
        uint256 returnToOwner = collateralToReturn - penalty;

        // Return remaining collateral to owner
        if (returnToOwner > 0) {
            IERC20(position.collateralToken).safeTransfer(position.owner, returnToOwner);
        }

        // Transfer penalty to caller
        if (penalty > 0) {
            IERC20(position.collateralToken).safeTransfer(msg.sender, penalty);
        }

        // Track TVL
        totalValueLocked -= collateralToReturn;

        // slither-disable-next-line reentrancy-eth
        // Update position
        position.tgauxMinted -= tgauxToLiquidate;
        position.collateralAmount -= collateralToReturn;
        position.borrowedAmount -= borrowedToRepay;

        // If fully liquidated, mark as inactive and remove from active set
        if (position.tgauxMinted == 0 || position.collateralAmount == 0) {
            position.isActive = false;
            _activePositions.remove(positionId);
        }

        emit PositionLiquidated(positionId, msg.sender, penalty);

        return penalty;
    }

    /**
     * @dev Returns the total value locked in the vault
     * @return Total value locked (sum of all active position collateral amounts)
     */
    function getTotalValueLocked() external view returns (uint256) {
        return totalValueLocked;
    }

    /**
     * @dev Returns the total number of currently active positions.
     */
    function activePositionCount() external view returns (uint256) {
        return _activePositions.length();
    }

    /**
     * @dev Returns all active position IDs. Use the paginated overload for large sets.
     */
    function getActivePositionIds() external view returns (uint256[] memory) {
        return _activePositions.values();
    }

    /**
     * @dev Returns a page of active position IDs.
     * @param offset Index to start from within the active set
     * @param limit Maximum number of IDs to return
     * @return ids Slice of active position IDs
     * @return total Total number of active positions
     */
    function getActivePositionIds(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        total = _activePositions.length();
        if (offset >= total || limit == 0) return (new uint256[](0), total);
        uint256 end = offset + limit > total ? total : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = _activePositions.at(i);
        }
    }

    // Internal functions

    /**
     * @dev Calculates collateralization ratio
     * @param collateralAmount Amount of collateral (6 decimals)
     * @param tgauxAmount Amount of TGAUX minted (18 decimals)
     * @param goldPrice Current gold price (8 decimals)
     * @return ratio Collateralization ratio in basis points
     */
    function _calculateCollateralRatio(uint256 collateralAmount, uint256 tgauxAmount, uint256 goldPrice)
        internal
        pure
        returns (uint256 ratio)
    {
        if (tgauxAmount == 0) {
            return type(uint256).max;
        }

        // collateralValue = collateralAmount (6 decimals)
        // tgauxValue = (tgauxAmount * goldPrice) / 10^20 (to get to 6 decimals)
        // ratio = (collateralValue * BASIS_POINTS) / tgauxValue

        uint256 tgauxValue = (tgauxAmount * goldPrice) / 1e20;
        ratio = (collateralAmount * BASIS_POINTS) / tgauxValue;
    }

    /**
     * @dev Checks if leverage value is valid
     * @param leverage Leverage value to check
     * @return valid True if leverage is valid
     */
    function _isValidLeverage(uint256 leverage) internal view returns (bool valid) {
        return leverageTiers[leverage].minCollateralRatio > 0;
    }

    /**
     * @dev Calculate liquidation penalty based on leverage
     * @param leverage Leverage level
     * @return penalty Penalty rate in basis points
     */
    function _calculateLiquidationPenalty(uint256 leverage) internal pure returns (uint256 penalty) {
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
}

/**
 * @dev Interface for LiquidityPool
 */
interface ILiquidityPool {
    function borrow(uint256 amount, address token) external;
    function repay(uint256 principal, uint256 interest, address token) external returns (bool);
}

/**
 * @dev Interface for FeeDistributor
 */
interface IFeeDistributor {
    function collectFees(address token, uint256 amount) external returns (uint256);
}
