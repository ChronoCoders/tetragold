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

/// @notice Adding collateral to an open position: who may ask, what the
///         settled price decides, and what a rejection gives back (D43).
/// @dev The oracle is the real one over mocked sources, so the price a
///      settlement here uses comes through the whole of section 7. The close
///      and liquidation paths belong to later units, so the two position flags
///      they will set are planted through the harness.
contract PositionManagerAddTest is Test {
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
    uint256 private constant ADD = 0.5 ether;
    uint256 private constant LEVERAGE = 3;
    uint256 private constant FUNDING = 10 ether;
    /// @dev Stated above the measurements. An add touches the same Fenwick
    ///      nodes as the open that made the position, so its settlement is
    ///      the cheaper of the two paths, and the ceiling still leaves room
    ///      for a deeper walk at the bottom of the price range.
    uint256 private constant REQUEST_CEILING = 400_000;
    uint256 private constant SETTLE_CEILING = 800_000;

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

    uint256 private positionId;

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
        vm.deal(lp, FUNDING);

        _seedPool(SEED);
        positionId = _openAPosition();
    }

    function test_AnAddRequestEscrowsTheGoldAndNamesThePosition() public {
        uint256 traderBefore = gold.balanceOf(trader);
        uint256 id = _requestAdd(trader, positionId, ADD);

        assertEq(manager.escrowedOunces(), ADD, "the escrow total did not take the gold");
        assertEq(gold.balanceOf(address(manager)), ADD, "D66: the balance and the escrow total disagree");
        assertEq(gold.balanceOf(trader), traderBefore - ADD, "the gold did not come from the owner");

        (
            address requester,
            uint256 escrowed,
            uint256 executionFee,
            uint256 targetTime,
            uint256 named,
            uint256 leverage,
            PositionManager.Kind kind,
            PositionManager.State state
        ) = manager.requestAt(id);

        assertEq(requester, trader);
        assertEq(escrowed, ADD);
        assertEq(executionFee, _feeFloor(GAS_ADD));
        assertEq(targetTime, block.timestamp + TARGET_DELAY, "the target is not one slot out");
        assertEq(named, positionId, "the request did not name the position");
        assertEq(leverage, NOTHING, "an add carried a leverage");
        assertEq(uint256(kind), uint256(PositionManager.Kind.Add));
        assertEq(uint256(state), uint256(PositionManager.State.Pending));
    }

    /// @dev D43: the owner of an open position is the only one who may add to
    ///      it, so a stranger and an unknown identifier are refused apart.
    ///      The stranger holds gold and has approved it, so the owner rule is
    ///      the only thing left to refuse the second call. Without that an
    ///      empty balance would refuse it just as well and the rule could be
    ///      missing.
    function test_AnAddRequestRefusesWhatIsNotTheOwnersOpenPosition() public {
        _mint(lp, ADD);
        assertEq(gold.balanceOf(lp), ADD, "the stranger holds no gold, so the refusal proves nothing");

        vm.prank(lp);
        assertTrue(gold.approve(address(manager), SEED));

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NoSuchPosition.selector, positionId + 1));
        // This call reverts by design, so no identifier comes back.
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId + 1, ADD);

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.NotPositionOwner.selector, lp, trader));
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ADD);

        assertEq(manager.escrowedOunces(), NOTHING, "a refused request escrowed something");
    }

    function test_AnAddRequestRefusesItsOwnRules() public {
        vm.startPrank(trader);
        assertTrue(gold.approve(address(manager), SEED));

        vm.expectRevert(PositionManager.ZeroAmount.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, NOTHING);

        uint256 short = _feeFloor(GAS_ADD) - 1;
        vm.expectRevert(abi.encodeWithSelector(PositionManager.FeeBelowEstimate.selector, short, _feeFloor(GAS_ADD)));
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: short}(positionId, ADD);
        vm.stopPrank();
    }

    /// @dev D58 lists add collateral among the inflows the brake stops, and
    ///      D50 does the same when PAXG is unusable. Both refuse at the door,
    ///      before any escrow moves.
    function test_AnAddRequestIsStoppedByTheBrakeAndByPaxg() public {
        vm.prank(guardian);
        manager.pauseInflows();

        vm.startPrank(trader);
        assertTrue(gold.approve(address(manager), SEED));
        vm.expectRevert(PositionManager.InflowsArePaused.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ADD);
        vm.stopPrank();

        vm.prank(guardian);
        manager.unpauseInflows();
        paxg.setFrozen(address(vault), true);

        vm.prank(trader);
        vm.expectRevert(PositionManager.PaxgUnusable.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ADD);

        assertEq(manager.escrowedOunces(), NOTHING, "a refused request escrowed something");
    }

    /// @dev D43 rule 3: an owner cannot race an exit with a rescue.
    function test_AnAddRequestIsRefusedWhileAnExitIsPending() public {
        manager.pokeFlags(positionId, true, false);

        vm.prank(trader);
        assertTrue(gold.approve(address(manager), SEED));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(PositionManager.ExitPending.selector, positionId));
        // forge-lint: disable-next-line(unused-return)
        manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ADD);

        manager.pokeFlags(positionId, false, false);
        uint256 id = _requestAdd(trader, positionId, ADD);
        assertEq(manager.escrowedOunces(), ADD, "the add was still refused once the exit was gone");
        _settleAdd(id, PRICE_18);
    }

    /// @dev D43 rule 5 and rule 6: q joins the pool and raises C by q * P,
    ///      while s and the reserve it holds are untouched.
    function test_AnAddSettlesIntoAHigherClaimAndLeavesTheSizeAlone() public {
        Snapshot memory start = _snapshot();
        uint256 id = _requestAdd(trader, positionId, ADD);
        uint256 expected = start.claim + (ADD * PRICE_18) / WAD;

        // The deposit measure subtracts the holding fee owed, which grows with
        // the clock, so it is read at the instant the settlement runs, with the
        // index already advanced to it. Then the only thing left to move the
        // measure is the add itself.
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);
        manager.pokeAdvance();
        start.deposit = manager.depositClaimUsd(PRICE_18);

        vm.expectEmit(address(manager));
        emit PositionManager.AddSettled(id, positionId, ADD, expected, PRICE_18);
        vm.prank(settler);
        manager.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));

        Snapshot memory end = _snapshot();

        assertTrue(end.open);
        assertEq(end.claim, expected, "C did not rise by q times the settled price");
        assertEq(end.size, start.size, "an add moved s");
        assertEq(end.openPrice, start.openPrice, "an add moved the open price");
        assertEq(end.openIndex, start.openIndex, "an add moved the fee index the position opened at");

        assertEq(end.poolOunces, start.poolOunces + ADD, "the pool did not take q");
        assertEq(end.reserved, start.reserved, "an add moved the reserve");
        assertEq(manager.escrowedOunces(), NOTHING, "the escrow was not released");
        assertEq(gold.balanceOf(address(manager)), NOTHING, "D66: the manager kept gold");
        assertEq(
            end.deposit, start.deposit + (ADD * PRICE_18) / WAD, "the claim book did not take the added collateral"
        );
    }

    /// @dev D43 rule 4: settling proves the position healthy at a settled
    ///      price, which is what clears the D22 fallback flag.
    function test_AnAddClearsTheFallbackFlag() public {
        manager.pokeFlags(positionId, false, true);
        (, bool flagged) = manager.positionFlags(positionId);
        assertTrue(flagged, "the flag was not planted, so clearing it proves nothing");

        _settleAdd(_requestAdd(trader, positionId, ADD), PRICE_18);

        (bool exitPending, bool afterSettle) = manager.positionFlags(positionId);
        assertFalse(afterSettle, "a settled add left the fallback flag up");
        assertFalse(exitPending, "a settled add raised the exit flag");
    }

    /// @dev I28 as r6.17 revises it: a pending add is an inflow, so the brake
    ///      rejects it at settlement rather than holding it until the brake
    ///      lifts (D70).
    function test_AnAddIsRejectedWhenTheBrakeComesOnAfterTheRequest() public {
        (,, uint256 claimBefore,,,) = manager.positionAt(positionId);
        uint256 traderBefore = gold.balanceOf(trader);
        uint256 id = _requestAdd(trader, positionId, ADD);

        vm.prank(guardian);
        manager.pauseInflows();

        vm.expectEmit(address(manager));
        emit PositionManager.RequestRejected(id, trader, PositionManager.Reason.InflowsPaused, PRICE_18);
        _settleAdd(id, PRICE_18);

        (,, uint256 claimAfter,,,) = manager.positionAt(positionId);
        assertEq(claimAfter, claimBefore, "a rejected add still raised C");
        assertEq(gold.balanceOf(trader), traderBefore, "D70: the escrow did not come back in full");
        assertEq(manager.escrowedOunces(), NOTHING, "the escrow total still holds a rejected add");
        assertEq(uint256(_stateOf(id)), uint256(PositionManager.State.Rejected));
    }

    function test_AnAddIsRejectedWhenPaxgGoesUnusableAfterTheRequest() public {
        uint256 traderBefore = gold.balanceOf(trader);
        uint256 id = _requestAdd(trader, positionId, ADD);

        paxg.setPaused(true);

        vm.expectEmit(address(manager));
        emit PositionManager.RequestRejected(id, trader, PositionManager.Reason.PaxgUnusable, PRICE_18);
        _settleAdd(id, PRICE_18);

        assertEq(gold.balanceOf(trader), traderBefore, "D70: the escrow did not come back in full");
    }

    /// @dev A close can settle between the add's request and its settlement,
    ///      in which case there is nothing left to add to.
    function test_AnAddIsRejectedWhenThePositionIsGone() public {
        uint256 traderBefore = gold.balanceOf(trader);
        uint256 id = _requestAdd(trader, positionId, ADD);

        manager.pokeClose(positionId);

        vm.expectEmit(address(manager));
        emit PositionManager.RequestRejected(id, trader, PositionManager.Reason.PositionClosed, PRICE_18);
        _settleAdd(id, PRICE_18);

        assertEq(gold.balanceOf(trader), traderBefore, "D70: the escrow did not come back in full");
    }

    /// @dev D43 rule 2: the price decides. The two prices here sit either side
    ///      of the position's liquidation level, so the same request settles
    ///      one way at 2900 and the other at 2800.
    function test_AnAddIsRejectedAtAPriceThatLiquidatesThePosition() public {
        uint256 low = 2800e18;
        uint256 high = 2900e18;
        assertTrue(manager.liquidatableAt(positionId, low), "the low price does not liquidate, so this proves nothing");
        assertFalse(manager.liquidatableAt(positionId, high), "the high price liquidates too");

        uint256 traderBefore = gold.balanceOf(trader);
        uint256 rejected = _requestAdd(trader, positionId, ADD);

        vm.expectEmit(address(manager));
        emit PositionManager.RequestRejected(rejected, trader, PositionManager.Reason.Liquidatable, low);
        _settleAdd(rejected, low);

        assertEq(gold.balanceOf(trader), traderBefore, "D70: the escrow did not come back in full");

        (,, uint256 claimBefore,,,) = manager.positionAt(positionId);
        uint256 settled = _requestAdd(trader, positionId, ADD);
        _settleAdd(settled, high);

        (,, uint256 claimAfter,,,) = manager.positionAt(positionId);
        assertEq(claimAfter, claimBefore + (ADD * high) / WAD, "the add above the level did not settle");
    }

    /// @dev D43 rule 5 at the exact edge: C may reach s * P_open and not pass
    ///      it, and one wei of gold more is one step too far.
    function test_AnAddExactlyAtTheNotionalCeilingSettlesAndOneWeiMoreDoesNot() public {
        (, uint256 size, uint256 claim, uint256 openPrice,,) = manager.positionAt(positionId);
        uint256 room = (size * openPrice) / WAD - claim;
        uint256 exact = (room * WAD) / PRICE_18;
        assertEq((exact * PRICE_18) / WAD, room, "the edge is not exact, so the one wei step proves nothing");

        uint256 tooMuch = _requestAdd(trader, positionId, exact + 1);
        vm.expectEmit(address(manager));
        emit PositionManager.RequestRejected(tooMuch, trader, PositionManager.Reason.ClaimWouldPassNotional, PRICE_18);
        _settleAdd(tooMuch, PRICE_18);

        uint256 id = _requestAdd(trader, positionId, exact);
        _settleAdd(id, PRICE_18);

        (,, uint256 claimAfter,,,) = manager.positionAt(positionId);
        assertEq(claimAfter, (size * openPrice) / WAD, "C did not reach the notional exactly");
        assertEq(uint256(_stateOf(id)), uint256(PositionManager.State.Settled));
    }

    /// @dev 5.4 rule 1 written the other way round, in signed arithmetic, so a
    ///      term dropped or moved in the manager's unsigned rearrangement
    ///      shows up as a disagreement at some price.
    function testFuzz_TheLiquidationCheckMatchesTheSpecFormula(uint256 priceSeed, uint256 wait) public {
        uint256 price18 = bound(priceSeed, 1000e18, 9000e18);
        vm.warp(block.timestamp + bound(wait, 0, 365 days));
        manager.pokeAdvance();

        (, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex,) = manager.positionAt(positionId);
        uint256 feeOunces = _ceilDiv(size * (manager.indexNow() - openIndex), WAD);
        uint256 notional = (size * price18) / WAD;

        int256 equity = int256(claim) + int256(notional) - int256(_ceilDiv(size * openPrice, WAD))
            - int256(_ceilDiv(feeOunces * price18, WAD));
        int256 threshold = int256(_ceilDiv(notional * MAINTENANCE_MARGIN_BPS, BPS));

        assertEq(manager.liquidatableAt(positionId, price18), equity < threshold, "the two forms disagree");
    }

    /// @dev 5.4 rule 1 is strict: equity exactly at the maintenance margin of
    ///      the notional is not liquidatable, and one wei under it is. The
    ///      position is written straight into the manager because no open
    ///      settles onto that edge by itself.
    function test_TheLiquidationThresholdIsStrictAtTheEdge() public {
        Edge memory edge = _edge();
        assertTrue(edge.feeOunces * WAD > edge.size * edge.indexDelta, "the fee is whole, so the edge is not one");

        uint256 at = manager.pokePosition(trader, edge.size, edge.claimAtThreshold, PRICE_18, edge.openIndex);
        uint256 under = manager.pokePosition(trader, edge.size, edge.claimAtThreshold - 1, PRICE_18, edge.openIndex);

        assertFalse(manager.liquidatableAt(at, PRICE_18), "equity exactly at the margin was called liquidatable");
        assertTrue(manager.liquidatableAt(under, PRICE_18), "equity one wei under the margin was not");
    }

    /// @dev D29 on the holding fee: a fractional fee is charged as the next
    ///      whole wei of ounces, which is against the owner. Floored instead,
    ///      the position below would come out healthy.
    function test_TheLiquidationCheckRoundsTheHoldingFeeUp() public {
        Edge memory edge = _edge();
        uint256 flooredFee = (edge.size * edge.indexDelta) / WAD;
        uint256 feeUsdUp = _ceilDiv(edge.feeOunces * PRICE_18, WAD);
        uint256 feeUsdDown = _ceilDiv(flooredFee * PRICE_18, WAD);

        assertGt(edge.feeOunces, flooredFee, "the fee is whole, so the direction cannot be read");
        // One wei under the edge only tells the two apart if the floored fee
        // costs at least two wei less than the fee at the ceiling.
        assertGt(feeUsdUp, feeUsdDown + 1, "the two roundings are too close to read a direction from");

        uint256 positionId =
            manager.pokePosition(trader, edge.size, edge.claimAtThreshold - 1, PRICE_18, edge.openIndex);

        assertTrue(manager.liquidatableAt(positionId, PRICE_18), "the holding fee was not charged at the ceiling");
    }

    /// @dev Section 7 rule 4: an add that nobody settles inside its window
    ///      gives the gold and the fee back, like any other request (I17).
    function test_AnExpiredAddReturnsTheGoldAndTheFee() public {
        uint256 traderBefore = gold.balanceOf(trader);
        uint256 id = _requestAdd(trader, positionId, ADD);
        (,, uint256 fee, uint256 target,,,,) = manager.requestAt(id);

        vm.warp(target + EXPIRY);
        vm.prank(trader);
        manager.expireRequest(id);

        assertEq(gold.balanceOf(trader), traderBefore, "the escrow did not come back");
        assertEq(manager.escrowedOunces(), NOTHING, "the escrow total still holds an expired add");
        assertEq(manager.ethCredit(trader), fee, "the execution fee was not credited back");
        assertEq(uint256(_stateOf(id)), uint256(PositionManager.State.Expired));
    }

    /// @dev The same stray ETH as on the open path: the add settles, the
    ///      claim rises, and the ETH forced into the oracle stays there.
    function test_StrayEthInTheOracleDoesNotDisturbAnAdd() public {
        address oracle = address(manager.SETTLEMENT_ORACLE());
        vm.deal(oracle, 1 ether);

        (,, uint256 claimBefore,,,) = manager.positionAt(positionId);
        _settleAdd(_requestAdd(trader, positionId, ADD), PRICE_18);

        (,, uint256 claimAfter,,,) = manager.positionAt(positionId);
        assertEq(claimAfter, claimBefore + (ADD * PRICE_18) / WAD, "the add did not settle");
        assertEq(oracle.balance, 1 ether, "the stray ETH moved");
        assertEq(address(manager).balance, manager.ethCredit(trader), "the manager held more than the credit");
    }

    function test_GasForTheAddPath() public {
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), SEED));

        vm.prank(trader);
        uint256 before = gasleft();
        uint256 id = manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(positionId, ADD);
        uint256 request = before - gasleft();

        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);
        vm.prank(settler);
        before = gasleft();
        manager.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));
        uint256 settle = before - gasleft();

        console2.log("add request gas", request);
        console2.log("add settlement gas", settle);

        assertLt(request, REQUEST_CEILING, "the add request outgrew its ceiling");
        assertLt(settle, SETTLE_CEILING, "the add settlement outgrew its ceiling");
    }

    /// @dev One read of everything an add is meant to move, and of everything
    ///      it is meant to leave alone.
    struct Snapshot {
        uint256 size;
        uint256 claim;
        uint256 openPrice;
        uint256 openIndex;
        bool open;
        uint256 poolOunces;
        uint256 reserved;
        uint256 deposit;
    }

    /// @dev A position sitting exactly on its liquidation level at PRICE_18,
    ///      with a fee that is not a whole wei of ounces so the rounding
    ///      direction is readable. Built from 5.4 rule 1 directly: equity is
    ///      C plus the notional now, less the notional at open and the fee
    ///      owed, and the level is the maintenance margin of the notional.
    struct Edge {
        uint256 size;
        uint256 openIndex;
        uint256 indexDelta;
        uint256 feeOunces;
        uint256 claimAtThreshold;
    }

    function _edge() private view returns (Edge memory edge) {
        edge.size = 3.5 ether;
        edge.indexDelta = 1;
        edge.openIndex = manager.indexNow() - edge.indexDelta;
        edge.feeOunces = _ceilDiv(edge.size * edge.indexDelta, WAD);

        uint256 notional = (edge.size * PRICE_18) / WAD;
        uint256 threshold = _ceilDiv(notional * MAINTENANCE_MARGIN_BPS, BPS);
        uint256 owed = _ceilDiv(edge.size * PRICE_18, WAD) + _ceilDiv(edge.feeOunces * PRICE_18, WAD) + threshold;
        edge.claimAtThreshold = owed - notional;
    }

    function _snapshot() private view returns (Snapshot memory shot) {
        (, shot.size, shot.claim, shot.openPrice, shot.openIndex, shot.open) = manager.positionAt(positionId);
        shot.poolOunces = pool.ounces();
        shot.reserved = pool.reserved();
        shot.deposit = manager.depositClaimUsd(PRICE_18);
    }

    function _openAPosition() private returns (uint256 id) {
        vm.prank(trader);
        assertTrue(gold.approve(address(manager), POST));
        vm.prank(trader);
        uint256 request = manager.requestOpen{value: _feeFloor(GAS_OPEN)}(POST, LEVERAGE);

        uint256 target = vm.getBlockTimestamp() + TARGET_DELAY;
        vm.warp(target);
        vm.prank(settler);
        manager.settleOpen{value: PYTH_FEE}(request, abi.encode(_report(target, PRICE_18)), _pyth(target, PRICE_18));

        id = 1;
        (,,,,, bool open) = manager.positionAt(id);
        assertTrue(open, "the fixture did not open a position");
    }

    function _requestAdd(address who, uint256 named, uint256 ounces) private returns (uint256 id) {
        vm.prank(who);
        assertTrue(gold.approve(address(manager), ounces));
        vm.prank(who);
        id = manager.requestAddCollateral{value: _feeFloor(GAS_ADD)}(named, ounces);
    }

    function _settleAdd(uint256 id, uint256 price18) private {
        (,,, uint256 target,,,,) = manager.requestAt(id);
        vm.warp(target);
        vm.prank(settler);
        manager.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_report(target, price18)), _pyth(target, price18));
    }

    function _stateOf(uint256 id) private view returns (PositionManager.State state) {
        (,,,,,,, state) = manager.requestAt(id);
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

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    receive() external payable {}
}
