// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
        uint256 indexed positionId, address indexed owner, uint256 collateral, uint256 leverage, uint256 tgauxMinted
    );
    event PositionClosed(uint256 indexed positionId, address indexed owner, uint256 returnAmount);
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event FeesCollected(uint256 amount, address indexed token);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 collateralSeized);

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
        oracle = new OracleAggregator(admin, address(chainlinkOracle), address(bandOracle), address(api3Oracle));

        // Initialize oracle with first price
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        // Deploy liquidity pool
        pool = new MockLiquidityPool();

        // Deploy VaultManager
        vm.prank(admin);
        vault = new VaultManager(admin, address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));

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
        new VaultManager(address(0), address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));
    }

    /* ============ Position Opening Tests ============ */

    function test_OpenPosition1xLeverage() public {
        // For 1x leverage with 150% CR: need $4500 to get $3000 worth of TGAUX
        uint256 collateral = 4500e6; // $4500 USDC
        uint256 leverage = 1;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);

        // Calculate expected TGAUX with 150% CR over-collateralization
        // effectiveCollateral = collateral - fee = 4500 - 4.5 = 4495.5
        // totalValue = effectiveCollateral / 1.5 = 4495.5 / 1.5 = 2997
        // expectedTgaux = (2997e6 * 1e20) / 2e11 = 1.4985e18
        uint256 effectiveCollateral = collateral - (collateral / 1000);
        uint256 totalValue = (effectiveCollateral * 10000) / 15000; // Divide by 1.5 for 150% CR
        uint256 expectedTgaux = (totalValue * 1e20) / GOLD_PRICE;
        uint256 expectedCollateral = effectiveCollateral;

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
        // Borrowed 1x effective (post-fee) collateral: 0.2% leverage fee
        uint256 effectiveCollateral = collateral - (collateral * 20) / BASIS_POINTS;
        assertEq(position.borrowedAmount, effectiveCollateral);
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
        // Borrowed 9x effective (post-fee) collateral: 0.2% leverage fee
        uint256 effectiveCollateral = collateral - (collateral * 20) / BASIS_POINTS;
        assertEq(position.borrowedAmount, effectiveCollateral * 9);
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
        // Extremely small amounts fail TGAUX minimum mint check first
        vm.expectRevert("TGAUX: amount below minimum");
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

    function test_ClosePositionWithMinReturnSucceeds() public {
        uint256 collateral = 3000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));

        uint256 tgauxBalance = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBalance);

        // Closing immediately: only the burn fee is deducted, so the return is
        // close to the post-open-fee collateral. A conservative floor passes.
        uint256 balanceBefore = usdc.balanceOf(user1);
        vault.closePosition(positionId, 2000e6);
        uint256 balanceAfter = usdc.balanceOf(user1);
        vm.stopPrank();

        assertFalse(vault.getPosition(positionId).isActive);
        assertGe(balanceAfter - balanceBefore, 2000e6);
    }

    function test_ClosePositionRevertsWhenReturnBelowMinimum() public {
        uint256 collateral = 3000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));

        uint256 tgauxBalance = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBalance);

        // Demand more than the full collateral back - must revert.
        vm.expectRevert("VaultManager: return below minimum");
        vault.closePosition(positionId, collateral + 1);
        vm.stopPrank();

        // Position remains active after the revert.
        assertTrue(vault.getPosition(positionId).isActive);
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
        assertEq(positionAfter.collateralAmount, positionBefore.collateralAmount + additionalCollateral);
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
        vm.warp(block.timestamp + 601);
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
        // For 150% CR to drop to 125%, need 20% price increase (150/125 = 1.2)
        // Use smaller increments to avoid circuit breaker (5% max per update)
        uint256 newPrice = GOLD_PRICE * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
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
        vm.stopPrank();

        // TGAUX stays with the position owner — liquidation burns from the owner
        // via vaultBurn, so the liquidator does not need to hold or approve TGAUX

        // Make position liquidatable with small increments to avoid circuit breaker
        // Need ~21.6% total increase for CR to drop from 150% to 125%
        uint256 newPrice = GOLD_PRICE * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 105 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        // Liquidate
        vm.startPrank(liquidator);

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
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        vm.startPrank(user2);
        vm.expectRevert();
        vault.liquidate(positionId);
        vm.stopPrank();
    }

    /// @dev Push gold price up in two 4% steps (~8.2% total), enough to drop a 2x
    ///      position's equity ratio below the 90% liquidation threshold without
    ///      tripping the 5% circuit breaker
    function _make2xLiquidatable() internal {
        uint256 newPrice = GOLD_PRICE * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        newPrice = newPrice * 104 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();
    }

    /// @dev C-01 regression: partial liquidation must repay the pool via repay(),
    ///      decrementing totalBorrowed, instead of a raw token transfer
    function test_LiquidatePositionRepaysPoolAccounting() public {
        uint256 collateral = 4000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        uint256 borrowedBefore = pool.totalBorrowed(address(usdc));
        assertEq(borrowedBefore, position.borrowedAmount);

        // Healthy at open; liquidatable only after an adverse price move
        assertFalse(vault.isLiquidatable(positionId));
        _make2xLiquidatable();
        assertTrue(vault.isLiquidatable(positionId));

        vm.prank(liquidator);
        vault.liquidatePosition(positionId, 2500);

        uint256 expectedRepay = (position.borrowedAmount * 2500) / BASIS_POINTS;
        assertEq(pool.totalBorrowed(address(usdc)), borrowedBefore - expectedRepay);
    }

    /// @dev Partial-path interest regression: a tranche must repay its
    ///      proportional share of accrued interest to the pool (the engine is
    ///      the production liquidation route; previously it passed interest=0,
    ///      so LPs collected nothing on engine-liquidated leveraged positions)
    function test_PartialLiquidationRepaysInterestToPool() public {
        uint256 collateral = 4000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);

        // Accrue enough interest that the position is liquidatable at the same
        // price (equity eroded below the 2x 90% margin purely by interest)
        vm.warp(block.timestamp + 220 days);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        oracle.updateTwap();
        assertTrue(vault.isLiquidatable(positionId));

        uint256 trancheInterest = (vault.calculateInterest(positionId) * 2500) / BASIS_POINTS;
        uint256 borrowedToRepay = (position.borrowedAmount * 2500) / BASIS_POINTS;
        assertGt(trancheInterest, 0);
        uint256 poolBalBefore = usdc.balanceOf(address(pool));
        uint256 borrowedBefore = pool.totalBorrowed(address(usdc));

        vm.prank(liquidator);
        vault.liquidatePosition(positionId, 2500);

        // Only principal decrements totalBorrowed; the pool actually received
        // principal PLUS this tranche's interest
        assertEq(pool.totalBorrowed(address(usdc)), borrowedBefore - borrowedToRepay);
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore + borrowedToRepay + trancheInterest);
    }

    /// @dev H-02 regression: liquidation burns TGAUX from the position owner via
    ///      vaultBurn — it must succeed even if the owner revoked all allowances
    function test_LiquidateSucceedsWithoutOwnerAllowance() public {
        uint256 collateral = 4000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        tgaux.approve(address(vault), 0); // owner revokes allowance
        vm.stopPrank();

        uint256 ownerTgauxBefore = tgaux.balanceOf(user1);
        _make2xLiquidatable();
        assertTrue(vault.isLiquidatable(positionId));

        vm.prank(liquidator);
        vault.liquidatePosition(positionId, 2500);

        // 25% of the owner's TGAUX was burned despite zero allowance
        VaultManager.Position memory position = vault.getPosition(positionId);
        assertEq(tgaux.balanceOf(user1), ownerTgauxBefore - (ownerTgauxBefore * 2500) / BASIS_POINTS);
        assertTrue(position.isActive);
    }

    /// @dev liquidate() distribution regression: remaining collateral (after
    ///      interest + penalty) goes to the position owner, not the liquidator;
    ///      the penalty accrues to protocol fees
    function test_LiquidateReturnsRemainderToOwner() public {
        uint256 collateral = 4000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        _make2xLiquidatable();

        uint256 interest = vault.calculateInterest(positionId);
        uint256 ownerBefore = usdc.balanceOf(user1);
        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        uint256 feesBefore = vault.collectedFees(address(usdc));
        uint256 poolBorrowedBefore = pool.totalBorrowed(address(usdc));

        vm.prank(liquidator);
        vault.liquidate(positionId);

        uint256 remaining = position.collateralAmount - interest;
        uint256 penalty = (remaining * 500) / BASIS_POINTS; // 2x penalty rate = 5%

        // Owner receives the residual equity; liquidator receives nothing
        assertEq(usdc.balanceOf(user1), ownerBefore + remaining - penalty);
        assertEq(usdc.balanceOf(liquidator), liquidatorBefore);
        // Penalty accrued as protocol fees
        assertEq(vault.collectedFees(address(usdc)), feesBefore + penalty);
        // Pool principal fully repaid
        assertEq(pool.totalBorrowed(address(usdc)), poolBorrowedBefore - position.borrowedAmount);
        assertFalse(vault.getPosition(positionId).isActive);
    }

    /// @dev Bad-debt cap regression: when accrued interest exceeds the position's
    ///      collateral, liquidation must still succeed — interest paid to the pool
    ///      is capped at the collateral and the shortfall is surfaced as bad debt,
    ///      instead of reverting or draining other positions' funds
    function test_LiquidateCapsInterestAtCollateralAndRealizesBadDebt() public {
        uint256 collateral = 12_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 10, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);

        // 10x: borrowed = 9x effective collateral; at 0.05%/day the interest
        // overtakes the collateral after ~222 days
        vm.warp(block.timestamp + 300 days);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        oracle.updateTwap();

        uint256 interest = vault.calculateInterest(positionId);
        assertGt(interest, position.collateralAmount);
        assertTrue(vault.isLiquidatable(positionId));

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 poolBalBefore = usdc.balanceOf(address(pool));
        uint256 ownerBefore = usdc.balanceOf(user1);

        vm.expectEmit(true, true, false, true);
        emit VaultManager.BadDebtRealized(positionId, address(usdc), interest - position.collateralAmount);

        vm.prank(liquidator);
        vault.liquidate(positionId);

        // Pool received principal plus interest capped at the collateral
        assertEq(usdc.balanceOf(address(pool)), poolBalBefore + position.borrowedAmount + position.collateralAmount);
        // Vault paid out exactly what the position held — nothing else drained
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - position.borrowedAmount - position.collateralAmount);
        // Owner gets nothing; principal record fully cleared
        assertEq(usdc.balanceOf(user1), ownerBefore);
        assertEq(pool.totalBorrowed(address(usdc)), 0);
        assertFalse(vault.getPosition(positionId).isActive);
    }

    /// @dev Same cap on the voluntary close path: an owner closing a position
    ///      whose interest exceeds its collateral gets nothing back, but the
    ///      vault never pays the pool more than the position holds
    function test_ClosePositionCapsInterestAtCollateral() public {
        uint256 collateral = 12_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 10, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);

        vm.warp(block.timestamp + 300 days);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        oracle.updateTwap();

        uint256 interest = vault.calculateInterest(positionId);
        assertGt(interest, position.collateralAmount);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 ownerBefore = usdc.balanceOf(user1);
        uint256 burnFee = (position.collateralAmount * 15) / BASIS_POINTS;

        vm.startPrank(user1);
        tgaux.approve(address(vault), position.tgauxMinted);
        vault.closePosition(positionId);
        vm.stopPrank();

        // Vault outflow = principal + (collateral - burnFee); burn fee stays as fees
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBefore - position.borrowedAmount - (position.collateralAmount - burnFee)
        );
        // Owner receives nothing back
        assertEq(usdc.balanceOf(user1), ownerBefore);
        assertEq(pool.totalBorrowed(address(usdc)), 0);
        assertFalse(vault.getPosition(positionId).isActive);
    }

    /// @dev addCollateral regression: adding collateral must not reset the
    ///      interest clock (previously wiped all accrued interest)
    function test_AddCollateralDoesNotResetInterest() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 5000e6);
        uint256 positionId = vault.openPosition(4000e6, 2, address(usdc));

        vm.warp(block.timestamp + 5 days);
        uint256 interestBefore = vault.calculateInterest(positionId);
        assertGt(interestBefore, 0);

        vault.addCollateral(positionId, 1000e6);

        // Accrued interest survives the collateral top-up
        assertEq(vault.calculateInterest(positionId), interestBefore);
        vm.stopPrank();
    }

    /// @dev Leveraged health ratio regression: a freshly opened leveraged position
    ///      must be healthy (equity/borrowed at the tier's open ratio), not
    ///      instantly liquidatable as under the old collateral/notional formula
    function test_LeveragedPositionHealthyAtOpen() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 4000e6);
        uint256 positionId2x = vault.openPosition(4000e6, 2, address(usdc));
        usdc.approve(address(vault), 12000e6);
        uint256 positionId10x = vault.openPosition(12000e6, 10, address(usdc));
        vm.stopPrank();

        // 2x opens at ~100% equity/borrowed (vs 90% liquidation threshold)
        assertFalse(vault.isLiquidatable(positionId2x));
        assertApproxEqAbs(vault.getPositionHealth(positionId2x), 10000, 5);

        // 10x opens at ~11.1% equity/borrowed (vs 10% liquidation threshold)
        assertFalse(vault.isLiquidatable(positionId10x));
        assertApproxEqAbs(vault.getPositionHealth(positionId10x), 1111, 5);
    }

    /// @dev Equity ratio falls as gold rises: ~1% adverse move liquidates 10x
    ///      while 2x stays healthy
    function test_LeveragedHealthDropsWithAdversePriceMove() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 4000e6);
        uint256 positionId2x = vault.openPosition(4000e6, 2, address(usdc));
        usdc.approve(address(vault), 12000e6);
        uint256 positionId10x = vault.openPosition(12000e6, 10, address(usdc));
        vm.stopPrank();

        // 2% gold rise: 10x equity ratio drops below its 10% threshold,
        // 2x (90% threshold, ~96% ratio after the move) stays healthy
        uint256 newPrice = GOLD_PRICE * 102 / 100;
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(newPrice));
        bandOracle.setReferenceData(newPrice * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        assertFalse(vault.isLiquidatable(positionId2x));
        assertTrue(vault.isLiquidatable(positionId10x));
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

        // Re-seed mock feeds and refresh oracle so the price is not stale after the warp
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        oracle.updateTwap();

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

    /* ============ Fuzz Tests ============ */

    /// @dev openPosition arithmetic must hold for any collateral and leverage tier:
    ///      borrow = effective * (L-1), TGAUX = effective * L at oracle price,
    ///      fee accounting and TVL all consistent
    function testFuzz_OpenPositionArithmetic(uint256 collateral, uint8 leverageSeed) public {
        uint256[4] memory tiers = [uint256(2), 3, 5, 10];
        uint256 leverage = tiers[leverageSeed % 4];
        collateral = bound(collateral, 100e6, 10_000e6);

        uint256 feesBefore = vault.collectedFees(address(usdc));
        uint256 tvlBefore = vault.totalValueLocked();

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        uint256 fee = (collateral * 20) / BASIS_POINTS;
        uint256 effective = collateral - fee;

        assertEq(position.collateralAmount, effective);
        assertEq(position.borrowedAmount, effective * (leverage - 1));
        assertEq(position.tgauxMinted, (effective * leverage * 1e20) / GOLD_PRICE);
        assertEq(vault.collectedFees(address(usdc)), feesBefore + fee);
        assertEq(vault.totalValueLocked(), tvlBefore + effective);
        assertEq(pool.totalBorrowed(address(usdc)), effective * (leverage - 1));

        // Health at open matches the tier's minimum CR (within rounding)
        uint256 expectedRatio = BASIS_POINTS / (leverage - 1);
        assertApproxEqAbs(vault.getPositionHealth(positionId), expectedRatio, 5);
        assertFalse(vault.isLiquidatable(positionId));
    }

    /// @dev Interest accrual must be linear in time and principal with no
    ///      rounding surprises across durations
    function testFuzz_InterestAccrual(uint256 daysElapsed, uint256 collateral) public {
        daysElapsed = bound(daysElapsed, 1, 365);
        collateral = bound(collateral, 100e6, 10_000e6);

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory position = vault.getPosition(positionId);
        vm.warp(block.timestamp + daysElapsed * 1 days);

        uint256 expected = (position.borrowedAmount * 5 * daysElapsed * 86400) / (BASIS_POINTS * 86400);
        assertEq(vault.calculateInterest(positionId), expected);
    }

    /// @dev Open + immediate close must round-trip: user pays exactly the open
    ///      and burn fees, the pool is fully repaid, and the vault keeps only fees
    function testFuzz_OpenCloseRoundtrip(uint256 collateral, uint8 leverageSeed) public {
        uint256[4] memory tiers = [uint256(2), 3, 5, 10];
        uint256 leverage = tiers[leverageSeed % 4];
        collateral = bound(collateral, 100e6, 10_000e6);

        uint256 balanceBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, leverage, address(usdc));

        tgaux.approve(address(vault), type(uint256).max);
        vault.closePosition(positionId);
        vm.stopPrank();

        uint256 openFee = (collateral * 20) / BASIS_POINTS;
        uint256 effective = collateral - openFee;
        uint256 burnFee = (effective * 15) / BASIS_POINTS;

        // User paid exactly openFee + burnFee (no interest in same block)
        assertEq(usdc.balanceOf(user1), balanceBefore - openFee - burnFee);
        // Pool fully repaid
        assertEq(pool.totalBorrowed(address(usdc)), 0);
        // All user TGAUX burned
        assertEq(tgaux.balanceOf(user1), 0);
        assertEq(vault.totalValueLocked(), 0);
    }
}
