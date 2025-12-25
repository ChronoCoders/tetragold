#!/bin/bash

# Tetra Gold Local Deployment Script
# Deploys all contracts to Anvil local testnet

set -e

echo "🚀 Tetra Gold - Local Deployment Script"
echo "========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
RPC_URL="http://127.0.0.1:8545"
DEPLOYER_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Check if Anvil is running
echo -e "${BLUE}Checking Anvil connection...${NC}"
if ! curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" > /dev/null 2>&1; then
    echo -e "${RED}❌ Anvil is not running!${NC}"
    echo ""
    echo "Please start Anvil in a separate terminal:"
    echo -e "${YELLOW}  anvil${NC}"
    echo ""
    exit 1
fi
echo -e "${GREEN}✅ Anvil is running${NC}"
echo ""

# Check deployer balance
echo -e "${BLUE}Checking deployer balance...${NC}"
BALANCE=$(cast balance $DEPLOYER_ADDRESS --rpc-url $RPC_URL)
echo -e "${GREEN}✅ Deployer balance: $BALANCE wei${NC}"
echo ""

# Clean previous deployment artifacts
echo -e "${BLUE}Cleaning previous artifacts...${NC}"
rm -rf broadcast/DeployLocal.s.sol/
rm -rf out/
echo -e "${GREEN}✅ Cleaned${NC}"
echo ""

# Build contracts
echo -e "${BLUE}Building contracts...${NC}"
forge build
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Build successful${NC}"
echo ""

# Deploy contracts
echo -e "${BLUE}Deploying contracts to Anvil...${NC}"
echo ""
forge script script/DeployLocal.s.sol \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvv

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}❌ Deployment failed!${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""

# Extract deployed addresses from broadcast file
BROADCAST_FILE="broadcast/DeployLocal.s.sol/31337/run-latest.json"

if [ -f "$BROADCAST_FILE" ]; then
    echo -e "${BLUE}📋 Deployed Contract Addresses:${NC}"
    echo ""

    # Parse addresses using jq if available
    if command -v jq &> /dev/null; then
        USDC=$(jq -r '.transactions[] | select(.contractName == "MockERC20" and .arguments[0] == "USD Coin") | .contractAddress' $BROADCAST_FILE | head -1)
        USDT=$(jq -r '.transactions[] | select(.contractName == "MockERC20" and .arguments[0] == "Tether USD") | .contractAddress' $BROADCAST_FILE | head -1)
        TGX=$(jq -r '.transactions[] | select(.contractName == "MockERC20" and .arguments[0] == "Tetra Gold Governance") | .contractAddress' $BROADCAST_FILE | head -1)
        TGAUX=$(jq -r '.transactions[] | select(.contractName == "TGAUX") | .contractAddress' $BROADCAST_FILE | head -1)
        ORACLE=$(jq -r '.transactions[] | select(.contractName == "OracleAggregator") | .contractAddress' $BROADCAST_FILE | head -1)
        LIQUIDITY_POOL=$(jq -r '.transactions[] | select(.contractName == "LiquidityPool") | .contractAddress' $BROADCAST_FILE | head -1)
        INSURANCE_FUND=$(jq -r '.transactions[] | select(.contractName == "InsuranceFund") | .contractAddress' $BROADCAST_FILE | head -1)
        FEE_DISTRIBUTOR=$(jq -r '.transactions[] | select(.contractName == "FeeDistributor") | .contractAddress' $BROADCAST_FILE | head -1)
        VAULT_MANAGER=$(jq -r '.transactions[] | select(.contractName == "VaultManager") | .contractAddress' $BROADCAST_FILE | head -1)
        LIQUIDATION_ENGINE=$(jq -r '.transactions[] | select(.contractName == "LiquidationEngine") | .contractAddress' $BROADCAST_FILE | head -1)

        echo "Mock Tokens:"
        echo "  USDC:              $USDC"
        echo "  USDT:              $USDT"
        echo "  TGX:               $TGX"
        echo ""
        echo "Core Contracts:"
        echo "  TGAUX:             $TGAUX"
        echo "  OracleAggregator:  $ORACLE"
        echo "  LiquidityPool:     $LIQUIDITY_POOL"
        echo "  InsuranceFund:     $INSURANCE_FUND"
        echo "  FeeDistributor:    $FEE_DISTRIBUTOR"
        echo "  VaultManager:      $VAULT_MANAGER"
        echo "  LiquidationEngine: $LIQUIDATION_ENGINE"
        echo ""

        # Save addresses to file
        cat > .deployed-addresses.env <<EOF
# Tetra Gold - Deployed Addresses (Anvil Local Testnet)
# Generated: $(date)

# Mock Tokens
USDC_ADDRESS=$USDC
USDT_ADDRESS=$USDT
TGX_ADDRESS=$TGX

# Core Contracts
TGAUX_ADDRESS=$TGAUX
ORACLE_AGGREGATOR_ADDRESS=$ORACLE
LIQUIDITY_POOL_ADDRESS=$LIQUIDITY_POOL
INSURANCE_FUND_ADDRESS=$INSURANCE_FUND
FEE_DISTRIBUTOR_ADDRESS=$FEE_DISTRIBUTOR
VAULT_MANAGER_ADDRESS=$VAULT_MANAGER
LIQUIDATION_ENGINE_ADDRESS=$LIQUIDATION_ENGINE

# Network Configuration
RPC_URL=$RPC_URL
DEPLOYER_ADDRESS=$DEPLOYER_ADDRESS
EOF

        echo -e "${GREEN}✅ Addresses saved to .deployed-addresses.env${NC}"
        echo ""
    fi
fi

# Verification commands
echo -e "${YELLOW}📝 Verification Commands:${NC}"
echo ""
echo "Check TGAUX total supply:"
echo -e "${BLUE}  cast call \$TGAUX_ADDRESS \"totalSupply()\" --rpc-url $RPC_URL${NC}"
echo ""
echo "Check oracle gold price:"
echo -e "${BLUE}  cast call \$ORACLE_AGGREGATOR_ADDRESS \"getGoldPrice()\" --rpc-url $RPC_URL${NC}"
echo ""
echo "Check deployer USDC balance:"
echo -e "${BLUE}  cast call \$USDC_ADDRESS \"balanceOf(address)(uint256)\" $DEPLOYER_ADDRESS --rpc-url $RPC_URL${NC}"
echo ""
echo "Check VaultManager has MINTER_ROLE:"
echo -e "${BLUE}  cast call \$TGAUX_ADDRESS \"hasRole(bytes32,address)(bool)\" \$(cast keccak \"MINTER_ROLE()\") \$VAULT_MANAGER_ADDRESS --rpc-url $RPC_URL${NC}"
echo ""

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}🎉 Ready for testing!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Source the addresses: ${YELLOW}source .deployed-addresses.env${NC}"
echo "2. Run integration tests: ${YELLOW}forge test${NC}"
echo "3. Interact with contracts using cast commands"
echo ""
