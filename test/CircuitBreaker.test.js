const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CircuitBreaker", function () {
    let circuitBreaker;
    let owner, manager, emergency;

    const DEVIATION_THRESHOLD = 500; // 5%
    const TIME_WINDOW = 300; // 5 minutes
    const COOLDOWN_PERIOD = 3600; // 1 hour
    const BASE_PRICE = ethers.utils.parseEther("3350");

    beforeEach(async function () {
        [owner, manager, emergency] = await ethers.getSigners();

        const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
        circuitBreaker = await CircuitBreaker.deploy(
            DEVIATION_THRESHOLD,
            TIME_WINDOW,
            COOLDOWN_PERIOD
        );

        // Grant roles
        const CIRCUIT_MANAGER_ROLE = await circuitBreaker.CIRCUIT_MANAGER_ROLE();
        const EMERGENCY_ROLE = await circuitBreaker.EMERGENCY_ROLE();
        
        await circuitBreaker.grantRole(CIRCUIT_MANAGER_ROLE, manager.address);
        await circuitBreaker.grantRole(EMERGENCY_ROLE, emergency.address);
    });

    describe("Deployment", function () {
        it("Should set correct initial configuration", async function () {
            const config = await circuitBreaker.getConfig();
            expect(config.priceDeviationThreshold).to.equal(DEVIATION_THRESHOLD);
            expect(config.timeWindow).to.equal(TIME_WINDOW);
            expect(config.cooldownPeriod).to.equal(COOLDOWN_PERIOD);
            expect(config.isActive).to.be.true;
        });

        it("Should not be triggered initially", async function () {
            expect(await circuitBreaker.isTriggered()).to.be.false;
        });
    });

    describe("Price Checking", function () {
        it("Should allow normal price changes", async function () {
            // Set initial price
            const [allowed1] = await circuitBreaker.connect(manager).callStatic.checkPrice(BASE_PRICE);
            expect(allowed1).to.be.true;
            
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);

            // Small price change (2%)
            const smallChange = BASE_PRICE.mul(102).div(100);
            const [allowed2] = await circuitBreaker.connect(manager).callStatic.checkPrice(smallChange);
            expect(allowed2).to.be.true;
        });

        it("Should trigger on large price deviation", async function () {
            // Set initial price
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);

            // Large price change (10%)
            const largeChange = BASE_PRICE.mul(110).div(100);
            
            await expect(circuitBreaker.connect(manager).checkPrice(largeChange))
                .to.emit(circuitBreaker, "CircuitBreakerTriggered");

            expect(await circuitBreaker.isTriggered()).to.be.true;
        });

        it("Should prevent operations when triggered", async function () {
            // Trigger circuit breaker
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            const largeChange = BASE_PRICE.mul(110).div(100);
            await circuitBreaker.connect(manager).checkPrice(largeChange);

            // Try to check another price
            const [allowed] = await circuitBreaker.connect(manager).callStatic.checkPrice(BASE_PRICE);
            expect(allowed).to.be.false;
        });

        it("Should calculate deviation correctly", async function () {
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            
            const newPrice = BASE_PRICE.mul(110).div(100); // 10% increase
            const [, deviation] = await circuitBreaker.connect(manager).callStatic.checkPrice(newPrice);
            
            expect(deviation).to.equal(1000); // 10% in basis points
        });
    });

    describe("Time-based Features", function () {
        it("Should reset after cooldown period", async function () {
            // Trigger circuit breaker
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            const largeChange = BASE_PRICE.mul(110).div(100);
            await circuitBreaker.connect(manager).checkPrice(largeChange);

            expect(await circuitBreaker.isTriggered()).to.be.true;

            // Fast forward past cooldown period
            await time.increase(COOLDOWN_PERIOD + 1);

            expect(await circuitBreaker.isTriggered()).to.be.false;
        });

        it("Should track time until reset", async function () {
            // Trigger circuit breaker
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            const largeChange = BASE_PRICE.mul(110).div(100);
            await circuitBreaker.connect(manager).checkPrice(largeChange);

            const timeUntilReset = await circuitBreaker.getTimeUntilReset();
            expect(timeUntilReset).to.be.closeTo(COOLDOWN_PERIOD, 10);

            // Fast forward halfway
            await time.increase(COOLDOWN_PERIOD / 2);
            
            const timeUntilReset2 = await circuitBreaker.getTimeUntilReset();
            expect(timeUntilReset2).to.be.closeTo(COOLDOWN_PERIOD / 2, 10);
        });

        it("Should handle rapid price changes within time window", async function () {
            // Set initial price
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);

            // Make several small changes quickly
            for (let i = 1; i <= 3; i++) {
                const price = BASE_PRICE.mul(100 + i).div(100); // 1%, 2%, 3% increases
                await circuitBreaker.connect(manager).checkPrice(price);
                await time.increase(60); // 1 minute between changes
            }

            // Now make a change that would trigger based on cumulative movement
            const finalPrice = BASE_PRICE.mul(107).div(100); // 7% total increase
            
            await expect(circuitBreaker.connect(manager).checkPrice(finalPrice))
                .to.emit(circuitBreaker, "CircuitBreakerTriggered");
        });
    });

    describe("Configuration Management", function () {
        it("Should update configuration", async function () {
            const newThreshold = 1000; // 10%
            const newTimeWindow = 600; // 10 minutes
            const newCooldown = 7200; // 2 hours

            await expect(circuitBreaker.connect(manager).updateConfig(
                newThreshold,
                newTimeWindow,
                newCooldown
            )).to.emit(circuitBreaker, "ConfigUpdated")
              .withArgs(newThreshold, newTimeWindow, newCooldown);

            const config = await circuitBreaker.getConfig();
            expect(config.priceDeviationThreshold).to.equal(newThreshold);
            expect(config.timeWindow).to.equal(newTimeWindow);
            expect(config.cooldownPeriod).to.equal(newCooldown);
        });

        it("Should prevent invalid configuration", async function () {
            // Threshold too high
            await expect(circuitBreaker.connect(manager).updateConfig(2001, TIME_WINDOW, COOLDOWN_PERIOD))
                .to.be.revertedWith("Threshold too high");

            // Time window too short
            await expect(circuitBreaker.connect(manager).updateConfig(DEVIATION_THRESHOLD, 59, COOLDOWN_PERIOD))
                .to.be.revertedWith("Time window too short");

            // Cooldown too short
            await expect(circuitBreaker.connect(manager).updateConfig(DEVIATION_THRESHOLD, TIME_WINDOW, 299))
                .to.be.revertedWith("Cooldown too short");
        });

        it("Should activate/deactivate circuit breaker", async function () {
            await circuitBreaker.connect(manager).setActive(false);
            
            const config = await circuitBreaker.getConfig();
            expect(config.isActive).to.be.false;

            // Should allow any price change when inactive
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            const extremeChange = BASE_PRICE.mul(200).div(100); // 100% increase
            const [allowed] = await circuitBreaker.connect(manager).callStatic.checkPrice(extremeChange);
            expect(allowed).to.be.true;
        });
    });

    describe("Emergency Functions", function () {
        it("Should allow emergency reset", async function () {
            // Trigger circuit breaker
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            const largeChange = BASE_PRICE.mul(110).div(100);
            await circuitBreaker.connect(manager).checkPrice(largeChange);

            expect(await circuitBreaker.isTriggered()).to.be.true;

            // Emergency reset
            await expect(circuitBreaker.connect(emergency).emergencyReset())
                .to.emit(circuitBreaker, "CircuitBreakerReset");

            expect(await circuitBreaker.isTriggered()).to.be.false;
        });

        it("Should prevent unauthorized emergency reset", async function () {
            await expect(circuitBreaker.connect(manager).emergencyReset())
                .to.be.revertedWith("AccessControl:");
        });
    });

    describe("Price History", function () {
        it("Should track price history", async function () {
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            
            expect(await circuitBreaker.getPriceHistoryLength()).to.equal(1);
            
            const [price, timestamp] = await circuitBreaker.getPriceHistoryEntry(0);
            expect(price).to.equal(BASE_PRICE);
            expect(timestamp).to.be.gt(0);
        });

        it("Should limit price history length", async function () {
            // Add more than MAX_HISTORY_LENGTH entries
            for (let i = 0; i < 105; i++) {
                const price = BASE_PRICE.add(i);
                await circuitBreaker.connect(manager).checkPrice(price);
            }

            expect(await circuitBreaker.getPriceHistoryLength()).to.equal(100);
        });

        it("Should get last price correctly", async function () {
            await circuitBreaker.connect(manager).checkPrice(BASE_PRICE);
            
            const [price, timestamp] = await circuitBreaker.getLastPrice();
            expect(price).to.equal(BASE_PRICE);
            expect(timestamp).to.be.gt(0);
        });
    });

    describe("Access Control", function () {
        it("Should prevent unauthorized price checking", async function () {
            await expect(circuitBreaker.connect(owner).checkPrice(BASE_PRICE))
                .to.be.revertedWith("AccessControl:");
        });

        it("Should prevent unauthorized configuration updates", async function () {
            await expect(circuitBreaker.connect(owner).updateConfig(1000, 600, 7200))
                .to.be.revertedWith("AccessControl:");
        });

        it("Should allow role-based access", async function () {
            const CIRCUIT_MANAGER_ROLE = await circuitBreaker.CIRCUIT_MANAGER_ROLE();
            await circuitBreaker.grantRole(CIRCUIT_MANAGER_ROLE, owner.address);

            await expect(circuitBreaker.connect(owner).checkPrice(BASE_PRICE))
                .to.not.be.reverted;
        });
    });
});