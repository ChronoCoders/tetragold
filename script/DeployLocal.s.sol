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

// ============ Inline Mocks (local deployment only) ============

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockChainlinkOracle {
    int256 private _price;
    uint256 private _updatedAt;

    constructor(int256 initialPrice) {
        _price = initialPrice;
        _updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
        return (1, _price, _updatedAt, _updatedAt, 1);
    }
}

contract MockBandOracle {
    uint256 private _rate;
    uint256 private _updatedAt;

    constructor(uint256 initialRate) {
        _rate = initialRate;
        _updatedAt = block.timestamp;
    }

    function getReferenceData(string memory, string memory)
        external
        view
        returns (uint256 rate, uint256 lastUpdatedBase, uint256 lastUpdatedQuote)
    {
        return (_rate, _updatedAt, _updatedAt);
    }
}

contract MockAPI3Oracle {
    int224 private _value;
    uint32 private _timestamp;

    constructor(int224 initialValue) {
        _value = initialValue;
        _timestamp = uint32(block.timestamp);
    }

    function read() external view returns (int224 value, uint32 timestamp) {
        return (_value, _timestamp);
    }
}

contract MockAavePool {
    function supply(address, uint256, address, uint16) external {}

    function withdraw(address, uint256 amount, address) external returns (uint256) {
        return amount;
    }
}

// ============ Deployment Script ============

/**
 * @title DeployLocal
 * @notice Deploys the full Tetra Gold protocol stack on a local Anvil node.
 * @dev Run with: forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
 */
contract DeployLocal is Script {
    // Anvil default account #0
    uint256 private constant DEPLOYER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Gold price: $2,847.00
    int256 private constant GOLD_PRICE_8DEC = 284700000000;
    uint256 private constant GOLD_PRICE_18DEC = 284700000000 * 1e10;

    uint256 private constant MINT_STABLE = 1_000_000 * 10 ** 6;
    uint256 private constant MINT_TGX = 1_000_000 * 10 ** 18;

    // Deployed addresses passed between helpers via storage
    address private usdc;
    address private usdt;
    address private tgx;
    address private tgaux;
    address private oracle;
    address private liquidityPool;
    address private vaultManager;
    address private insuranceFund;
    address private feeDistributor;
    address private liquidationEngine;

    function run() external {
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);
        address deployer = vm.addr(DEPLOYER_PRIVATE_KEY);

        console.log("=== TETRA GOLD LOCAL DEPLOYMENT ===");
        console.log("Deployer:", deployer);
        console.log("");

        _deployTokensAndOracle(deployer);
        _deployCore(deployer);
        _configureRoles();
        _mintTestTokens(deployer);
        _printSummary();

        vm.stopBroadcast();
    }

    function _deployTokensAndOracle(address deployer) internal {
        console.log("[1/4] Deploying mock tokens...");
        usdc = address(new MockERC20("USD Coin", "USDC", 6));
        usdt = address(new MockERC20("Tether USD", "USDT", 6));
        tgx = address(new MockERC20("Tetra Gold Governance", "TGX", 18));

        console.log("[2/4] Deploying mock oracles and TGAUX...");
        address chainlink = address(new MockChainlinkOracle(GOLD_PRICE_8DEC));
        address band = address(new MockBandOracle(GOLD_PRICE_18DEC));
        address api3 = address(new MockAPI3Oracle(int224(int256(GOLD_PRICE_18DEC))));

        tgaux = address(new TGAUX(deployer));
        oracle = address(new OracleAggregator(deployer, chainlink, band, api3));

        // Seed TWAP with initial gold price
        OracleAggregator(oracle).updateTwap();
    }

    function _deployCore(address deployer) internal {
        console.log("[3/4] Deploying core protocol contracts...");

        liquidityPool = address(new LiquidityPool(deployer, usdc, usdt));

        vaultManager = address(new VaultManager(deployer, tgaux, oracle, liquidityPool, usdc, usdt));

        address aavePool = address(new MockAavePool());
        insuranceFund = address(new InsuranceFund(deployer, vaultManager, liquidityPool, aavePool));

        feeDistributor = address(new FeeDistributor(deployer, tgx, insuranceFund, deployer));
        FeeDistributor(feeDistributor).addSupportedToken(usdc);
        FeeDistributor(feeDistributor).addSupportedToken(usdt);

        liquidationEngine = address(new LiquidationEngine(deployer, vaultManager, insuranceFund, deployer));
    }

    function _configureRoles() internal {
        console.log("[4/4] Configuring roles...");

        TGAUX(tgaux).grantRole(TGAUX(tgaux).MINTER_ROLE(), vaultManager);
        console.log("- MINTER_ROLE            -> VaultManager");

        LiquidityPool(liquidityPool).grantRole(LiquidityPool(liquidityPool).VAULT_MANAGER_ROLE(), vaultManager);
        console.log("- VAULT_MANAGER_ROLE     -> VaultManager (LiquidityPool)");

        VaultManager(vaultManager).grantRole(VaultManager(vaultManager).LIQUIDATOR_ROLE(), liquidationEngine);
        console.log("- LIQUIDATOR_ROLE        -> LiquidationEngine");

        InsuranceFund(insuranceFund).grantRole(InsuranceFund(insuranceFund).VAULT_MANAGER_ROLE(), feeDistributor);
        InsuranceFund(insuranceFund)
            .grantRole(InsuranceFund(insuranceFund).LIQUIDATION_ENGINE_ROLE(), liquidationEngine);
        console.log("- VAULT_MANAGER_ROLE     -> FeeDistributor (InsuranceFund)");
        console.log("- LIQUIDATION_ENGINE_ROLE -> LiquidationEngine (InsuranceFund)");

        // Pre-register tokens so getTotalReserves() is accurate before first deposit
        InsuranceFund(insuranceFund).addSupportedToken(usdc);
        InsuranceFund(insuranceFund).addSupportedToken(usdt);
        console.log("- Supported tokens registered in InsuranceFund");

        // Wire VaultManager -> FeeDistributor fee push path
        FeeDistributor(feeDistributor).grantRole(FeeDistributor(feeDistributor).VAULT_MANAGER_ROLE(), vaultManager);
        VaultManager(vaultManager).grantRole(VaultManager(vaultManager).FEE_COLLECTOR_ROLE(), vaultManager);
        VaultManager(vaultManager).setFeeDistributor(feeDistributor);
        console.log("- VAULT_MANAGER_ROLE     -> VaultManager (FeeDistributor)");
        console.log("- feeDistributor set in VaultManager");
    }

    function _mintTestTokens(address deployer) internal {
        MockERC20(usdc).mint(deployer, MINT_STABLE);
        MockERC20(usdt).mint(deployer, MINT_STABLE);
        MockERC20(tgx).mint(deployer, MINT_TGX);
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=== DEPLOYED ADDRESSES ===");
        console.log("USDC:               ", usdc);
        console.log("USDT:               ", usdt);
        console.log("TGX:                ", tgx);
        console.log("TGAUX:              ", tgaux);
        console.log("OracleAggregator:   ", oracle);
        console.log("LiquidityPool:      ", liquidityPool);
        console.log("VaultManager:       ", vaultManager);
        console.log("InsuranceFund:      ", insuranceFund);
        console.log("FeeDistributor:     ", feeDistributor);
        console.log("LiquidationEngine:  ", liquidationEngine);
        console.log("");
        console.log("Gold price seed:     $2,847.00");
        console.log("Deployer balance:    1,000,000 USDC / USDT / TGX");
        console.log("=== DEPLOYMENT COMPLETE ===");
    }
}
