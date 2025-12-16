# Tetra Gold (TGAUX) Token

ERC-20 token implementation for the Tetra Gold protocol, representing ownership of physical gold.

## Overview

TGAUX is a gold-backed token where:
- **1 TGAUX = 1 troy ounce of gold = 31.1035 grams**
- **Minimum transferable amount: 0.03215 TGAUX** (approximately 1 gram)

## Features

- ✅ ERC-20 standard compliant with 18 decimals
- ✅ Dynamic supply (minted on-demand by authorized VaultManager)
- ✅ Burnable (users can burn their own tokens)
- ✅ Pausable (emergency stop functionality)
- ✅ Non-upgradeable (immutable for security)
- ✅ Access control using OpenZeppelin's AccessControl
- ✅ Custom events for minting and burning

## Technical Specifications

### Token Details
- **Name**: Tetra Gold
- **Symbol**: TGAUX
- **Decimals**: 18
- **Initial Supply**: 0 (dynamic minting)

### Roles
- **DEFAULT_ADMIN_ROLE**: Can grant/revoke other roles
- **MINTER_ROLE**: Can mint new tokens (typically assigned to VaultManager)
- **PAUSER_ROLE**: Can pause/unpause token transfers

### Key Constants
- `MINIMUM_TRANSFER_AMOUNT`: 32150000000000000 wei (0.03215 TGAUX)

## Project Structure

```
tetragold/
├── src/
│   └── TGAUX.sol              # Main token contract
├── test/
│   └── TGAUX.t.sol            # Comprehensive test suite
├── script/
│   └── DeployTGAUX.s.sol      # Deployment script
├── lib/                       # Dependencies (OpenZeppelin)
└── foundry.toml               # Foundry configuration
```

## Dependencies

- **OpenZeppelin Contracts v5.0.0**
  - ERC20
  - ERC20Burnable
  - ERC20Pausable
  - AccessControl
- **Foundry** (Forge, Cast, Anvil)

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd tetragold
```

2. Install Foundry (if not already installed):
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

3. Install dependencies:
```bash
forge install
```

## Testing

The test suite includes comprehensive coverage of:
- ✅ Constructor and initialization
- ✅ Minting by authorized addresses
- ✅ Burning by token holders
- ✅ Transfer restrictions (minimum amount, pause)
- ✅ Access control enforcement
- ✅ Decimal precision handling
- ✅ ERC-20 standard compliance
- ✅ Integration workflows
- ✅ Fuzz testing

Run tests:
```bash
forge test
```

Run tests with verbosity:
```bash
forge test -vvv
```

Run tests with gas reporting:
```bash
forge test --gas-report
```

Run coverage:
```bash
forge coverage
```

## Deployment

### Local/Testnet Deployment

1. Set environment variables:
```bash
export DEPLOYER_PRIVATE_KEY=<your-private-key>
export DEFAULT_ADMIN=<admin-address>
export VAULT_MANAGER=<vault-manager-address>  # Optional
```

2. Deploy to testnet:
```bash
forge script script/DeployTGAUX.s.sol:DeployTGAUX \
    --rpc-url <RPC_URL> \
    --broadcast \
    --verify
```

### Mainnet Deployment

For mainnet deployment, ensure:
- Thorough testing on testnets
- Security audit completion
- Multi-sig setup for admin roles
- Proper key management

```bash
forge script script/DeployTGAUX.s.sol:DeployTGAUX \
    --rpc-url <MAINNET_RPC_URL> \
    --broadcast \
    --verify \
    --slow
```

## Usage

### Minting Tokens (VaultManager only)

```solidity
// After deployment, grant MINTER_ROLE to VaultManager
token.grantRole(MINTER_ROLE, vaultManagerAddress);

// Mint tokens
token.mint(userAddress, amount);  // amount >= 0.03215 TGAUX
```

### Burning Tokens

```solidity
// Users can burn their own tokens
token.burn(amount);

// Or burn with allowance
token.burnFrom(account, amount);
```

### Pausing (Emergency)

```solidity
// Pause all transfers
token.pause();

// Unpause when safe
token.unpause();
```

## Security Considerations

1. **Non-Upgradeable**: Contract is immutable once deployed
2. **Access Control**: Critical functions protected by role-based access
3. **Pausable**: Emergency stop mechanism for security incidents
4. **Minimum Transfer**: Enforced to maintain gold gram equivalency
5. **OpenZeppelin**: Battle-tested implementations

## Contract Verification

After deployment, verify the contract on block explorers:

```bash
forge verify-contract \
    --chain-id <CHAIN_ID> \
    --compiler-version v0.8.20 \
    <CONTRACT_ADDRESS> \
    src/TGAUX.sol:TGAUX
```

## Gas Optimization

The contract is optimized with:
- Compiler optimization enabled (200 runs)
- Efficient storage layout
- Minimal external calls
- OpenZeppelin's gas-optimized implementations

## License

MIT License - See LICENSE file for details

## Audit Status

⚠️ **This contract should be audited before mainnet deployment**

Recommended audit focus areas:
- Access control implementation
- Mint/burn mechanics
- Pause functionality
- Minimum transfer enforcement
- Integration with VaultManager

## Development

### Build
```bash
forge build
```

### Test
```bash
forge test
```

### Format
```bash
forge fmt
```

### Gas Snapshots
```bash
forge snapshot
```

### Static Analysis
```bash
slither src/TGAUX.sol
```

## Support

For issues, questions, or contributions, please open an issue or pull request on the repository.

## Additional Resources

- [OpenZeppelin Documentation](https://docs.openzeppelin.com/)
- [Foundry Book](https://book.getfoundry.sh/)
- [ERC-20 Token Standard](https://eips.ethereum.org/EIPS/eip-20)
