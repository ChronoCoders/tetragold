// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {TGX} from "../src/TGX.sol";
import {TGXVesting} from "../src/TGXVesting.sol";
import {TGXEmissions} from "../src/TGXEmissions.sol";
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

    function withdraw(address, uint256 amount, address) external pure returns (uint256) {
        return amount;
    }
}

/**
 * @title IncentiveLoopE2E
 * @notice End-to-end coverage of the full TGX incentive loop:
 *         LP deposit -> stake LP -> earn TGX emissions -> stake TGX -> earn protocol fees.
 *         Mirrors script/DeployLocal.s.sol wiring (core 7 + TGX trio, emissions funded 65M)
 *         and asserts the exact values verified on anvil, so future drift in the emission
 *         rate, allocation points, or fee split breaks the test.
 */
contract IncentiveLoopE2ETest is Test {
    TGAUX tgaux;
    TGX tgx;
    TGXVesting vesting;
    TGXEmissions emissions;
    VaultManager vault;
    LiquidityPool pool;
    LiquidationEngine engine;
    OracleAggregator oracle;
    InsuranceFund insurance;
    FeeDistributor distributor;

    MockERC20 usdc;
    MockERC20 usdt;
    MockChainlinkOracle chainlink;
    MockBandOracle band;
    MockAPI3Oracle api3;

    address lpC;
    address lpA;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    uint256 constant GOLD_PRICE = 200_000_000_000; // $2,000, 8 decimals
    uint256 constant EMISSIONS_SUPPLY = 65_000_000e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        chainlink = new MockChainlinkOracle(8);
        band = new MockBandOracle();
        api3 = new MockAPI3Oracle();
        chainlink.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        band.setReferenceData(GOLD_PRICE * 1e10);
        api3.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        vm.startPrank(admin);

        tgaux = new TGAUX(admin);
        tgx = new TGX(admin, treasury);
        oracle = new OracleAggregator(admin, address(chainlink), address(band), address(api3));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        pool = new LiquidityPool(admin, address(usdc), address(usdt));
        (,,, lpC,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        (,,, lpA,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);

        vault = new VaultManager(admin, address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));

        MockAavePool aave = new MockAavePool();
        insurance = new InsuranceFund(admin, address(vault), address(pool), address(aave));
        distributor = new FeeDistributor(admin, address(tgx), address(insurance), treasury);
        engine = new LiquidationEngine(admin, address(vault), address(insurance), treasury);

        vesting = new TGXVesting(admin, address(tgx));
        emissions = new TGXEmissions(admin, address(tgx), lpC, lpA);

        // Role wiring (mirror DeployLocal)
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vault));
        pool.grantRole(pool.VAULT_MANAGER_ROLE(), address(vault));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(engine));
        vault.setFeeDistributor(address(distributor));
        distributor.grantRole(distributor.VAULT_MANAGER_ROLE(), address(vault));
        distributor.addSupportedToken(address(usdc));
        distributor.addSupportedToken(address(usdt));
        insurance.grantRole(insurance.VAULT_MANAGER_ROLE(), address(distributor));
        insurance.grantRole(insurance.LIQUIDATION_ENGINE_ROLE(), address(engine));
        insurance.addSupportedToken(address(usdc));
        insurance.addSupportedToken(address(usdt));

        vm.stopPrank();

        // Fund the emissions reward pool from the genesis TGX supply
        vm.prank(treasury);
        tgx.transfer(address(emissions), EMISSIONS_SUPPLY);

        usdc.mint(user, 300_000e6);
    }

    function test_FullIncentiveLoop() public {
        // Deploy fidelity: TGX trio present, emissions reward pool funded with 65M
        assertTrue(address(vesting) != address(0), "TGXVesting deployed");
        assertEq(tgx.balanceOf(address(emissions)), EMISSIONS_SUPPLY, "emissions funded 65M TGX");

        // 1. Deposit 200,000 USDC into the Conservative pool (LP mints 1:1 on first deposit)
        vm.startPrank(user);
        usdc.approve(address(pool), 200_000e6);
        uint256 lpReceived = pool.depositLP(200_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        vm.stopPrank();
        assertEq(lpReceived, 200_000e6, "received 200k TGLP-C");
        assertEq(IERC20(lpC).balanceOf(user), 200_000e6, "user holds 200k TGLP-C");

        // 2. Stake the TGLP-C in TGXEmissions pool 0
        vm.startPrank(user);
        IERC20(lpC).approve(address(emissions), lpReceived);
        emissions.stake(0, lpReceived);
        vm.stopPrank();
        (uint256 stakedAmt,) = emissions.userInfo(0, user);
        assertEq(stakedAmt, 200_000e6, "LP staked in emissions pool 0");

        // 3. Advance one day; pending TGX == Year-1 pool-0 emission (80% of the daily rate)
        vm.warp(block.timestamp + 1 days);
        uint256 pending = emissions.pendingTGX(0, user);
        uint256 expectedDaily = emissions.YEAR1_RATE() * 1 days * 80 / 100;
        assertEq(pending, expectedDaily, "pending == year1 pool0 daily emission");
        assertApproxEqAbs(pending, 54_795e18, 1e18, "~54,795 TGX/day to pool 0");

        // 4. Claim TGX
        uint256 tgxBefore = tgx.balanceOf(user);
        vm.prank(user);
        emissions.claim(0);
        assertEq(tgx.balanceOf(user) - tgxBefore, pending, "claimed exactly the pending TGX");

        // 5. Stake 1,000 of the claimed TGX in FeeDistributor
        vm.startPrank(user);
        tgx.approve(address(distributor), 1_000e18);
        distributor.stake(1_000e18);
        vm.stopPrank();
        assertEq(distributor.totalStakedTGX(), 1_000e18, "1,000 TGX staked for fee share");

        // 6. Refresh the oracle after the time jump, then open a 2x position (10,000 USDC)
        chainlink.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        band.setReferenceData(GOLD_PRICE * 1e10);
        api3.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        vm.warp(block.timestamp + 61);
        oracle.updateTwap();

        uint256 feesBefore = vault.collectedFees(address(usdc));
        vm.startPrank(user);
        usdc.approve(address(vault), 10_000e6);
        vault.openPosition(10_000e6, 2, address(usdc));
        vm.stopPrank();
        assertEq(vault.collectedFees(address(usdc)) - feesBefore, 20e6, "0.2% open fee on 10k = 20 USDC");

        // 7. Push the fee to the FeeDistributor; the staker reward index advances
        vm.prank(admin);
        vault.pushFeesToDistributor(address(usdc));
        assertGt(distributor.accRewardPerShare(address(usdc)), 0, "staker reward index advanced");

        // 8. Claim the fee reward; the sole TGX staker gets 30% of 20 = 6 USDC
        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        distributor.claimRewards(address(usdc));
        assertEq(usdc.balanceOf(user) - usdcBefore, 6e6, "staker receives 30% fee share = 6 USDC");
    }
}
