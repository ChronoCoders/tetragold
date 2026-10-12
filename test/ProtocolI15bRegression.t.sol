// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
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

/// @notice A hand sequence that D46 must stop, pinned so it cannot drift. The
///         owner of a position tries to add far more collateral than its open
///         notional allows, then the price falls. D46 rejects the add on clean
///         code, so the pool still covers every payout; with the two D46 layers
///         broken the add settles, the claim outgrows the gold behind it, and
///         I15b is the claim that sees it while the reserve bound of I15a does
///         not.
contract ProtocolI15bRegressionTest is Test {
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
    uint256 private constant TARGET_DELAY = 12;
    uint8 private constant TIER_5X = 2;
    bytes32 private constant REJECTED_SIG = keccak256("RequestRejected(uint256,address,uint8,uint256)");

    PositionManagerHarness private manager;
    CounterpartyPool private pool;
    ProtocolHandler private handler;

    function setUp() public {
        vm.warp(START);
        vm.txGasPrice(GAS_PRICE);

        MockPaxg paxgReading = new MockPaxg();
        MockERC20 paxg = new MockERC20("Paxos Gold", "PAXG", 18);
        TgauxVault vault = new TgauxVault(address(paxg), makeAddr("treasury"), 0, 0);
        TGAUX gold = vault.TOKEN();
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
        handler = new ProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE, 7 days);
    }

    function test_AnAddPastTheNotionalCannotOutrunThePool() public {
        handler.movePrice(5000e18);
        handler.lpDeposit(0, 5.5 ether);
        handler.requestOpen(1, 1 ether, TIER_5X);
        handler.passTime(TARGET_DELAY);
        handler.settleOpen(0);

        handler.requestAdd(0, 50 ether);
        handler.passTime(TARGET_DELAY);

        vm.recordLogs();
        handler.settleAdd(0);
        PositionManager.Reason reason = _rejectionReason(vm.getRecordedLogs());

        handler.movePrice(3000e18);

        assertGe(pool.ounces(), pool.reserved(), "I15a: the reserve bound holds either way");
        assertGe(
            pool.ounces(), handler.i15bPayoutOunces(), "I15b: the add outran the gold behind it and the pool cannot pay"
        );
        assertEq(
            uint8(reason),
            uint8(PositionManager.Reason.ClaimWouldPassNotional),
            "D46 rule 5 is what rejected the add, so the cap is the guard"
        );
    }

    function _rejectionReason(Vm.Log[] memory logs) private pure returns (PositionManager.Reason) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == REJECTED_SIG) {
                (uint8 reason,) = abi.decode(logs[i].data, (uint8, uint256));
                return PositionManager.Reason(reason);
            }
        }
        return PositionManager.Reason.None;
    }
}
