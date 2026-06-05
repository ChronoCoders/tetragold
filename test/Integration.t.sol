// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";

contract MockAavePool {
    function supply(address, uint256, address, uint16) external {}
    function withdraw(address, uint256 amount, address) external returns (uint256) { return amount; }
}

/**
 * @title Integration
 * @notice End-to-end tests covering complete protocol lifecycle scenarios.
 */
contract IntegrationTest is Test {
    // Protocol contracts
    TGAUX            public tgaux;
    VaultManager     public vault;
    LiquidityPool    public pool;
    LiquidationEngine public engine;
    OracleAggregator public oracle;
    InsuranceFund    public insurance;
    FeeDistributor   public distributor;

    // Tokens
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockERC20 public tgx;

    // Oracles
    MockChainlinkOracle public chainlink;
    MockBandOracle      public band;
    MockAPI3Oracle      public api3;

    // Actors
    address public admin     = makeAddr("admin");
    address public treasury  = makeAddr("treasury");
    address public user1     = makeAddr("user1");
    address public user2     = makeAddr("user2");
    address public liquidator = makeAddr("liquidator");
    address public staker    = makeAddr("staker");

    uint256 public constant GOLD_PRICE = 200_000_000_000; // $2,000 with 8 decimals

    function setUp() public {
        // Tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);
        tgx  = new MockERC20("TGX", "TGX", 18);

        // Oracles
        chainlink = new MockChainlinkOracle(8);
        band      = new MockBandOracle();
        api3      = new MockAPI3Oracle();
        chainlink.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        band.setReferenceData(GOLD_PRICE * 1e10);
        api3.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        vm.startPrank(admin);

        // Core contracts
        tgaux = new TGAUX(admin);
        oracle = new OracleAggregator(admin, address(chainlink), address(band), address(api3));
        oracle.updateTwap();

        pool = new LiquidityPool(address(usdc), address(usdt));
        vault = new VaultManager(admin, address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));

        MockAavePool aave = new MockAavePool();
        insurance = new InsuranceFund(admin, address(vault), address(pool), address(aave));
        distributor = new FeeDistributor(admin, address(tgx), address(insurance), treasury);
        engine = new LiquidationEngine(address(vault), address(insurance), treasury);

        // Role wiring
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vault));
        pool.grantRole(pool.VAULT_MANAGER_ROLE(), address(vault));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(engine));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), liquidator);
        vault.setFeeDistributor(address(distributor));
        // Admin retains FEE_COLLECTOR_ROLE (granted in VaultManager constructor)
        distributor.grantRole(distributor.VAULT_MANAGER_ROLE(), address(vault));
        distributor.addSupportedToken(address(usdc));
        distributor.addSupportedToken(address(usdt));
        insurance.grantRole(insurance.VAULT_MANAGER_ROLE(), address(distributor));
        insurance.grantRole(insurance.LIQUIDATION_ENGINE_ROLE(), address(engine));
        insurance.addSupportedToken(address(usdc));
        insurance.addSupportedToken(address(usdt));

        vm.stopPrank();

        // Fund accounts
        usdc.mint(user1, 100_000e6);
        usdc.mint(user2, 100_000e6);
        tgx.mint(staker, 10_000e18);

        // Seed LiquidityPool with deposits so borrow calls succeed
        address lp = makeAddr("lp");
        usdc.mint(lp, 2_000_000e6);
        usdt.mint(lp, 2_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(pool), 2_000_000e6);
        usdt.approve(address(pool), 2_000_000e6);
        pool.depositLP(1_000_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        pool.depositLP(1_000_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdt));
        pool.depositLP(1_000_000e6, LiquidityPool.PoolType.AGGRESSIVE, address(usdc));
        pool.depositLP(1_000_000e6, LiquidityPool.PoolType.AGGRESSIVE, address(usdt));
        vm.stopPrank();
    }

    // ============ Helpers ============

    function _updatePrice(uint256 newPrice) internal {
        chainlink.setLatestAnswer(SafeCast.toInt256(newPrice));
        band.setReferenceData(newPrice * 1e10);
        api3.setValue(SafeCast.toInt224(SafeCast.toInt256(newPrice * 1e10)));
        oracle.updateTwap();
    }

    function _makeLiquidatable(uint256 positionId) internal returns (bool) {
        // Ramp price up in 5% increments to avoid circuit breaker
        uint256 price = GOLD_PRICE;
        for (uint256 i = 0; i < 6; i++) {
            price = price * 105 / 100;
            _updatePrice(price);
        }
        return vault.isLiquidatable(positionId);
    }

    // ============ Full Position Lifecycle ============

    function test_FullLifecycle_OpenInterestClose() public {
        uint256 collateral = 5_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 2, address(usdc));
        vm.stopPrank();

        VaultManager.Position memory pos = vault.getPosition(positionId);
        assertTrue(pos.isActive);
        assertGt(tgaux.balanceOf(user1), 0);
        assertEq(vault.activePositionCount(), 1);

        // Time passes, interest accrues
        vm.warp(block.timestamp + 30 days);
        uint256 interest = vault.calculateInterest(positionId);
        assertGt(interest, 0);

        // Close position
        uint256 tgauxBal = tgaux.balanceOf(user1);
        vm.startPrank(user1);
        tgaux.approve(address(vault), tgauxBal);
        vault.closePosition(positionId);
        vm.stopPrank();

        assertFalse(vault.getPosition(positionId).isActive);
        assertEq(vault.activePositionCount(), 0);
        assertEq(tgaux.balanceOf(user1), 0);
    }

    function test_FullLifecycle_LiquidationViaEngine() public {
        uint256 collateral = 3_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));
        tgaux.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        assertTrue(_makeLiquidatable(positionId));
        assertEq(vault.activePositionCount(), 1);

        // Mark and wait grace period
        vm.prank(liquidator);
        engine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        uint256 insuranceBefore = usdc.balanceOf(address(insurance));

        vm.prank(liquidator);
        uint256 penalty = engine.liquidatePosition(positionId);

        assertGt(penalty, 0);
        // Insurance fund received its 30% share
        assertGt(usdc.balanceOf(address(insurance)), insuranceBefore);
        // Treasury received its 20% share
        assertGt(usdc.balanceOf(treasury), 0);
        // Liquidator has pending rewards
        assertGt(engine.pendingTokenRewards(liquidator, address(usdc)), 0);
    }

    function test_FullLifecycle_LiquidatorClaimsRewards() public {
        uint256 collateral = 3_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));
        tgaux.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        assertTrue(_makeLiquidatable(positionId));

        vm.prank(liquidator);
        engine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        vm.prank(liquidator);
        engine.liquidatePosition(positionId);

        uint256 pending = engine.pendingTokenRewards(liquidator, address(usdc));
        assertGt(pending, 0);

        uint256 balBefore = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        engine.claimRewards(address(usdc));

        assertEq(usdc.balanceOf(liquidator), balBefore + pending);
        assertEq(engine.pendingTokenRewards(liquidator, address(usdc)), 0);
    }

    // ============ Fee Distribution Lifecycle ============

    function test_FeeFlow_PushToDistributor_StakerClaims() public {
        // Staker stakes TGX
        vm.startPrank(staker);
        tgx.approve(address(distributor), 10_000e18);
        distributor.stake(10_000e18);
        vm.stopPrank();

        // Open and close a position to generate fees
        uint256 collateral = 3_000e6;
        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));
        uint256 tgauxBal = tgaux.balanceOf(user1);
        tgaux.approve(address(vault), tgauxBal);
        vault.closePosition(positionId);
        vm.stopPrank();

        uint256 fees = vault.collectedFees(address(usdc));
        assertGt(fees, 0);

        // Push fees through FeeDistributor (admin has FEE_COLLECTOR_ROLE)
        vm.prank(admin);
        vault.pushFeesToDistributor(address(usdc));
        assertEq(vault.collectedFees(address(usdc)), 0);

        // Staker earned rewards (30% of fees, subject to MasterChef integer division precision)
        uint256 pendingStaker = distributor.getPendingRewards(staker, address(usdc));
        uint256 expectedStakerShare = (fees * 3000) / 10000;
        assertApproxEqAbs(pendingStaker, expectedStakerShare, expectedStakerShare / 100 + 1); // within 1%

        // Insurance fund received 30%
        assertEq(usdc.balanceOf(address(insurance)), (fees * 3000) / 10000);

        // Treasury received 40%
        assertEq(usdc.balanceOf(treasury), (fees * 4000) / 10000);

        // Staker claims
        uint256 balBefore = usdc.balanceOf(staker);
        vm.prank(staker);
        distributor.claimRewards(address(usdc));
        assertEq(usdc.balanceOf(staker), balBefore + pendingStaker);
    }

    // ============ Multiple Positions + Pagination ============

    function test_ActivePositionCount_And_Pagination() public {
        // Open 3 positions
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(user1);
            usdc.approve(address(vault), 3_000e6);
            vault.openPosition(3_000e6, 1, address(usdc));
            vm.stopPrank();
        }

        assertEq(vault.activePositionCount(), 3);

        // Paginate
        (uint256[] memory page1, uint256 total) = vault.getActivePositionIds(0, 2);
        assertEq(total, 3);
        assertEq(page1.length, 2);

        (uint256[] memory page2, ) = vault.getActivePositionIds(2, 2);
        assertEq(page2.length, 1);

        // Close one, count drops
        uint256 id1 = page1[0];
        uint256 tgauxBal = tgaux.balanceOf(user1);
        vm.startPrank(user1);
        tgaux.approve(address(vault), tgauxBal);
        vault.closePosition(id1);
        vm.stopPrank();

        assertEq(vault.activePositionCount(), 2);
    }

    // ============ Insurance Fund Rebalance ============

    function test_InsuranceFund_Rebalance_AllTokens() public {
        // Deposit to insurance fund so there's something to rebalance
        usdc.mint(address(insurance), 10_000e6);
        vm.store(
            address(insurance),
            keccak256(abi.encode(address(usdc), uint256(10))), // reserves slot (approx)
            bytes32(uint256(10_000e6))
        );

        // Just verify rebalance() no longer reverts (previously called _rebalanceToken(address(0)))
        vm.prank(admin);
        // If token list is empty it's a no-op, but no revert
        insurance.rebalance();
    }

    function test_InsuranceFund_Rebalance_WithRegisteredTokens() public {
        // Register tokens, deposit reserves, then rebalance
        uint256 depositAmount = 10_000e6;
        usdc.mint(address(this), depositAmount);
        usdc.approve(address(insurance), depositAmount);

        // Cache role hash before setting prank to avoid staticcall consuming it
        bytes32 vmRole = insurance.VAULT_MANAGER_ROLE();
        vm.prank(admin);
        insurance.grantRole(vmRole, address(this));

        insurance.depositFromFees(depositAmount, address(usdc));
        assertEq(insurance.reserves(address(usdc)), depositAmount);

        // rebalance should not revert
        vm.prank(admin);
        insurance.rebalance();
    }

    // ============ Penalty Distribution Accounting ============

    function test_PenaltyDistribution_Percentages() public {
        uint256 collateral = 3_000e6;

        vm.startPrank(user1);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));
        tgaux.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        assertTrue(_makeLiquidatable(positionId));

        vm.prank(liquidator);
        engine.markForLiquidation(positionId);
        vm.warp(block.timestamp + 11 minutes);

        uint256 insuranceBefore = usdc.balanceOf(address(insurance));
        uint256 treasuryBefore  = usdc.balanceOf(treasury);

        vm.prank(liquidator);
        uint256 penalty = engine.liquidatePosition(positionId);
        assertGt(penalty, 0);

        uint256 liquidatorReward  = engine.pendingTokenRewards(liquidator, address(usdc));
        uint256 insuranceReceived = usdc.balanceOf(address(insurance)) - insuranceBefore;
        uint256 treasuryReceived  = usdc.balanceOf(treasury) - treasuryBefore;

        // 50/30/20 split
        assertEq(liquidatorReward,  (penalty * 5000) / 10000);
        assertEq(insuranceReceived, (penalty * 3000) / 10000);
        assertEq(treasuryReceived,  penalty - liquidatorReward - insuranceReceived);
    }
}
