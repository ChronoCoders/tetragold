// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TGX} from "../src/TGX.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {TGXEmissions} from "../src/TGXEmissions.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeploySmokeTest
 * @notice End-to-end smoke test for script/Deploy.s.sol. It deploys mock
 *         dependencies, runs the real deployment script against them, asserts
 *         the deployed wiring, then applies the printed post-deploy
 *         configuration and proves the protocol actually opens and closes a
 *         position. Guards the deployment path against constructor / wiring
 *         regressions that unit tests on individual contracts would not catch.
 */
contract DeploySmokeTest is Test {
    uint256 internal constant DEPLOYER_KEY = 0xA11CE;
    uint256 internal constant GOLD_PRICE = 200000000000; // $2000, 8 decimals

    Deploy internal deployer;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");

    MockERC20 internal usdc;
    MockERC20 internal usdt;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        MockChainlinkOracle chainlink = new MockChainlinkOracle(8);
        MockBandOracle band = new MockBandOracle();
        MockAPI3Oracle api3 = new MockAPI3Oracle();
        chainlink.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        band.setReferenceData(GOLD_PRICE * 1e10);
        api3.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));
        MockAavePool aave = new MockAavePool();

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_KEY)));
        vm.setEnv("ADMIN", vm.toString(admin));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("USDC", vm.toString(address(usdc)));
        vm.setEnv("USDT", vm.toString(address(usdt)));
        vm.setEnv("CHAINLINK_XAU_USD", vm.toString(address(chainlink)));
        vm.setEnv("BAND_ORACLE", vm.toString(address(band)));
        vm.setEnv("API3_ORACLE", vm.toString(address(api3)));
        vm.setEnv("AAVE_POOL", vm.toString(address(aave)));

        deployer = new Deploy();
        deployer.run();
    }

    function test_DeploySucceedsAndContractsWired() public view {
        assertTrue(address(deployer.tgaux()) != address(0));
        assertTrue(address(deployer.tgx()) != address(0));
        assertTrue(address(deployer.oracle()) != address(0));
        assertTrue(address(deployer.liquidityPool()) != address(0));
        assertTrue(address(deployer.tgxVesting()) != address(0));
        assertTrue(address(deployer.tgxEmissions()) != address(0));
        assertTrue(address(deployer.vaultManager()) != address(0));
        assertTrue(address(deployer.insuranceFund()) != address(0));
        assertTrue(address(deployer.feeDistributor()) != address(0));
        assertTrue(address(deployer.liquidationEngine()) != address(0));
        assertTrue(address(deployer.timelock()) != address(0));

        // TGX genesis: full 100M minted to treasury.
        TGX tgx = deployer.tgx();
        assertEq(tgx.totalSupply(), tgx.MAX_SUPPLY());
        assertEq(tgx.balanceOf(treasury), tgx.MAX_SUPPLY());

        // FeeDistributor wired to the freshly deployed TGX, not an external one.
        assertEq(deployer.feeDistributor().tgxToken(), address(tgx));

        // Admin holds DEFAULT_ADMIN_ROLE on the core contracts.
        VaultManager vault = deployer.vaultManager();
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));

        // Emissions pools point at the LiquidityPool's own LP tokens.
        TGXEmissions emissions = deployer.tgxEmissions();
        (IERC20 stakeC,,,,) = emissions.pools(0);
        (IERC20 stakeA,,,,) = emissions.pools(1);
        assertEq(address(stakeC), deployer.lpConservative());
        assertEq(address(stakeA), deployer.lpAggressive());
    }

    function test_ProtocolFunctionalAfterPostDeployConfig() public {
        _applyPendingConfig();

        // Seed the oracle TWAP and open/close a 1x position end to end.
        deployer.oracle().updateTwap();

        VaultManager vault = deployer.vaultManager();
        TGAUX tgaux = deployer.tgaux();

        uint256 collateral = 4500e6;
        usdc.mint(user, collateral);

        vm.startPrank(user);
        usdc.approve(address(vault), collateral);
        uint256 positionId = vault.openPosition(collateral, 1, address(usdc));
        assertGt(tgaux.balanceOf(user), 0);

        tgaux.approve(address(vault), type(uint256).max);
        uint256 balBefore = usdc.balanceOf(user);
        vault.closePosition(positionId);
        vm.stopPrank();

        assertEq(tgaux.balanceOf(user), 0);
        assertGt(usdc.balanceOf(user), balBefore);
    }

    /// @dev Mirrors the "PENDING ROLE CONFIGURATION" block printed by Deploy.run().
    function _applyPendingConfig() internal {
        TGAUX tgaux = deployer.tgaux();
        VaultManager vault = deployer.vaultManager();
        LiquidityPool pool = deployer.liquidityPool();
        InsuranceFund fund = deployer.insuranceFund();
        FeeDistributor dist = deployer.feeDistributor();
        LiquidationEngine engine = deployer.liquidationEngine();

        vm.startPrank(admin);
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vault));
        pool.grantRole(pool.VAULT_MANAGER_ROLE(), address(vault));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(engine));
        vault.grantRole(vault.FEE_COLLECTOR_ROLE(), address(vault));
        dist.grantRole(dist.VAULT_MANAGER_ROLE(), address(vault));
        vault.setFeeDistributor(address(dist));
        dist.addSupportedToken(address(usdc));
        dist.addSupportedToken(address(usdt));
        fund.grantRole(fund.VAULT_MANAGER_ROLE(), address(dist));
        fund.grantRole(fund.LIQUIDATION_ENGINE_ROLE(), address(engine));
        fund.addSupportedToken(address(usdc));
        fund.addSupportedToken(address(usdt));
        vm.stopPrank();
    }
}
