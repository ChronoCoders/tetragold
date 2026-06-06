// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";

/**
 * @title VerifyDeploy
 * @notice Reads all deployed contracts and confirms every role and address
 *         configuration is correct. Logs PASS/FAIL for each check.
 *
 * Required environment variables (deployed contract addresses):
 *   TGAUX, VAULT_MANAGER, LIQUIDITY_POOL, ORACLE_AGGREGATOR,
 *   INSURANCE_FUND, FEE_DISTRIBUTOR, LIQUIDATION_ENGINE,
 *   ADMIN, USDC, USDT
 *
 * Usage (read-only, no broadcast needed):
 *   forge script script/VerifyDeploy.s.sol --rpc-url $RPC_URL
 */
contract VerifyDeploy is Script {
    uint256 private _passed;
    uint256 private _failed;

    address private tgauxAddr;
    address private vaultManagerAddr;
    address private liquidityPoolAddr;
    address private oracleAddr;
    address private insuranceFundAddr;
    address private feeDistributorAddr;
    address private liquidationEngineAddr;
    address private admin;
    address private usdc;
    address private usdt;

    function run() external {
        tgauxAddr = vm.envAddress("TGAUX");
        vaultManagerAddr = vm.envAddress("VAULT_MANAGER");
        liquidityPoolAddr = vm.envAddress("LIQUIDITY_POOL");
        oracleAddr = vm.envAddress("ORACLE_AGGREGATOR");
        insuranceFundAddr = vm.envAddress("INSURANCE_FUND");
        feeDistributorAddr = vm.envAddress("FEE_DISTRIBUTOR");
        liquidationEngineAddr = vm.envAddress("LIQUIDATION_ENGINE");
        admin = vm.envAddress("ADMIN");
        usdc = vm.envAddress("USDC");
        usdt = vm.envAddress("USDT");

        console.log("=== TETRA GOLD DEPLOYMENT VERIFICATION ===");
        console.log("");

        _verifyTGAUX();
        _verifyVaultManager();
        _verifyLiquidityPool();
        _verifyInsuranceFund();
        _verifyFeeDistributor();
        _verifyOracle();
        _verifyLiquidationEngine();

        console.log("");
        console.log("Results: passed =", _passed, "failed =", _failed);
        if (_failed == 0) {
            console.log("ALL CHECKS PASSED");
        } else {
            console.log("SOME CHECKS FAILED - review output above");
        }
    }

    function _verifyTGAUX() internal {
        console.log("[TGAUX]");
        TGAUX tgaux = TGAUX(tgauxAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", tgaux.hasRole(tgaux.DEFAULT_ADMIN_ROLE(), admin));
        _check("VaultManager has MINTER_ROLE", tgaux.hasRole(tgaux.MINTER_ROLE(), vaultManagerAddr));
    }

    function _verifyVaultManager() internal {
        console.log("[VaultManager]");
        VaultManager vault = VaultManager(vaultManagerAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        _check("LiquidationEngine has LIQUIDATOR_ROLE", vault.hasRole(vault.LIQUIDATOR_ROLE(), liquidationEngineAddr));
        _check("feeDistributor set", vault.feeDistributor() == feeDistributorAddr);
        _check("tgaux address correct", address(vault.tgaux()) == tgauxAddr);
        _check("oracle address correct", address(vault.oracle()) == oracleAddr);
        _check("liquidityPool address correct", vault.liquidityPool() == liquidityPoolAddr);
    }

    function _verifyLiquidityPool() internal {
        console.log("[LiquidityPool]");
        LiquidityPool lp = LiquidityPool(liquidityPoolAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", lp.hasRole(lp.DEFAULT_ADMIN_ROLE(), admin));
        _check("VaultManager has VAULT_MANAGER_ROLE", lp.hasRole(lp.VAULT_MANAGER_ROLE(), vaultManagerAddr));
    }

    function _verifyInsuranceFund() internal {
        console.log("[InsuranceFund]");
        InsuranceFund ins = InsuranceFund(insuranceFundAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", ins.hasRole(ins.DEFAULT_ADMIN_ROLE(), admin));
        _check("FeeDistributor has VAULT_MANAGER_ROLE", ins.hasRole(ins.VAULT_MANAGER_ROLE(), feeDistributorAddr));
        _check(
            "LiquidationEngine has LIQUIDATION_ENGINE_ROLE",
            ins.hasRole(ins.LIQUIDATION_ENGINE_ROLE(), liquidationEngineAddr)
        );
        _check("USDC token registered", ins.tokenDecimals(usdc) > 0);
        _check("USDT token registered", ins.tokenDecimals(usdt) > 0);
        _check("vaultManager address correct", ins.vaultManager() == vaultManagerAddr);
    }

    function _verifyFeeDistributor() internal {
        console.log("[FeeDistributor]");
        FeeDistributor dist = FeeDistributor(feeDistributorAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", dist.hasRole(dist.DEFAULT_ADMIN_ROLE(), admin));
        _check("VaultManager has VAULT_MANAGER_ROLE", dist.hasRole(dist.VAULT_MANAGER_ROLE(), vaultManagerAddr));
        _check("USDC supported", dist.isSupported(usdc));
        _check("USDT supported", dist.isSupported(usdt));
    }

    function _verifyOracle() internal {
        console.log("[OracleAggregator]");
        OracleAggregator ora = OracleAggregator(oracleAddr);
        _check("admin has DEFAULT_ADMIN_ROLE", ora.hasRole(ora.DEFAULT_ADMIN_ROLE(), admin));
        _check("lastPrice seeded (updateTwap called)", ora.lastPrice() > 0);
    }

    function _verifyLiquidationEngine() internal {
        console.log("[LiquidationEngine]");
        LiquidationEngine eng = LiquidationEngine(liquidationEngineAddr);
        _check("vaultManager address correct", eng.vaultManager() == vaultManagerAddr);
        _check("insuranceFund address correct", eng.insuranceFund() == insuranceFundAddr);
    }

    function _check(string memory label, bool condition) internal {
        if (condition) {
            console.log("  PASS", label);
            _passed++;
        } else {
            console.log("  FAIL", label);
            _failed++;
        }
    }
}
