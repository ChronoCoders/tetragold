const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("OracleAggregator", function () {
    let oracleAggregator;
    let owner, oracle1, oracle2, oracle3;
    let mockOracle1, mockOracle2;

    beforeEach(async function () {
        [owner, oracle1, oracle2, oracle3] = await ethers.getSigners();

        const OracleAggregator = await ethers.getContractFactory("OracleAggregator");
        oracleAggregator = await OracleAggregator.deploy();

        // Deploy mock oracles for testing
        const MockOracle = await ethers.getContractFactory("MockOracle");
        mockOracle1 = await MockOracle.deploy(ethers.utils.parseEther("3350")); // $3350
        mockOracle2 = await MockOracle.deploy(ethers.utils.parseEther("3355")); // $3355
    });

    describe("Oracle Management", function () {
        it("Should add oracle successfully", async function () {
            await expect(oracleAggregator.addOracle(oracle1.address, 5000, 3600))
                .to.emit(oracleAggregator, "OracleAdded")
                .withArgs(oracle1.address, 5000);

            const config = await oracleAggregator.getOracleConfig(oracle1.address);
            expect(config.oracle).to.equal(oracle1.address);
            expect(config.weight).to.equal(5000);
            expect(config.maxStaleness).to.equal(3600);
            expect(config.isActive).to.be.true;
        });

        it("Should prevent adding too many oracles", async function () {
            // Add maximum number of oracles
            for (let i = 0; i < 10; i++) {
                const wallet = ethers.Wallet.createRandom();
                await oracleAggregator.addOracle(wallet.address, 1000, 3600);
            }

            // Try to add one more
            await expect(oracleAggregator.addOracle(oracle1.address, 1000, 3600))
                .to.be.revertedWithCustomError(oracleAggregator, "TooManyOracles");
        });

        it("Should prevent adding oracle with invalid weight", async function () {
            await expect(oracleAggregator.addOracle(oracle1.address, 0, 3600))
                .to.be.revertedWithCustomError(oracleAggregator, "InvalidWeight");

            await expect(oracleAggregator.addOracle(oracle1.address, 10001, 3600))
                .to.be.revertedWithCustomError(oracleAggregator, "InvalidWeight");
        });

        it("Should remove oracle successfully", async function () {
            // Add two oracles first
            await oracleAggregator.addOracle(oracle1.address, 5000, 3600);
            await oracleAggregator.addOracle(oracle2.address, 5000, 3600);

            await expect(oracleAggregator.removeOracle(oracle1.address))
                .to.emit(oracleAggregator, "OracleRemoved")
                .withArgs(oracle1.address);

            const config = await oracleAggregator.getOracleConfig(oracle1.address);
            expect(config.oracle).to.equal(ethers.constants.AddressZero);
        });

        it("Should prevent removing oracle when below minimum", async function () {
            await oracleAggregator.addOracle(oracle1.address, 5000, 3600);
            await oracleAggregator.addOracle(oracle2.address, 5000, 3600);

            // Remove one oracle
            await oracleAggregator.removeOracle(oracle1.address);

            // Try to remove the last one (would go below minimum)
            await expect(oracleAggregator.removeOracle(oracle2.address))
                .to.be.revertedWithCustomError(oracleAggregator, "InsufficientOracles");
        });

        it("Should update oracle weight", async function () {
            await oracleAggregator.addOracle(oracle1.address, 5000, 3600);

            await expect(oracleAggregator.updateOracleWeight(oracle1.address, 7000))
                .to.emit(oracleAggregator, "OracleWeightUpdated")
                .withArgs(oracle1.address, 7000);

            const config = await oracleAggregator.getOracleConfig(oracle1.address);
            expect(config.weight).to.equal(7000);
        });
    });

    describe("Price Aggregation", function () {
        beforeEach(async function () {
            // Add test oracles
            await oracleAggregator.addOracle(mockOracle1.address, 6000, 3600);
            await oracleAggregator.addOracle(mockOracle2.address, 4000, 3600);
        });

        it("Should aggregate prices correctly", async function () {
            await expect(oracleAggregator.updateAggregatedPrice())
                .to.emit(oracleAggregator, "PriceAggregated");

            const [price, timestamp] = await oracleAggregator.getLatestPrice();
            expect(price).to.be.gt(0);
            expect(timestamp).to.be.gt(0);
        });

        it("Should calculate weighted average correctly", async function () {
            // Mock oracle 1: $3350 with 60% weight
            // Mock oracle 2: $3355 with 40% weight
            // Expected: (3350 * 0.6) + (3355 * 0.4) = 2010 + 1342 = 3352

            await oracleAggregator.updateAggregatedPrice();
            const [price] = await oracleAggregator.getLatestPrice();
            
            // Allow for small rounding differences
            expect(price).to.be.closeTo(ethers.utils.parseEther("3352"), ethers.utils.parseEther("1"));
        });

        it("Should get all oracle prices", async function () {
            const prices = await oracleAggregator.getAllPrices();
            expect(prices.length).to.equal(2);
            expect(prices[0].price).to.be.gt(0);
            expect(prices[1].price).to.be.gt(0);
        });
    });

    describe("Deviation Checking", function () {
        beforeEach(async function () {
            await oracleAggregator.addOracle(mockOracle1.address, 10000, 3600);
            await oracleAggregator.updateAggregatedPrice();
        });

        it("Should detect price deviation", async function () {
            const [currentPrice] = await oracleAggregator.getLatestPrice();
            const newPrice = currentPrice.mul(110).div(100); // 10% increase

            const [exceeded, deviation] = await oracleAggregator.checkDeviation(newPrice);
            expect(exceeded).to.be.true;
            expect(deviation).to.equal(1000); // 10% in basis points
        });

        it("Should not trigger on small deviations", async function () {
            const [currentPrice] = await oracleAggregator.getLatestPrice();
            const newPrice = currentPrice.mul(102).div(100); // 2% increase

            const [exceeded, deviation] = await oracleAggregator.checkDeviation(newPrice);
            expect(exceeded).to.be.false;
            expect(deviation).to.equal(200); // 2% in basis points
        });

        it("Should update deviation threshold", async function () {
            await expect(oracleAggregator.updateDeviationThreshold(500))
                .to.emit(oracleAggregator, "DeviationThresholdUpdated")
                .withArgs(500);

            expect(await oracleAggregator.deviationThreshold()).to.equal(500);
        });
    });

    describe("Access Control", function () {
        it("Should prevent unauthorized oracle management", async function () {
            await expect(oracleAggregator.connect(oracle1).addOracle(oracle2.address, 5000, 3600))
                .to.be.revertedWith("AccessControl:");
        });

        it("Should prevent unauthorized price updates", async function () {
            await expect(oracleAggregator.connect(oracle1).updateAggregatedPrice())
                .to.be.revertedWith("AccessControl:");
        });

        it("Should allow role-based access", async function () {
            const ORACLE_MANAGER_ROLE = await oracleAggregator.ORACLE_MANAGER_ROLE();
            await oracleAggregator.grantRole(ORACLE_MANAGER_ROLE, oracle1.address);

            await expect(oracleAggregator.connect(oracle1).addOracle(oracle2.address, 5000, 3600))
                .to.emit(oracleAggregator, "OracleAdded");
        });
    });
});

// Mock Oracle Contract for testing
contract MockOracle {
    uint256 private price;
    uint256 private lastUpdate;

    constructor(uint256 _price) {
        price = _price;
        lastUpdate = block.timestamp;
    }

    function getPrice() external view returns (uint256, uint256, uint256) {
        return (price, lastUpdate, 9500); // 95% confidence
    }

    function updatePrice(uint256 _newPrice) external {
        price = _newPrice;
        lastUpdate = block.timestamp;
    }
}