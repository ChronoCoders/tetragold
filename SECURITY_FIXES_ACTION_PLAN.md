# Security Fixes Action Plan
**Tetra Gold Protocol**
**Date:** December 21, 2025

---

## Priority 1: MUST FIX (Before Production Deployment)

### ✅ Fix 1: Standardize Solidity Version to 0.8.30

**Impact:** Removes known compiler bugs, ensures consistency
**Effort:** Low (5 minutes)
**Risk:** None

**Files to Update:**
1. src/TGAUX.sol
2. src/OracleAggregator.sol
3. src/VaultManager.sol
4. src/LiquidityPool.sol
5. src/LiquidationEngine.sol
6. src/LPToken.sol
7. src/interfaces/AutomationCompatibleInterface.sol

**Change:**
```solidity
// FROM:
pragma solidity ^0.8.20;

// TO:
pragma solidity 0.8.30;
```

**Commands:**
```bash
# Find and replace
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/TGAUX.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/OracleAggregator.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/VaultManager.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/LiquidityPool.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/LiquidationEngine.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/LPToken.sol
sed -i 's/pragma solidity \^0\.8\.20;/pragma solidity 0.8.30;/g' src/interfaces/AutomationCompatibleInterface.sol

# Rebuild and test
forge build
forge test
```

---

### ✅ Fix 2: Add Zero-Address Validation in LiquidityPool

**Impact:** Prevents deployment errors
**Effort:** Low (2 minutes)
**Risk:** None

**File:** src/LiquidityPool.sol

**Current Code (Line 86-88):**
```solidity
constructor(address _usdc, address _usdt) {
    usdc = _usdc;
    usdt = _usdt;
```

**Fixed Code:**
```solidity
constructor(address _usdc, address _usdt) {
    if (_usdc == address(0)) revert LiquidityPool__ZeroAddress();
    if (_usdt == address(0)) revert LiquidityPool__ZeroAddress();
    usdc = _usdc;
    usdt = _usdt;
```

**Add Custom Error (Line ~40):**
```solidity
error LiquidityPool__ZeroAddress();
```

---

## Priority 2: SHOULD FIX (Code Quality & Best Practices)

### ✅ Fix 3: Add Interface Inheritance

**Impact:** Improved type safety and documentation
**Effort:** Medium (15 minutes)
**Risk:** Low

#### 3a. Define Interfaces

**Create:** src/interfaces/IInsuranceFund.sol
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IInsuranceFund {
    function depositFromFees(uint256 amount, address token) external;
    function depositFromLiquidation(uint256 amount, address token) external;
    function coverLoss(
        uint256 positionId,
        uint256 amount,
        address token,
        CoverageReason reason
    ) external returns (uint256);

    enum CoverageReason {
        LIQUIDATION_SHORTFALL,
        ORACLE_FAILURE,
        PROTOCOL_INSOLVENCY
    }
}
```

**Create:** src/interfaces/ILiquidityPool.sol
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILiquidityPool {
    enum PoolType {
        STABLE,
        AGGRESSIVE
    }

    function borrow(uint256 amount, address token) external returns (uint256);
    function repay(uint256 amount, address token) external returns (uint256);
    function getAvailableLiquidity(PoolType poolType) external view returns (uint256);
}
```

**Create:** src/interfaces/IVaultManager.sol
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IVaultManager {
    struct Position {
        address owner;
        uint256 collateralAmount;
        address collateralToken;
        uint256 tgauxMinted;
        uint256 borrowedAmount;
        uint256 leverage;
        uint256 openPrice;
        uint256 lastUpdateTimestamp;
        bool isActive;
    }

    function getPosition(uint256 positionId) external view returns (Position memory);
    function getPositionHealth(uint256 positionId) external view returns (uint256);
    function isLiquidatable(uint256 positionId) external view returns (bool);
    function liquidatePosition(uint256 positionId, uint256 percentage) external returns (uint256);
    function getActivePositionIds() external view returns (uint256[] memory);
}
```

#### 3b. Update Contract Declarations

**src/InsuranceFund.sol (Line 15):**
```solidity
// FROM:
contract InsuranceFund is AccessControl, Pausable, ReentrancyGuard {

// TO:
import "./interfaces/IInsuranceFund.sol";

contract InsuranceFund is IInsuranceFund, AccessControl, Pausable, ReentrancyGuard {
```

**src/LiquidityPool.sol (Line 15):**
```solidity
// FROM:
contract LiquidityPool is AccessControl, Pausable, ReentrancyGuard {

// TO:
import "./interfaces/ILiquidityPool.sol";

contract LiquidityPool is ILiquidityPool, AccessControl, Pausable, ReentrancyGuard {
```

**src/VaultManager.sol (Line 24):**
```solidity
// FROM:
contract VaultManager is AccessControl, Pausable, ReentrancyGuard {

// TO:
import "./interfaces/IVaultManager.sol";

contract VaultManager is IVaultManager, AccessControl, Pausable, ReentrancyGuard {
```

---

### ✅ Fix 4: Improve Constant Readability in TGAUX

**Impact:** Better code readability
**Effort:** Low (1 minute)
**Risk:** None

**File:** src/TGAUX.sol (Line 33)

**Current:**
```solidity
uint256 public constant MINIMUM_TRANSFER_AMOUNT = 32150000000000000;
```

**Improved:**
```solidity
/// @notice Minimum transfer amount (1 milligram of gold = 0.03215 TGAUX)
uint256 public constant MINIMUM_TRANSFER_AMOUNT = 32.15e15; // 32,150,000,000,000,000 wei
```

---

### ✅ Fix 5: Cache Array Lengths in FeeDistributor

**Impact:** Gas optimization (~3 gas per iteration)
**Effort:** Low (2 minutes)
**Risk:** None

**File:** src/FeeDistributor.sol

**Location 1: _updateRewards() (Line 228-246):**
```solidity
// FROM:
for (uint256 i = 0; i < supportedTokens.length; i++) {

// TO:
uint256 tokensLength = supportedTokens.length;
for (uint256 i = 0; i < tokensLength; i++) {
```

**Location 2: _resetDebt() (Line 258-264):**
```solidity
// FROM:
for (uint256 i = 0; i < supportedTokens.length; i++) {

// TO:
uint256 tokensLength = supportedTokens.length;
for (uint256 i = 0; i < tokensLength; i++) {
```

---

## Priority 3: OPTIONAL (Nice to Have)

### Fix 6: Refactor OracleAggregator._fetchOraclePrices()

**Impact:** Reduced complexity, improved maintainability
**Effort:** Medium (20 minutes)
**Risk:** Low (requires thorough testing)

**File:** src/OracleAggregator.sol

**Current:** Single function with complexity 13

**Refactored:**

```solidity
/**
 * @dev Fetch prices from all configured oracles
 */
function _fetchOraclePrices() internal view returns (
    uint256[3] memory prices,
    uint256[3] memory updatedAts,
    bool[3] memory validFlags
) {
    (prices[0], updatedAts[0], validFlags[0]) = _fetchChainlinkPrice();
    (prices[1], updatedAts[1], validFlags[1]) = _fetchBandPrice();
    (prices[2], updatedAts[2], validFlags[2]) = _fetchAPI3Price();
}

/**
 * @dev Fetch price from Chainlink oracle
 */
function _fetchChainlinkPrice() internal view returns (
    uint256 price,
    uint256 updatedAt,
    bool valid
) {
    if (chainlinkOracle == address(0)) return (0, 0, false);

    try IAggregatorV3(chainlinkOracle).latestRoundData() returns (
        uint80,
        int256 answer,
        uint256,
        uint256 _updatedAt,
        uint80
    ) {
        if (answer <= 0) return (0, 0, false);
        if (block.timestamp - _updatedAt > PRICE_STALENESS_THRESHOLD) {
            return (0, 0, false);
        }

        // Chainlink GOLD/USD is 8 decimals, normalize to 18
        uint256 normalizedPrice = uint256(answer) * 1e10;
        return (normalizedPrice, _updatedAt, true);
    } catch {
        return (0, 0, false);
    }
}

/**
 * @dev Fetch price from Band Protocol oracle
 */
function _fetchBandPrice() internal view returns (
    uint256 price,
    uint256 updatedAt,
    bool valid
) {
    if (bandOracle == address(0)) return (0, 0, false);

    try IBandOracle(bandOracle).getReferenceData("XAU", "USD") returns (
        IBandOracle.ReferenceData memory data
    ) {
        if (data.rate == 0) return (0, 0, false);
        if (block.timestamp - data.lastUpdatedBase > PRICE_STALENESS_THRESHOLD) {
            return (0, 0, false);
        }

        return (data.rate, data.lastUpdatedBase, true);
    } catch {
        return (0, 0, false);
    }
}

/**
 * @dev Fetch price from API3 oracle
 */
function _fetchAPI3Price() internal view returns (
    uint256 price,
    uint256 updatedAt,
    bool valid
) {
    if (api3Oracle == address(0)) return (0, 0, false);

    try IAPI3Oracle(api3Oracle).read() returns (int224 value, uint32 timestamp) {
        if (value <= 0) return (0, 0, false);
        if (block.timestamp - timestamp > PRICE_STALENESS_THRESHOLD) {
            return (0, 0, false);
        }

        return (uint256(uint224(value)), timestamp, true);
    } catch {
        return (0, 0, false);
    }
}
```

---

### Fix 7: Rename _liquidatePositionInternal

**Impact:** Naming convention compliance
**Effort:** Low (5 minutes)
**Risk:** Low (update all references)

**File:** src/LiquidationEngine.sol

**Change:**
```solidity
// FROM:
function _liquidatePositionInternal(uint256 positionId, address liquidator)

// TO:
function _internalLiquidatePosition(uint256 positionId, address liquidator)
```

**Update References:**
- Line 169: `this._internalLiquidatePosition(positionIds[i], msg.sender)`
- Line 281: `this._internalLiquidatePosition(positionIds[i], msg.sender)`
- Line 401: Declaration

---

## Implementation Checklist

### Phase 1: Critical Fixes (Required Before Deployment)
- [ ] Fix 1: Standardize Solidity version to 0.8.30
- [ ] Fix 2: Add zero-address validation in LiquidityPool
- [ ] Run full test suite: `forge test`
- [ ] Verify gas costs: `forge test --gas-report`
- [ ] Commit: "Security fixes: Standardize version, add zero-checks"

### Phase 2: Quality Improvements (Recommended)
- [ ] Fix 3: Add interface inheritance
- [ ] Fix 4: Improve constant readability
- [ ] Fix 5: Cache array lengths
- [ ] Run full test suite
- [ ] Commit: "Code quality improvements: Interfaces, readability, gas optimization"

### Phase 3: Optional Enhancements
- [ ] Fix 6: Refactor OracleAggregator (if time permits)
- [ ] Fix 7: Rename function for naming convention
- [ ] Run full test suite
- [ ] Commit: "Optional enhancements: Code refactoring"

### Phase 4: Final Verification
- [ ] Run Slither again: `slither . --exclude-dependencies`
- [ ] Verify 0 high/medium findings
- [ ] Confirm 242/242 tests passing
- [ ] Generate final audit report
- [ ] Tag release: `v1.0.0-audit-ready`

---

## Test Commands

```bash
# After each fix phase:
forge clean
forge build
forge test --summary

# Gas report
forge test --gas-report

# Re-run Slither
slither . --exclude-dependencies --print human-summary

# Coverage
forge coverage

# Specific contract tests
forge test --match-contract LiquidityPoolTest -vv
```

---

## Estimated Timeline

| Phase | Fixes | Time | Effort |
|-------|-------|------|--------|
| Phase 1 | Critical (1-2) | 10 min | Required |
| Phase 2 | Quality (3-5) | 30 min | Recommended |
| Phase 3 | Optional (6-7) | 30 min | Nice-to-have |
| Phase 4 | Verification | 15 min | Required |
| **TOTAL** | **7 fixes** | **~90 min** | **Professional** |

---

## Post-Fixes Checklist

### Before Professional Audit
- [ ] All Priority 1 fixes implemented
- [ ] All Priority 2 fixes implemented
- [ ] Full test suite passing (242/242)
- [ ] Gas optimizations reviewed
- [ ] Code documentation complete
- [ ] README updated
- [ ] Deployment scripts ready

### Professional Audit Preparation
- [ ] Engage Tier-1 audit firm (Consensys, Trail of Bits, OpenZeppelin)
- [ ] Provide complete codebase + tests
- [ ] Provide architecture documentation
- [ ] Provide threat model
- [ ] Set up communication channel

### Pre-Mainnet
- [ ] Professional audit complete
- [ ] All audit findings addressed
- [ ] Testnet deployment successful
- [ ] Multi-sig setup for admin functions
- [ ] Bug bounty program live
- [ ] Monitoring infrastructure ready
- [ ] Incident response plan documented

---

## Contact & Support

For questions or assistance with security fixes:
- Review: SECURITY_AUDIT_REPORT.md
- Tests: `forge test -vvv`
- Documentation: https://book.getfoundry.sh/

**Remember:** Security is a continuous process, not a one-time event!

---

**End of Action Plan**
