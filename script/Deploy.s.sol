// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {TGX} from "../src/TGX.sol";
import {TGXVesting} from "../src/TGXVesting.sol";
import {TGXEmissions} from "../src/TGXEmissions.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Deploy
 * @notice Full protocol deployment for testnet and mainnet, including the TGX
 *         governance/reward token ecosystem (TGX, TGXVesting, TGXEmissions).
 *
 * Required environment variables:
 *   DEPLOYER_PRIVATE_KEY  - deployer account
 *   ADMIN                 - multisig that receives all admin roles
 *   TREASURY              - address that receives the 100M TGX genesis mint
 *                           and the protocol treasury fee share
 *   USDC                  - USDC token address on target network
 *   USDT                  - USDT token address on target network
 *   CHAINLINK_XAU_USD     - Chainlink XAU/USD AggregatorV3 address
 *   BAND_ORACLE           - Band Protocol StdReference address
 *   API3_ORACLE           - API3 dAPI proxy address for XAU/USD
 *   AAVE_POOL             - Aave v3 Pool address
 *
 * TGX is deployed by this script (no external TGX address is required); the
 * full 100M supply is minted to TREASURY, which then distributes it per the
 * pending actions printed at the end of the run.
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // TGX genesis allocation (100,000,000 TGX minted to treasury):
    //   65M emissions / 15M team+contributor vesting / 20M treasury reserve

    struct Addresses {
        address admin;
        address treasury;
        address usdc;
        address usdt;
        address chainlink;
        address band;
        address api3;
        address aavePool;
    }

    // Deployed contracts, exposed as public state so deployment can be verified
    // (e.g. by VerifyDeploy or a smoke test) after run() completes.
    TGAUX public tgaux;
    TGX public tgx;
    OracleAggregator public oracle;
    LiquidityPool public liquidityPool;
    TGXVesting public tgxVesting;
    TGXEmissions public tgxEmissions;
    VaultManager public vaultManager;
    InsuranceFund public insuranceFund;
    FeeDistributor public feeDistributor;
    LiquidationEngine public liquidationEngine;
    TimelockController public timelock;
    address public lpConservative;
    address public lpAggressive;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        Addresses memory env = Addresses({
            admin: vm.envAddress("ADMIN"),
            treasury: vm.envAddress("TREASURY"),
            usdc: vm.envAddress("USDC"),
            usdt: vm.envAddress("USDT"),
            chainlink: vm.envAddress("CHAINLINK_XAU_USD"),
            band: vm.envAddress("BAND_ORACLE"),
            api3: vm.envAddress("API3_ORACLE"),
            aavePool: vm.envAddress("AAVE_POOL")
        });

        _validate(env);

        vm.startBroadcast(deployerKey);

        console.log("=== TETRA GOLD DEPLOYMENT ===");
        console.log("Admin:   ", env.admin);
        console.log("Treasury:", env.treasury);
        console.log("");

        // 1. TGAUX token
        tgaux = new TGAUX(env.admin);
        console.log("TGAUX:              ", address(tgaux));

        // 2. TGX governance/reward token (mints 100M to treasury)
        tgx = new TGX(env.admin, env.treasury);
        console.log("TGX:                ", address(tgx));

        // 3. Oracle aggregator
        oracle = new OracleAggregator(env.admin, env.chainlink, env.band, env.api3);
        console.log("OracleAggregator:   ", address(oracle));

        // 4. Liquidity pool (constructs its own TGLP-C / TGLP-A LP tokens)
        liquidityPool = new LiquidityPool(env.admin, env.usdc, env.usdt);
        console.log("LiquidityPool:      ", address(liquidityPool));

        (,,, lpConservative,) = liquidityPool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        (,,, lpAggressive,) = liquidityPool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);
        console.log("  TGLP-C:           ", lpConservative);
        console.log("  TGLP-A:           ", lpAggressive);

        // 5. TGX vesting (team + contributors, schedules created on demand by admin)
        tgxVesting = new TGXVesting(env.admin, address(tgx));
        console.log("TGXVesting:         ", address(tgxVesting));

        // 6. TGX emissions (stake-to-earn over TGLP-C / TGLP-A, 4-year step decay)
        tgxEmissions = new TGXEmissions(env.admin, address(tgx), lpConservative, lpAggressive);
        console.log("TGXEmissions:       ", address(tgxEmissions));

        // 7. VaultManager
        vaultManager =
            new VaultManager(env.admin, address(tgaux), address(oracle), address(liquidityPool), env.usdc, env.usdt);
        console.log("VaultManager:       ", address(vaultManager));

        // 8. InsuranceFund
        insuranceFund = new InsuranceFund(env.admin, address(vaultManager), address(liquidityPool), env.aavePool);
        console.log("InsuranceFund:      ", address(insuranceFund));

        // 9. FeeDistributor (wired to the freshly deployed TGX)
        feeDistributor = new FeeDistributor(env.admin, address(tgx), address(insuranceFund), env.treasury);
        console.log("FeeDistributor:     ", address(feeDistributor));

        // 10. LiquidationEngine
        liquidationEngine =
            new LiquidationEngine(env.admin, address(vaultManager), address(insuranceFund), env.treasury);
        console.log("LiquidationEngine:  ", address(liquidationEngine));

        // 11. Governance timelock (48h) for slow parameter tuning. The admin
        // multisig is the sole proposer and executor; the timelock self-administers
        // (admin == address(0)) so role management also flows through the delay.
        address[] memory proposers = new address[](1);
        proposers[0] = env.admin;
        address[] memory executors = new address[](1);
        executors[0] = env.admin;
        timelock = new TimelockController(48 hours, proposers, executors, address(0));
        console.log("TimelockController: ", address(timelock));

        vm.stopBroadcast();

        _printPendingActions(address(tgxEmissions), address(tgxVesting), address(timelock));
    }

    function _printPendingActions(address tgxEmissions, address tgxVesting, address timelock) internal view {
        // Role setup and TGX distribution must be executed by the admin multisig
        // and treasury after deployment. Run VerifyDeploy.s.sol to confirm roles.
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

        console.log("");
        console.log("=== PENDING TGX DISTRIBUTION (run as treasury) ===");
        console.log("Genesis: 100,000,000 TGX minted to treasury");
        console.log("- Fund emissions: tgx.transfer(emissions, 65,000,000e18)");
        console.log("  emissions:", tgxEmissions);
        console.log("- Vesting budget: approve admin to pull up to 15,000,000e18 for team/contributor schedules");
        console.log("  vesting:  ", tgxVesting);
        console.log("- Remaining 20,000,000 TGX stays in treasury reserve");
        console.log(
            "Emission step decay (per year): 25M / 15M / 7.5M / 2.5M = 50M emitted; ~15M sweepable after year 4"
        );

        console.log("");
        console.log("=== PENDING TIMELOCK HANDOFF (run as admin) ===");
        console.log("Move slow parameter tuning behind the 48h timelock, keep pause immediate:");
        console.log("  timelock:", timelock);
        console.log("- oracle.grantRole(PARAM_ROLE, timelock)");
        console.log("- oracle.renounceRole(PARAM_ROLE, admin)");
        console.log("- insuranceFund.grantRole(PARAM_ROLE, timelock)");
        console.log("- insuranceFund.renounceRole(PARAM_ROLE, admin)");
        console.log("setPriceDeviation / setCircuitBreakerThreshold / updateTargetPercentage now require the timelock");
    }

    function _validate(Addresses memory env) internal pure {
        require(env.admin != address(0), "Deploy: ADMIN not set");
        require(env.treasury != address(0), "Deploy: TREASURY not set");
        require(env.usdc != address(0), "Deploy: USDC not set");
        require(env.usdt != address(0), "Deploy: USDT not set");
        require(env.chainlink != address(0), "Deploy: CHAINLINK_XAU_USD not set");
        require(env.band != address(0), "Deploy: BAND_ORACLE not set");
        require(env.api3 != address(0), "Deploy: API3_ORACLE not set");
        require(env.aavePool != address(0), "Deploy: AAVE_POOL not set");
    }
}
