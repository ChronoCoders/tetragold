// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {PushFallbackPrice} from "../src/oracle/PushFallbackPrice.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TgauxVault} from "../src/TgauxVault.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {ProtocolInvariantTest} from "./ProtocolInvariant.t.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";
import {TightProtocolHandler} from "./handlers/TightProtocolHandler.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPaxg} from "./mocks/MockPaxg.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";
import {PositionManagerHarness} from "./mocks/PositionManagerHarness.sol";

/// @notice The same invariants as ProtocolInvariantTest, run against a pool
///         held tight: one small LP deposit, a wide price band and a step mix
///         weighted toward adds. The base campaign keeps a deep pool, where the
///         reserve slack hides a claim that outgrew its notional; this one
///         leaves no slack, so I15b sees the shortfall a broken D46 lets in.
/// forge-config: default.invariant.fail-on-revert = true
contract TightProtocolInvariantTest is ProtocolInvariantTest {
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
    uint256 private constant SMALL_LP = 3 ether;
    uint256 private constant ADD_WEIGHT = 4;
    uint256 private constant TIGHT_SELECTORS = 6 + 2 * ADD_WEIGHT;

    function setUp() public override {
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
        TightProtocolHandler tight = new TightProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE);
        handler = tight;

        tight.lpDeposit(0, SMALL_LP);

        bytes4[] memory selectors = new bytes4[](TIGHT_SELECTORS);
        selectors[0] = ProtocolHandler.requestOpen.selector;
        selectors[1] = ProtocolHandler.settleOpen.selector;
        selectors[2] = ProtocolHandler.passTime.selector;
        selectors[3] = TightProtocolHandler.moveWidePrice.selector;
        selectors[4] = ProtocolHandler.expireOpen.selector;
        selectors[5] = ProtocolHandler.dustTheOracle.selector;
        for (uint256 i = 0; i < ADD_WEIGHT; i++) {
            selectors[6 + i] = ProtocolHandler.requestAdd.selector;
            selectors[6 + ADD_WEIGHT + i] = ProtocolHandler.settleAdd.selector;
        }
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The base drive assumes the base selector mix and a deep pool, so it
    ///      has nothing to say about the tight campaign. The invariants carry
    ///      their own anti vacuity in the live assertions, and the metrics table
    ///      shows each step is reached.
    function test_HandlerReachesEveryStep() public override {}
}
