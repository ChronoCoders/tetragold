// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {MockLiquidityPool} from "./mocks/MockLiquidityPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract VaultManagerTest is Test {
    VaultManager public vault;
    TGAUX public tgaux;
    OracleAggregator public oracle;
    MockLiquidityPool public pool;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockChainlinkOracle public chainlinkOracle;
    MockBandOracle public bandOracle;
    MockAPI3Oracle public api3Oracle;

    address public admin;
    address public user1;
    address public user2;
    address public liquidator;
    address public feeCollector;

    uint256 constant GOLD_PRICE = 200000000000; // $2000 with 8 decimals
    uint256 constant USDC_AMOUNT = 10000e6; // 10,000 USDC
    uint256 constant BASIS_POINTS = 10000;

    // Events
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        uint256 collateral,
        uint256 leverage,
        uint256 tgauxMinted
    );
    event PositionClosed(
        uint256 indexed positionId,
        address indexed owner,
        uint256 returnAmount
    );
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event FeesCollected(uint256 amount, address indexed token);
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 collateralSeized
    );

    function setUp() public {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");
        feeCollector = makeAddr("feeCollector");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Deploy TGAUX
        vm.prank(admin);
        tgaux = new TGAUX(admin);

        // Deploy mock oracles
        chainlinkOracle = new MockChainlinkOracle(8);
        bandOracle = new MockBandOracle();
        api3Oracle = new MockAPI3Oracle();

        // Set oracle prices ($2000)
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        // Deploy oracle aggregator
        vm.prank(admin);
        oracle = new OracleAggregator(
            admin,
            address(chainlinkOracle),
            address(bandOracle),
            address(api3Oracle)
        );

        // Initialize oracle with first price
        oracle.updateTwap();

        // Deploy liquidity pool
        pool = new MockLiquidityPool();

        // Deploy VaultManager
        vm.prank(admin);
        vault = new VaultManager(
            admin,
            address(tgaux),
            address(oracle),
            address(pool),
            address(usdc),
            address(usdt)
        );

        // Grant roles
        bytes32 minterRole = tgaux.MINTER_ROLE();
        bytes32 liquidatorRole = vault.LIQUIDATOR_ROLE();
        bytes32 feeCollectorRole = vault.FEE_COLLECTOR_ROLE();

        vm.startPrank(admin);
        tgaux.grantRole(minterRole, address(vault));
        vault.grantRole(liquidatorRole, liquidator);
        vault.grantRole(feeCollectorRole, feeCollector);
        vm.stopPrank();

        // Mint tokens to users (increase for 10x leverage test)
        usdc.mint(user1, USDC_AMOUNT * 2);
        usdc.mint(user2, USDC_AMOUNT * 2);
        usdt.mint(user1, USDC_AMOUNT * 2);
        usdt.mint(user2, USDC_AMOUNT * 2);

        // Fund liquidity pool (increase for 10x leverage tests)
        usdc.mint(address(pool), USDC_AMOUNT * 100);
        usdt.mint(address(pool), USDC_AMOUNT * 100);
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.FEE_COLLECTOR_ROLE(), admin));
        assertEq(address(vault.tgaux()), address(tgaux));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.liquidityPool(), address(pool));
        assertTrue(vault.supportedCollateral(address(usdc)));
        assertTrue(vault.supportedCollateral(address(usdt)));
    }

    function test_ConstructorRevertsWithZeroAddresses() public {
        vm.expectRevert("VaultManager: zero admin address");
        new VaultManager(
            address(0),
            address(tgaux),
            address(oracle),
            address(pool),
            address(usdc),
            address(usdt)
        );
    }

    /* ============ Position Opening Tests ============ */

    function test_OpenPosition1xLeverage() public {
        // For 1x leverage with 150% CR: need $4500 to get $3000 worth of TGAUX
        uint256 collateral = 4500e6; // $4500 USDC
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);

        // Calculate expected TGAUX: (4500e6 * 1e20) / 200000000000 = 2.25e18
        uint256 expectedTgaux = (collateral * leverage * 1e20) / GOLD_PRICE;
        uint256 expectedCollateral = collateral - (collateral / 1000);

        vm.expectEmit(true, true, false, true);
        emit PositionOpened(1, user1, expectedCollateral, leverage, expectedTgaux);

        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        assertEq(positionId, 1);

        VaultManager.Position memory position = vault.getPosition(positionId);
        assertEq(position.owner, user1);
        assertEq(position.leverage, leverage);
        assertTrue(position.isActive);
        assertEq(position.borrowedAmount, 0); // No borrowing at 1x
        assertEq(position.collateralToken, address(usdc));

        // Check TGAUX minted to user
        assertTrue(tgaux.balanceOf(user1) > 0);
    }

    function test_OpenPosition2xLeverage() public {
        uint256 collateral = 4000e6; // $4000 USDC
        uint256 leverage = 2;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        assertEq(position.leverage, leverage);
        assertEq(position.borrowedAmount, collateral); // Borrowed 1x collateral
        assertTrue(position.isActive);
    }

    function test_OpenPosition10xLeverage() public {
        uint256 collateral = 12000e6; // $12000 USDC for 600% CR
        uint256 leverage = 10;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        assertEq(position.leverage, leverage);
        assertEq(position.borrowedAmount, collateral * 9); // Borrowed 9x collateral
        assertTrue(position.isActive);
    }

    function test_OpenPositionWithUSDT() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdt.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdt));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        assertEq(position.collateralToken, address(usdt));
    }

    function test_OpenPositionRevertsWithUnsupportedCollateral() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(user1, 1000e18);

        vm.startPrank(user1);
        randomToken.approve(address(vault), 1000e18);
        vm.expectRevert("VaultManager: unsupported collateral");
        vault.openPosition(1000e18, 1, address(randomToken));
        vm.stopPrank();
    }

    function test_OpenPositionRevertsWithZeroCollateral() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert("VaultManager: zero collateral");
        vault.openPosition(0, 1, address(usdc));
        vm.stopPrank();
    }

    function test_OpenPositionRevertsWithInvalidLeverage() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert("VaultManager: invalid leverage");
        vault.openPosition(1000e6, 4, address(usdc)); // 4x not supported
        vm.stopPrank();
    }

    function test_OpenPositionRevertsWithInsufficientCollateral() public {
        uint256 collateral = 1e4; // 0.01 USDC - extremely small amount
        uint256 leverage = 10;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        vm.expectRevert("VaultManager: insufficient collateral");
        vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();
    }

    function test_OpenPositionCollectsProtocolFee() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;
        uint256 expectedFee = (collateral * 10) / BASIS_POINTS; // 0.1%

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        assertEq(vault.collectedFees(address(usdc)), expectedFee);
    }

    function test_OpenPositionCollectsHigherFeeWithLeverage() public {
        uint256 collateral = 4000e6;
        uint256 leverage = 2;
        uint256 expectedFee = (collateral * 20) / BASIS_POINTS; // 0.2%

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        assertEq(vault.collectedFees(address(usdc)), expectedFee);
    }

    /* ============ Position Closing Tests ============ */

    function test_ClosePosition1xLeverage() public {
        // Open position
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));

        // Get TGAUX minted
        uint256 tgauxBalance = tgaux.balanceOf(user1);

        // Approve TGAUX for burning
        tgaux.approve(address(vault), tgauxBalance);

        // Close position
        uint256 balanceBefore = usdc.balanceOf(user1);
        vault.closePosition(positionId);
        uint256 balanceAfter = usdc.balanceOf(user1);
        vm.stopPrank();

        // Check position is closed
        VaultManager.Position memory position = vault.getPosition(positionId);
        assertFalse(position.isActive);

        // Check collateral returned (minus fees)
        assertTrue(balanceAfter > balanceBefore);
    }

    function test_ClosePosition2xLeverage() public {
        // Open position with 2x leverage - use enough collateral to cover borrowing costs
        uint256 collateral = 5000e6;
        uint256 leverage = 2;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));

        // Get TGAUX minted
        uint256 tgauxBalance = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBalance);

        // Don't wait - close immediately to minimize interest
        vault.closePosition(positionId);
        vm.stopPrank();

        // Check position is closed
        VaultManager.Position memory position = vault.getPosition(positionId);
        assertFalse(position.isActive);
    }

    function test_ClosePositionRevertsWhenNotOwner() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert("VaultManager: not position owner");
        vault.closePosition(positionId);
        vm.stopPrank();
    }

    function test_ClosePositionRevertsWhenNotActive() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));

        uint256 tgauxBalance = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBalance);
        vault.closePosition(positionId);

        vm.expectRevert("VaultManager: position not active");
        vault.closePosition(positionId);
        vm.stopPrank();
    }

    function test_ClosePositionCollectsBurnFee() public {
        uint256 collateral = 3000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));

        uint256 feesBefore = vault.collectedFees(address(usdc));

        uint256 tgauxBalance = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBalance);
        vault.closePosition(positionId);
        vm.stopPrank();

        uint256 feesAfter = vault.collectedFees(address(usdc));
        assertTrue(feesAfter > feesBefore);
    }

    /* ============ Add Collateral Tests ============ */

    function test_AddCollateral() public {
        uint256 initialCollateral = 3000e6;
        uint256 additionalCollateral = 1000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), initialCollateral + additionalCollateral);
        uint256 positionId = vault.openPosition(initialCollateral, 1, address(usdc));

        VaultManager.Position memory positionBefore = vault.getPosition(positionId);

        vm.expectEmit(true, false, false, true);
        emit CollateralAdded(positionId, additionalCollateral);

        vault.addCollateral(positionId, additionalCollateral);
        vm.stopPrank();

        VaultManager.Position memory positionAfter = vault.getPosition(positionId);
        assertEq(
            positionAfter.collateralAmount,
            positionBefore.collateralAmount + additionalCollateral
        );
    }

    function test_AddCollateralRevertsWhenNotOwner() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert("VaultManager: not position owner");
        vault.addCollateral(positionId, 1000e6);
        vm.stopPrank();
    }

    function test_AddCollateralRevertsWithZeroAmount() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));

        vm.expectRevert("VaultManager: zero amount");
        vault.addCollateral(positionId, 0);
        vm.stopPrank();
    }

    /* ============ Interest Calculation Tests ============ */

    function test_CalculateInterest() public {
        uint256 collateral = 4000e6;
        uint256 leverage = 2;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);

        // Warp 1 day forward
        vm.warp(block.timestamp + 1 days);

        uint256 interest = vault.calculateInterest(positionId);
        uint256 expectedInterest = (position.borrowedAmount * 5) / BASIS_POINTS; // 0.05%

        assertEq(interest, expectedInterest);
    }

    function test_CalculateInterestMultipleDays() public {
        uint256 collateral = 4000e6;
        uint256 leverage = 2;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);

        // Warp 10 days forward
        vm.warp(block.timestamp + 10 days);

        uint256 interest = vault.calculateInterest(positionId);
        uint256 expectedInterest = (position.borrowedAmount * 5 * 10) / BASIS_POINTS; // 0.5%

        assertEq(interest, expectedInterest);
    }

    function test_CalculateInterestNoLeverage() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        uint256 interest = vault.calculateInterest(positionId);
        assertEq(interest, 0); // No interest on 1x leverage
    }

    /* ============ Position Health Tests ============ */

    function test_GetPositionHealth() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        uint256 health = vault.getPositionHealth(positionId);
        assertTrue(health >= 15000); // Should be at least 150%
    }

    function test_GetPositionHealthDecreasesWhenPriceIncreases() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        uint256 healthBefore = vault.getPositionHealth(positionId);

        // Increase gold price by 4% (within circuit breaker threshold)
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        uint256 healthAfter = vault.getPositionHealth(positionId);
        assertTrue(healthAfter < healthBefore);
    }

    /* ============ Liquidation Tests ============ */

    function test_IsLiquidatable() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        // Position should not be liquidatable initially
        assertFalse(vault.isLiquidatable(positionId));

        // Increase price significantly to make position liquidatable
        // Use smaller increments to avoid circuit breaker
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        // Increase again
        newPrice = newPrice * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        // Now position should be liquidatable
        assertTrue(vault.isLiquidatable(positionId));
    }

    function test_Liquidate() public {
        uint256 collateral = 3000e6;
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));

        VaultManager.Position memory position = vault.getPosition(positionId);

        // Transfer TGAUX to liquidator for later use
        tgaux.transfer(liquidator, position.tgauxMinted);
        vm.stopPrank();

        // Make position liquidatable with small increments to avoid circuit breaker
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        newPrice = newPrice * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        // Liquidate
        vm.startPrank(liquidator);
        tgaux.approve(address(vault), position.tgauxMinted);

        vm.expectEmit(true, true, false, false);
        emit PositionLiquidated(positionId, liquidator, 0);

        vault.liquidate(positionId);
        vm.stopPrank();

        // Check position is closed
        VaultManager.Position memory closedPosition = vault.getPosition(positionId);
        assertFalse(closedPosition.isActive);
    }

    function test_LiquidateRevertsWhenNotLiquidatable() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.startPrank(liquidator);
        vm.expectRevert("VaultManager: position not liquidatable");
        vault.liquidate(positionId);
        vm.stopPrank();
    }

    function test_LiquidateRevertsWhenNotLiquidator() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        // Make position liquidatable with small increments
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        newPrice = newPrice * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();

        vm.startPrank(user2);
        vm.expectRevert();
        vault.liquidate(positionId);
        vm.stopPrank();
    }

    /* ============ Fee Collection Tests ============ */

    function test_CollectFees() public {
        uint256 collateral = 3000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        vault.openPosition(collateral, 1, address(usdc));
        vm.stopPrank();

        uint256 fees = vault.collectedFees(address(usdc));
        assertTrue(fees > 0);

        vm.startPrank(feeCollector);
        uint256 balanceBefore = usdc.balanceOf(feeCollector);

        vm.expectEmit(true, true, false, true);
        emit FeesCollected(fees, address(usdc));

        vault.collectFees(address(usdc));
        uint256 balanceAfter = usdc.balanceOf(feeCollector);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, fees);
        assertEq(vault.collectedFees(address(usdc)), 0);
    }

    function test_CollectFeesRevertsWhenNoFees() public {
        vm.startPrank(feeCollector);
        vm.expectRevert("VaultManager: no fees to collect");
        vault.collectFees(address(usdc));
        vm.stopPrank();
    }

    function test_CollectFeesRevertsWhenNotFeeCollector() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert();
        vault.collectFees(address(usdc));
        vm.stopPrank();
    }

    /* ============ Pause/Unpause Tests ============ */

    function test_Pause() public {
        vm.prank(admin);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    function test_OpenPositionRevertsWhenPaused() public {
        vm.prank(admin);
        vault.pause();

        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        vm.expectRevert();
        vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();
    }

    function test_PauseRevertsWhenNotAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();
    }

    /* ============ Integration Tests ============ */

    function test_CompletePositionLifecycle() public {
        uint256 collateral = 4000e6;
        uint256 leverage = 2;

        // Open position
        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));

        // Check initial state
        VaultManager.Position memory position = vault.getPosition(positionId);
        assertTrue(position.isActive);
        uint256 tgauxMinted = position.tgauxMinted;
        assertTrue(tgauxMinted > 0);

        // Add collateral
        usdc.approve(address(vault), 1000e6);
        vault.addCollateral(positionId, 1000e6);

        // Wait some time for interest to accrue
        vm.warp(block.timestamp + 5 days);

        // Close position
        tgaux.approve(address(vault), tgauxMinted);
        vault.closePosition(positionId);
        vm.stopPrank();

        // Verify position is closed
        position = vault.getPosition(positionId);
        assertFalse(position.isActive);
    }

    function test_MultiplePositions() public {
        // User1 opens position with USDC
        vm.startPrank(user1);
        usdc.approve(address(vault), 3000e6);
        uint256 positionId1 = vault.openPosition(3000e6, 1, address(usdc));
        vm.stopPrank();

        // User2 opens position with USDT
        vm.startPrank(user2);
        usdt.approve(address(vault), 4000e6);
        uint256 positionId2 = vault.openPosition(4000e6, 2, address(usdt));
        vm.stopPrank();

        // Check both positions exist
        VaultManager.Position memory pos1 = vault.getPosition(positionId1);
        VaultManager.Position memory pos2 = vault.getPosition(positionId2);

        assertEq(pos1.owner, user1);
        assertEq(pos2.owner, user2);
        assertTrue(pos1.isActive);
        assertTrue(pos2.isActive);
    }
}
