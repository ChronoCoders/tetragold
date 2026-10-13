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

/// @notice Closing a position (D71 rules 3 to 5, D47, D49). The settled price
///         decides the payout, the fee collected and any bad debt, and the one
///         call hands the book its four values back, releases the reserve, pays
///         the owner and covers bad debt from the fund then the pool.
/// @dev The oracle is the real one over mocked sources, so the price comes
///      through the whole of section 7. A position is opened through the real
///      path so the book and the pool are consistent before the close.
contract PositionManagerCloseTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant NOTHING = 0;
    uint256 private constant TARGET_DELAY = 12;

    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant EXPIRY = 300;
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
    uint256 private constant MAX_AGE = 6 hours;
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));

    uint256 private constant SEED = 1000 ether;
    uint256 private constant POST = 1 ether;
    uint256 private constant LEVERAGE = 3;
    bytes32 private constant CLOSE_SETTLED_SIG =
        keccak256("CloseSettled(uint256,uint256,address,uint256,uint256,uint256,uint256)");
    bytes32 private constant FEE_ROUTED_SIG = keccak256("FeeRouted(uint256,uint256,uint256)");
    bytes32 private constant PAID_SIG = keccak256("Paid(address,uint256,uint256)");

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

    struct CloseOut {
        uint256 price18;
        uint256 payout;
        uint256 collected;
        uint256 badDebt;
        uint256 toTreasury;
        uint256 toFund;
        uint256 toPool;
        uint256 ifPaid;
        bool sawFeeRouted;
    }

    struct Terms {
        uint256 payout;
        uint256 collected;
        uint256 badDebt;
        uint256 holdingFee;
        uint256 closeFee;
    }

    function setUp() public {
        guardian = makeAddr("guardian");
        treasury = makeAddr("treasury");
        lp = makeAddr("lp");
        trader = makeAddr("trader");
        settler = makeAddr("settler");

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

    // --- profit, loss, break even ------------------------------------------

    function test_AProfitPaysTheOwnerAndNeverAboveTheSize() public {
        uint256 id = _openAPosition();
        (, uint256 size,,,,) = manager.positionAt(id);
        uint256 before = gold.balanceOf(trader);

        CloseOut memory out = _close(id, 5000e18);
        Terms memory want = _expected(id, 5000e18);

        assertGt(out.payout, NOTHING, "a profit paid nothing");
        assertEq(out.payout, want.payout, "payout disagreed with the independent recompute");
        assertEq(out.badDebt, NOTHING, "a profit left bad debt");
        assertLe(out.payout, size, "I2: the payout rose above the position size");
        assertEq(gold.balanceOf(trader) - before, out.payout, "the owner did not receive the payout");
    }

    function test_ALossStillReturnsResidualEquity() public {
        uint256 id = _openAPosition();
        uint256 before = gold.balanceOf(trader);

        CloseOut memory out = _close(id, 3800e18);
        Terms memory want = _expected(id, 3800e18);

        assertEq(out.payout, want.payout, "payout disagreed with the recompute");
        assertEq(out.badDebt, NOTHING, "a mild loss left bad debt");
        assertEq(gold.balanceOf(trader) - before, out.payout, "the owner did not receive the residual");
    }

    function test_AFlatCloseReturnsCollateralLessTheFees() public {
        uint256 id = _openAPosition();
        CloseOut memory out = _close(id, PRICE_18);
        Terms memory want = _expected(id, PRICE_18);

        assertEq(out.payout, want.payout, "break even payout disagreed");
        assertEq(out.collected, want.collected, "break even collected disagreed");
        assertEq(out.badDebt, NOTHING, "break even left bad debt");
        assertEq(out.payout + out.collected, want.payout + want.collected, "payout plus collected drifted");
    }

    // --- fee cap and rounding ----------------------------------------------

    function test_GrossBelowTheFeesCapsTheCollectionAndPaysNothing() public {
        uint256 id = _openAPosition();
        // Let the holding fee run past the collateral so the fees exceed a
        // positive gross: payout is zero and the collection caps at gross.
        vm.warp(vm.getBlockTimestamp() + 1500 days);

        CloseOut memory out = _close(id, PRICE_18);
        Terms memory want = _expected(id, PRICE_18);

        assertGt(want.holdingFee + want.closeFee, want.collected, "the fees did not exceed gross, so nothing is capped");
        assertEq(out.payout, NOTHING, "a position eaten by fees still paid out");
        assertEq(out.collected, want.collected, "the collection was not capped at gross");
        assertEq(out.badDebt, NOTHING, "a positive gross produced bad debt");
    }

    function test_TheCloseFeeRoundsUpAtAWeiEdge() public {
        // size * f is not a whole number of ounces, so the close fee rounds up.
        uint256 id = _openAt(POST + 7, LEVERAGE);
        (, uint256 size,,,,) = manager.positionAt(id);
        assertTrue((size * POSITION_FEE_BPS) % BPS != 0, "pick a size whose fee is not whole");

        CloseOut memory out = _close(id, 5000e18);
        Terms memory want = _expected(id, 5000e18);
        assertEq(want.closeFee, (size * POSITION_FEE_BPS + BPS - 1) / BPS, "the close fee did not round up");
        // Collected on a profit is the full fee, so the rounded close fee shows
        // through the collection the contract reports.
        assertEq(out.collected, want.collected, "the collection did not carry the rounded fee");
    }

    // --- bad debt -----------------------------------------------------------

    function test_BadDebtTheFundCoversInFull() public {
        uint256 id = _openAPosition();
        _fillFund(50 ether);
        uint256 fundBefore = fund.ounces();
        uint256 poolBefore = pool.ounces();

        CloseOut memory out = _close(id, 1000e18);
        Terms memory want = _expected(id, 1000e18);

        assertGt(out.badDebt, NOTHING, "the crash left no bad debt");
        assertEq(out.badDebt, want.badDebt, "bad debt disagreed with the recompute");
        assertEq(out.payout, NOTHING, "bad debt still paid the owner");
        assertLe(out.badDebt, fundBefore, "this case wants the fund to cover in full");
        assertEq(fundBefore - fund.ounces(), out.badDebt, "the fund did not pay the whole bad debt");
        // The pool loses the reserve it released and gains the fund's cover.
        assertEq(pool.ounces(), poolBefore + out.badDebt, "the pool did not receive the fund's cover");
    }

    function test_BadDebtTheFundCoversPartlyAndThePoolAbsorbsTheRest() public {
        uint256 id = _openAPosition();
        _fillFund(1 ether);
        uint256 fundBefore = fund.ounces();
        uint256 poolBefore = pool.ounces();

        CloseOut memory out = _close(id, 1000e18);

        assertGt(out.badDebt, fundBefore, "this case wants the bad debt to exceed the fund");
        assertEq(fund.ounces(), NOTHING, "the fund did not empty itself into the pool");
        assertEq(pool.ounces(), poolBefore + fundBefore, "the pool took more or less than the fund held");
    }

    function test_BadDebtRoundsUpAtAWeiEdge() public {
        uint256 id = _openAPosition();
        _fillFund(50 ether);
        (, uint256 size, uint256 claim, uint256 openPrice,,) = manager.positionAt(id);

        // A crash price with a non-round tail, so the loss in ounces is not a
        // whole number and the round-up shows.
        uint256 price = 1500000000000000000001;
        uint256 held = claim + (size * price) / WAD;
        uint256 owed = (size * openPrice + WAD - 1) / WAD;
        assertGt(owed, held, "pick a price that puts the position under water");
        uint256 lossUsd = (owed - held) * WAD;
        assertTrue(lossUsd % price != 0, "pick a price whose loss leaves a remainder");
        uint256 ceiling = lossUsd / price + 1;

        CloseOut memory out = _close(id, price);
        assertEq(out.badDebt, ceiling, "the bad debt did not round up to the ceiling");
        assertEq(out.ifPaid, ceiling, "the fund did not cover the ceiling into the pool");
    }

    // --- rules at the door --------------------------------------------------

    function test_ACloseGoesThroughWhileTheBrakeIsOn() public {
        uint256 id = _openAPosition();
        vm.prank(guardian);
        manager.pauseInflows();

        CloseOut memory out = _close(id, 5000e18);
        assertGt(out.payout, NOTHING, "the brake stopped a close");
        (,,,,, bool open) = manager.positionAt(id);
        assertFalse(open, "the position did not close under the brake");
    }

    function test_ACloseGoesThroughWhilePaxgIsUnusable() public {
        uint256 id = _openAPosition();
        paxg.setFrozen(address(vault), true);

        CloseOut memory out = _close(id, 5000e18);
        assertGt(out.payout, NOTHING, "an unusable PAXG stopped a close");
        (,,,,, bool open) = manager.positionAt(id);
        assertFalse(open, "the position did not close with PAXG unusable");
    }

    function test_ACloseRequestIsRefusedWhileAnAddIsPending() public {
        uint256 id = _openAPosition();
        _mint(trader, 0.1 ether);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), 0.1 ether));
        vm.prank(trader);
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(id, 0.1 ether);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.AddPending.selector, id));
        manager.requestClose{value: _feeFloor(GAS_CLOSE)}(id);
    }

    function test_APendingAddIsRejectedAfterThePositionHasClosed() public {
        uint256 id = _openAPosition();
        _mint(trader, 0.1 ether);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), 0.1 ether));
        vm.prank(trader);
        uint256 addId = manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(id, 0.1 ether);

        // The position goes the way a close or a liquidation takes it.
        manager.pokeClose(id);

        uint256 before = gold.balanceOf(trader);
        (,,, uint256 target,,,,) = manager.requestAt(addId);
        vm.warp(target);
        vm.prank(settler);
        manager.settleAddCollateral{value: PYTH_FEE}(
            addId, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18)
        );

        (,,,,,,, PositionManager.State state) = manager.requestAt(addId);
        assertEq(uint8(state), uint8(PositionManager.State.Rejected), "the add was not rejected after the close");
        assertEq(gold.balanceOf(trader) - before, 0.1 ether, "the add escrow was not refunded");
    }

    function test_ACloseRequestFromANonOwnerIsRefused() public {
        uint256 id = _openAPosition();
        vm.deal(lp, 1 ether);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotPositionOwner.selector, lp, trader));
        manager.requestClose{value: _feeFloor(GAS_CLOSE)}(id);
    }

    function test_ASecondCloseRequestIsRefused() public {
        uint256 id = _openAPosition();
        vm.prank(trader);
        manager.requestClose{value: _feeFloor(GAS_CLOSE)}(id);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.ExitPending.selector, id));
        manager.requestClose{value: _feeFloor(GAS_CLOSE)}(id);
    }

    function test_AnExpiredCloseClearsTheExitFlagAndClosesOnTheNextTry() public {
        uint256 id = _openAPosition();

        vm.prank(trader);
        uint256 reqId = manager.requestClose{value: _feeFloor(GAS_CLOSE)}(id);

        // The close outlives its window, as it would through an oracle outage,
        // and the owner expires it (section 7 rule 4).
        (,,, uint256 target,,,,) = manager.requestAt(reqId);
        vm.warp(target + EXPIRY);
        vm.prank(trader);
        manager.expireRequest(reqId);

        (bool exitPending,) = manager.positionFlags(id);
        assertFalse(exitPending, "an expired close left the exit flag set");

        // A fresh close now goes through and settles, which it could not if the
        // flag were still set.
        CloseOut memory out = _close(id, 5000e18);
        (,,,,, bool open) = manager.positionAt(id);
        assertFalse(open, "the position did not close on the second request");
        assertGt(out.payout, NOTHING, "the second close paid nothing");
    }

    function test_ACloseReleasesTheReserveAndClearsTheExitFlag() public {
        uint256 id = _openAPosition();
        (, uint256 size,,,,) = manager.positionAt(id);
        uint256 reservedBefore = pool.reserved();

        _close(id, 5000e18);

        assertEq(reservedBefore - pool.reserved(), size, "the reserve was not released");
        (,,,,, bool open) = manager.positionAt(id);
        assertFalse(open, "the position is still open");
        (bool exitPending,) = manager.positionFlags(id);
        assertFalse(exitPending, "the exit flag was not cleared");
    }

    // --- independent reference ---------------------------------------------

    /// @notice The contract's payout, collection, bad debt and the three fee
    ///         shares equal a recompute written in plain arithmetic here, for a
    ///         fuzzed collateral, leverage and close price.
    function test_IndependentReferenceMatchesTheContract(uint256 postSeed, uint8 tierSeed, uint256 priceSeed) public {
        uint256 post = bound(postSeed, 0.5 ether, 20 ether);
        uint256[3] memory tiers = [uint256(2), 3, 5];
        uint256 leverage = tiers[tierSeed % 3];
        uint256 price = bound(priceSeed, 1000e18, 7000e18);

        uint256 id = _openAt(post, leverage);
        _fillFund(30 ether);

        uint256 ownerBefore = gold.balanceOf(trader);
        uint256 treasuryBefore = gold.balanceOf(treasury);
        uint256 fundBefore = gold.balanceOf(address(fund));
        uint256 poolBefore = gold.balanceOf(address(pool));

        CloseOut memory out = _close(id, price);
        Terms memory want = _expected(id, price);
        (uint256 toTreasury, uint256 toFund, uint256 toPool) = _shares(want.collected);

        assertEq(out.payout, want.payout, "payout");
        assertEq(out.collected, want.collected, "collected");
        assertEq(out.badDebt, want.badDebt, "badDebt");
        assertEq(out.toTreasury, toTreasury, "treasury share");
        assertEq(out.toFund, toFund, "fund share");
        assertEq(out.toPool, toPool, "pool share");
        assertEq(toTreasury + toFund + toPool, want.collected, "the shares did not sum to the collection");

        // The balance deltas match the figures, in unsigned conservation form so
        // no signed cast is needed: fund gains its fee and loses what it covered,
        // the pool loses the payout and the two fee shares and gains the cover.
        assertEq(gold.balanceOf(trader), ownerBefore + out.payout, "owner received the payout");
        assertEq(gold.balanceOf(treasury), treasuryBefore + out.toTreasury, "treasury received its share");
        assertEq(gold.balanceOf(address(fund)) + out.ifPaid, fundBefore + out.toFund, "fund delta");
        assertEq(
            gold.balanceOf(address(pool)) + out.payout + out.toTreasury + out.toFund,
            poolBefore + out.ifPaid,
            "pool delta"
        );
    }

    /// @notice D56 and D20: the three fee shares a close collects are on chain
    ///         in a FeeRouted event, the same event the open path uses.
    function test_TheFeeRoutedEventCarriesTheShares() public {
        uint256 id = _openAt(POST + 7, LEVERAGE);
        CloseOut memory out = _close(id, 5000e18);
        Terms memory want = _expected(id, 5000e18);
        (uint256 toTreasury, uint256 toFund, uint256 toPool) = _shares(want.collected);

        assertTrue(out.sawFeeRouted, "the close emitted no FeeRouted event");
        assertEq(out.toTreasury, toTreasury, "FeeRouted treasury share");
        assertEq(out.toFund, toFund, "FeeRouted fund share");
        assertEq(out.toPool, toPool, "FeeRouted pool share");
        assertEq(out.toTreasury + out.toFund + out.toPool, want.collected, "FeeRouted shares did not sum to collected");
    }

    /// @notice D49: when the fund cannot cover the whole bad debt, the pool
    ///         absorbs the rest, and that absorbed part is badDebt (CloseSettled)
    ///         less paid (the fund's Paid), both on chain.
    function test_ThePoolAbsorbedBadDebtIsDerivableFromTheLogs() public {
        uint256 id = _openAPosition();
        _fillFund(1 ether);
        uint256 fundBefore = fund.ounces();

        CloseOut memory out = _close(id, 1000e18);

        assertGt(out.badDebt, fundBefore, "this case wants the bad debt to exceed the fund");
        assertEq(out.ifPaid, fundBefore, "the fund did not pay all it held");
        uint256 absorbed = out.badDebt - out.ifPaid;
        assertGt(absorbed, NOTHING, "the pool absorbed nothing, so this proves nothing");
        assertEq(out.badDebt, out.ifPaid + absorbed, "the split of bad debt did not reconstruct from the logs");
    }

    // --- gas ----------------------------------------------------------------

    function test_GasForTheClosePath() public {
        // First close pays cold storage (fresh); the second touches slots the
        // first warmed (warm). Both must sit under the GAS_CLOSE estimate (D65).
        uint256 fresh = _measureCloseGas(_openAt(POST, 2));
        uint256 warm = _measureCloseGas(_openAt(POST, 3));

        assertLt(fresh, GAS_CLOSE, "a fresh settled close used more than the GAS_CLOSE estimate");
        assertLt(warm, GAS_CLOSE, "a warm settled close used more than the GAS_CLOSE estimate");
        emit log_named_uint("GAS_CLOSE settle gas, fresh", fresh);
        emit log_named_uint("GAS_CLOSE settle gas, warm", warm);
    }

    function _measureCloseGas(uint256 positionId) private returns (uint256 used) {
        vm.deal(trader, trader.balance + _feeFloor(GAS_CLOSE));
        vm.prank(trader);
        uint256 reqId = manager.requestClose{value: _feeFloor(GAS_CLOSE)}(positionId);
        (,,, uint256 target,,,,) = manager.requestAt(reqId);
        vm.warp(target);

        bytes memory report = abi.encode(_report(target, 5000e18));
        bytes[] memory update = _pyth(target, 5000e18);

        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        uint256 gasBefore = gasleft();
        manager.settleClose{value: PYTH_FEE}(reqId, report, update);
        used = gasBefore - gasleft();
    }

    // --- helpers ------------------------------------------------------------

    function _openAPosition() private returns (uint256 id) {
        id = _openAt(POST, LEVERAGE);
    }

    function _openAt(uint256 post, uint256 leverage) private returns (uint256 id) {
        _mint(trader, post);
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), post));
        vm.deal(trader, trader.balance + _feeFloor(GAS_OPEN));
        vm.prank(trader);
        uint256 request = manager.requestOpen{value: _feeFloor(GAS_OPEN)}(post, leverage);

        uint256 target = vm.getBlockTimestamp() + TARGET_DELAY;
        vm.warp(target);
        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(request, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));

        id = manager.nextPositionId() - 1;
        (,,,,, bool open) = manager.positionAt(id);
        assertTrue(open, "the fixture did not open a position");
    }

    function _close(uint256 positionId, uint256 price18) private returns (CloseOut memory out) {
        vm.deal(trader, trader.balance + _feeFloor(GAS_CLOSE));
        vm.prank(trader);
        uint256 reqId = manager.requestClose{value: _feeFloor(GAS_CLOSE)}(positionId);

        (,,, uint256 target,,,,) = manager.requestAt(reqId);
        vm.warp(target);

        vm.recordLogs();
        vm.deal(settler, settler.balance + PYTH_FEE);
        vm.prank(settler);
        manager.settleClose{value: PYTH_FEE}(reqId, abi.encode(_report(target, price18)), _pyth(target, price18));
        out = _decodeClose(vm.getRecordedLogs());
    }

    /// @dev The close's logs: CloseSettled for the dashboard figures, FeeRouted
    ///      for the three shares where they leave the pool, and the fund's Paid
    ///      for how much bad debt it covered. Each is checked where it is used.
    function _decodeClose(Vm.Log[] memory logs) private view returns (CloseOut memory out) {
        bool sawClose;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 topic = logs[i].topics.length == 0 ? bytes32(0) : logs[i].topics[0];
            if (topic == CLOSE_SETTLED_SIG) {
                (out.price18, out.payout, out.collected, out.badDebt) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                sawClose = true;
            } else if (topic == FEE_ROUTED_SIG) {
                (out.toTreasury, out.toFund, out.toPool) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                out.sawFeeRouted = true;
            } else if (topic == PAID_SIG && logs[i].emitter == address(fund)) {
                // Paid(to indexed, requested, paid); the covered amount is paid.
                (, uint256 paid) = abi.decode(logs[i].data, (uint256, uint256));
                out.ifPaid = paid;
            }
        }
        require(sawClose, "no CloseSettled event");
    }

    /// @dev The close terms recomputed in plain arithmetic, independent of the
    ///      contract helper, from the position's state and the index the
    ///      settlement wrote (read back after the close as the stored index).
    function _expected(uint256 positionId, uint256 price18) private view returns (Terms memory want) {
        (, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex,) = _positionBeforeClose(positionId);
        uint256 iNow = manager.indexStored();

        want.holdingFee = (size * (iNow - openIndex) + WAD - 1) / WAD;
        want.closeFee = (size * POSITION_FEE_BPS + BPS - 1) / BPS;

        // D29 written from scratch, not copied from the contract: the position
        // holds C + floor(s*P) and owes ceil(s*P_open). When it holds at least
        // what it owes, the equity the owner takes rounds down; when it owes
        // more, that shortfall is bad debt the fund owes the pool, so it rounds
        // up, here by adding one whenever the ounce division leaves a remainder.
        uint256 held = claim + (size * price18) / WAD;
        uint256 owed = (size * openPrice + WAD - 1) / WAD;
        uint256 grossPos = 0;
        if (held >= owed) {
            grossPos = ((held - owed) * WAD) / price18;
        } else {
            uint256 lossUsd = (owed - held) * WAD;
            uint256 floored = lossUsd / price18;
            want.badDebt = lossUsd % price18 == 0 ? floored : floored + 1;
        }

        uint256 fees = want.holdingFee + want.closeFee;
        want.collected = grossPos < fees ? grossPos : fees;
        want.payout = grossPos > fees ? grossPos - fees : 0;
    }

    /// @dev The position's terms as of the close. `positionAt` reads zero once
    ///      the position is closed, so the opening fields are captured from the
    ///      cached copy a test takes before it closes; here they are read from
    ///      the stored position, which the close leaves in place but for `open`.
    function _positionBeforeClose(uint256 positionId)
        private
        view
        returns (address owner, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex, bool open)
    {
        return manager.positionAt(positionId);
    }

    function _shares(uint256 collected) private view returns (uint256 toTreasury, uint256 toFund, uint256 toPool) {
        if (collected == 0) {
            return (0, 0, 0);
        }
        toTreasury = (collected * TREASURY_SHARE_BPS) / BPS;
        toFund = fund.atTarget() ? 0 : (collected * INSURANCE_SHARE_BPS) / BPS;
        toPool = collected - toTreasury - toFund;
    }

    function _fillFund(uint256 ounces) private {
        _mint(address(fund), ounces);
        // forge-lint: disable-next-line(unused-return)
        manager.pokeSyncFund();
    }

    function _config() private returns (PositionManager.Config memory) {
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
            lastUpdateTimestamp: uint32(target),
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

    function _feeFloor(uint256 gasEstimate) private pure returns (uint256) {
        return gasEstimate * GAS_PRICE;
    }

    receive() external payable {}
}
