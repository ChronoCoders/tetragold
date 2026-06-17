// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {TGAUX} from "../src/TGAUX.sol";
import {VaultManager} from "../src/VaultManager.sol";
import {OracleAggregator} from "../src/OracleAggregator.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {LiquidationEngine} from "../src/LiquidationEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {MockLiquidityPool} from "./mocks/MockLiquidityPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal insurance sink for the LiquidationEngine penalty split
contract InsuranceSink {
    function depositFromLiquidation(uint256 amount, address token) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

/**
 * @title VaultHandler
 * @dev Bounded-action handler for invariant testing. Owns all positions it
 *      opens, drives the oracle within circuit breaker limits, and exercises
 *      open / close / addCollateral / partial+full liquidation paths.
 */
contract VaultHandler is Test {
    VaultManager public immutable vault;
    TGAUX public immutable tgaux;
    MockERC20 public immutable usdc;
    OracleAggregator public immutable oracle;
    MockChainlinkOracle public immutable chainlinkOracle;
    MockBandOracle public immutable bandOracle;
    MockAPI3Oracle public immutable api3Oracle;

    uint256 public currentPrice;
    uint256[] public openIds;

    // Ghost totals for fee conservation checks
    uint256 public ghostFeesCollected;

    constructor(
        VaultManager _vault,
        TGAUX _tgaux,
        MockERC20 _usdc,
        OracleAggregator _oracle,
        MockChainlinkOracle _chainlink,
        MockBandOracle _band,
        MockAPI3Oracle _api3,
        uint256 _startPrice
    ) {
        vault = _vault;
        tgaux = _tgaux;
        usdc = _usdc;
        oracle = _oracle;
        chainlinkOracle = _chainlink;
        bandOracle = _band;
        api3Oracle = _api3;
        currentPrice = _startPrice;

        tgaux.approve(address(vault), type(uint256).max);
    }

    /* ============ Actions ============ */

    function openPosition(uint256 collateral, uint256 leverageSeed) external {
        uint256[5] memory tiers = [uint256(1), 2, 3, 5, 10];
        uint256 leverage = tiers[leverageSeed % 5];
        collateral = bound(collateral, 100e6, 5_000e6);

        _refreshOracle(currentPrice);

        usdc.mint(address(this), collateral);
        usdc.approve(address(vault), collateral);
        vault.openPosition(collateral, leverage, address(usdc));
        openIds.push(vault.nextPositionId() - 1);
    }

    function closePosition(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);

        VaultManager.Position memory position = vault.getPosition(positionId);
        // Interest is paid from collateral; skip if it would underflow the close path
        uint256 interest = vault.calculateInterest(positionId);
        if (interest >= position.collateralAmount) return;

        vault.closePosition(positionId);
    }

    function addCollateral(uint256 idSeed, uint256 amount) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;
        amount = bound(amount, 1e6, 1_000e6);

        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.addCollateral(positionId, amount);
    }

    function movePrice(uint256 pctSeed, bool up) external {
        // Move up to 4% per step, within the 5% circuit breaker
        uint256 pctBps = bound(pctSeed, 0, 400);
        uint256 newPrice = up ? currentPrice * (10_000 + pctBps) / 10_000 : currentPrice * (10_000 - pctBps) / 10_000;
        // Keep price in a sane band to avoid degenerate positions
        if (newPrice < 500e8 || newPrice > 10_000e8) return;

        currentPrice = newPrice;
        _refreshOracle(currentPrice);
    }

    function liquidatePartial(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        if (!vault.isLiquidatable(positionId)) return;

        uint256 feesBefore = vault.collectedFees(address(usdc));
        uint256 penalty = vault.liquidatePosition(positionId, 2500);
        ghostFeesCollected += vault.collectedFees(address(usdc)) - feesBefore;
        // Penalty is transferred out to the caller (this handler plays engine)
        penalty; // silence unused
    }

    function liquidateFull(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        if (!vault.isLiquidatable(positionId)) return;

        vault.liquidate(positionId);
    }

    function warpTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 3 days));
        _refreshOracle(currentPrice);
    }

    /* ============ Helpers ============ */

    function _pickActive(uint256 seed) internal view returns (uint256) {
        uint256 count = vault.activePositionCount();
        if (count == 0) return 0;
        (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
        return ids[seed % ids.length];
    }

    function _refreshOracle(uint256 price) internal {
        // Advance past the min update interval and refresh all feeds so the
        // aggregated price is never stale during a run
        vm.warp(block.timestamp + 601);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(price));
        bandOracle.setReferenceData(price * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(price * 1e10)));
        oracle.updateTwap();
    }
}

/**
 * @title InvariantTest
 * @dev Protocol-level invariants over randomized open/close/liquidate sequences:
 *      pool borrow accounting, TVL accounting, and TGAUX supply backing.
 */
contract InvariantTest is Test {
    VaultManager public vault;
    TGAUX public tgaux;
    OracleAggregator public oracle;
    MockLiquidityPool public pool;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockChainlinkOracle public chainlinkOracle;
    MockBandOracle public bandOracle;
    MockAPI3Oracle public api3Oracle;
    VaultHandler public handler;

    address public admin = makeAddr("admin");
    uint256 public constant GOLD_PRICE = 2_000e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        vm.prank(admin);
        tgaux = new TGAUX(admin);

        chainlinkOracle = new MockChainlinkOracle(8);
        bandOracle = new MockBandOracle();
        api3Oracle = new MockAPI3Oracle();
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        vm.prank(admin);
        oracle = new OracleAggregator(admin, address(chainlinkOracle), address(bandOracle), address(api3Oracle));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        pool = new MockLiquidityPool();
        usdc.mint(address(pool), 100_000_000e6);

        vm.prank(admin);
        vault = new VaultManager(admin, address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));

        handler = new VaultHandler(vault, tgaux, usdc, oracle, chainlinkOracle, bandOracle, api3Oracle, GOLD_PRICE);

        vm.startPrank(admin);
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vault));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @dev Pool borrow accounting: the pool's outstanding borrowed total must
    ///      equal the sum of borrowedAmount across all active positions
    ///      (C-01 class of bugs: raw transfers bypassing repay would break this)
    function invariant_PoolBorrowedMatchesActivePositions() public view {
        uint256 count = vault.activePositionCount();
        uint256 sumBorrowed = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                sumBorrowed += vault.getPosition(ids[i]).borrowedAmount;
            }
        }
        assertEq(pool.totalBorrowed(address(usdc)), sumBorrowed);
    }

    /// @dev TVL accounting: totalValueLocked must equal the sum of
    ///      collateralAmount across all active positions
    function invariant_TvlMatchesActiveCollateral() public view {
        uint256 count = vault.activePositionCount();
        uint256 sumCollateral = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                sumCollateral += vault.getPosition(ids[i]).collateralAmount;
            }
        }
        assertEq(vault.totalValueLocked(), sumCollateral);
    }

    /// @dev Supply backing: TGAUX total supply must equal the sum of
    ///      tgauxMinted across active positions (mint on open, burn on
    ///      close/liquidation, nothing else)
    function invariant_TgauxSupplyMatchesActivePositions() public view {
        uint256 count = vault.activePositionCount();
        uint256 sumMinted = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                sumMinted += vault.getPosition(ids[i]).tgauxMinted;
            }
        }
        assertEq(tgaux.totalSupply(), sumMinted);
    }

    /// @dev Solvency: the vault's USDC balance must cover all active
    ///      collateral plus borrowed principal held plus uncollected fees
    function invariant_VaultSolvency() public view {
        uint256 count = vault.activePositionCount();
        uint256 owedToPositions = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                VaultManager.Position memory position = vault.getPosition(ids[i]);
                owedToPositions += position.collateralAmount + position.borrowedAmount;
            }
        }
        assertGe(usdc.balanceOf(address(vault)) + 1, owedToPositions + vault.collectedFees(address(usdc)));
    }
}

/**
 * @title RealPoolHandler
 * @dev Like VaultHandler, but wired to the REAL LiquidityPool (dual-pool
 *      routing, interest crediting) and the REAL LiquidationEngine (mark /
 *      grace / tranche state machine). CONSERVATIVE is seeded thin so borrows
 *      regularly spill into AGGRESSIVE — exercising cross-pool repay routing.
 */
contract RealPoolHandler is Test {
    VaultManager public immutable vault;
    TGAUX public immutable tgaux;
    MockERC20 public immutable usdc;
    OracleAggregator public immutable oracle;
    LiquidityPool public immutable pool;
    LiquidationEngine public immutable engine;
    MockChainlinkOracle public immutable chainlinkOracle;
    MockBandOracle public immutable bandOracle;
    MockAPI3Oracle public immutable api3Oracle;

    uint256 public currentPrice;

    constructor(
        VaultManager _vault,
        TGAUX _tgaux,
        MockERC20 _usdc,
        OracleAggregator _oracle,
        LiquidityPool _pool,
        LiquidationEngine _engine,
        MockChainlinkOracle _chainlink,
        MockBandOracle _band,
        MockAPI3Oracle _api3,
        uint256 _startPrice
    ) {
        vault = _vault;
        tgaux = _tgaux;
        usdc = _usdc;
        oracle = _oracle;
        pool = _pool;
        engine = _engine;
        chainlinkOracle = _chainlink;
        bandOracle = _band;
        api3Oracle = _api3;
        currentPrice = _startPrice;

        tgaux.approve(address(vault), type(uint256).max);

        // Seed pools: thin CONSERVATIVE, deep AGGRESSIVE, so the same token is
        // routinely borrowed from BOTH pools
        usdc.mint(address(this), 5_030_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositLP(30_000e6, LiquidityPool.PoolType.CONSERVATIVE, address(usdc));
        pool.depositLP(5_000_000e6, LiquidityPool.PoolType.AGGRESSIVE, address(usdc));
    }

    /* ============ Actions ============ */

    function openPosition(uint256 collateral, uint256 leverageSeed) external {
        uint256[5] memory tiers = [uint256(1), 2, 3, 5, 10];
        uint256 leverage = tiers[leverageSeed % 5];
        collateral = bound(collateral, 100e6, 5_000e6);

        _refreshOracle(currentPrice);

        usdc.mint(address(this), collateral);
        usdc.approve(address(vault), collateral);
        vault.openPosition(collateral, leverage, address(usdc));
    }

    function closePosition(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        vault.closePosition(positionId);
    }

    function addCollateral(uint256 idSeed, uint256 amount) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;
        amount = bound(amount, 1e6, 1_000e6);

        usdc.mint(address(this), amount);
        usdc.approve(address(vault), amount);
        vault.addCollateral(positionId, amount);
    }

    function depositLP(uint256 amount, bool aggressive) external {
        amount = bound(amount, 100e6, 50_000e6);
        usdc.mint(address(this), amount);
        pool.depositLP(
            amount, aggressive ? LiquidityPool.PoolType.AGGRESSIVE : LiquidityPool.PoolType.CONSERVATIVE, address(usdc)
        );
    }

    function movePrice(uint256 pctSeed, bool up) external {
        uint256 pctBps = bound(pctSeed, 0, 400);
        uint256 newPrice = up ? currentPrice * (10_000 + pctBps) / 10_000 : currentPrice * (10_000 - pctBps) / 10_000;
        if (newPrice < 500e8 || newPrice > 10_000e8) return;

        currentPrice = newPrice;
        _refreshOracle(currentPrice);
    }

    /// @dev Drive the engine through its full mark -> grace -> tranche flow
    function engineLiquidate(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        if (!vault.isLiquidatable(positionId)) return;

        // First call: auto-mark (or liquidate if a previous mark matured)
        try engine.liquidatePosition(positionId) {} catch {}

        // Pass the grace period and try the tranche
        vm.warp(block.timestamp + 11 minutes);
        _refreshOracle(currentPrice);
        if (!vault.isLiquidatable(positionId)) return;
        try engine.liquidatePosition(positionId) {} catch {}
    }

    /// @dev Clear a recovered position's stale mark (keeper hygiene sweep)
    function clearMark(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        if (vault.isLiquidatable(positionId)) return;
        try engine.clearMark(positionId) {} catch {}
    }

    function liquidateFull(uint256 idSeed) external {
        uint256 positionId = _pickActive(idSeed);
        if (positionId == 0) return;

        _refreshOracle(currentPrice);
        if (!vault.isLiquidatable(positionId)) return;

        vault.liquidate(positionId);
    }

    function warpTime(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 hours, 3 days));
        _refreshOracle(currentPrice);
    }

    /* ============ Helpers ============ */

    function _pickActive(uint256 seed) internal view returns (uint256) {
        uint256 count = vault.activePositionCount();
        if (count == 0) return 0;
        (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
        return ids[seed % ids.length];
    }

    function _refreshOracle(uint256 price) internal {
        vm.warp(block.timestamp + 601);
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(price));
        bandOracle.setReferenceData(price * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(price * 1e10)));
        oracle.updateTwap();
    }
}

/**
 * @title RealPoolInvariantTest
 * @dev Invariants over the REAL LiquidityPool and LiquidationEngine — the
 *      layers the mock-based suite cannot see: per-pool borrow attribution,
 *      cross-pool repay routing, interest crediting, and the engine's
 *      mark/grace/tranche flow
 */
contract RealPoolInvariantTest is Test {
    VaultManager public vault;
    TGAUX public tgaux;
    OracleAggregator public oracle;
    LiquidityPool public pool;
    LiquidationEngine public engine;
    InsuranceSink public insurance;
    MockERC20 public usdc;
    MockERC20 public usdt;
    MockChainlinkOracle public chainlinkOracle;
    MockBandOracle public bandOracle;
    MockAPI3Oracle public api3Oracle;
    RealPoolHandler public handler;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    uint256 public constant GOLD_PRICE = 2_000e8;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        vm.prank(admin);
        tgaux = new TGAUX(admin);

        chainlinkOracle = new MockChainlinkOracle(8);
        bandOracle = new MockBandOracle();
        api3Oracle = new MockAPI3Oracle();
        chainlinkOracle.setLatestAnswer(SafeCast.toInt256(GOLD_PRICE));
        bandOracle.setReferenceData(GOLD_PRICE * 1e10);
        api3Oracle.setValue(SafeCast.toInt224(SafeCast.toInt256(GOLD_PRICE * 1e10)));

        vm.prank(admin);
        oracle = new OracleAggregator(admin, address(chainlinkOracle), address(bandOracle), address(api3Oracle));
        vm.warp(block.timestamp + 601);
        oracle.updateTwap();

        pool = new LiquidityPool(admin, address(usdc), address(usdt));

        vm.prank(admin);
        vault = new VaultManager(admin, address(tgaux), address(oracle), address(pool), address(usdc), address(usdt));

        insurance = new InsuranceSink();
        vm.prank(admin);
        engine = new LiquidationEngine(admin, address(vault), address(insurance), treasury);

        handler = new RealPoolHandler(
            vault, tgaux, usdc, oracle, pool, engine, chainlinkOracle, bandOracle, api3Oracle, GOLD_PRICE
        );

        vm.startPrank(admin);
        tgaux.grantRole(tgaux.MINTER_ROLE(), address(vault));
        pool.grantRole(pool.VAULT_MANAGER_ROLE(), address(vault));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(engine));
        vault.grantRole(vault.LIQUIDATOR_ROLE(), address(handler));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// @dev Per-pool borrow attribution: each pool's borrowedByToken must equal
    ///      the sum of active borrows that were drawn from that pool (tracked
    ///      via vault.borrowPoolOf) — a misrouted repay breaks this immediately
    function invariant_PerPoolBorrowedMatchesAttribution() public view {
        uint256 count = vault.activePositionCount();
        uint256 sumConservative = 0;
        uint256 sumAggressive = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                VaultManager.Position memory position = vault.getPosition(ids[i]);
                if (position.borrowedAmount == 0) continue;
                if (vault.borrowPoolOf(ids[i]) == uint8(LiquidityPool.PoolType.CONSERVATIVE)) {
                    sumConservative += position.borrowedAmount;
                } else {
                    sumAggressive += position.borrowedAmount;
                }
            }
        }
        assertEq(pool.borrowedByToken(LiquidityPool.PoolType.CONSERVATIVE, address(usdc)), sumConservative);
        assertEq(pool.borrowedByToken(LiquidityPool.PoolType.AGGRESSIVE, address(usdc)), sumAggressive);
    }

    /// @dev Pool internal consistency: each pool's aggregate totalBorrowed must
    ///      equal its per-token borrow tracking
    function invariant_PoolAggregateMatchesPerToken() public view {
        (, uint256 consBorrowed,,,) = pool.getPoolInfo(LiquidityPool.PoolType.CONSERVATIVE);
        (, uint256 aggBorrowed,,,) = pool.getPoolInfo(LiquidityPool.PoolType.AGGRESSIVE);
        assertEq(
            consBorrowed,
            pool.borrowedByToken(LiquidityPool.PoolType.CONSERVATIVE, address(usdc))
                + pool.borrowedByToken(LiquidityPool.PoolType.CONSERVATIVE, address(usdt))
        );
        assertEq(
            aggBorrowed,
            pool.borrowedByToken(LiquidityPool.PoolType.AGGRESSIVE, address(usdc))
                + pool.borrowedByToken(LiquidityPool.PoolType.AGGRESSIVE, address(usdt))
        );
    }

    /// @dev Pool solvency: the pool's actual token balance must equal its
    ///      tracked per-pool balances (deposits - borrows + repayments)
    function invariant_PoolBalanceMatchesTracking() public view {
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolBalances(LiquidityPool.PoolType.CONSERVATIVE, address(usdc))
                + pool.poolBalances(LiquidityPool.PoolType.AGGRESSIVE, address(usdc))
        );
    }

    /// @dev Supply backing holds through the real engine's tranche liquidations
    function invariant_TgauxSupplyMatchesActivePositions() public view {
        uint256 count = vault.activePositionCount();
        uint256 sumMinted = 0;
        if (count > 0) {
            (uint256[] memory ids,) = vault.getActivePositionIds(0, count);
            for (uint256 i = 0; i < ids.length; i++) {
                sumMinted += vault.getPosition(ids[i]).tgauxMinted;
            }
        }
        assertEq(tgaux.totalSupply(), sumMinted);
    }
}
