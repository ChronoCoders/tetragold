// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TGAUX} from "../src/TGAUX.sol";

/**
 * @title DeployTGAUX
 * @dev Deployment script for TGAUX token
 *
 * Usage:
 * forge script script/DeployTGAUX.s.sol:DeployTGAUX --rpc-url <RPC_URL> --broadcast --verify
 *
 * Environment variables:
 * - DEPLOYER_PRIVATE_KEY: Private key of the deployer account
 * - DEFAULT_ADMIN: Address to receive DEFAULT_ADMIN_ROLE and PAUSER_ROLE
 * - VAULT_MANAGER: (Optional) Address to receive MINTER_ROLE
 */
contract DeployTGAUX is Script {
    function run() external {
        // Get deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Get default admin address (required)
        address defaultAdmin = vm.envAddress("DEFAULT_ADMIN");
        require(defaultAdmin != address(0), "DEFAULT_ADMIN not set");

        // Get vault manager address (optional)
        address vaultManager;
        try vm.envAddress("VAULT_MANAGER") returns (address _vaultManager) {
            vaultManager = _vaultManager;
        } catch {
            vaultManager = address(0);
        }

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy TGAUX token
        TGAUX tgaux = new TGAUX(defaultAdmin);
        console.log("TGAUX deployed at:", address(tgaux));
        console.log("Default admin:", defaultAdmin);

        // Grant MINTER_ROLE to VaultManager if specified
        if (vaultManager != address(0)) {
            tgaux.grantRole(tgaux.MINTER_ROLE(), vaultManager);
            console.log("MINTER_ROLE granted to VaultManager:", vaultManager);
        } else {
            console.log("No VaultManager specified - MINTER_ROLE not granted");
            console.log("Grant MINTER_ROLE manually using:");
            console.log("  tgaux.grantRole(MINTER_ROLE, <vault_manager_address>)");
        }

        vm.stopBroadcast();

        // Output deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Token Name:", tgaux.name());
        console.log("Token Symbol:", tgaux.symbol());
        console.log("Decimals:", tgaux.decimals());
        console.log("Minimum Transfer Amount:", tgaux.MINIMUM_TRANSFER_AMOUNT());
        console.log("Total Supply:", tgaux.totalSupply());
    }
}
