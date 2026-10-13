// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
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

/// @notice The one deployment every protocol test uses: the vault, the pool,
///         the fund and the manager wired to their oracles behind the mocks.
///         It lives here so the two campaigns and the regression cannot drift
///         apart in their Config; each caller then builds only the handler it
///         targets, the selectors and the LP seed it needs.
abstract contract ProtocolDeployment is Test {
    uint256 internal constant U_MAX_BPS = 8000;
    uint256 internal constant EXPIRY = 600;
    uint256 internal constant IF_TARGET = 100 ether;
    uint256 internal constant FEE_FLOOR = 0.0894e18;
    uint256 internal constant FEE_CAP = 0.3e18;
    uint256 internal constant FEE_EXPONENT = 2;
    uint256 internal constant POSITION_FEE_BPS = 10;
    uint256 internal constant TREASURY_SHARE_BPS = 4000;
    uint256 internal constant INSURANCE_SHARE_BPS = 3000;
    uint256 internal constant POOL_SHARE_BPS = 3000;
    uint256 internal constant MIN_NOTIONAL_USD = 1000e18;
    uint256 internal constant MAINTENANCE_MARGIN_BPS = 600;
    uint256 internal constant GAS_OPEN = 400_000;
    uint256 internal constant GAS_ADD = 300_000;
    uint256 internal constant GAS_OVERHEAD = 80_000;
    uint256 internal constant GAS_PRICE = 2 gwei;
    uint256 internal constant PYTH_FEE = 1000 wei;
    uint256 internal constant START = 1_784_116_800;
    uint256 internal constant BAND_BPS = 50;
    uint64 internal constant PYTH_DELAY = 30;
    uint8 internal constant STREAM_DECIMALS = 18;
    uint8 internal constant FEED_DECIMALS = 8;
    uint256 internal constant MAX_AGE = 6 hours;
    bytes32 internal constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 internal constant PYTH_ID = bytes32(uint256(0x765d2ba9));

    PositionManagerHarness public manager;
    CounterpartyPool public pool;
    InsuranceFund public fund;
    ProtocolHandler public handler;
    TGAUX public gold;
    MockERC20 internal paxg;
    MockPaxg internal paxgReading;

    /// @dev Builds the stack and leaves `paxg`/`paxgReading` for the caller to
    ///      pass into whichever handler it constructs. Does not create a
    ///      handler or set any fuzz target.
    function _deployProtocol() internal {
        vm.warp(START);
        vm.txGasPrice(GAS_PRICE);

        paxgReading = new MockPaxg();
        paxg = new MockERC20("Paxos Gold", "PAXG", 18);
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
    }
}
