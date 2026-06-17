// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {MockLiquidityPool} from "./mocks/MockLiquidityPool.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockInsuranceFund {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public depositsReceived;

    function depositFromLiquidation(uint256 amount, address token) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        depositsReceived[token] += amount;
    }

    function getDeposits(address token) external view returns (uint256) {
        return depositsReceived[token];
    }
}

contract LiquidationEngineTest is Test {
    LiquidationEngine public liquidationEngine;
    VaultManager public vaultManager;
    TGAUX public tgaux;
    OracleAggregator public oracle;
    MockLiquidityPool public liquidityPool;
    MockERC20 public usdc;
    MockERC20 public usdt;

    MockChainlinkOracle public chainlinkOracle;
    MockBandOracle public bandOracle;
    MockAPI3Oracle public api3Oracle;

    address public admin;
    address public user1;
    address public liquidator;
    MockInsuranceFund public insuranceFund;
    address public treasury;

    uint256 public constant GOLD_PRICE = 200000000000; // $2000 with 8 decimals

    event PositionMarkedForLiquidation(uint256 indexed positionId, uint256 timestamp);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 penalty, uint256 portion);
    event LiquidatorRegistered(address indexed liquidator);

    function setUp() public {
        admin = vm.addr(1);
        user1 = vm.addr(2);
        liquidator = vm.addr(3);
        treasury = vm.addr(5);

        insuranceFund = new MockInsuranceFund();

        vm.startPrank(admin);

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy TGAUX
        tgaux = new TGAUX(admin);

        // Deploy oracles
        chainlinkOracle = new MockChainlinkOracle(8);
        bandOracle = new MockBandOracle();
        api3Oracle = new MockAPI3Oracle();

        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        // Deploy OracleAggregator
        oracle = new OracleAggregator(admin, address(chainlinkOracle), address(bandOracle), address(api3Oracle));

        // Update TWAP
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        // Deploy mock liquidity pool
        liquidityPool = new MockLiquidityPool();

        // Deploy VaultManager
        vaultManager = new VaultManager(
            admin, address(tgaux), address(oracle), address(liquidityPool), address(usdc), address(usdt)
        );

        // Grant roles
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vaultManager));

        // Deploy LiquidationEngine
        liquidationEngine = new LiquidationEngine(address(vaultManager), address(insuranceFund), treasury);

        // Grant liquidator role to LiquidationEngine
        vaultManager.grantRole(vaultManager.LIQUIDATOR_ROLE(), address(liquidationEngine));
        vaultManager.grantRole(vaultManager.LIQUIDATOR_ROLE(), liquidator);

        vm.stopPrank();

        // Mint tokens
        usdc.mint(user1, 100000e6);
        usdt.mint(user1, 100000e6);
        usdc.mint(address(liquidityPool), 1000000e6);
        usdt.mint(address(liquidityPool), 1000000e6);
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertEq(liquidationEngine.vaultManager(), address(vaultManager));
        assertEq(liquidationEngine.insuranceFund(), address(insuranceFund));
        assertEq(liquidationEngine.treasury(), treasury);
    }

    function test_ConstructorRevertsWithZeroAddress() public {
        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(0), address(insuranceFund), treasury);

        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(vaultManager), address(0), treasury);

        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(vaultManager), address(insuranceFund), address(0));
    }

    /* ============ Liquidator Registration Tests ============ */

    function test_RegisterAsLiquidator() public {
        vm.prank(liquidator);
        vm.expectEmit(true, true, true, true);
        emit LiquidatorRegistered(liquidator);

        liquidationEngine.registerAsLiquidator();

        LiquidationEngine.LiquidatorStats memory stats = liquidationEngine.getLiquidatorStats(liquidator);
        assertTrue(stats.isRegistered);
    }

    /* ============ Position Marking Tests ============ */

    function test_MarkForLiquidation() public {
        // Create an unhealthy position
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        vm.expectEmit(true, false, false, false);
        emit PositionMarkedForLiquidation(positionId, block.timestamp);

        liquidationEngine.markForLiquidation(positionId);

        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertTrue(info.isMarked);
        assertEq(info.markedTime, block.timestamp);
    }

    function test_MarkForLiquidationRevertsWhenNotLiquidatable() public {
        // Create a healthy position
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 3000e6);
        uint256 positionId = vaultManager.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__PositionNotLiquidatable.selector);
        liquidationEngine.markForLiquidation(positionId);
    }

    /* ============ Liquidation Tests ============ */

    function test_LiquidatePosition() public {
        uint256 positionId = _createLiquidatablePosition();

        // Mark for liquidation
        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Fast forward past grace period
        vm.warp(block.timestamp + 11 minutes);

        // Liquidate
        vm.prank(liquidator);
        vm.expectEmit(true, true, false, false);
        emit PositionLiquidated(positionId, liquidator, 0, 2500);

        uint256 penalty = liquidationEngine.liquidatePosition(positionId);

        assertTrue(penalty > 0);

        // Check stats
        LiquidationEngine.LiquidatorStats memory stats = liquidationEngine.getLiquidatorStats(liquidator);
        assertEq(stats.totalLiquidations, 1);
        assertTrue(stats.totalRewards > 0);
    }

    /// @dev Stale mark policy: a mark past its validity window is re-marked
    ///      WITHOUT a fresh grace period — the owner already received a full
    ///      grace from the original mark and never cleared it while healthy,
    ///      so keeper downtime must not repeatedly delay liquidation
    function test_StaleMarkLiquidatesWithoutFreshGrace() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        uint256 firstMark = block.timestamp;

        // Warp past grace period AND mark validity (10 min + 1 h)
        vm.warp(block.timestamp + liquidationEngine.GRACE_PERIOD() + liquidationEngine.MARK_VALIDITY() + 1);

        // The stale mark is refreshed and liquidation proceeds in the same call
        vm.prank(liquidator);
        uint256 penalty = liquidationEngine.liquidatePosition(positionId);
        assertGt(penalty, 0);

        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertGt(info.markedTime, firstMark);
        assertEq(info.tranchesLiquidated, 1);
    }

    /// @dev An owner cannot use markForLiquidation on their own stale mark to
    ///      buy a fresh grace period: a stale re-mark is backdated so the
    ///      position remains immediately liquidatable
    function test_ManualRemarkOfStaleMarkGrantsNoGrace() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        vm.warp(block.timestamp + liquidationEngine.GRACE_PERIOD() + liquidationEngine.MARK_VALIDITY() + 1);

        // Owner front-runs the keeper with a manual re-mark
        vm.prank(user1);
        liquidationEngine.markForLiquidation(positionId);

        // No new grace: liquidation still proceeds immediately
        vm.prank(liquidator);
        uint256 penalty = liquidationEngine.liquidatePosition(positionId);
        assertGt(penalty, 0);
    }

    /// @dev clearMark: a recovered position can clear its mark, and a later
    ///      relapse gets a fresh mark with a full grace period
    function test_ClearMarkRestoresFreshGraceAfterRecovery() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Cannot clear while still liquidatable
        vm.prank(user1);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__StillLiquidatable.selector);
        liquidationEngine.clearMark(positionId);

        // Owner self-remediates with extra collateral, then clears the mark
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 1500e6);
        vaultManager.addCollateral(positionId, 1500e6);
        liquidationEngine.clearMark(positionId);
        vm.stopPrank();

        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertFalse(info.isMarked);

        // Position relapses much later (well past the old mark's validity):
        // walk the price up in 4% steps (inside the 5% circuit breaker) until
        // the topped-up position is undercollateralized again
        vm.warp(block.timestamp + 2 hours);
        uint256 stepPrice = GOLD_PRICE * 125 / 100; // current price after helper
        for (uint256 i = 0; i < 10; i++) {
            stepPrice = stepPrice * 104 / 100;
            chainlinkOracle.setLatestAnswer(SafeCast.toInt256(stepPrice));
            bandOracle.setReferenceData(stepPrice * 1e10);
            api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(stepPrice * 1e10)));
            vm.warp(block.timestamp + 601);
            oracle.updateTwap();
        }
        assertTrue(vaultManager.isLiquidatable(positionId));

        // Fresh mark with a FULL grace period — not instant liquidation
        vm.prank(liquidator);
        uint256 penalty = liquidationEngine.liquidatePosition(positionId);
        assertEq(penalty, 0);

        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__GracePeriodActive.selector);
        liquidationEngine.liquidatePosition(positionId);
    }

    function test_ClearMarkRevertsWhenNotMarked() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.expectRevert(LiquidationEngine.LiquidationEngine__NotMarked.selector);
        liquidationEngine.clearMark(positionId);
    }

    /// @dev clearMark is owner-only: a third party cannot delete a legitimate
    ///      mark during a transient healthy wick to restart the grace clock
    function test_ClearMarkRevertsWhenNotOwner() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Bring the position back to health so the StillLiquidatable guard
        // would pass, isolating the owner check
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 3000e6);
        vaultManager.addCollateral(positionId, 3000e6);
        vm.stopPrank();
        assertFalse(vaultManager.isLiquidatable(positionId));

        // A non-owner (here the liquidator) cannot clear it
        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__NotPositionOwner.selector);
        liquidationEngine.clearMark(positionId);
    }

    /// @dev Oscillation guard: clearing a mark then relapsing within
    ///      GRACE_PERIOD + MARK_VALIDITY is treated as a continuation, not a
    ///      fresh recovery — the re-mark is backdated and liquidation proceeds
    ///      immediately, so recover->clear->relapse cannot farm endless graces
    function test_ClearThenQuickRelapseGetsNoFreshGrace() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Owner tops up just over the threshold to clear, then clears the mark
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 300e6);
        vaultManager.addCollateral(positionId, 300e6);
        liquidationEngine.clearMark(positionId);
        vm.stopPrank();
        assertFalse(vaultManager.isLiquidatable(positionId));

        // Relapse shortly after: 4 x 3% steps (~40 min total, inside the
        // GRACE + MARK_VALIDITY = 70 min window from the clear)
        uint256 stepPrice = GOLD_PRICE * 125 / 100; // price after the helper
        for (uint256 i = 0; i < 4; i++) {
            stepPrice = stepPrice * 103 / 100;
            chainlinkOracle.setLatestAnswer(SafeCast.toInt256(stepPrice));
            bandOracle.setReferenceData(stepPrice * 1e10);
            api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(stepPrice * 1e10)));
            vm.warp(block.timestamp + 601);
            oracle.updateTwap();
        }
        assertTrue(vaultManager.isLiquidatable(positionId));

        // No fresh grace: the position is liquidated on the first attempt
        vm.prank(liquidator);
        uint256 penalty = liquidationEngine.liquidatePosition(positionId);
        assertGt(penalty, 0);
    }

    /// @dev MIN_LIQUIDATION_VALUE gates only the FIRST tranche. A position whose
    ///      equity starts just above the floor drops below it after a tranche or
    ///      two; the check must not re-fire mid-sequence and strand the position
    ///      before it reaches the final settling tranche.
    function test_TrancheSequenceCompletesWhenEquityFallsBelowMinValue() public {
        // Small 2x position: engine equity (notional - debt) lands just above
        // the $100 floor at the liquidation point, so it dips below after the
        // first 25% tranche
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 110e6);
        uint256 positionId = vaultManager.openPosition(110e6, 2, address(usdc));
        tgaux.approve(address(vaultManager), type(uint256).max);
        vm.stopPrank();

        // Two 4% steps (within the circuit breaker) make the 2x liquidatable
        uint256 price = GOLD_PRICE;
        for (uint256 i = 0; i < 2; i++) {
            price = price * 104 / 100;
            chainlinkOracle.setLatestAnswer(SafeCast.toInt256(price));
            bandOracle.setReferenceData(price * 1e10);
            api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(price * 1e10)));
            vm.warp(block.timestamp + 601);
            oracle.updateTwap();
        }
        assertTrue(vaultManager.isLiquidatable(positionId));
        assertGe(_positionValue(positionId), liquidationEngine.MIN_LIQUIDATION_VALUE());

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        // First tranche succeeds; equity then drops below the floor
        vm.startPrank(liquidator);
        liquidationEngine.liquidatePosition(positionId);
        assertLt(_positionValue(positionId), liquidationEngine.MIN_LIQUIDATION_VALUE());

        // Remaining tranches must still proceed (previously reverted
        // InsufficientValue) and the position fully settles
        liquidationEngine.liquidatePosition(positionId);
        liquidationEngine.liquidatePosition(positionId);
        liquidationEngine.liquidatePosition(positionId);
        vm.stopPrank();

        VaultManager.Position memory position = vaultManager.getPosition(positionId);
        assertFalse(position.isActive);
        assertEq(position.borrowedAmount, 0);
        assertEq(position.tgauxMinted, 0);
    }

    /// @dev Reads a position's engine-side value (notional - debt) via the
    ///      public checkPositions view
    function _positionValue(uint256 positionId) internal view returns (uint256) {
        LiquidationEngine.LiquidationCandidate[] memory candidates = liquidationEngine.checkPositions(0, 50);
        for (uint256 i = 0; i < candidates.length; i++) {
            if (candidates[i].positionId == positionId) {
                return candidates[i].positionValue;
            }
        }
        return 0;
    }

    /// @dev Mark overwrite guard: a live mark cannot be re-marked, so an owner
    ///      cannot reset their own grace period to dodge liquidation
    function test_MarkForLiquidationRevertsWhenAlreadyMarked() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Immediate re-mark (e.g., by the position owner) is rejected
        vm.prank(user1);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__AlreadyMarked.selector);
        liquidationEngine.markForLiquidation(positionId);

        // Still rejected inside the liquidation window after grace expiry
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(user1);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__AlreadyMarked.selector);
        liquidationEngine.markForLiquidation(positionId);
    }

    /// @dev M-01 regression: an unmarked liquidatable position must be auto-marked
    ///      on the first liquidation attempt instead of being liquidated instantly
    function test_AutoMarkOnFirstLiquidationAttempt() public {
        uint256 positionId = _createLiquidatablePosition();

        // No explicit markForLiquidation() — first attempt should auto-mark and not liquidate
        vm.prank(liquidator);
        vm.expectEmit(true, false, false, false);
        emit PositionMarkedForLiquidation(positionId, block.timestamp);

        uint256 penalty = liquidationEngine.liquidatePosition(positionId);
        assertEq(penalty, 0);

        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertTrue(info.isMarked);
        assertEq(info.tranchesLiquidated, 0);

        // Second attempt within grace period still reverts
        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__GracePeriodActive.selector);
        liquidationEngine.liquidatePosition(positionId);

        // After the grace period the liquidation proceeds
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(liquidator);
        penalty = liquidationEngine.liquidatePosition(positionId);
        assertGt(penalty, 0);
    }

    /// @dev M-01 regression: checkUpkeep must surface unmarked liquidatable
    ///      positions so performUpkeep can auto-mark them
    function test_CheckUpkeepIncludesUnmarkedPositions() public {
        uint256 positionId = _createLiquidatablePosition();

        (bool upkeepNeeded, bytes memory performData) = liquidationEngine.checkUpkeep("");
        assertTrue(upkeepNeeded);

        uint256[] memory ids = abi.decode(performData, (uint256[]));
        assertEq(ids.length, 1);
        assertEq(ids[0], positionId);

        // performUpkeep auto-marks instead of liquidating
        liquidationEngine.performUpkeep(performData);
        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertTrue(info.isMarked);
        assertEq(info.tranchesLiquidated, 0);

        // After grace period, the same flow liquidates
        vm.warp(block.timestamp + 11 minutes);
        (upkeepNeeded, performData) = liquidationEngine.checkUpkeep("");
        assertTrue(upkeepNeeded);
        liquidationEngine.performUpkeep(performData);

        info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertEq(info.tranchesLiquidated, 1);
    }

    function test_LiquidatePositionRevertsBeforeGracePeriod() public {
        uint256 positionId = _createLiquidatablePosition();

        // Mark for liquidation
        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        // Try to liquidate immediately
        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__GracePeriodActive.selector);
        liquidationEngine.liquidatePosition(positionId);
    }

    function test_PartialLiquidationMultipleTranches() public {
        uint256 positionId = _createLiquidatablePosition();

        // Mark
        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);

        vm.warp(block.timestamp + 11 minutes);

        // Liquidate 25% (tranche 1)
        vm.prank(liquidator);
        liquidationEngine.liquidatePosition(positionId);

        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertEq(info.tranchesLiquidated, 1);

        // Liquidate 25% (tranche 2)
        vm.prank(liquidator);
        liquidationEngine.liquidatePosition(positionId);

        info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertEq(info.tranchesLiquidated, 2);
    }

    /// @dev The final tranche settles the whole remainder, so a position is
    ///      fully closed after MAX_TRANCHES rather than left active with ~31%
    ///      residual principal stranded (25% of remaining never reaches zero)
    function test_PositionFullySettledAfter4Tranches() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        // Liquidate 4 tranches: 25%, 25%, 25%, then the final 100% of remainder
        vm.startPrank(liquidator);
        liquidationEngine.liquidatePosition(positionId);
        liquidationEngine.liquidatePosition(positionId);
        liquidationEngine.liquidatePosition(positionId);
        liquidationEngine.liquidatePosition(positionId);

        // Position is fully settled: nothing left active, nothing stranded
        VaultManager.Position memory position = vaultManager.getPosition(positionId);
        assertFalse(position.isActive);
        assertEq(position.collateralAmount, 0);
        assertEq(position.tgauxMinted, 0);
        assertEq(position.borrowedAmount, 0);

        // A further attempt reverts (the position is no longer liquidatable)
        vm.expectRevert(LiquidationEngine.LiquidationEngine__GracePeriodActive.selector);
        liquidationEngine.liquidatePosition(positionId);
        vm.stopPrank();
    }

    /* ============ Batch Liquidation Tests ============ */

    function test_BatchLiquidate() public {
        // Create multiple positions first
        uint256[] memory positionIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(user1);
            usdc.approve(address(vaultManager), 3000e6);
            positionIds[i] = vaultManager.openPosition(3000e6, 1, address(usdc));
            tgaux.approve(address(vaultManager), type(uint256).max);
            vm.stopPrank();
        }

        // Make all positions liquidatable with a single price increase sequence
        for (uint256 i = 0; i < 5; i++) {
            uint256 newPrice = GOLD_PRICE * (105 + i * 5) / 100;
            chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
            bandOracle.setReferenceData(newPrice * 1e10);
            api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
            vm.warp(block.timestamp + 601);
            oracle.updateTwap();
        }

        // Mark all for liquidation
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(liquidator);
            liquidationEngine.markForLiquidation(positionIds[i]);
        }

        vm.warp(block.timestamp + 11 minutes);

        // Batch liquidate
        vm.prank(liquidator);
        uint256 totalPenalty = liquidationEngine.batchLiquidate(positionIds);

        assertTrue(totalPenalty > 0);

        // Check stats
        LiquidationEngine.LiquidatorStats memory stats = liquidationEngine.getLiquidatorStats(liquidator);
        assertEq(stats.totalLiquidations, 3);
    }

    /* ============ Penalty Calculation Tests ============ */

    function test_CalculatePenalty() public view {
        assertEq(liquidationEngine.calculatePenalty(1), 500); // 5%
        assertEq(liquidationEngine.calculatePenalty(2), 500); // 5%
        assertEq(liquidationEngine.calculatePenalty(3), 700); // 7%
        assertEq(liquidationEngine.calculatePenalty(5), 1000); // 10%
        assertEq(liquidationEngine.calculatePenalty(10), 1500); // 15%
    }

    /* ============ Chainlink Automation Tests ============ */

    function test_CheckUpkeep() public {
        // Create liquidatable position
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        // Check upkeep
        (bool upkeepNeeded, bytes memory performData) = liquidationEngine.checkUpkeep("");

        assertTrue(upkeepNeeded);

        uint256[] memory positionIds = abi.decode(performData, (uint256[]));
        assertEq(positionIds.length, 1);
        assertEq(positionIds[0], positionId);
    }

    function test_PerformUpkeep() public {
        // Create liquidatable position
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        // Get perform data
        (, bytes memory performData) = liquidationEngine.checkUpkeep("");

        // Perform upkeep
        liquidationEngine.performUpkeep(performData);

        // Check position was liquidated
        LiquidationEngine.LiquidationInfo memory info = liquidationEngine.getPositionLiquidationInfo(positionId);
        assertEq(info.tranchesLiquidated, 1);
    }

    /* ============ Admin Function Tests ============ */

    function test_PauseUnpause() public {
        vm.prank(admin);
        liquidationEngine.pause();
        assertTrue(liquidationEngine.paused());

        vm.prank(admin);
        liquidationEngine.unpause();
        assertFalse(liquidationEngine.paused());
    }

    function test_UpdateInsuranceFund() public {
        address newFund = vm.addr(6);

        vm.prank(admin);
        liquidationEngine.updateInsuranceFund(newFund);

        assertEq(liquidationEngine.insuranceFund(), newFund);
    }

    function test_UpdateTreasury() public {
        address newTreasury = vm.addr(7);

        vm.prank(admin);
        liquidationEngine.updateTreasury(newTreasury);

        assertEq(liquidationEngine.treasury(), newTreasury);
    }

    /* ============ Branch coverage ============ */

    function test_UpdateInsuranceFundRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        liquidationEngine.updateInsuranceFund(address(0));
    }

    function test_UpdateTreasuryRevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        liquidationEngine.updateTreasury(address(0));
    }

    function test_ClaimRewardsRevertsWhenNoRewards() public {
        vm.prank(liquidator);
        vm.expectRevert(LiquidationEngine.LiquidationEngine__NoRewardsToClaim.selector);
        liquidationEngine.claimRewards(address(usdc));
    }

    function test_LiquidatePositionInternalRevertsWhenCalledExternally() public {
        vm.expectRevert("LiquidationEngine: internal only");
        liquidationEngine.liquidatePositionInternal(0, liquidator);
    }

    function test_BatchLiquidateTruncatesOversizedInput() public {
        // 11 ids (> MAX_LIQUIDATIONS_PER_UPKEEP). None are liquidatable, so every
        // attempt is skipped by the try/catch; the call exercises the length cap.
        uint256[] memory ids = new uint256[](11);
        uint256 total = liquidationEngine.batchLiquidate(ids);
        assertEq(total, 0);
    }

    function test_PerformUpkeepTruncatesOversizedInput() public {
        uint256[] memory ids = new uint256[](11);
        liquidationEngine.performUpkeep(abi.encode(ids));
    }

    /* ============ Helper Functions ============ */

    function _createLiquidatablePosition() internal returns (uint256 positionId) {
        // Open a 1x position
        vm.startPrank(user1);
        usdc.approve(address(vaultManager), 3000e6);
        positionId = vaultManager.openPosition(3000e6, 1, address(usdc));

        // Approve VaultManager to burn TGAUX for liquidation
        tgaux.approve(address(vaultManager), type(uint256).max);
        vm.stopPrank();

        // Increase price significantly to make it liquidatable
        // For 1x leverage with 150% CR to drop to 125% liquidation threshold
        // Need to do multiple small increases to avoid circuit breaker
        for (uint256 i = 0; i < 5; i++) {
            uint256 newPrice = GOLD_PRICE * (105 + i * 5) / 100;
            chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
            bandOracle.setReferenceData(newPrice * 1e10);
            api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
            vm.warp(block.timestamp + 601);
            oracle.updateTwap();
        }

        return positionId;
    }
}
