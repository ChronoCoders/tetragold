# Tetra Gold Protocol

A decentralized synthetic derivatives protocol that provides leveraged exposure to the gold (XAU/USD) spot price. Users deposit stablecoin collateral to mint TGAUX - a synthetic token that tracks gold price movements - at up to 10x leverage, backed by on-chain liquidity pools, automated liquidations, and a protocol-owned insurance reserve.

## Architecture

```
tetragold/
├── src/
│   ├── TGAUX.sol                           # Synthetic gold price token (ERC-20)
│   ├── VaultManager.sol                    # Position lifecycle and collateral management
│   ├── LiquidityPool.sol                   # Two-pool LP system (conservative / aggressive)
│   ├── LiquidationEngine.sol               # Chainlink Automation-powered liquidations
│   ├── OracleAggregator.sol                # Multi-source TWAP oracle (Chainlink, Band, API3)
│   ├── InsuranceFund.sol                   # Bad debt coverage with Aave yield generation
│   ├── FeeDistributor.sol                  # Protocol revenue distribution
│   ├── LPToken.sol                         # ERC-20 LP share token
│   └── interfaces/
│       └── AutomationCompatibleInterface.sol
├── test/
│   ├── TGAUX.t.sol
│   ├── VaultManager.t.sol
│   ├── LiquidityPool.t.sol
│   ├── LiquidationEngine.t.sol
│   ├── OracleAggregator.t.sol
│   ├── InsuranceFund.t.sol
│   ├── FeeDistributor.t.sol
│   └── mocks/
├── script/
│   ├── DeployTGAUX.s.sol
│   └── DeployLocal.s.sol
├── foundry.toml
└── lib/
```

## Protocol Overview

### TGAUX Token

TGAUX is a synthetic ERC-20 token where 1 TGAUX represents 1 troy ounce of gold at the current XAU/USD spot price. It is not backed by or redeemable for physical gold; it tracks the gold price through the oracle system. Token supply is dynamic - minted when positions are opened and burned when positions are closed.

| Property | Value |
|---|---|
| Name | Tetra Gold |
| Symbol | TGAUX |
| Decimals | 18 |
| Minimum transfer | 0.03215 TGAUX |
| Initial supply | 0 (dynamic) |

### VaultManager

The core contract for opening and managing leveraged positions. Users deposit USDC or USDT as collateral, select a leverage tier, and receive TGAUX proportional to the notional value of their position.

**Supported leverage tiers:**

| Leverage | Min Collateral Ratio | Liquidation Ratio |
|---|---|---|
| 1x | 150% | 125% |
| 2x | 100% | 90% |
| 3x | 50% | 45% |
| 5x | 25% | 22.5% |
| 10x | 11.1% | 10% |

**Protocol fees:**
- Opening fee (no leverage): 0.1%
- Opening fee (leveraged): 0.2%
- Closing fee: 0.15%
- Borrowing rate: 0.05% per day (18.25% APR)

### LiquidityPool

A dual-pool system that funds leveraged positions by lending collateral to the VaultManager.

- **Conservative pool** - lower-risk LP exposure, preferred for borrow selection
- **Aggressive pool** - higher-risk/reward LP exposure, secondary borrow source

LP token price appreciates as borrowing interest accrues. The interest rate model uses a kinked curve with an 80% optimal utilization target.

### OracleAggregator

Aggregates gold price data from three independent oracle sources with manipulation resistance:

- **Chainlink** AggregatorV3 (XAU/USD)
- **Band Protocol** reference data
- **API3** data feed

Price logic:
- Prices normalized to 8 decimal precision
- If deviation between sources exceeds 2%, the median is used instead of the average
- TWAP calculated over a 10-minute rolling window
- Prices older than 2 hours are treated as stale and rejected
- Circuit breaker pauses the system if any single update moves price more than 5%

### LiquidationEngine

Automates partial liquidations of undercollateralized positions using Chainlink Automation.

- Positions are liquidated in 25% tranches (up to 4 tranches = full liquidation)
- A 10-minute grace period follows marking before liquidation can execute
- Penalty distribution: 50% liquidator, 30% insurance fund, 20% treasury
- `checkUpkeep` / `performUpkeep` implement the Chainlink Automation interface

### InsuranceFund

Accumulates protocol reserves to cover bad debt from failed liquidations and other loss events.

- Funded by 30% of protocol fees and 30% of liquidation penalties
- Idle reserves deployed to Aave v3 for yield generation
- Default target: 50% of reserves deployed, 50% liquid
- Target reserve size: 1.5% of protocol TVL; minimum: 0.5%
- Coverage events recorded on-chain with reason classification

### FeeDistributor

Collects fees from the VaultManager and distributes them according to fixed allocations:

| Recipient | Share |
|---|---|
| Insurance Fund | 30% |
| Treasury | 40% |
| TGX Stakers | 30% |

TGX stakers earn a pro-rata share of staker fees using a MasterChef-style reward accounting model. Rewards accumulate per supported token and can be claimed at any time.

## Dependencies

- **[OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts)** - ERC-20, AccessControl, Pausable, ReentrancyGuard, SafeERC20
- **[Foundry](https://github.com/foundry-rs/foundry)** - Forge, Cast, Anvil
- **Solidity 0.8.30**

## Installation

```bash
git clone https://github.com/ChronoCoders/tetragold.git
cd tetragold

# Install Foundry if needed
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install
```

## Testing

```bash
# Run full test suite
forge test

# Run with verbose output
forge test -vvv

# Run a specific contract's tests
forge test --match-contract VaultManagerTest

# Gas report
forge test --gas-report

# Coverage
forge coverage
```

**Test suite:** 333 tests across 12 contract test suites, including unit tests, integration tests, and fuzz tests.

## Deployment

### Environment Variables

```bash
export DEPLOYER_PRIVATE_KEY=<deployer-private-key>
export DEFAULT_ADMIN=<admin-multisig-address>
export VAULT_MANAGER=<vault-manager-address>   # optional - grants MINTER_ROLE at deploy
```

### Deploy TGAUX Token

```bash
forge script script/DeployTGAUX.s.sol:DeployTGAUX \
    --rpc-url <RPC_URL> \
    --broadcast \
    --verify
```

### Post-Deployment Role Setup

After deploying all contracts, the following roles must be configured:

| Contract | Role | Grantee |
|---|---|---|
| TGAUX | `MINTER_ROLE` | VaultManager |
| LiquidityPool | `VAULT_MANAGER_ROLE` | VaultManager |
| VaultManager | `LIQUIDATOR_ROLE` | LiquidationEngine |
| InsuranceFund | `VAULT_MANAGER_ROLE` | FeeDistributor |
| InsuranceFund | `LIQUIDATION_ENGINE_ROLE` | LiquidationEngine |
| InsuranceFund | `COVERAGE_MANAGER_ROLE` | Admin multisig |

## Access Control

All contracts use OpenZeppelin's `AccessControl`. The `DEFAULT_ADMIN_ROLE` cannot be renounced - a guard prevents it to avoid permanently locking out governance.

| Role | Holder | Permissions |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Admin multisig | Grant/revoke all roles |
| `MINTER_ROLE` | VaultManager | Mint TGAUX |
| `PAUSER_ROLE` | Admin multisig | Pause token transfers |
| `LIQUIDATOR_ROLE` | LiquidationEngine | Execute liquidations |
| `FEE_COLLECTOR_ROLE` | FeeDistributor | Withdraw collected fees |
| `VAULT_MANAGER_ROLE` | VaultManager | Borrow/repay from LiquidityPool |

## Security Properties

- **Non-upgradeable** - all contracts are immutable once deployed
- **Reentrancy protection** - `ReentrancyGuard` on all state-mutating external functions
- **Emergency pause** - all critical paths respect the `whenNotPaused` modifier
- **Oracle circuit breaker** - system pauses automatically on abnormal price movement
- **Partial liquidations** - 25% tranches reduce the impact of sudden position closures
- **Grace period** - 10-minute window between marking and liquidation, allowing self-remediation; marks expire after 1 hour and require re-marking (fresh grace period) so recovered-then-relapsed positions are never liquidated instantly
- **SafeERC20** - all token transfers use OZ's safe wrappers

## Operations Runbook: Oracle Liveness

The protocol deliberately chooses safety over liveness: positions are never priced against stale or untrusted data, which means oracle disruptions halt user flows. Operators must understand and monitor the following:

### Halt conditions

| Condition | Trigger | Effect |
|---|---|---|
| Circuit breaker | Any single `updateTwap()` moves the price > 5% | OracleAggregator pauses itself; `getGoldPrice()` reverts; **all** open/close/liquidation flows halt |
| Stale price | No successful `updateTwap()` for 2 hours (`MAX_PRICE_AGE`) | `getGoldPrice()` reverts; same system-wide halt |
| Insufficient sources | Fewer than 2 of 3 oracle feeds valid | `updateTwap()` reverts; price ages toward staleness |

Note: a halt blocks `closePosition()` too - users cannot exit positions until the oracle recovers. Interest continues to accrue during a halt. Minimize downtime.

### Keeper requirements

- `updateTwap()` must be called at least every 2 hours; recommended cadence is every 5-10 minutes (minimum interval between updates is 60 seconds)
- Run at least two independent keepers (e.g., Chainlink Automation + an in-house bot) so a single keeper failure cannot stale the price
- Alert if `block.timestamp - lastUpdateTime` exceeds 30 minutes - that leaves 90 minutes to remediate before the protocol halts

### Recovery procedure (circuit breaker pause)

1. Verify the price movement was genuine (compare Chainlink/Band/API3 against off-chain reference prices)
2. If genuine: admin multisig calls `unpause()` on OracleAggregator; the next `updateTwap()` re-seeds from current feeds. Expect a wave of liquidations - the auto-mark pass grants every affected position a 10-minute grace period first
3. If a feed malfunctioned: call `updateOracleAddress()` to replace the faulty feed before unpausing
4. After unpausing, confirm `updateTwap()` succeeds and `getGoldPrice()` returns a fresh price before announcing recovery

## Build

```bash
forge build
forge fmt
forge snapshot
```

## License

MIT
