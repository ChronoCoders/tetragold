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
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPaxg} from "./mocks/MockPaxg.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";
import {PositionManagerHarness} from "./mocks/PositionManagerHarness.sol";

/// @notice The vault, the pool, the fund and the manager under one campaign.
/// @dev The invariants that span contracts live here rather than in any one of
///      them: the escrow identity of D66, conservation of TGAUX across every
///      holder, I15a, I6 and I19. The per contract invariants keep their own
///      suites.
///
///      The handler swallows nothing: it returns early when a step has nothing
///      to act on, so a revert in a sequence is a defect.
/// forge-config: default.invariant.fail-on-revert = true
contract ProtocolInvariantTest is Test {
    uint256 private constant NOTHING = 0;
    uint256 private constant SELECTORS = 9;
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
    uint256 private constant START = 1_784_116_800;
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
    uint8 private constant STREAM_DECIMALS = 18;
    uint8 private constant FEED_DECIMALS = 8;
    uint256 private constant MAX_AGE = 6 hours;
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));
    uint256 private constant DRIVE_DEPOSIT = 40 ether;
    uint256 private constant DRIVE_POST = 5 ether;
    uint256 private constant DRIVE_ADD = 1 ether;
    /// @dev One slot, which a request's target sits at (section 7 rule 2).
    uint256 private constant TARGET_DELAY = 12;

    PositionManagerHarness public manager;
    CounterpartyPool public pool;
    InsuranceFund public fund;
    ProtocolHandler public handler;
    TGAUX public gold;

    function setUp() public {
        vm.warp(START);
        vm.txGasPrice(GAS_PRICE);

        MockPaxg paxgReading = new MockPaxg();
        MockERC20 paxg = new MockERC20("Paxos Gold", "PAXG", 18);
        TgauxVault vault = new TgauxVault(address(paxg), makeAddr("treasury"), 0, 0);
        gold = vault.TOKEN();
        ReentrancyLock lock = new ReentrancyLock();
        MockPyth pyth = new MockPyth();
        pyth.setFee(PYTH_FEE);
        TradingCalendar calendar = new TradingCalendar(makeAddr("calendar proposer"));

        manager = new PositionManagerHarness(
            PositionManager.Config({
                gold: address(gold),
                paxg: address(paxgReading),
                settlementOracle: address(
                    new SettlementOracle(
                        address(new MockVerifierProxy()),
                        address(pyth),
                        FEED_ID,
                        PYTH_ID,
                        STREAM_DECIMALS,
                        BAND_BPS,
                        PYTH_DELAY
                    )
                ),
                fallbackPrice: address(
                    new PushFallbackPrice(address(new MockChainlinkOracle(FEED_DECIMALS)), address(calendar), MAX_AGE)
                ),
                calendar: address(calendar),
                lock: address(lock),
                guardian: makeAddr("guardian"),
                windDown: makeAddr("wind down"),
                treasury: makeAddr("treasury"),
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
            })
        );
        pool = manager.POOL();
        fund = manager.INSURANCE_FUND();
        handler = new ProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE);

        bytes4[] memory selectors = new bytes4[](SELECTORS);
        selectors[0] = ProtocolHandler.lpDeposit.selector;
        selectors[1] = ProtocolHandler.requestOpen.selector;
        selectors[2] = ProtocolHandler.settleOpen.selector;
        selectors[3] = ProtocolHandler.expireOpen.selector;
        selectors[4] = ProtocolHandler.passTime.selector;
        selectors[5] = ProtocolHandler.movePrice.selector;
        selectors[6] = ProtocolHandler.movePaxg.selector;
        selectors[7] = ProtocolHandler.requestAdd.selector;
        selectors[8] = ProtocolHandler.settleAdd.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice D66: the manager holds TGAUX for pending requests and nothing
    ///         else, so its balance is its escrow total.
    function invariant_D66_TheManagerHoldsOnlyItsEscrow() public view {
        assertEq(handler.escrowMismatches(), NOTHING, "D66: the manager's balance left its escrow total");
        assertEq(gold.balanceOf(address(manager)), manager.escrowedOunces(), "D66: and it disagrees right now");
    }

    /// @notice I1 across the protocol: every ounce of TGAUX is held by one of
    ///         the accounts this campaign accounts for, so none has leaked.
    function invariant_I1_EveryOunceIsAccountedFor() public view {
        assertEq(handler.conservationBreaks(), NOTHING, "I1: TGAUX left the accounted set");
    }

    /// @notice I15a: pool ounces cover the reserve at every step.
    function invariant_I15a_OuncesCoverTheReserve() public view {
        assertEq(handler.coverageBreaks(), NOTHING, "I15a: pool ounces fell under R");
        assertGe(pool.ounces(), pool.reserved(), "I15a: and they do right now");
    }

    /// @notice I7: R stays inside u_max of pool ounces.
    function invariant_I7_ReservedStaysInsideUMax() public view {
        assertLe(pool.reserved() * 10_000, pool.ounces() * U_MAX_BPS, "I7: R rose above u_max of pool ounces");
    }

    /// @notice I6: the withdrawal measure never falls under the deposit
    ///         measure, with the close fee of D71 rule 6 in the latter.
    function invariant_I6_LowSideNeverUnderTheHighSide() public view {
        assertEq(handler.sideInversions(), NOTHING, "I6: the low side fell under the high side");
    }

    /// @notice I19: the holding fee rate never falls as utilisation rises.
    function invariant_I19_RateIsMonotonicInUtilisation() public view {
        assertEq(handler.rateInversions(), NOTHING, "I19: the rate moved against utilisation");
    }

    /// @notice I26 and D50: while PAXG is unusable no open request is taken,
    ///         and nothing else about it changes.
    function invariant_I26_NoInflowWhilePaxgIsUnusable() public view {
        assertEq(handler.inflowsAllowedWhileUnusable(), NOTHING, "I26: an open was taken while PAXG was unusable");
    }

    /// @notice I17 and D70: every request this campaign finished ended in one
    ///         of the terminal states, never back in pending.
    function invariant_I17_RequestsEndWhereTheyShould() public view {
        assertEq(handler.wrongEndings(), NOTHING, "I17: a request ended somewhere else");
    }

    /// @dev Every assertion above holds on a campaign that did nothing, so this
    ///      drives each step by hand first.
    function test_HandlerReachesEveryStep() public {
        handler.lpDeposit(0, DRIVE_DEPOSIT);
        assertGt(pool.ounces(), NOTHING, "the pool took no deposit");
        assertGt(pool.shareSupply(), NOTHING, "the pool minted no shares");

        handler.requestOpen(1, DRIVE_POST, 0);
        assertEq(handler.requests(), 1, "no open was requested");
        assertGt(manager.escrowedOunces(), NOTHING, "the request escrowed nothing");

        handler.passTime(TARGET_DELAY);
        handler.settleOpen(0);
        assertEq(handler.settlements(), 1, "the open did not settle");
        assertGt(pool.reserved(), NOTHING, "the settlement reserved nothing");

        handler.requestOpen(2, DRIVE_POST, 2);
        handler.passTime(EXPIRY * 2);
        handler.expireOpen(0);
        assertEq(handler.expiries(), 1, "the request did not expire");

        handler.requestAdd(0, DRIVE_ADD);
        assertEq(handler.adds(), 1, "no add was requested");
        handler.passTime(TARGET_DELAY);
        handler.settleAdd(0);
        assertEq(handler.addSettlements(), 1, "the add did not settle");

        handler.requestAdd(0, type(uint256).max);
        handler.passTime(TARGET_DELAY);
        handler.settleAdd(0);
        assertEq(handler.addRejections(), 1, "D43 rule 5 was never reached, so the ceiling proves nothing");
        assertEq(handler.wrongEndings(), NOTHING, "I17: an add ended somewhere else");

        handler.movePrice(type(uint256).max);

        handler.movePaxg(true, false);
        handler.requestOpen(1, DRIVE_POST, 0);
        assertGt(handler.inflowRefusals(), NOTHING, "D50 was never tested on the request path");
        assertEq(handler.inflowsAllowedWhileUnusable(), NOTHING, "I26: an open was taken while PAXG was unusable");

        handler.movePaxg(false, false);
        handler.requestOpen(1, DRIVE_POST, 0);
        assertGt(handler.requests(), 2, "the request path did not come back");

        assertEq(handler.escrowMismatches(), NOTHING, "D66 broke during the drive");
        assertEq(handler.conservationBreaks(), NOTHING, "I1 broke during the drive");
        assertEq(handler.coverageBreaks(), NOTHING, "I15a broke during the drive");
        assertEq(handler.sideInversions(), NOTHING, "I6 broke during the drive");
    }
}
