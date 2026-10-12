// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClaimBook} from "./libraries/ClaimBook.sol";
import {FeeIndex} from "./libraries/FeeIndex.sol";
import {CounterpartyPool} from "./CounterpartyPool.sol";
import {InsuranceFund} from "./InsuranceFund.sol";
import {IPaxg} from "./interfaces/IPaxg.sol";
import {IPositionBook} from "./interfaces/IPositionBook.sol";
import {PushFallbackPrice} from "./oracle/PushFallbackPrice.sol";
import {ReentrancyLock} from "./ReentrancyLock.sol";
import {SettlementOracle} from "./oracle/SettlementOracle.sol";
import {TGAUX} from "./TGAUX.sol";
import {TradingCalendar} from "./oracle/TradingCalendar.sol";

/**
 * @title PositionManager
 * @notice The contract positions, the pool and the insurance fund hang from
 *         (D63). This is its skeleton: the deployment, the claim book, the fee
 *         index and the guardian brake. No request, settlement, liquidation or
 *         wind down path exists yet.
 * @dev It deploys the pool and the fund itself, so both record this address as
 *      their position manager and neither can be pointed at anything else
 *      afterwards. There is no setter here and no owner: every parameter is an
 *      immutable taken at construction (D58 rule 1).
 *
 *      It answers `IPositionBook` for the pool through `ClaimBook`, so the two
 *      D48 claim measures cost one tree walk and no position is visited (D60).
 *      Both measures read the index as of this block rather than as of the last
 *      advance, which keeps them right when the pool asks inside a settlement
 *      that has already advanced and when a dashboard asks between blocks
 *      (D55).
 *
 *      Every state changing path advances the index first, at the utilisation
 *      that held over the interval and before its own change (D53). `_advance`
 *      is that call, and the order is the caller's duty because the library
 *      cannot see it.
 *
 *      Liquidation will live here as well, and nothing is reached by
 *      delegatecall: the libraries are internal and compile into this contract,
 *      which is also why splitting them out would not shrink it (D58 rule 1,
 *      D63).
 */
contract PositionManager is IPositionBook {
    using ClaimBook for ClaimBook.Book;
    using FeeIndex for FeeIndex.Index;

    /// @notice One unit of the 1e18 scale the fee curve is written in.
    uint256 private constant WAD = 1e18;

    /// @notice Denominator the pool states its utilisation ceiling in.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Everything the deployment needs, in one argument so that
    ///         thirteen positional values cannot be transposed.
    /// @param gold The TGAUX token.
    /// @param paxg The PAXG token, read for D50.
    /// @param settlementOracle The two source oracle of section 7.
    /// @param fallbackPrice The D22 push fallback.
    /// @param calendar The trading calendar, which gates the fallback (D61).
    /// @param lock The guard shared with the pool, the fund and the vault.
    /// @param guardian The multisig that may pause inflows (D58 rule 2).
    /// @param windDown The multisig that may start a wind down (D21, D68).
    /// @param treasury Where the treasury share goes (D20).
    /// @param poolUMaxBps The pool's utilisation ceiling, in basis points.
    /// @param requestExpiry Seconds a pool request stays settleable.
    /// @param insuranceTarget The routing ceiling of the fund (D20, D49).
    /// @param feeFloorRate Yearly holding fee at no utilisation (D42).
    /// @param feeCapRate Yearly holding fee at the ceiling and above (D53).
    /// @param feeExponent n in the fee curve, one to four (D53).
    struct Config {
        address gold;
        address paxg;
        address settlementOracle;
        address fallbackPrice;
        address calendar;
        address lock;
        address guardian;
        address windDown;
        address treasury;
        uint256 poolUMaxBps;
        uint256 requestExpiry;
        uint256 insuranceTarget;
        uint256 feeFloorRate;
        uint256 feeCapRate;
        uint256 feeExponent;
    }

    TGAUX public immutable GOLD;
    IPaxg public immutable PAXG;
    SettlementOracle public immutable SETTLEMENT_ORACLE;
    PushFallbackPrice public immutable FALLBACK_PRICE;
    TradingCalendar public immutable CALENDAR;
    ReentrancyLock public immutable LOCK;

    /// @notice The counterparty pool this contract deployed (D44).
    CounterpartyPool public immutable POOL;

    /// @notice The insurance fund this contract deployed (D49).
    InsuranceFund public immutable INSURANCE_FUND;

    /// @notice The vault that holds the PAXG behind TGAUX, read from the token
    ///         rather than passed in, so it cannot disagree with the token.
    ///         This is the address D50 asks PAXG about.
    address public immutable PAXG_HOLDER;

    address public immutable GUARDIAN;
    address public immutable WIND_DOWN;
    address public immutable TREASURY;

    uint256 public immutable FEE_FLOOR_RATE;
    uint256 public immutable FEE_CAP_RATE;
    uint256 public immutable FEE_U_MAX;
    uint256 public immutable FEE_EXPONENT;

    /// @notice Whether the guardian has paused inflows (D58 rule 2).
    bool public inflowsPaused;

    /// @dev Internal rather than private so a harness can plant a position set
    ///      and drive an advance while no open path exists yet. The paths that
    ///      will maintain both live in this contract.
    ClaimBook.Book internal _book;
    FeeIndex.Index internal _index;

    event InflowsPaused(address indexed guardian);
    event InflowsUnpaused(address indexed guardian);

    error ZeroAddress();
    error NotGuardian(address caller);
    error PoolHasNoShares();

    constructor(Config memory config) {
        if (
            config.gold == address(0) || config.paxg == address(0) || config.settlementOracle == address(0)
                || config.fallbackPrice == address(0) || config.calendar == address(0) || config.lock == address(0)
                || config.guardian == address(0) || config.windDown == address(0) || config.treasury == address(0)
        ) {
            revert ZeroAddress();
        }

        GOLD = TGAUX(config.gold);
        PAXG = IPaxg(config.paxg);
        SETTLEMENT_ORACLE = SettlementOracle(config.settlementOracle);
        FALLBACK_PRICE = PushFallbackPrice(config.fallbackPrice);
        CALENDAR = TradingCalendar(config.calendar);
        LOCK = ReentrancyLock(config.lock);
        GUARDIAN = config.guardian;
        WIND_DOWN = config.windDown;
        TREASURY = config.treasury;
        PAXG_HOLDER = TGAUX(config.gold).VAULT();

        // The pool states its ceiling in basis points and the fee curve in the
        // 1e18 scale, so one input serves both and the conversion is exact for
        // every basis point value.
        FEE_FLOOR_RATE = config.feeFloorRate;
        FEE_CAP_RATE = config.feeCapRate;
        FEE_U_MAX = (config.poolUMaxBps * WAD) / BPS_DENOMINATOR;
        FEE_EXPONENT = config.feeExponent;
        FeeIndex.validate(
            FeeIndex.Params({
                floorRate: config.feeFloorRate,
                capRate: config.feeCapRate,
                uMax: FEE_U_MAX,
                exponent: config.feeExponent
            })
        );

        POOL = new CounterpartyPool(config.gold, config.lock, config.poolUMaxBps, config.requestExpiry);
        INSURANCE_FUND = new InsuranceFund(config.gold, config.treasury, config.lock, config.insuranceTarget);

        // The index measures from here, not from the epoch.
        // forge-lint: disable-next-line(block-timestamp)
        _index.start(block.timestamp);
    }

    /// @notice Pause the inflows the guardian may pause (D58 rule 2).
    /// @dev Nothing reads this yet. The paths it will stop are the position
    ///      open and the add of collateral; it can never stop an outflow and it
    ///      moves no balance.
    function pauseInflows() external {
        if (msg.sender != GUARDIAN) {
            revert NotGuardian(msg.sender);
        }
        inflowsPaused = true;
        emit InflowsPaused(msg.sender);
    }

    /// @notice Let those inflows through again (D58 rule 2).
    function unpauseInflows() external {
        if (msg.sender != GUARDIAN) {
            revert NotGuardian(msg.sender);
        }
        inflowsPaused = false;
        emit InflowsUnpaused(msg.sender);
    }

    /// @inheritdoc IPositionBook
    function depositClaimUsd(uint256 price18) external view returns (uint256) {
        return _book.depositClaimUsd(price18, indexNow());
    }

    /// @inheritdoc IPositionBook
    function withdrawalClaimUsd(uint256 price18) external view returns (uint256) {
        return _book.withdrawalClaimUsd(price18, indexNow());
    }

    /// @notice The fee index as of this block, without writing it.
    /// @dev The stored value plus what the interval since the last advance has
    ///      earned at the utilisation standing now. Both claim measures read
    ///      this rather than the stored value, so a pool asking inside a
    ///      settlement and a dashboard asking between blocks get the same
    ///      answer (D53, D55).
    function indexNow() public view returns (uint256) {
        // The interval is measured in slot time, which post merge Ethereum
        // fixes (consensus-specs specs/bellatrix/beacon-chain.md:446 at
        // 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        uint256 elapsed = block.timestamp - _index.lastAdvance;
        // Zero means this block has already advanced the index, so there is
        // nothing to add. Nothing here trusts the timestamp beyond that: a
        // validator nudging it changes a fraction of a second of accrual, and
        // the accrual rounds up regardless.
        // forge-lint: disable-next-line(block-timestamp)
        if (elapsed == 0) {
            return _index.value;
        }
        return _index.value + FeeIndex.increment(currentRate(), elapsed);
    }

    /// @notice The index as it was last written.
    function indexStored() external view returns (uint256) {
        return _index.value;
    }

    /// @notice When the index was last written.
    function indexLastAdvance() external view returns (uint256) {
        return _index.lastAdvance;
    }

    /// @notice The yearly holding fee rate at the pool's utilisation now (D53).
    function currentRate() public view returns (uint256) {
        return FeeIndex.rate(POOL.reserved(), POOL.ounces(), _feeParams());
    }

    /// @notice Utilisation in basis points, as the pool reports it (D46, D55).
    function utilisationBps() external view returns (uint256) {
        return POOL.utilisationBps();
    }

    /// @notice Reserved ounces R (D46, D55).
    function reservedOunces() external view returns (uint256) {
        return POOL.reserved();
    }

    /// @notice Whether PAXG can be used at all (D50).
    /// @dev False when Paxos has frozen the vault that holds the PAXG behind
    ///      TGAUX, and false when PAXG is paused altogether. Inflows valued at
    ///      the gold price stop in either case; outflows carry on in TGAUX.
    function paxgUsable() external view returns (bool) {
        return !PAXG.isFrozen(PAXG_HOLDER) && !PAXG.paused();
    }

    /// @dev Advance the index before any change to reserved ounces or pool
    ///      ounces, which is what D53 requires of every state changing path:
    ///      the interval that just passed was spent at the utilisation standing
    ///      now, not at the one the change is about to produce.
    function _advance() internal {
        // Slot time again, as in `indexNow`.
        // forge-lint: disable-next-line(block-timestamp)
        _index.advance(POOL.reserved(), POOL.ounces(), _feeParams(), block.timestamp);
    }

    /// @dev D48 as revised in r6.7: an open is refused while the pool holds no
    ///      shares, because the first deposit then prices at one share per
    ///      ounce and would take any trader collateral already in the pool as a
    ///      windfall. The open path calls this; nothing else does.
    function _requireSharesExist() internal view {
        if (POOL.shareSupply() == 0) {
            revert PoolHasNoShares();
        }
    }

    /// @dev The fee curve, rebuilt from the immutables that hold it.
    function _feeParams() private view returns (FeeIndex.Params memory) {
        return
            FeeIndex.Params({floorRate: FEE_FLOOR_RATE, capRate: FEE_CAP_RATE, uMax: FEE_U_MAX, exponent: FEE_EXPONENT});
    }
}
