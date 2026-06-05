// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";

/**
 * @title Deploy
 * @notice Full protocol deployment for testnet and mainnet.
 *
 * Required environment variables:
 *   DEPLOYER_PRIVATE_KEY  - deployer account
 *   ADMIN                 - multisig that receives all admin roles
 *   TREASURY              - address that receives treasury fee share
 *   USDC                  - USDC token address on target network
 *   USDT                  - USDT token address on target network
 *   TGX                   - TGX governance token address
 *   CHAINLINK_XAU_USD     - Chainlink XAU/USD AggregatorV3 address
 *   BAND_ORACLE           - Band Protocol StdReference address
 *   API3_ORACLE           - API3 dAPI proxy address for XAU/USD
 *   AAVE_POOL             - Aave v3 Pool address
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    struct Addresses {
        address admin;
        address treasury;
        address usdc;
        address usdt;
        address tgx;
        address chainlink;
        address band;
        address api3;
        address aavePool;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        Addresses memory env = Addresses({
            admin:    vm.envAddress("ADMIN"),
            treasury: vm.envAddress("TREASURY"),
            usdc:     vm.envAddress("USDC"),
            usdt:     vm.envAddress("USDT"),
            tgx:      vm.envAddress("TGX"),
            chainlink: vm.envAddress("CHAINLINK_XAU_USD"),
            band:     vm.envAddress("BAND_ORACLE"),
            api3:     vm.envAddress("API3_ORACLE"),
            aavePool: vm.envAddress("AAVE_POOL")
        });

        _validate(env);

        vm.startBroadcast(deployerKey);

        console.log("=== TETRA GOLD DEPLOYMENT ===");
        console.log("Admin:   ", env.admin);
        console.log("Treasury:", env.treasury);
        console.log("");

        // 1. TGAUX token
        TGAUX tgaux = new TGAUX(env.admin);
        console.log("TGAUX:              ", address(tgaux));

        // 2. Oracle aggregator
        OracleAggregator oracle = new OracleAggregator(
            env.admin, env.chainlink, env.band, env.api3
        );
        console.log("OracleAggregator:   ", address(oracle));

        // 3. Liquidity pool
        LiquidityPool liquidityPool = new LiquidityPool(env.usdc, env.usdt);
        console.log("LiquidityPool:      ", address(liquidityPool));

        // 4. VaultManager
        VaultManager vaultManager = new VaultManager(
            env.admin, address(tgaux), address(oracle),
            address(liquidityPool), env.usdc, env.usdt
        );
        console.log("VaultManager:       ", address(vaultManager));

        // 5. InsuranceFund
        InsuranceFund insuranceFund = new InsuranceFund(
            env.admin, address(vaultManager), address(liquidityPool), env.aavePool
        );
        console.log("InsuranceFund:      ", address(insuranceFund));

        // 6. FeeDistributor
        FeeDistributor feeDistributor = new FeeDistributor(
            env.admin, env.tgx, address(insuranceFund), env.treasury
        );
        console.log("FeeDistributor:     ", address(feeDistributor));

        // 7. LiquidationEngine
        LiquidationEngine liquidationEngine = new LiquidationEngine(
            address(vaultManager), address(insuranceFund), env.treasury
        );
        console.log("LiquidationEngine:  ", address(liquidationEngine));

        vm.stopBroadcast();

        // Role setup must be executed by the admin multisig after deployment.
        // Run VerifyDeploy.s.sol to confirm all roles are correctly configured.
        console.log("");
        console.log("=== PENDING ROLE CONFIGURATION (run as admin) ===");
        console.log("tgaux.grantRole(MINTER_ROLE, vaultManager)");
        console.log("liquidityPool.grantRole(VAULT_MANAGER_ROLE, vaultManager)");
        console.log("vaultManager.grantRole(LIQUIDATOR_ROLE, liquidationEngine)");
        console.log("vaultManager.setFeeDistributor(feeDistributor)");
        console.log("vaultManager.grantRole(FEE_COLLECTOR_ROLE, vaultManager)");
        console.log("feeDistributor.grantRole(VAULT_MANAGER_ROLE, vaultManager)");
        console.log("feeDistributor.addSupportedToken(usdc)");
        console.log("feeDistributor.addSupportedToken(usdt)");
        console.log("insuranceFund.grantRole(VAULT_MANAGER_ROLE, feeDistributor)");
        console.log("insuranceFund.grantRole(LIQUIDATION_ENGINE_ROLE, liquidationEngine)");
        console.log("insuranceFund.addSupportedToken(usdc)");
        console.log("insuranceFund.addSupportedToken(usdt)");
        console.log("oracle.updateTwap()  // seed initial price");
    }

    function _validate(Addresses memory env) internal pure {
        require(env.admin    != address(0), "Deploy: ADMIN not set");
        require(env.treasury != address(0), "Deploy: TREASURY not set");
        require(env.usdc     != address(0), "Deploy: USDC not set");
        require(env.usdt     != address(0), "Deploy: USDT not set");
        require(env.tgx      != address(0), "Deploy: TGX not set");
        require(env.chainlink != address(0), "Deploy: CHAINLINK_XAU_USD not set");
        require(env.band     != address(0), "Deploy: BAND_ORACLE not set");
        require(env.api3     != address(0), "Deploy: API3_ORACLE not set");
        require(env.aavePool != address(0), "Deploy: AAVE_POOL not set");
    }
}
