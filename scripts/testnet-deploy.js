const { ethers, upgrades } = require("hardhat");
const fs = require("fs");
const path = require("path");

/**
 * Testnet Deployment Script for TetraGold (TGAUx)
 * 
 * This script deploys all contracts to testnet with appropriate test configurations
 * Includes mock oracles and reduced timelock delays for testing
 */

async function main() {
    console.log("🚀 Starting TetraGold Testnet Deployment...\n");

    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    
    console.log("📝 Deployment Details:");
    console.log("- Network:", network.name, `(Chain ID: ${network.chainId})`);
    console.log("- Deployer:", deployer.address);
    console.log("- Balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH\n");

    // Testnet configuration
    const config = {
        circuitBreaker: {
            deviationThreshold: 500,  // 5% (same as mainnet)
            timeWindow: 300,          // 5 minutes (same as mainnet)
            cooldownPeriod: 1800      // 30 minutes (reduced for testing)
        },
        timelock: {
            minDelay: 3600,           // 1 hour (reduced for testing)
            proposers: [deployer.address],
            executors: [deployer.address],
            admin: deployer.address
        },
        token: {
            name: "TetraGold Testnet",
            symbol: "TGAUx-TEST",
            mintFee: 50,              // 0.5%
            redeemFee: 50,            // 0.5%
            feeRecipient: deployer.address
        },
        oracles: {
            mockPrice: ethers.utils.parseEther("3350"), // $3350 base price
            updateInterval: 300,      // 5 minutes
            priceVariation: 50        // ±$50 variation
        }
    };

    const deploymentResults = {};

    try {
        // 1. Deploy Mock Oracles for Testing
        console.log("🔧 Deploying Mock Oracles...");
        
        const MockChainlinkOracle = await ethers.getContractFactory("MockChainlinkOracle");
        const mockChainlink = await MockChainlinkOracle.deploy(
            config.oracles.mockPrice,
            8, // decimals
            "Gold / USD"
        );
        await mockChainlink.deployed();
        console.log("✅ Mock Chainlink Oracle:", mockChainlink.address);

        const MockBandOracle = await ethers.getContractFactory("MockBandOracle");
        const mockBand = await MockBandOracle.deploy(config.oracles.mockPrice);
        await mockBand.deployed();
        console.log("✅ Mock Band Oracle:", mockBand.address);

        deploymentResults.mockOracles = {
            chainlink: mockChainlink.address,
            band: mockBand.address
        };

        // 2. Deploy Circuit Breaker
        console.log("\n🔧 Deploying Circuit Breaker...");
        const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
        const circuitBreaker = await CircuitBreaker.deploy(
            config.circuitBreaker.deviationThreshold,
            config.circuitBreaker.timeWindow,
            config.circuitBreaker.cooldownPeriod
        );
        await circuitBreaker.deployed();
        console.log("✅ Circuit Breaker:", circuitBreaker.address);
        deploymentResults.circuitBreaker = circuitBreaker.address;

        // 3. Deploy Oracle Aggregator
        console.log("\n🔧 Deploying Oracle Aggregator...");
        const OracleAggregator = await ethers.getContractFactory("OracleAggregator");
        const oracleAggregator = await OracleAggregator.deploy();
        await oracleAggregator.deployed();
        console.log("✅ Oracle Aggregator:", oracleAggregator.address);
        deploymentResults.oracleAggregator = oracleAggregator.address;

        // 4. Deploy Timelock Controller
        console.log("\n🔧 Deploying Timelock Controller...");
        const TetraGoldTimelock = await ethers.getContractFactory("TetraGoldTimelock");
        const timelock = await TetraGoldTimelock.deploy(
            config.timelock.proposers,
            config.timelock.executors,
            config.timelock.admin
        );
        await timelock.deployed();
        console.log("✅ Timelock Controller:", timelock.address);
        deploymentResults.timelock = timelock.address;

        // 5. Deploy TGAUx Token (Upgradeable)
        console.log("\n🔧 Deploying TGAUx Token (Upgradeable)...");
        const TGAUx = await ethers.getContractFactory("TGAUx");
        const tgaux = await upgrades.deployProxy(TGAUx, [
            config.token.name,
            config.token.symbol,
            oracleAggregator.address,
            circuitBreaker.address,
            config.token.feeRecipient
        ], { 
            initializer: 'initialize',
            kind: 'uups'
        });
        await tgaux.deployed();
        console.log("✅ TGAUx Token:", tgaux.address);
        deploymentResults.tgaux = tgaux.address;

        // 6. Configure System
        console.log("\n🔐 Configuring System Permissions...");

        // Grant circuit breaker manager role to TGAUx
        const CIRCUIT_MANAGER_ROLE = await circuitBreaker.CIRCUIT_MANAGER_ROLE();
        await circuitBreaker.grantRole(CIRCUIT_MANAGER_ROLE, tgaux.address);
        console.log("✅ Granted CIRCUIT_MANAGER_ROLE to TGAUx");

        // Grant price updater role for oracle aggregator
        const PRICE_UPDATER_ROLE = await oracleAggregator.PRICE_UPDATER_ROLE();
        await oracleAggregator.grantRole(PRICE_UPDATER_ROLE, deployer.address);
        console.log("✅ Granted PRICE_UPDATER_ROLE to deployer");

        // 7. Configure Oracle Aggregator
        console.log("\n🔧 Configuring Oracle Aggregator...");

        // Add mock Chainlink oracle (60% weight)
        await oracleAggregator.addOracle(
            mockChainlink.address,
            6000, // 60% weight
            3600  // 1 hour staleness
        );
        console.log("✅ Added Chainlink oracle (60% weight)");

        // Add mock Band oracle (40% weight)
        await oracleAggregator.addOracle(
            mockBand.address,
            4000, // 40% weight
            1800  // 30 minutes staleness
        );
        console.log("✅ Added Band oracle (40% weight)");

        // Initial price update
        await oracleAggregator.updateAggregatedPrice();
        console.log("✅ Initial price aggregation completed");

        // 8. Verify Deployment
        console.log("\n🔍 Verifying Deployment...");

        const tokenName = await tgaux.name();
        const tokenSymbol = await tgaux.symbol();
        const version = await tgaux.version();
        const [currentPrice, timestamp] = await oracleAggregator.getLatestPrice();

        console.log("📊 Verification Results:");
        console.log("- Token Name:", tokenName);
        console.log("- Token Symbol:", tokenSymbol);
        console.log("- Contract Version:", version);
        console.log("- Current Price:", ethers.utils.formatEther(currentPrice), "USD");
        console.log("- Price Timestamp:", new Date(timestamp * 1000).toISOString());

        // 9. Setup Price Update Automation (for testing)
        console.log("\n⚡ Setting up automated price updates...");
        
        // Deploy price updater bot for testnet
        const PriceUpdaterBot = await ethers.getContractFactory("PriceUpdaterBot");
        const priceBot = await PriceUpdaterBot.deploy(
            oracleAggregator.address,
            mockChainlink.address,
            mockBand.address,
            config.oracles.updateInterval
        );
        await priceBot.deployed();
        console.log("✅ Price Updater Bot:", priceBot.address);
        deploymentResults.priceBot = priceBot.address;

        // Grant bot permission to update prices
        await oracleAggregator.grantRole(PRICE_UPDATER_ROLE, priceBot.address);
        console.log("✅ Granted price update permissions to bot");

        // 10. Generate Deployment Summary
        const deploymentSummary = {
            network: {
                name: network.name,
                chainId: network.chainId,
                blockNumber: await ethers.provider.getBlockNumber()
            },
            deployer: deployer.address,
            timestamp: new Date().toISOString(),
            contracts: deploymentResults,
            configuration: config,
            verification: {
                tokenName,
                tokenSymbol,
                version,
                currentPrice: ethers.utils.formatEther(currentPrice),
                priceTimestamp: new Date(timestamp * 1000).toISOString()
            }
        };

        // Save deployment info
        const deploymentDir = path.join(__dirname, "../deployments");
        if (!fs.existsSync(deploymentDir)) {
            fs.mkdirSync(deploymentDir, { recursive: true });
        }

        const filename = `testnet-deployment-${network.name}-${Date.now()}.json`;
        const filepath = path.join(deploymentDir, filename);
        fs.writeFileSync(filepath, JSON.stringify(deploymentSummary, null, 2));

        console.log("\n📋 Deployment Summary:");
        console.log("=====================================");
        console.log(JSON.stringify(deploymentSummary, null, 2));
        console.log("=====================================");
        console.log(`\n💾 Deployment info saved to: ${filepath}`);

        // 11. Testing Instructions
        console.log("\n🧪 Testing Instructions:");
        console.log("1. Frontend Configuration:");
        console.log(`   - Update VITE_CONTRACT_ADDRESS=${tgaux.address}`);
        console.log(`   - Update VITE_ORACLE_ADDRESS=${oracleAggregator.address}`);
        console.log(`   - Update VITE_NETWORK_ID=${network.chainId}`);
        console.log("\n2. Test Scenarios:");
        console.log("   - Mint tokens with test ETH");
        console.log("   - Redeem tokens back to ETH");
        console.log("   - Monitor price updates (every 5 minutes)");
        console.log("   - Test circuit breaker with large price changes");
        console.log("   - Verify emergency pause functionality");
        console.log("\n3. Monitoring:");
        console.log("   - Watch price bot updates");
        console.log("   - Monitor oracle health");
        console.log("   - Track transaction costs");

        console.log("\n🎉 Testnet Deployment Completed Successfully!");
        console.log("\n⚠️  Important Notes:");
        console.log("- This is a TESTNET deployment with mock oracles");
        console.log("- Timelock delays are reduced for testing (1 hour vs 48 hours)");
        console.log("- Price updates are automated every 5 minutes");
        console.log("- Use testnet ETH for all transactions");
        console.log("- Report any issues to the development team");

        return deploymentSummary;

    } catch (error) {
        console.error("\n❌ Deployment Failed:");
        console.error(error);
        
        // Save error info for debugging
        const errorInfo = {
            error: error.message,
            stack: error.stack,
            timestamp: new Date().toISOString(),
            network: network.name,
            deployer: deployer.address
        };

        const errorDir = path.join(__dirname, "../deployments/errors");
        if (!fs.existsSync(errorDir)) {
            fs.mkdirSync(errorDir, { recursive: true });
        }

        const errorFile = path.join(errorDir, `error-${Date.now()}.json`);
        fs.writeFileSync(errorFile, JSON.stringify(errorInfo, null, 2));
        console.log(`\n💾 Error details saved to: ${errorFile}`);

        process.exit(1);
    }
}

// Execute deployment
if (require.main === module) {
    main()
        .then((result) => {
            console.log("\n✅ Deployment script completed successfully!");
            process.exit(0);
        })
        .catch((error) => {
            console.error("\n❌ Deployment script failed:");
            console.error(error);
            process.exit(1);
        });
}

module.exports = { main };