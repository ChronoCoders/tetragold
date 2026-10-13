// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
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
import {ReenteringSettler} from "./mocks/ReenteringSettler.sol";

/// @notice The open path: the request, its execution fee, its escrow, and every
///         rule its settlement applies (D65, D66, D70, D71, section 5.1).
/// @dev The oracle is the real one over mocked sources, so a settlement here
///      goes through the whole of section 7 rather than a stand in for it. The
///      pool is seeded through the harness, because the manager's own LP
///      request path belongs to a later unit (D69).
contract PositionManagerOpenTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant NOTHING = 0;
    uint256 private constant TARGET_DELAY = 12;

    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant EXPIRY = 600;
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
    uint256 private constant GAS_OPEN = 400_000;
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
    uint32 private constant CLOSED_STATUS = 1;
    int192 private constant STREAM_PRICE = 4000e18;
    int64 private constant PYTH_PRICE = 4000e8;
    int32 private constant PYTH_EXPO = -8;
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
    uint256 private constant FUNDING = 10 ether;
    /// @dev Stated above the measurements rather than fitted to them. A
    ///      settlement's cost is dominated by the claim book's first touch of
    ///      the Fenwick nodes for the entry price's bucket, which is 14 slots
    ///      at this test's price and up to 20 at the bottom of the range, so
    ///      the ceiling leaves room for the deeper walk.
    uint256 private constant LEVERAGE_HIGH = 5;
    uint256 private constant REQUEST_CEILING = 400_000;
    uint256 private constant SETTLE_CEILING = 1_100_000;

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

        _mint(lp, SEED);
        _mint(trader, SEED);
        vm.deal(trader, FUNDING);
        vm.deal(settler, FUNDING);

        _seedPool(SEED);
    }

    function test_AnOpenRequestEscrowsTheGoldAndTheFee() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);

        assertEq(manager.escrowedOunces(), POST, "the escrow total did not take the gold");
        assertEq(gold.balanceOf(address(manager)), POST, "D66: the balance and the escrow total disagree");
        assertEq(gold.balanceOf(trader), SEED - POST, "the gold did not come from the trader");
        assertEq(address(manager).balance, _feeFloor(GAS_OPEN), "the execution fee did not arrive");

        (
            address requester,
            uint256 escrowed,
            uint256 executionFee,
            uint256 targetTime,
            uint256 positionId,
            uint256 leverage,
            PositionManager.Kind kind,
            PositionManager.State state
        ) = manager.requestAt(id);

        assertEq(requester, trader);
        assertEq(escrowed, POST);
        assertEq(executionFee, _feeFloor(GAS_OPEN));
        assertEq(targetTime, START + TARGET_DELAY, "the target is not one slot out");
        assertEq(positionId, NOTHING, "an open named a position");
        assertEq(leverage, LEVERAGE);
        assertEq(uint256(kind), uint256(PositionManager.Kind.Open));
        assertEq(uint256(state), uint256(PositionManager.State.Pending));
    }

    function test_AnOpenRequestRefusesItsOwnRules() public {
        vm.startPrank(trader);
        assertTrue(gold.approve(address(manager), SEED));

        vm.expectRevert(PositionManager.ZeroAmount.selector);
        // This call reverts by design, so no identifier comes back.
        // forge-lint: disable-next-line(unused-return)
        manager.requestOpen{value: _feeFloor(GAS_OPEN)}(NOTHING, LEVERAGE);

        vm.expectRevert(abi.encodeWithSelector(PositionManager.BadLeverage.selector, 4));
        // forge-lint: disable-next-line(unused-return)
        manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, 4);

        uint256 short = _feeFloor(GAS_OPEN) - 1;
        vm.expectRevert(abi.encodeWithSelector(PositionManager.FeeBelowEstimate.selector, short, _feeFloor(GAS_OPEN)));
        // forge-lint: disable-next-line(unused-return)
        manager.requestOpen{value: short}(POST, LEVERAGE);
        vm.stopPrank();
    }

    /// @dev D58: the brake stops an open request at the door, before any
    ///      escrow moves. D50 does the same when PAXG is unusable.
    function test_AnOpenRequestIsStoppedByTheBrakeAndByPaxg() public {
        vm.prank(guardian);
        manager.pauseInflows();

        vm.startPrank(trader);
        assertTrue(gold.approve(address(manager), SEED));
        vm.expectRevert(PositionManager.InflowsArePaused.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, LEVERAGE);
        vm.stopPrank();

        vm.prank(guardian);
        manager.unpauseInflows();
        paxg.setFrozen(address(vault), true);

        vm.prank(trader);
        vm.expectRevert(PositionManager.PaxgUnusable.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, LEVERAGE);

        assertEq(manager.escrowedOunces(), NOTHING, "a refused request escrowed something");
    }

    /// @dev Section 5.1 and D71 rule 2: s is q times k, the open fee comes out
    ///      of q, and the claim is what is left at the settled price.
    function test_AnOpenSettlesIntoAPositionAndAReserve() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        uint256 poolBefore = pool.ounces();

        _settleOpen(id);

        uint256 size = POST * LEVERAGE;
        uint256 feeOunces = _feeOunces(size);
        uint256 joined = POST - feeOunces;
        uint256 claim = (joined * PRICE_18) / WAD;

        (address owner, uint256 recordedSize, uint256 recordedClaim, uint256 openPrice, uint256 openIndex, bool open) =
            manager.positionAt(1);

        assertEq(owner, trader);
        assertEq(recordedSize, size, "s is not q times k");
        assertEq(recordedClaim, claim, "C is not what is left of q at the open price");
        assertEq(openPrice, PRICE_18);
        assertEq(openIndex, manager.indexStored(), "the position did not record the index it opened at");
        assertTrue(open);

        assertEq(pool.reserved(), size, "the pool did not reserve s");
        assertEq(manager.escrowedOunces(), NOTHING, "the escrow was not released");
        assertEq(gold.balanceOf(address(manager)), NOTHING, "D66: the manager kept gold");
        assertEq(pool.ounces(), poolBefore + joined + _poolShare(feeOunces), "the pool did not take q less the fee");
        assertEq(manager.depositClaimUsd(PRICE_18) > NOTHING, true, "the claim book did not take the position");
    }

    /// @dev D20: the fee splits three ways, and the fund's share goes to the
    ///      fund while it is under its target.
    function test_TheOpenFeeRoutesThreeWaysBelowTheTarget() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        uint256 feeOunces = _feeOunces(POST * LEVERAGE);

        _settleOpen(id);

        uint256 toTreasury = (feeOunces * TREASURY_SHARE_BPS) / BPS;
        uint256 toFund = (feeOunces * INSURANCE_SHARE_BPS) / BPS;

        assertGt(feeOunces, NOTHING, "the test fee is zero, so this proves nothing");
        assertEq(gold.balanceOf(treasury), toTreasury, "the treasury share did not arrive");
        assertEq(fund.ounces(), toFund, "the fund share did not arrive");
        assertEq(gold.balanceOf(address(fund)), toFund, "the fund's books and balance disagree");
    }

    /// @dev D20: once the fund is at its target the fund's share goes to the
    ///      pool instead.
    function test_TheOpenFeeGoesToThePoolOnceTheFundIsAtTarget() public {
        _fillTheFund();
        assertTrue(fund.atTarget(), "the fund was not filled");

        uint256 fundBefore = fund.ounces();
        uint256 poolBefore = pool.ounces();
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        uint256 feeOunces = _feeOunces(POST * LEVERAGE);
        uint256 joined = POST - feeOunces;

        _settleOpen(id);

        uint256 toTreasury = (feeOunces * TREASURY_SHARE_BPS) / BPS;

        assertEq(fund.ounces(), fundBefore, "the fund took a share while at its target");
        assertEq(gold.balanceOf(treasury), toTreasury, "the treasury share did not arrive");
        assertEq(pool.ounces(), poolBefore + joined + feeOunces - toTreasury, "the pool did not take the fund's share");
    }

    /// @dev D65: the settler is paid gas plus the Pyth fee out of the deposited
    ///      fee, keeps nothing of its own, and the rest is credited to the
    ///      requester to pull.
    function test_TheSettlerIsPaidAndTheRestIsCredited() public {
        uint256 fee = _feeFloor(GAS_OPEN) * 4;
        uint256 id = _requestOpenWithFee(trader, POST, LEVERAGE, fee);

        uint256 settlerBefore = settler.balance;
        _settleOpen(id);

        uint256 credited = manager.ethCredit(trader);
        uint256 paidToSettler = settler.balance - settlerBefore + PYTH_FEE;

        assertGt(paidToSettler, NOTHING, "the settler was paid nothing");
        assertEq(paidToSettler + credited, fee, "the fee did not split between the settler and the credit");
        // What the manager still holds is exactly the credit, which is waiting
        // to be pulled rather than kept (D70).
        assertEq(address(manager).balance, credited, "the manager held something besides the credit");

        uint256 traderBefore = trader.balance;
        vm.prank(trader);
        manager.withdrawCredit();

        assertEq(trader.balance, traderBefore + credited, "the credit did not pull");
        assertEq(manager.ethCredit(trader), NOTHING);
        assertEq(address(manager).balance, NOTHING, "the manager kept ETH after the credit was pulled");
    }

    /// @dev ETH can be forced into the oracle with SELFDESTRUCT, and the
    ///      oracle has no sweep. A settlement must not read its own balance to
    ///      learn what Pyth took: the oracle reports that figure, so the stray
    ///      ETH stays where it is and no settlement notices it. Measuring by
    ///      balance difference instead made every settlement revert on panic
    ///      0x11 once the stray exceeded the Pyth fee, which breaks I14.
    function test_StrayEthInTheOracleDoesNotDisturbASettlement() public {
        uint256[3] memory strays = [uint256(1), PYTH_FEE, 1 ether];
        address oracle = address(manager.SETTLEMENT_ORACLE());

        for (uint256 i = 0; i < strays.length; i++) {
            uint256 stray = strays[i];
            vm.deal(oracle, stray);

            uint256 fee = _feeFloor(GAS_OPEN) * 4;
            uint256 id = _requestOpenWithFee(trader, POST, LEVERAGE, fee);
            uint256 settlerBefore = settler.balance;

            _settleOpen(id);

            uint256 credited = manager.ethCredit(trader);
            uint256 paidToSettler = settler.balance - settlerBefore + PYTH_FEE;

            assertEq(paidToSettler + credited, fee, "the fee did not split between the settler and the credit");
            assertEq(address(manager).balance, credited, "the manager held something besides the credit");
            assertEq(oracle.balance, stray, "the stray ETH moved");

            vm.prank(trader);
            manager.withdrawCredit();
        }
    }

    function test_ACreditCannotBePulledTwiceOrByAnyoneElse() public {
        uint256 id = _requestOpenWithFee(trader, POST, LEVERAGE, _feeFloor(GAS_OPEN) * 4);
        _settleOpen(id);

        vm.prank(lp);
        vm.expectRevert(PositionManager.NothingToWithdraw.selector);
        manager.withdrawCredit();

        vm.startPrank(trader);
        manager.withdrawCredit();
        vm.expectRevert(PositionManager.NothingToWithdraw.selector);
        manager.withdrawCredit();
        vm.stopPrank();
    }

    /// @dev Section 7 rule 2 and rule 4: not before the target, not at or after
    ///      the deadline.
    function test_SettlementWaitsForTheTargetAndStopsAtTheDeadline() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        uint256 target = START + TARGET_DELAY;

        vm.warp(target - 1);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.TooEarly.selector, target));
        _settleOpenRaw(id, target);

        vm.warp(target + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.TooLate.selector, target + EXPIRY));
        _settleOpenRaw(id, target);

        vm.warp(target + EXPIRY - 1);
        _settleOpenRaw(id, target);
        assertEq(pool.reserved(), POST * LEVERAGE, "the last second of the window did not settle");
    }

    /// @dev Section 7 rule 4: an oracle that cannot prove a price for the target
    ///      reverts and the request waits, which is the one failure that is not
    ///      a rejection.
    function test_AnOracleFailureLeavesTheRequestPending() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        uint256 target = START + TARGET_DELAY;
        vm.warp(target);

        ReportV8 memory closed = _report(target);
        closed.marketStatus = CLOSED_STATUS;

        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByReport.selector, CLOSED_STATUS));
        manager.settleOpen{value: PYTH_FEE}(id, abi.encode(closed), _pythUpdate(target));

        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(id);
        assertEq(uint256(state), uint256(PositionManager.State.Pending), "an oracle failure ended the request");
        assertEq(manager.escrowedOunces(), POST, "an oracle failure released the escrow");
    }

    /// @dev D57: a position too small to be worth liquidating is rejected at
    ///      its price, and the gold goes back.
    function test_AnOpenUnderTheMinimumNotionalIsRejected() public {
        // Half the smallest q whose notional reaches the minimum, so the
        // rejection is the minimum's and not a rounding accident.
        uint256 tiny = (MIN_NOTIONAL_USD * WAD) / PRICE_18 / LEVERAGE / 2;
        uint256 id = _requestOpen(trader, tiny, LEVERAGE);
        uint256 heldBefore = gold.balanceOf(trader);

        _settleOpen(id);

        assertEq(gold.balanceOf(trader), heldBefore + tiny, "the escrow was not refunded");
        assertEq(manager.escrowedOunces(), NOTHING, "the escrow was not released");
        assertEq(pool.reserved(), NOTHING, "a rejected open reserved something");
        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(id);
        assertEq(uint256(state), uint256(PositionManager.State.Rejected), "the request did not end as rejected");
    }

    /// @dev D46 bounds R after the open, so an open whose own collateral is
    ///      what makes it fit must settle. At 3x on a pool of 1000 ounces the
    ///      old reading of the ceiling stopped at 266 ounces posted; this one
    ///      posts 300, which only fits because its own 299 join the pool first.
    function test_AnOpenThatFitsOnlyBecauseOfItsOwnCollateralSettles() public {
        uint256 post = 300 ether;
        assertGt(post * LEVERAGE, pool.reservableOunces(), "the old reading would have allowed this anyway");

        uint256 id = _requestOpen(trader, post, LEVERAGE);
        _settleOpen(id);

        assertEq(pool.reserved(), post * LEVERAGE, "an open that fits was rejected");
        assertLe(pool.reserved() * BPS, pool.ounces() * U_MAX_BPS, "I7: the open that settled broke the ceiling");
    }

    /// @dev And one that does not fit even with its own collateral in the pool
    ///      is rejected rather than reverting inside the reserve (D70).
    function test_AnOpenPastTheReserveCeilingIsRejected() public {
        uint256 post = 400 ether;
        uint256 id = _requestOpen(trader, post, LEVERAGE);

        _settleOpen(id);

        assertEq(pool.reserved(), NOTHING, "the reserve ceiling let an open through");
        assertEq(gold.balanceOf(trader), SEED, "the escrow was not refunded");
        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(id);
        assertEq(uint256(state), uint256(PositionManager.State.Rejected), "the request did not end as rejected");
    }

    /// @dev D46 and D70: the manager's own ceiling check and the pool's
    ///      `reserve` check must agree exactly. If the manager's were the
    ///      looser of the two, an open at the edge would pass it and then
    ///      revert inside `reserve`, which leaves the request pending until
    ///      expiry and wastes the settler's gas instead of rejecting it.
    ///
    ///      The pool reserves against its ounces after this open's gold has
    ///      landed, so the manager predicts that figure: its ounces now, plus
    ///      what joins, plus the pool's own share of the fee. The fuzz walks q
    ///      across the edge, with and without the fund at its target so the
    ///      pool's share of the fee changes, and asserts the settlement never
    ///      reverts.
    function testFuzz_TheTwoCeilingChecksNeverDisagree(uint256 postSeed, bool fundAtTarget) public {
        if (fundAtTarget) {
            _fillTheFund();
        }
        // Either side of the edge, which at 3x on this pool sits near 363
        // ounces posted.
        uint256 post = bound(postSeed, 360 ether, 367 ether);
        _mint(trader, post);

        uint256 id = _requestOpen(trader, post, LEVERAGE);
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        vm.prank(settler);
        try manager.settleOpen{value: PYTH_FEE}(id, abi.encode(_report(target)), _pythUpdate(target)) {
        // Settled or rejected: both are answers, and the next lines say
        // which one it was and that it was a sound one.
        }
        catch (bytes memory reason) {
            assertTrue(
                bytes4(reason) != CounterpartyPool.ReserveBreaksCoverage.selector,
                "the manager let an open through that the pool's own check refused"
            );
            assertTrue(false, "a settlement reverted instead of settling or rejecting");
        }

        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(id);
        assertTrue(
            state == PositionManager.State.Settled || state == PositionManager.State.Rejected,
            "the request neither settled nor was rejected"
        );
        if (state == PositionManager.State.Settled) {
            assertLe(pool.reserved() * BPS, pool.ounces() * U_MAX_BPS, "I7: a settled open broke the ceiling");
        }
    }

    /// @dev The edge itself, worked out by hand so the test does not search for
    ///      it. On a pool of 1100.84 ounces, 400 posted at 3x pays a fee of 1.2
    ///      and sends 0.36 of it to the pool, so 1500 ounces stand against a
    ///      reserve of 1200, which is exactly u_max of them. It must settle,
    ///      and the smallest step up in size must not.
    function test_AnOpenExactlyAtTheCeilingSettlesAndOneStepMoreDoesNot() public {
        uint256 extra = 100.84 ether;
        _mint(lp, extra);
        _seedPool(extra);
        assertEq(pool.ounces(), 1100.84 ether, "the pool was not seeded to the figure this test needs");

        uint256 post = 400 ether;
        uint256 size = post * LEVERAGE;
        uint256 feeOunces = _feeOunces(size);
        uint256 poolAfter = pool.ounces() + post - feeOunces + _poolShare(feeOunces);
        assertEq((poolAfter * U_MAX_BPS) / BPS, size, "this is not the exact edge");

        _mint(trader, post * 2);
        uint256 id = _requestOpen(trader, post, LEVERAGE);
        _settleOpen(id);

        assertEq(pool.reserved(), size, "an open exactly at the ceiling was rejected");
        assertEq(pool.reserved() * BPS, pool.ounces() * U_MAX_BPS, "the settled open is not sitting on the edge");

        // One wei more posted is k wei more of size, which is the smallest step
        // this tier can take past the edge.
        uint256 over = _requestOpen(trader, post + 1, LEVERAGE);
        _settleOpen(over);

        assertEq(pool.reserved(), size, "a step past the ceiling was taken");
        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(over);
        assertEq(uint256(state), uint256(PositionManager.State.Rejected), "the step past the edge was not rejected");
    }

    /// @dev D71: once f times the largest tier reaches one, the open fee would
    ///      be the whole collateral, so the constructor refuses it rather than
    ///      letting a settlement panic on the subtraction.
    function test_TheConstructorBoundsTheFeeAgainstTheLargestTier() public {
        PositionManager.Config memory config = _config();
        config.positionFeeBps = BPS / LEVERAGE_HIGH;
        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.FeeTooHighForLeverage.selector, BPS / LEVERAGE_HIGH, LEVERAGE_HIGH)
        );
        new PositionManagerHarness(config);

        config = _config();
        config.positionFeeBps = BPS / LEVERAGE_HIGH - 1;
        PositionManagerHarness justInside = new PositionManagerHarness(config);
        assertEq(justInside.POSITION_FEE_BPS(), BPS / LEVERAGE_HIGH - 1, "the boundary value was refused");
    }

    /// @dev D31: the section is held across the settler's payment, so a settler
    ///      that tries to come back in fails its own settlement and nothing
    ///      else. It comes back through `requestOpen`, a different locked path,
    ///      so the lock is what refuses it rather than the state machine of the
    ///      settlement it is inside.
    function test_AReenteringSettlerOnlyBreaksItsOwnSettlement() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        ReenteringSettler attacker = new ReenteringSettler(manager);
        vm.deal(address(attacker), FUNDING);

        vm.expectRevert(
            abi.encodeWithSelector(PositionManager.TransferFailed.selector, address(attacker), _settlerPay(id))
        );
        attacker.settle(
            id, abi.encode(_report(target)), _pythUpdate(target), PYTH_FEE, POST, LEVERAGE, _feeFloor(GAS_OPEN), true
        );

        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State state) = manager.requestAt(id);
        assertEq(uint256(state), uint256(PositionManager.State.Pending), "the failed settlement changed the request");
        assertEq(pool.reserved(), NOTHING, "the failed settlement reserved something");

        _settleOpenRaw(id, target);
        assertEq(pool.reserved(), POST * LEVERAGE, "an honest settler could not settle afterwards");
    }

    /// @dev And the thing that refuses the reentry is the shared lock, not the
    ///      state machine of the settlement it is inside. This settler swallows
    ///      the refusal instead of passing it on, so its settlement finishes
    ///      and the reason it recorded survives to be read.
    function test_TheSharedLockIsWhatRefusesAReentry() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);

        ReenteringSettler attacker = new ReenteringSettler(manager);
        vm.deal(address(attacker), FUNDING);

        attacker.settle(
            id, abi.encode(_report(target)), _pythUpdate(target), PYTH_FEE, POST, LEVERAGE, _feeFloor(GAS_OPEN), false
        );

        assertEq(
            attacker.lastReason(),
            abi.encodeWithSelector(ReentrancyLock.Held.selector, address(manager)),
            "the reentry was refused by something other than the shared lock"
        );
        assertEq(pool.reserved(), POST * LEVERAGE, "the settlement did not finish once the reentry was swallowed");
    }

    /// @dev Only the oracle may pay this contract, so stray ETH cannot get
    ///      stuck where nothing can pay it out.
    function test_OnlyTheOracleMayPayTheManager() public {
        vm.deal(trader, FUNDING);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.UnexpectedEth.selector, trader));
        // The destination is the contract under test, not an address a caller
        // chose, and the call reverts by design.
        // forge-lint: disable-next-line(arbitrary-send-eth,low-level-calls,unused-return)
        (bool sent,) = address(manager).call{value: 1 wei}("");
        sent;

        address oracle = address(manager.SETTLEMENT_ORACLE());
        vm.deal(oracle, FUNDING);
        vm.prank(oracle);
        // forge-lint: disable-next-line(arbitrary-send-eth,low-level-calls)
        (bool fromOracle,) = address(manager).call{value: 1 wei}("");
        assertTrue(fromOracle, "the oracle could not refund the manager");
        assertEq(address(manager).balance, 1 wei, "the refund did not land");
    }

    /// @dev D58 and D50 again, this time at settlement: the brake and PAXG are
    ///      read a second time, because both can change between the request and
    ///      the price.
    function test_TheBrakeAndPaxgRejectAtSettlement() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        vm.prank(guardian);
        manager.pauseInflows();

        _settleOpen(id);

        assertEq(pool.reserved(), NOTHING, "the brake let an open settle");
        assertEq(gold.balanceOf(trader), SEED, "the escrow was not refunded");

        vm.prank(guardian);
        manager.unpauseInflows();
        uint256 second = _requestOpen(trader, POST, LEVERAGE);
        paxg.setPaused(true);

        _settleOpen(second);

        assertEq(pool.reserved(), NOTHING, "PAXG unusable let an open settle");
        assertEq(gold.balanceOf(trader), SEED, "the escrow was not refunded");
    }

    /// @dev Section 7 rule 4: the requester takes the whole fee back on expiry,
    ///      with the escrow.
    function test_AnExpiredRequestRefundsEverything() public {
        uint256 fee = _feeFloor(GAS_OPEN);
        uint256 id = _requestOpenWithFee(trader, POST, LEVERAGE, fee);
        uint256 target = START + TARGET_DELAY;

        vm.warp(target + EXPIRY - 1);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotExpiredYet.selector, target + EXPIRY));
        manager.expireRequest(id);

        vm.warp(target + EXPIRY);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotRequester.selector, lp, trader));
        manager.expireRequest(id);

        vm.prank(trader);
        manager.expireRequest(id);

        assertEq(gold.balanceOf(trader), SEED, "the escrow did not come back");
        assertEq(manager.escrowedOunces(), NOTHING);
        assertEq(manager.ethCredit(trader), fee, "the whole fee was not credited");
    }

    /// @dev D71 rule 6: the deposit measure also carries the close fee every
    ///      open position will owe, and the withdrawal measure does not.
    function test_TheDepositMeasureCarriesTheCloseFee() public {
        uint256 id = _requestOpen(trader, POST, LEVERAGE);
        _settleOpen(id);

        uint256 closeFee = manager.closeFeeUsd(PRICE_18);
        uint256 raw = manager.withdrawalClaimUsd(PRICE_18);

        assertGt(closeFee, NOTHING, "the close fee term is zero, so this proves nothing");
        assertEq(
            closeFee,
            (pool.reserved() * PRICE_18 * POSITION_FEE_BPS + BPS * WAD - 1) / (BPS * WAD),
            "the close fee term is not f of notional rounded up"
        );
        assertLt(manager.depositClaimUsd(PRICE_18), raw, "the deposit measure did not carry the close fee");
    }

    /// @notice What an open costs to request and to settle (D65, O5).
    /// @dev The same conditions as the other gas tables: isolation is on, so
    ///      each call is its own transaction and every read is cold. These are
    ///      the measured inputs for the estimate the execution fee is quoted
    ///      against, and the ceilings are stated above the measurements rather
    ///      than fitted to them.
    function test_GasForTheOpenPath() public {
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), POST));

        uint256 before = gasleft();
        vm.prank(trader);
        uint256 id = manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, LEVERAGE);
        uint256 requestGas = before - gasleft();

        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);
        bytes memory payload = abi.encode(_report(target));
        bytes[] memory update = _pythUpdate(target);

        before = gasleft();
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(id, payload, update);
        uint256 settleGas = before - gasleft();

        console2.log("requestOpen, fresh request slots ", requestGas);
        console2.log("settleOpen, first open position  ", settleGas);
        console2.log("GAS_OPEN as configured           ", GAS_OPEN);
        console2.log("GAS_OVERHEAD as configured       ", GAS_OVERHEAD);

        assertLt(requestGas, REQUEST_CEILING, "a request cost more than the stated ceiling");
        assertLt(settleGas, SETTLE_CEILING, "a settlement cost more than the stated ceiling");
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
            requestExpiry: EXPIRY,
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
        vm.prank(lp);
        assertTrue(gold.approve(address(pool), ounces));
        uint256 id = manager.seedRequest(lp, ounces);
        vm.warp(block.timestamp + TARGET_DELAY);
        // forge-lint: disable-next-line(unused-return)
        manager.seedSettle(id, PRICE_18);
        vm.warp(START);
    }

    /// @dev Fees the fund's own way, to put it at its routing target.
    function _fillTheFund() private {
        _mint(address(this), IF_TARGET);
        assertTrue(gold.transfer(address(fund), IF_TARGET));
        manager.pokeSyncFund();
    }

    function _requestOpen(address who, uint256 ounces, uint256 leverage) private returns (uint256 id) {
        return _requestOpenWithFee(who, ounces, leverage, _feeFloor(GAS_OPEN));
    }

    function _requestOpenWithFee(address who, uint256 ounces, uint256 leverage, uint256 fee)
        private
        returns (uint256 id)
    {
        vm.prank(who);
        assertTrue(gold.approve(address(manager), ounces));
        vm.prank(who);
        id = manager.requestOpen{value: fee}(ounces, leverage);
    }

    /// @dev The request's own target, read back rather than assumed, because a
    ///      second request in the same test records a later one.
    function _settleOpen(uint256 id) private {
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);
        _settleOpenRaw(id, target);
    }

    function _settleOpenRaw(uint256 id, uint256 target) private {
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(id, abi.encode(_report(target)), _pythUpdate(target));
    }

    function _report(uint256 target) private pure returns (ReportV8 memory) {
        return ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: uint32(target) - WINDOW,
            observationsTimestamp: uint32(target) + WINDOW,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(target) + EXPIRY_AHEAD,
            lastUpdateTimestamp: uint32(target),
            midPrice: STREAM_PRICE,
            marketStatus: OPEN_STATUS
        });
    }

    function _pythUpdate(uint256 target) private pure returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: PYTH_ID,
                price: IPyth.Price({price: PYTH_PRICE, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)}),
                emaPrice: IPyth.Price({price: PYTH_PRICE, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)})
            })
        );
    }

    /// @dev What the manager owes a settler for a request, which is the whole
    ///      deposited fee whenever the gas it took exceeds the deposit.
    function _settlerPay(uint256 id) private view returns (uint256) {
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 fee,,,,,) = manager.requestAt(id);
        return fee;
    }

    function _feeFloor(uint256 gasEstimate) private pure returns (uint256) {
        return gasEstimate * GAS_PRICE;
    }

    function _feeOunces(uint256 size) private pure returns (uint256) {
        return (size * POSITION_FEE_BPS + BPS - 1) / BPS;
    }

    function _poolShare(uint256 feeOunces) private pure returns (uint256) {
        uint256 toTreasury = (feeOunces * TREASURY_SHARE_BPS) / BPS;
        uint256 toFund = (feeOunces * INSURANCE_SHARE_BPS) / BPS;
        return feeOunces - toTreasury - toFund;
    }

    receive() external payable {}
}
