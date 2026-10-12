// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {FeeIndex} from "../src/libraries/FeeIndex.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {PushFallbackPrice} from "../src/oracle/PushFallbackPrice.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TgauxVault} from "../src/TgauxVault.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPaxg} from "./mocks/MockPaxg.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";
import {PositionManagerHarness} from "./mocks/PositionManagerHarness.sol";

/// @notice The manager's deployment, its claim book, its fee index and its
///         guardian brake.
/// @dev The pool and the fund are deployed by the manager, so the wiring check
///      is that each of them points back at it and that all three share one
///      lock. The claim measures are driven through a harness, because the open
///      path that will fill the book does not exist yet.
contract PositionManagerTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant NOTHING = 0;
    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant EXPIRY = 600;
    uint256 private constant IF_TARGET = 100 ether;
    uint256 private constant FEE_FLOOR = 0.0894e18;
    uint256 private constant FEE_CAP = 0.3e18;
    uint256 private constant FEE_EXPONENT = 2;
    /// @dev One past the largest exponent the curve accepts.
    uint256 private constant BAD_EXPONENT = 5;
    uint256 private constant YEAR = 365 * 86_400;
    uint256 private constant START = 1_783_900_800;

    uint256 private constant SIZE = 10 ether;
    uint256 private constant ENTRY = 4000e18;
    uint256 private constant PRICE = 4100e18;
    uint8 private constant FEED_DECIMALS = 8;
    uint256 private constant MAX_AGE = 6 hours;
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
    uint8 private constant STREAM_DECIMALS = 18;
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));

    PositionManagerHarness private manager;
    CounterpartyPool private pool;
    InsuranceFund private fund;
    ReentrancyLock private lock;
    TgauxVault private vault;
    TGAUX private gold;
    MockPaxg private paxg;

    address private guardian;
    address private windDown;
    address private treasury;
    address private stranger;

    function setUp() public {
        guardian = makeAddr("guardian");
        windDown = makeAddr("wind down");
        treasury = makeAddr("treasury");
        stranger = makeAddr("stranger");

        vm.warp(START);
        paxg = new MockPaxg();
        vault = new TgauxVault(address(new MockERC20("Paxos Gold", "PAXG", 18)), treasury, 0, 0);
        gold = vault.TOKEN();
        lock = new ReentrancyLock();

        manager = new PositionManagerHarness(_config());
        pool = manager.POOL();
        fund = manager.INSURANCE_FUND();
    }

    function test_DeploymentWiresThePoolAndTheFundToTheManager() public {
        assertEq(address(pool.POSITION_MANAGER()), address(manager), "the pool does not point at the manager");
        assertEq(fund.POSITION_MANAGER(), address(manager), "the fund does not point at the manager");

        assertEq(address(pool.LOCK()), address(lock), "the pool holds another lock");
        assertEq(address(fund.LOCK()), address(lock), "the fund holds another lock");
        assertEq(address(manager.LOCK()), address(lock), "the manager holds another lock");

        assertEq(address(pool.GOLD()), address(gold));
        assertEq(address(fund.GOLD()), address(gold));
        assertEq(pool.U_MAX_BPS(), U_MAX_BPS);
        assertEq(pool.REQUEST_EXPIRY(), EXPIRY);
        assertEq(fund.TARGET(), IF_TARGET);
        // D69: the pool holds no guardian of its own. The brake is the
        // manager's, and the manager is the only way in.
        // forge-lint: disable-next-line(low-level-calls)
        (bool ok,) = address(pool).call(abi.encodeWithSignature("GUARDIAN()"));
        assertFalse(ok, "the pool still names a guardian");
    }

    function test_DeploymentStoresEveryParameter() public view {
        assertEq(manager.GUARDIAN(), guardian);
        assertEq(manager.WIND_DOWN(), windDown);
        assertEq(manager.TREASURY(), treasury);
        assertEq(address(manager.PAXG()), address(paxg));
        assertEq(manager.PAXG_HOLDER(), address(vault), "the manager did not read the vault from the token");
        assertEq(manager.FEE_FLOOR_RATE(), FEE_FLOOR);
        assertEq(manager.FEE_CAP_RATE(), FEE_CAP);
        assertEq(manager.FEE_EXPONENT(), FEE_EXPONENT);
        assertEq(manager.FEE_U_MAX(), (U_MAX_BPS * WAD) / BPS, "the fee ceiling is not the pool's own");
    }

    /// @dev The index measures from deployment, not from the epoch, which is
    ///      what `start` is for: without it the first advance would bill every
    ///      second since 1970.
    function test_TheIndexStartsAtDeploymentAndNotAtZero() public view {
        assertEq(manager.indexLastAdvance(), START, "the index did not start at deployment");
        assertEq(manager.indexStored(), NOTHING);
        assertEq(manager.indexNow(), NOTHING, "an index at its start was already accruing");
    }

    function test_TheIndexViewMatchesAWrittenAdvance() public {
        assertEq(manager.currentRate(), FEE_FLOOR, "an empty pool is not at the floor");

        vm.warp(START + YEAR);
        uint256 viewed = manager.indexNow();
        assertEq(viewed, FEE_FLOOR, "a year at the floor did not accrue the floor");
        assertEq(manager.indexStored(), NOTHING, "the view wrote the index");

        manager.pokeAdvance();

        assertEq(manager.indexStored(), viewed, "the written index differs from the view");
        assertEq(manager.indexNow(), viewed, "the view moved after the advance");
        assertEq(manager.indexLastAdvance(), START + YEAR);
    }

    /// @dev Both measures read the index as of now, so time passing moves them
    ///      without anything being written.
    function test_BothClaimMeasuresReadThePositionsAndTheIndexNow() public {
        manager.recordPosition(SIZE, (SIZE * ENTRY) / WAD / 2, ENTRY, NOTHING);

        uint256 claim = (SIZE * ENTRY) / WAD / 2;
        uint256 gain = (SIZE * (PRICE - ENTRY)) / WAD;

        assertEq(manager.depositClaimUsd(PRICE), claim + gain, "the deposit measure missed the gain");
        assertGt(manager.withdrawalClaimUsd(PRICE), NOTHING, "the withdrawal measure read nothing");
        assertGe(
            manager.withdrawalClaimUsd(PRICE), manager.depositClaimUsd(PRICE), "I6: the low side fell under the high"
        );

        vm.warp(START + YEAR);
        assertGt(manager.indexNow(), NOTHING, "the index did not move with time");
        assertLt(
            manager.depositClaimUsd(PRICE),
            claim + gain,
            "a year of fees did not come off the deposit measure through the index view"
        );
    }

    function test_TheClaimBookFollowsRemovals() public {
        uint256 claim = (SIZE * ENTRY) / WAD / 2;
        manager.recordPosition(SIZE, claim, ENTRY, NOTHING);
        manager.dropPosition(SIZE, claim, ENTRY, NOTHING);

        assertEq(manager.depositClaimUsd(PRICE), NOTHING, "the book kept a closed position");
        assertEq(manager.withdrawalClaimUsd(PRICE), NOTHING, "the book kept a closed position");
        assertEq(manager.reservedOunces(), NOTHING, "the pool kept a reservation");
    }

    function test_TheBrakeIsGuardianOnly() public {
        assertFalse(manager.inflowsPaused());

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotGuardian.selector, stranger));
        manager.pauseInflows();

        vm.prank(guardian);
        manager.pauseInflows();
        assertTrue(manager.inflowsPaused(), "the guardian could not pause inflows");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotGuardian.selector, stranger));
        manager.unpauseInflows();

        vm.prank(guardian);
        manager.unpauseInflows();
        assertFalse(manager.inflowsPaused(), "the guardian could not let inflows through again");
    }

    /// @dev D50: PAXG is usable only when the vault is not frozen and the token
    ///      is not paused, which is all four states of the two readings.
    function test_PaxgUsableInAllFourStates() public {
        assertTrue(manager.paxgUsable(), "a healthy PAXG did not read as usable");

        paxg.setFrozen(address(vault), true);
        assertFalse(manager.paxgUsable(), "a frozen vault read as usable");

        paxg.setPaused(true);
        assertFalse(manager.paxgUsable(), "a frozen and paused PAXG read as usable");

        paxg.setFrozen(address(vault), false);
        assertFalse(manager.paxgUsable(), "a paused PAXG read as usable");

        paxg.setPaused(false);
        assertTrue(manager.paxgUsable(), "PAXG did not come back");
    }

    /// @dev The freeze that matters is the vault's, not the manager's own.
    function test_PaxgUsableWatchesTheVaultAndNotTheManager() public {
        paxg.setFrozen(address(manager), true);
        assertTrue(manager.paxgUsable(), "the manager's own freeze was read instead of the vault's");

        paxg.setFrozen(address(vault), true);
        assertFalse(manager.paxgUsable(), "the vault's freeze was not read");
    }

    /// @dev D48 as revised in r6.7, held as an internal check until the open
    ///      path exists to call it.
    function test_TheEmptyPoolRuleRefusesWhileNoShareExists() public {
        vm.expectRevert(PositionManager.PoolHasNoShares.selector);
        manager.pokeRequireSharesExist();
    }

    function test_ConstructorRejectsAZeroAddressAndABadCurve() public {
        PositionManager.Config memory config = _config();
        config.gold = address(0);
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManagerHarness(config);

        config = _config();
        config.guardian = address(0);
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManagerHarness(config);

        config = _config();
        config.windDown = address(0);
        vm.expectRevert(PositionManager.ZeroAddress.selector);
        new PositionManagerHarness(config);

        config = _config();
        config.feeFloorRate = NOTHING;
        vm.expectRevert(FeeIndex.ZeroFloorRate.selector);
        new PositionManagerHarness(config);

        config = _config();
        config.feeCapRate = FEE_FLOOR - 1;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.CapBelowFloor.selector, FEE_FLOOR - 1, FEE_FLOOR));
        new PositionManagerHarness(config);

        config = _config();
        config.feeExponent = BAD_EXPONENT;
        vm.expectRevert(abi.encodeWithSelector(FeeIndex.ExponentOutOfRange.selector, BAD_EXPONENT));
        new PositionManagerHarness(config);
    }

    function _config() private returns (PositionManager.Config memory) {
        MockVerifierProxy verifier = new MockVerifierProxy();
        MockPyth pyth = new MockPyth();
        TradingCalendar calendar = new TradingCalendar(makeAddr("calendar proposer"));
        SettlementOracle oracle = new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY
        );
        PushFallbackPrice fallbackPrice =
            new PushFallbackPrice(address(new MockChainlinkOracle(FEED_DECIMALS)), address(calendar), MAX_AGE);

        return PositionManager.Config({
            gold: address(gold),
            paxg: address(paxg),
            settlementOracle: address(oracle),
            fallbackPrice: address(fallbackPrice),
            calendar: address(calendar),
            lock: address(lock),
            guardian: guardian,
            windDown: windDown,
            treasury: treasury,
            poolUMaxBps: U_MAX_BPS,
            requestExpiry: EXPIRY,
            insuranceTarget: IF_TARGET,
            feeFloorRate: FEE_FLOOR,
            feeCapRate: FEE_CAP,
            feeExponent: FEE_EXPONENT
        });
    }
}
