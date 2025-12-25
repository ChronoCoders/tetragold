// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Import all production contracts
import {TGAUX} from "../src/TGAUX.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {FeeDistributor} from "../src/FeeDistributor.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing
 */
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

/**
 * @title DeployLocal
 * @notice Deployment script for Tetra Gold protocol on local Anvil testnet
 * @dev Deploys all contracts in correct order and configures them for testing
 */
contract DeployLocal is Script {
    // Anvil default account #0 private key
    uint256 private constant DEPLOYER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Gold price: $2,847.00 (8 decimals)
    uint256 private constant GOLD_PRICE = 284700000000;

    // Test token amounts
    uint256 private constant USDC_MINT_AMOUNT = 1_000_000 * 10**6;  // 1M USDC (6 decimals)
    uint256 private constant USDT_MINT_AMOUNT = 1_000_000 * 10**6;  // 1M USDT (6 decimals)
    uint256 private constant TGX_MINT_AMOUNT = 1_000_000 * 10**18;  // 1M TGX (18 decimals)

    function run() external {
        // Start broadcasting transactions
        vm.startBroadcast(DEPLOYER_PRIVATE_KEY);

        address deployer = vm.addr(DEPLOYER_PRIVATE_KEY);

        console.log("=== TETRA GOLD DEPLOYMENT ===");
        console.log("");
        console.log("Network: Anvil Local Testnet");
        console.log("Chain ID: 31337");
        console.log("Deployer:", deployer);
        console.log("");

        // ============ STEP 1: Deploy Mock Tokens ============
        console.log("Deploying Mock Tokens...");

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        MockERC20 tgx = new MockERC20("Tetra Gold Governance", "TGX", 18);

        console.log("Mock tokens deployed!");
        console.log("");

        // ============ STEP 2: Deploy TGAUX Token ============
        console.log("Deploying TGAUX...");

        TGAUX tgaux = new TGAUX(deployer);

        console.log("TGAUX deployed!");
        console.log("");

        // ============ STEP 3: Deploy OracleAggregator ============
        console.log("Deploying OracleAggregator...");

        OracleAggregator oracle = new OracleAggregator(
            address(0), // chainlink (mock mode)
            address(0), // band (mock mode)
            address(0), // api3 (mock mode)
            deployer    // admin
        );

        // Set mock gold price: $2,847.00
        oracle.setMockPrice(GOLD_PRICE);

        console.log("OracleAggregator deployed and configured!");
        console.log("");

        // ============ STEP 4: Deploy LiquidityPool ============
        console.log("Deploying LiquidityPool...");

        LiquidityPool liquidityPool = new LiquidityPool(
            address(usdc),
            address(usdt)
        );

        console.log("LiquidityPool deployed!");
        console.log("");

        // ============ STEP 5: Deploy InsuranceFund ============
        console.log("Deploying InsuranceFund...");

        InsuranceFund insuranceFund = new InsuranceFund(
            address(0),              // vaultManager (set later)
            address(liquidityPool)
        );

        console.log("InsuranceFund deployed!");
        console.log("");

        // ============ STEP 6: Deploy FeeDistributor ============
        console.log("Deploying FeeDistributor...");

        FeeDistributor feeDistributor = new FeeDistributor(
            address(insuranceFund),
            deployer,          // treasury
            address(tgx),      // TGX token
            address(usdc)      // reward token
        );

        console.log("FeeDistributor deployed!");
        console.log("");

        // ============ STEP 7: Deploy VaultManager ============
        console.log("Deploying VaultManager...");

        VaultManager vaultManager = new VaultManager(
            address(tgaux),
            address(oracle),
            address(liquidityPool),
            address(feeDistributor),
            address(insuranceFund),
            deployer  // treasury
        );

        console.log("VaultManager deployed!");
        console.log("");

        // ============ STEP 8: Deploy LiquidationEngine ============
        console.log("Deploying LiquidationEngine...");

        LiquidationEngine liquidationEngine = new LiquidationEngine(
            address(vaultManager),
            address(oracle),
            address(insuranceFund)
        );

        console.log("LiquidationEngine deployed!");
        console.log("");

        // ============ POST-DEPLOYMENT CONFIGURATION ============
        console.log("Configuring contracts...");
        console.log("");

        // 1. Grant MINTER_ROLE to VaultManager
        bytes32 MINTER_ROLE = tgaux.MINTER_ROLE();
        tgaux.grantRole(MINTER_ROLE, address(vaultManager));
        console.log("- MINTER_ROLE granted to VaultManager");

        // 2. Update InsuranceFund with VaultManager address
        insuranceFund.updateVaultManager(address(vaultManager));
        console.log("- VaultManager set in InsuranceFund");

        // 3. Add supported tokens to InsuranceFund
        insuranceFund.addSupportedToken(address(usdc));
        insuranceFund.addSupportedToken(address(usdt));
        console.log("- Supported tokens added to InsuranceFund");

        // 4. Add reward tokens to FeeDistributor
        feeDistributor.addSupportedToken(address(usdc));
        feeDistributor.addSupportedToken(address(usdt));
        console.log("- Reward tokens added to FeeDistributor");

        // 5. Grant VAULT_MANAGER_ROLE to VaultManager in LiquidityPool
        bytes32 VAULT_MANAGER_ROLE = liquidityPool.VAULT_MANAGER_ROLE();
        liquidityPool.grantRole(VAULT_MANAGER_ROLE, address(vaultManager));
        console.log("- VAULT_MANAGER_ROLE granted in LiquidityPool");

        // 6. Grant LIQUIDATOR_ROLE to LiquidationEngine in VaultManager
        bytes32 LIQUIDATOR_ROLE = vaultManager.LIQUIDATOR_ROLE();
        vaultManager.grantRole(LIQUIDATOR_ROLE, address(liquidationEngine));
        console.log("- LIQUIDATOR_ROLE granted to LiquidationEngine");

        // 7. Mint test tokens to deployer
        usdc.mint(deployer, USDC_MINT_AMOUNT);
        usdt.mint(deployer, USDT_MINT_AMOUNT);
        tgx.mint(deployer, TGX_MINT_AMOUNT);
        console.log("- Test tokens minted to deployer");

        console.log("");
        console.log("Configuration complete!");
        console.log("");

        // ============ FINAL OUTPUT ============
        console.log("=== MOCK TOKENS ===");
        console.log("USDC:", address(usdc));
        console.log("USDT:", address(usdt));
        console.log("TGX:", address(tgx));
        console.log("");
        console.log("=== CORE CONTRACTS ===");
        console.log("TGAUX:", address(tgaux));
        console.log("OracleAggregator:", address(oracle));
        console.log("LiquidityPool:", address(liquidityPool));
        console.log("InsuranceFund:", address(insuranceFund));
        console.log("FeeDistributor:", address(feeDistributor));
        console.log("VaultManager:", address(vaultManager));
        console.log("LiquidationEngine:", address(liquidationEngine));
        console.log("");
        console.log("=== CONFIGURATION ===");
        console.log("Gold Price: $2,847.00");
        console.log("MINTER_ROLE granted: YES");
        console.log("VAULT_MANAGER_ROLE granted: YES");
        console.log("LIQUIDATOR_ROLE granted: YES");
        console.log("Test tokens minted: YES");
        console.log("Deployer USDC balance: 1,000,000 USDC");
        console.log("Deployer USDT balance: 1,000,000 USDT");
        console.log("Deployer TGX balance: 1,000,000 TGX");
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Ready for testing!");
        console.log("");

        // Stop broadcasting
        vm.stopBroadcast();
    }
}
