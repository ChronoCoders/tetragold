// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    address public insuranceFund;
    address public treasury;

    uint256 public constant GOLD_PRICE = 200000000000; // $2000 with 8 decimals

    event PositionMarkedForLiquidation(uint256 indexed positionId, uint256 timestamp);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 penalty, uint256 portion);
    event LiquidatorRegistered(address indexed liquidator);

    function setUp() public {
        admin = vm.addr(1);
        user1 = vm.addr(2);
        liquidator = vm.addr(3);
        insuranceFund = vm.addr(4);
        treasury = vm.addr(5);

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
        oracle = new OracleAggregator(
            admin,
            address(chainlinkOracle),
            address(bandOracle),
            address(api3Oracle)
        );

        // Update TWAP
        oracle.updateTwap();

        // Deploy mock liquidity pool
        liquidityPool = new MockLiquidityPool();

        // Deploy VaultManager
        vaultManager = new VaultManager(
            admin,
            address(tgaux),
            address(oracle),
            address(liquidityPool),
            address(usdc),
            address(usdt)
        );

        // Grant roles
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vaultManager));

        // Deploy LiquidationEngine
        liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            insuranceFund,
            treasury
        );

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
        assertEq(liquidationEngine.insuranceFund(), insuranceFund);
        assertEq(liquidationEngine.treasury(), treasury);
    }

    function test_ConstructorRevertsWithZeroAddress() public {
        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(0), insuranceFund, treasury);

        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(vaultManager), address(0), treasury);

        vm.expectRevert(LiquidationEngine.LiquidationEngine__InvalidAddress.selector);
        new LiquidationEngine(address(vaultManager), insuranceFund, address(0));
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

    function test_LiquidatePositionRevertsAfter4Tranches() public {
        uint256 positionId = _createLiquidatablePosition();

        vm.prank(liquidator);
        liquidationEngine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        // Liquidate 4 tranches (100%)
        vm.startPrank(liquidator);
        liquidationEngine.liquidatePosition(positionId); // 25%
        liquidationEngine.liquidatePosition(positionId); // 50%
        liquidationEngine.liquidatePosition(positionId); // 75%
        liquidationEngine.liquidatePosition(positionId); // 100%

        // Try 5th liquidation
        vm.expectRevert(LiquidationEngine.LiquidationEngine__PositionFullyLiquidated.selector);
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
            oracle.updateTwap();
        }

        return positionId;
    }
}
