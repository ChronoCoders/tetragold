const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TGAUx Token", function () {
    let tgaux, oracleAggregator, circuitBreaker, timelock;
    let owner, user1, user2, feeRecipient;
    let deployer;

    const INITIAL_PRICE = ethers.utils.parseEther("3350"); // $3350 per oz
    const MINT_FEE = 50; // 0.5%
    const REDEEM_FEE = 50; // 0.5%

    beforeEach(async function () {
        [owner, user1, user2, feeRecipient] = await ethers.getSigners();

        // Deploy Circuit Breaker
        const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
        circuitBreaker = await CircuitBreaker.deploy(
            500, // 5% deviation threshold
            300, // 5 minute time window
            3600 // 1 hour cooldown
        );

        // Deploy Oracle Aggregator
        const OracleAggregator = await ethers.getContractFactory("OracleAggregator");
        oracleAggregator = await OracleAggregator.deploy();

        // Deploy Timelock
        const TetraGoldTimelock = await ethers.getContractFactory("TetraGoldTimelock");
        timelock = await TetraGoldTimelock.deploy(
            [owner.address], // proposers
            [owner.address], // executors
            owner.address    // admin
        );

        // Deploy TGAUx as upgradeable proxy
        const TGAUx = await ethers.getContractFactory("TGAUx");
        tgaux = await upgrades.deployProxy(TGAUx, [
            "TetraGold",
            "TGAUx",
            oracleAggregator.address,
            circuitBreaker.address,
            feeRecipient.address
        ], { initializer: 'initialize' });

        // Grant roles
        await circuitBreaker.grantRole(
            await circuitBreaker.CIRCUIT_MANAGER_ROLE(),
            tgaux.address
        );
    });

    describe("Deployment", function () {
        it("Should set the correct name and symbol", async function () {
            expect(await tgaux.name()).to.equal("TetraGold");
            expect(await tgaux.symbol()).to.equal("TGAUx");
        });

        it("Should set the correct initial parameters", async function () {
            expect(await tgaux.mintFee()).to.equal(MINT_FEE);
            expect(await tgaux.redeemFee()).to.equal(REDEEM_FEE);
            expect(await tgaux.feeRecipient()).to.equal(feeRecipient.address);
        });

        it("Should grant correct roles to deployer", async function () {
            const DEFAULT_ADMIN_ROLE = await tgaux.DEFAULT_ADMIN_ROLE();
            const MINTER_ROLE = await tgaux.MINTER_ROLE();
            const PAUSER_ROLE = await tgaux.PAUSER_ROLE();

            expect(await tgaux.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
            expect(await tgaux.hasRole(MINTER_ROLE, owner.address)).to.be.true;
            expect(await tgaux.hasRole(PAUSER_ROLE, owner.address)).to.be.true;
        });
    });

    describe("Minting", function () {
        beforeEach(async function () {
            // Mock oracle price
            await oracleAggregator.updateAggregatedPrice();
        });

        it("Should mint tokens correctly", async function () {
            const usdAmount = ethers.utils.parseEther("1000"); // $1000
            const expectedTokens = usdAmount.div(INITIAL_PRICE.div(ethers.utils.parseEther("1")));
            const fee = expectedTokens.mul(MINT_FEE).div(10000);
            const tokensAfterFee = expectedTokens.sub(fee);

            await expect(tgaux.connect(user1).mint(usdAmount, tokensAfterFee))
                .to.emit(tgaux, "Mint")
                .withArgs(user1.address, usdAmount, tokensAfterFee, fee);

            expect(await tgaux.balanceOf(user1.address)).to.equal(tokensAfterFee);
            expect(await tgaux.balanceOf(feeRecipient.address)).to.equal(fee);
        });

        it("Should reject minting below minimum amount", async function () {
            const tooSmallAmount = ethers.utils.parseEther("0.0001");
            
            await expect(tgaux.connect(user1).mint(tooSmallAmount, 0))
                .to.be.revertedWithCustomError(tgaux, "InvalidAmount");
        });

        it("Should reject minting above maximum amount", async function () {
            const tooLargeAmount = ethers.utils.parseEther("2000000"); // 2M USD
            
            await expect(tgaux.connect(user1).mint(tooLargeAmount, 0))
                .to.be.revertedWithCustomError(tgaux, "InvalidAmount");
        });

        it("Should respect slippage protection", async function () {
            const usdAmount = ethers.utils.parseEther("1000");
            const tooHighMinTokens = ethers.utils.parseEther("1000"); // Unrealistic expectation
            
            await expect(tgaux.connect(user1).mint(usdAmount, tooHighMinTokens))
                .to.be.revertedWithCustomError(tgaux, "InvalidAmount");
        });
    });

    describe("Redeeming", function () {
        beforeEach(async function () {
            // Setup: mint some tokens first
            await oracleAggregator.updateAggregatedPrice();
            const usdAmount = ethers.utils.parseEther("1000");
            const expectedTokens = usdAmount.div(INITIAL_PRICE.div(ethers.utils.parseEther("1")));
            const fee = expectedTokens.mul(MINT_FEE).div(10000);
            const tokensAfterFee = expectedTokens.sub(fee);
            
            await tgaux.connect(user1).mint(usdAmount, tokensAfterFee);
        });

        it("Should redeem tokens correctly", async function () {
            const tokenAmount = ethers.utils.parseEther("0.1");
            const expectedUsd = tokenAmount.mul(INITIAL_PRICE).div(ethers.utils.parseEther("1"));
            const fee = expectedUsd.mul(REDEEM_FEE).div(10000);
            const usdAfterFee = expectedUsd.sub(fee);

            const initialBalance = await tgaux.balanceOf(user1.address);

            await expect(tgaux.connect(user1).redeem(tokenAmount, usdAfterFee))
                .to.emit(tgaux, "Redeem")
                .withArgs(user1.address, tokenAmount, usdAfterFee, fee);

            expect(await tgaux.balanceOf(user1.address)).to.equal(initialBalance.sub(tokenAmount));
        });

        it("Should reject redeeming more than balance", async function () {
            const balance = await tgaux.balanceOf(user1.address);
            const tooMuchTokens = balance.add(ethers.utils.parseEther("1"));
            
            await expect(tgaux.connect(user1).redeem(tooMuchTokens, 0))
                .to.be.revertedWithCustomError(tgaux, "InsufficientBalance");
        });

        it("Should respect slippage protection on redeem", async function () {
            const tokenAmount = ethers.utils.parseEther("0.1");
            const tooHighMinUsd = ethers.utils.parseEther("1000"); // Unrealistic expectation
            
            await expect(tgaux.connect(user1).redeem(tokenAmount, tooHighMinUsd))
                .to.be.revertedWithCustomError(tgaux, "InvalidAmount");
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow emergency pause", async function () {
            await expect(tgaux.emergencyPause("Test emergency"))
                .to.emit(tgaux, "EmergencyModeActivated")
                .withArgs(owner.address, "Test emergency");

            expect(await tgaux.emergencyMode()).to.be.true;
            expect(await tgaux.paused()).to.be.true;
        });

        it("Should prevent operations during emergency", async function () {
            await tgaux.emergencyPause("Test emergency");
            
            await expect(tgaux.connect(user1).mint(ethers.utils.parseEther("100"), 0))
                .to.be.revertedWithCustomError(tgaux, "EmergencyModeActive");
        });

        it("Should allow deactivating emergency mode", async function () {
            await tgaux.emergencyPause("Test emergency");
            
            await expect(tgaux.deactivateEmergency())
                .to.emit(tgaux, "EmergencyModeDeactivated")
                .withArgs(owner.address);

            expect(await tgaux.emergencyMode()).to.be.false;
            expect(await tgaux.paused()).to.be.false;
        });
    });

    describe("Access Control", function () {
        it("Should prevent unauthorized fee updates", async function () {
            await expect(tgaux.connect(user1).updateFees(100, 100))
                .to.be.revertedWith("AccessControl:");
        });

        it("Should allow authorized fee updates", async function () {
            await expect(tgaux.updateFees(100, 100))
                .to.emit(tgaux, "FeesUpdated")
                .withArgs(100, 100);

            expect(await tgaux.mintFee()).to.equal(100);
            expect(await tgaux.redeemFee()).to.equal(100);
        });

        it("Should prevent setting fees too high", async function () {
            await expect(tgaux.updateFees(1001, 100))
                .to.be.revertedWith("Fee too high");
        });
    });

    describe("Circuit Breaker Integration", function () {
        it("Should respect circuit breaker triggers", async function () {
            // Trigger circuit breaker by simulating extreme price movement
            await circuitBreaker.checkPrice(INITIAL_PRICE.mul(2)); // 100% increase
            
            await expect(tgaux.connect(user1).mint(ethers.utils.parseEther("100"), 0))
                .to.be.revertedWithCustomError(tgaux, "CircuitBreakerActive");
        });
    });

    describe("Upgradeability", function () {
        it("Should be upgradeable by authorized role", async function () {
            const TGAUxV2 = await ethers.getContractFactory("TGAUx");
            const upgraded = await upgrades.upgradeProxy(tgaux.address, TGAUxV2);
            
            expect(await upgraded.version()).to.equal("1.0.0");
        });

        it("Should prevent unauthorized upgrades", async function () {
            const UPGRADER_ROLE = await tgaux.UPGRADER_ROLE();
            await tgaux.revokeRole(UPGRADER_ROLE, owner.address);
            
            const TGAUxV2 = await ethers.getContractFactory("TGAUx");
            await expect(upgrades.upgradeProxy(tgaux.address, TGAUxV2))
                .to.be.revertedWith("AccessControl:");
        });
    });

    describe("Oracle Integration", function () {
        it("Should get current price from oracle", async function () {
            const [price, timestamp] = await tgaux.getCurrentPrice();
            expect(price).to.be.gt(0);
            expect(timestamp).to.be.gt(0);
        });

        it("Should update oracle aggregator", async function () {
            const newAggregator = await ethers.getContractFactory("OracleAggregator");
            const newAggregatorInstance = await newAggregator.deploy();

            await expect(tgaux.updateOracleAggregator(newAggregatorInstance.address))
                .to.emit(tgaux, "OracleAggregatorUpdated")
                .withArgs(newAggregatorInstance.address);

            expect(await tgaux.oracleAggregator()).to.equal(newAggregatorInstance.address);
        });
    });
});