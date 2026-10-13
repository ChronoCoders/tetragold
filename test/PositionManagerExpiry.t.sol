// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {IPyth} from "../src/oracle/interfaces/IPyth.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {PushFallbackPrice} from "../src/oracle/PushFallbackPrice.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {ReportV8} from "../src/oracle/ReportV8.sol";
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

/// @notice Expiry is not free (D72). A request that no price qualifies for can
///         be expired by anyone once its window closes. The escrow returns to
///         the requester, less the open fee an expiring open still owes; the
///         execution fee is kept, paying the caller its gas and crediting the
///         treasury the rest.
/// @dev The scaffolding mirrors the close suite: the real oracle over mocked
///      sources and positions opened through the real path, so the book and the
///      pool stay consistent.
contract PositionManagerExpiryTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant NOTHING = 0;
    uint256 private constant TARGET_DELAY = 12;
    uint256 private constant EXPIRY = 300;

    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant IF_TARGET = 100 ether;
    uint256 private constant FEE_FLOOR = 0.0894e18;
    uint256 private constant FEE_CAP = 0.3e18;
    uint256 private constant FEE_EXPONENT = 2;
    uint256 private constant POSITION_FEE_BPS = 10;
    uint256 private constant TREASURY_SHARE_BPS = 4000;
    uint256 private constant INSURANCE_SHARE_BPS = 3000;
    uint256 private constant POOL_SHARE_BPS = 3000;
    uint256 private constant MIN_NOTIONAL_USD = 1000e18;
    uint256 private constant MAINTENANCE_MARGIN_BPS = 600;
    uint256 private constant GAS_OPEN = 1_000_000;
    uint256 private constant GAS_ADD = 300_000;
    uint256 private constant GAS_CLOSE = 500_000;
    uint256 private constant GAS_OVERHEAD = 80_000;
    uint256 private constant GAS_PRICE = 2 gwei;
    uint256 private constant PYTH_FEE = 1000 wei;

    /// @dev 2026-07-15 12:00 UTC, a Wednesday with the market open.
    uint256 private constant START = 1_784_116_800;
    uint32 private constant WINDOW = 12;
    uint32 private constant EXPIRY_AHEAD = 86_400;
    uint32 private constant OPEN_STATUS = 2;
    int32 private constant PYTH_EXPO = -8;
    uint256 private constant PYTH_SCALE = 1e10;
    uint256 private constant PRICE_18 = 4000e18;
    uint8 private constant STREAM_DECIMALS = 18;
    uint8 private constant FEED_DECIMALS = 8;
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
    uint256 private constant PRIMARY_AGE = 60;
    uint256 private constant MAX_AGE = 6 hours;
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));

    uint256 private constant SEED = 1000 ether;
    uint256 private constant POST = 1 ether;
    uint256 private constant LEVERAGE = 3;

    bytes32 private constant REQUEST_EXPIRED_SIG = keccak256("RequestExpired(uint256,address,uint256,uint256)");
    bytes32 private constant EXPIRER_PAID_SIG = keccak256("ExpirerPaid(uint256,address,uint256,uint256)");
    bytes32 private constant FEE_ROUTED_SIG = keccak256("FeeRouted(uint256,uint256,uint256)");

    PositionManagerHarness private manager;
    CounterpartyPool private pool;
    InsuranceFund private fund;
    ReentrancyLock private lock;
    TgauxVault private vault;
    TGAUX private gold;
    MockERC20 private paxgToken;
    MockPaxg private paxg;
    MockPyth private pyth;
    MockVerifierProxy private verifier;

    address private guardian;
    address private treasury;
    address private lp;
    address private trader;
    address private settler;
    address private stranger;

    struct ExpiryOut {
        uint256 refunded;
        uint256 fee;
        uint256 paid;
        uint256 treasuryEth;
        uint256 feeTreasury;
        uint256 feeFund;
        uint256 feePool;
        bool sawFeeRouted;
    }

    function setUp() public {
        guardian = makeAddr("guardian");
        treasury = makeAddr("treasury");
        lp = makeAddr("lp");
        trader = makeAddr("trader");
        settler = makeAddr("settler");
        stranger = makeAddr("stranger");

        vm.warp(START);
        vm.txGasPrice(GAS_PRICE);

        paxg = new MockPaxg();
        paxgToken = new MockERC20("Paxos Gold", "PAXG", 18);
        vault = new TgauxVault(address(paxgToken), treasury, 0, 0);
        gold = vault.TOKEN();
        lock = new ReentrancyLock();
        verifier = new MockVerifierProxy();
        pyth = new MockPyth();
        pyth.setFee(PYTH_FEE);

        manager = new PositionManagerHarness(_config());
        pool = manager.POOL();
        fund = manager.INSURANCE_FUND();

        vm.deal(trader, 100 ether);
        vm.deal(settler, 100 ether);

        _seedPool(SEED);
    }

    // --- the door -----------------------------------------------------------

    function test_ExpiryBeforeTheDeadlineIsRefused() public {
        uint256 id = _pendingOpen(POST, LEVERAGE);
        (,,, uint256 target,,,,) = manager.requestAt(id);

        vm.warp(target + EXPIRY - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotExpiredYet.selector, target + EXPIRY));
        manager.expireRequest(id);
    }

    function test_AStrangerMayExpireACloseAfterTheDeadline() public {
        uint256 positionId = _openPosition();
        uint256 id = _pendingClose(positionId);

        _warpToDeadline(id);
        uint256 strangerEth = stranger.balance;

        vm.prank(stranger);
        manager.expireRequest(id);

        // The caller is a stranger, yet it is paid out of the fee, and the exit
        // flag the close set is released (D72 rule 2).
        assertGt(stranger.balance - strangerEth, NOTHING, "the stranger was paid no gas");
        (bool exitPending,) = manager.positionFlags(positionId);
        assertFalse(exitPending, "an expired close left the exit flag set");
    }

    // --- the open charge ----------------------------------------------------

    function test_TheOpenExpiryChargeIsExactAtAWeiEdge() public {
        // size * f is not a whole number of ounces, so the charge rounds up.
        uint256 post = POST + 7;
        uint256 size = post * LEVERAGE;
        assertTrue((size * POSITION_FEE_BPS) % BPS != 0, "pick a size whose fee is not whole");

        uint256 id = _pendingOpen(post, LEVERAGE);
        _warpToDeadline(id);

        uint256 traderBefore = gold.balanceOf(trader);
        ExpiryOut memory out = _expire(id, stranger);

        uint256 charge = (size * POSITION_FEE_BPS + BPS - 1) / BPS;
        assertEq(out.feeTreasury + out.feeFund + out.feePool, charge, "the routed charge is not the rounded fee");
        assertEq(out.refunded, post - charge, "the refund is not q less the rounded charge");
        assertEq(gold.balanceOf(trader) - traderBefore, post - charge, "the requester did not get q less the charge");
    }

    function test_AnAddExpiryTakesNoOunces() public {
        uint256 positionId = _openPosition();
        uint256 add = 0.3 ether;
        uint256 id = _pendingAdd(positionId, add);
        _warpToDeadline(id);

        uint256 traderBefore = gold.balanceOf(trader);
        uint256 treasuryGold = gold.balanceOf(treasury);
        ExpiryOut memory out = _expire(id, stranger);

        assertFalse(out.sawFeeRouted, "an add expiry routed a fee");
        assertEq(out.refunded, add, "an add expiry did not refund the whole escrow");
        assertEq(gold.balanceOf(trader) - traderBefore, add, "the add escrow did not come back in full");
        assertEq(gold.balanceOf(treasury), treasuryGold, "an add expiry moved gold to the treasury");
    }

    function test_ACloseExpiryTakesNoOunces() public {
        uint256 positionId = _openPosition();
        uint256 id = _pendingClose(positionId);
        _warpToDeadline(id);

        uint256 treasuryGold = gold.balanceOf(treasury);
        uint256 poolGold = gold.balanceOf(address(pool));
        ExpiryOut memory out = _expire(id, stranger);

        assertFalse(out.sawFeeRouted, "a close expiry routed a fee");
        assertEq(out.refunded, NOTHING, "a close holds no escrow to refund");
        assertEq(gold.balanceOf(treasury), treasuryGold, "a close expiry moved gold to the treasury");
        assertEq(gold.balanceOf(address(pool)), poolGold, "a close expiry moved gold to the pool");
    }

    // --- the execution fee --------------------------------------------------

    function test_TheCallersGasCreditIsCappedAtTheFee() public {
        uint256 id = _pendingClose(_openPosition());
        (,, uint256 fee,,,,,) = manager.requestAt(id);
        _warpToDeadline(id);

        // The gas price at expiry is far above the one the fee was quoted at,
        // so the gas owed dwarfs the fee and the payment caps at it.
        vm.txGasPrice(GAS_PRICE * 100_000);
        uint256 strangerEth = stranger.balance;
        ExpiryOut memory out = _expire(id, stranger);

        assertEq(out.paid, fee, "the payment was not capped at the fee");
        assertEq(out.treasuryEth, NOTHING, "a capped payment still credited the treasury");
        assertEq(stranger.balance - strangerEth, fee, "the capped payment did not reach the caller");
    }

    function test_TheTreasuryCreditEqualsTheFeeLessTheCallersGas() public {
        uint256 id = _pendingClose(_openPosition());
        (,, uint256 fee,,,,,) = manager.requestAt(id);
        _warpToDeadline(id);

        uint256 strangerEth = stranger.balance;
        ExpiryOut memory out = _expire(id, stranger);

        assertGt(out.paid, NOTHING, "the caller was paid no gas");
        assertLt(out.paid, fee, "the fee was fully spent on gas, so the split proves nothing");
        assertEq(stranger.balance - strangerEth, out.paid, "the caller's balance did not rise by the gas paid");
        assertEq(out.treasuryEth, fee - out.paid, "the treasury credit is not the fee less the gas");
        assertEq(manager.ethCredit(treasury), out.treasuryEth, "the treasury credit was not recorded for a pull");
        assertEq(out.paid + out.treasuryEth, fee, "the fee did not split into gas and treasury");
    }

    function test_ARequesterExpiringItsOwnRequestGetsOnlyItsGas() public {
        uint256 id = _pendingOpen(POST, LEVERAGE);
        (,, uint256 fee,,,,,) = manager.requestAt(id);
        _warpToDeadline(id);

        uint256 traderEth = trader.balance;
        ExpiryOut memory out = _expire(id, trader);

        // Of the fee, the requester recovers only its gas; the rest is the
        // treasury's, and the requester is never credited the fee to pull.
        assertEq(trader.balance - traderEth, out.paid, "the requester recovered more or less than its gas");
        assertLe(out.paid, fee, "the gas recovered rose above the fee");
        assertEq(manager.ethCredit(trader), NOTHING, "the requester was credited the fee");
        assertEq(out.treasuryEth, fee - out.paid, "the treasury did not keep the rest of the fee");
    }

    // --- the escrow identity ------------------------------------------------

    function test_TheEscrowIdentityHoldsAfterEveryKindOfExpiry() public {
        uint256 openId = _pendingOpen(POST, LEVERAGE);
        _warpToDeadline(openId);
        _expire(openId, stranger);
        _assertEscrowIdentity("after an open expiry");

        uint256 positionId = _openPosition();
        uint256 addId = _pendingAdd(positionId, 0.3 ether);
        _warpToDeadline(addId);
        _expire(addId, stranger);
        _assertEscrowIdentity("after an add expiry");

        uint256 closeId = _pendingClose(positionId);
        _warpToDeadline(closeId);
        _expire(closeId, stranger);
        _assertEscrowIdentity("after a close expiry");
    }

    // --- independent reference ----------------------------------------------

    /// @notice The open expiry charge, its three shares and the two ETH credits
    ///         match a recompute in plain arithmetic here, for a fuzzed q, tier
    ///         and request gas price.
    function test_IndependentReferenceForTheOpenExpiry(uint256 postSeed, uint8 tierSeed, uint256 gasPriceSeed) public {
        uint256 post = bound(postSeed, 0.5 ether, 20 ether);
        uint256[3] memory tiers = [uint256(2), 3, 5];
        uint256 leverage = tiers[tierSeed % 3];
        uint256 requestGasPrice = bound(gasPriceSeed, 1 gwei, 50 gwei);

        vm.txGasPrice(requestGasPrice);
        uint256 id = _pendingOpen(post, leverage);
        uint256 fee = post == 0 ? 0 : GAS_OPEN * requestGasPrice;
        _warpToDeadline(id);

        uint256 traderBefore = gold.balanceOf(trader);
        ExpiryOut memory out = _expire(id, stranger);

        // Charge and the three shares, recomputed from scratch (D71, D20, D29).
        uint256 charge = (post * leverage * POSITION_FEE_BPS + BPS - 1) / BPS;
        uint256 toTreasury = (charge * TREASURY_SHARE_BPS) / BPS;
        uint256 toFund = fund.atTarget() ? 0 : (charge * INSURANCE_SHARE_BPS) / BPS;
        assertEq(out.feeTreasury, toTreasury, "treasury share");
        assertEq(out.feeFund, toFund, "fund share");
        assertEq(out.feePool, charge - toTreasury - toFund, "pool share");
        assertEq(out.refunded, post - charge, "refund");
        assertEq(gold.balanceOf(trader) - traderBefore, post - charge, "the requester did not get the refund");

        // Both ETH credits: the fee splits into exactly the caller's gas and the
        // treasury's remainder, neither more nor less, with the gas never over
        // the fee (D72 rule 3).
        assertEq(fee, GAS_OPEN * requestGasPrice, "the fee is not the floor at the request gas price");
        assertLe(out.paid, fee, "the gas paid rose above the fee");
        assertEq(out.treasuryEth, fee - out.paid, "the treasury credit is not the fee less the gas");
        assertEq(out.paid + out.treasuryEth, fee, "the fee did not split in two");
        assertEq(manager.ethCredit(treasury), out.treasuryEth, "the recorded treasury credit disagreed");
    }

    // --- D73: a stale primary report waits, it is never rejected ------------

    function test_AStaleReportLeavesTheOpenPendingThenAFreshOneSettles() public {
        uint256 id = _pendingOpen(POST, LEVERAGE);
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        manager.settleOpen{value: PYTH_FEE}(id, abi.encode(_stale(target, PRICE_18)), _pyth(target, PRICE_18));

        (,,,,,,, PositionManager.State pending) = manager.requestAt(id);
        assertEq(
            uint256(pending), uint256(PositionManager.State.Pending), "a stale report did not leave the open pending"
        );

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(id, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));
        (,,,,,,, PositionManager.State settled) = manager.requestAt(id);
        assertEq(uint256(settled), uint256(PositionManager.State.Settled), "a fresh report did not settle the open");
    }

    function test_AStaleReportLeavesTheAddPendingThenAFreshOneSettles() public {
        uint256 id = _pendingAdd(_openPosition(), 0.3 ether);
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        manager.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_stale(target, PRICE_18)), _pyth(target, PRICE_18));

        (,,,,,,, PositionManager.State pending) = manager.requestAt(id);
        assertEq(
            uint256(pending), uint256(PositionManager.State.Pending), "a stale report did not leave the add pending"
        );

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));
        (,,,,,,, PositionManager.State settled) = manager.requestAt(id);
        assertEq(uint256(settled), uint256(PositionManager.State.Settled), "a fresh report did not settle the add");
    }

    function test_AStaleReportLeavesTheClosePendingThenAFreshOneSettles() public {
        uint256 id = _pendingClose(_openPosition());
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        manager.settleClose{value: PYTH_FEE}(id, abi.encode(_stale(target, PRICE_18)), _pyth(target, PRICE_18));

        (,,,,,,, PositionManager.State pending) = manager.requestAt(id);
        assertEq(
            uint256(pending), uint256(PositionManager.State.Pending), "a stale report did not leave the close pending"
        );

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleClose{value: PYTH_FEE}(id, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));
        (,,,,,,, PositionManager.State settled) = manager.requestAt(id);
        assertEq(uint256(settled), uint256(PositionManager.State.Settled), "a fresh report did not settle the close");
    }

    function test_AStaleReportThatNeverGoesFreshExpiresUnderD72() public {
        uint256 id = _pendingOpen(POST, LEVERAGE);
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        manager.settleOpen{value: PYTH_FEE}(id, abi.encode(_stale(target, PRICE_18)), _pyth(target, PRICE_18));

        // It never settled, so past the window it expires like any waiting
        // request (D72); staleness never turns into a D70 rejection.
        _warpToDeadline(id);
        _expire(id, stranger);
        (,,,,,,, PositionManager.State expired) = manager.requestAt(id);
        assertEq(uint256(expired), uint256(PositionManager.State.Expired), "a stale open did not expire under D72");
    }

    /// @dev A report that spans the target but whose price was last updated one
    ///      second past the deployment's age bound (D73 rule 2).
    function _stale(uint256 target, uint256 price18) private pure returns (ReportV8 memory report) {
        report = _report(target, price18);
        report.lastUpdateTimestamp = (uint64(uint32(target) + WINDOW) - uint64(PRIMARY_AGE) - 1) * 1e9;
    }

    // --- helpers ------------------------------------------------------------

    function _warpToDeadline(uint256 id) private {
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target + EXPIRY);
    }

    function _assertEscrowIdentity(string memory where) private view {
        assertEq(gold.balanceOf(address(manager)), manager.escrowedOunces(), string.concat("D66 broke ", where));
    }

    function _expire(uint256 id, address caller) private returns (ExpiryOut memory out) {
        vm.recordLogs();
        vm.prank(caller);
        manager.expireRequest(id);
        out = _decodeExpiry(vm.getRecordedLogs());
    }

    function _decodeExpiry(Vm.Log[] memory logs) private view returns (ExpiryOut memory out) {
        bool sawExpired;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics.length == 0 ? bytes32(0) : logs[i].topics[0];
            if (topic == REQUEST_EXPIRED_SIG && logs[i].emitter == address(manager)) {
                (out.refunded, out.fee) = abi.decode(logs[i].data, (uint256, uint256));
                sawExpired = true;
            } else if (topic == EXPIRER_PAID_SIG && logs[i].emitter == address(manager)) {
                (out.paid, out.treasuryEth) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (topic == FEE_ROUTED_SIG && logs[i].emitter == address(manager)) {
                (out.feeTreasury, out.feeFund, out.feePool) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                out.sawFeeRouted = true;
            }
        }
        require(sawExpired, "no RequestExpired event");
    }

    function _pendingOpen(uint256 post, uint256 leverage) private returns (uint256 id) {
        _mint(trader, post);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), post));
        vm.deal(trader, trader.balance + _feeFloor(GAS_OPEN));
        vm.prank(trader);
        id = manager.requestOpen{value: _feeFloor(GAS_OPEN)}(post, leverage);
    }

    function _openPosition() private returns (uint256 positionId) {
        _mint(trader, POST);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), POST));
        vm.deal(trader, trader.balance + _feeFloor(GAS_OPEN));
        vm.prank(trader);
        uint256 request = manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, LEVERAGE);

        uint256 target = vm.getBlockTimestamp() + TARGET_DELAY;
        vm.warp(target);
        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(request, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));

        positionId = manager.nextPositionId() - 1;
        (,,,,, bool open) = manager.positionAt(positionId);
        assertTrue(open, "the fixture did not open a position");
    }

    function _pendingAdd(uint256 positionId, uint256 ounces) private returns (uint256 id) {
        _mint(trader, ounces);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), ounces));
        vm.deal(trader, trader.balance + _feeFloor(GAS_ADD));
        vm.prank(trader);
        id = manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ounces);
    }

    function _pendingClose(uint256 positionId) private returns (uint256 id) {
        vm.deal(trader, trader.balance + _feeFloor(GAS_CLOSE));
        vm.prank(trader);
        id = manager.requestClose{value: _feeFloor(GAS_CLOSE)}(positionId);
    }

    function _config() private returns (PositionManager.Config memory) {
        TradingCalendar calendar = new TradingCalendar(makeAddr("calendar proposer"));
        SettlementOracle oracle = new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY, PRIMARY_AGE
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
            windDown: makeAddr("wind down"),
            treasury: treasury,
            poolUMaxBps: U_MAX_BPS,
            insuranceTarget: IF_TARGET,
            feeFloorRate: FEE_FLOOR,
            feeCapRate: FEE_CAP,
            feeExponent: FEE_EXPONENT,
            positionFeeBps: POSITION_FEE_BPS,
            treasuryShareBps: TREASURY_SHARE_BPS,
            insuranceShareBps: INSURANCE_SHARE_BPS,
            poolShareBps: POOL_SHARE_BPS,
            minNotionalUsd: MIN_NOTIONAL_USD,
            maintenanceMarginBps: MAINTENANCE_MARGIN_BPS,
            gasOpen: GAS_OPEN,
            gasAdd: GAS_ADD,
            gasClose: GAS_CLOSE,
            gasOverhead: GAS_OVERHEAD
        });
    }

    function _mint(address to, uint256 ounces) private {
        paxgToken.mint(address(this), ounces);
        assertTrue(paxgToken.approve(address(vault), ounces));
        uint256 minted = vault.deposit(ounces);
        assertTrue(gold.transfer(to, minted));
    }

    function _seedPool(uint256 ounces) private {
        _mint(lp, ounces);
        vm.prank(lp);
        assertTrue(gold.approve(address(pool), ounces));
        uint256 id = manager.seedRequest(lp, ounces);
        vm.warp(vm.getBlockTimestamp() + TARGET_DELAY);
        // forge-lint: disable-next-line(unused-return)
        manager.seedSettle(id, PRICE_18);
    }

    function _report(uint256 target, uint256 price18) private pure returns (ReportV8 memory) {
        return ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: uint32(target) - WINDOW,
            observationsTimestamp: uint32(target) + WINDOW,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(target) + EXPIRY_AHEAD,
            lastUpdateTimestamp: uint64(uint32(target) + WINDOW) * 1e9,
            midPrice: int192(int256(price18)),
            marketStatus: OPEN_STATUS
        });
    }

    function _pyth(uint256 target, uint256 price18) private pure returns (bytes[] memory update) {
        int64 price = int64(int256(price18 / PYTH_SCALE));
        update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: PYTH_ID,
                price: IPyth.Price({price: price, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)}),
                emaPrice: IPyth.Price({price: price, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)})
            })
        );
    }

    function _feeFloor(uint256 gasEstimate) private view returns (uint256) {
        return gasEstimate * tx.gasprice;
    }

    receive() external payable {}
}
