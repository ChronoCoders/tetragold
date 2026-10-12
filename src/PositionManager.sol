// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
    using SafeERC20 for IERC20;

    /// @notice One unit of the 1e18 scale the fee curve is written in.
    uint256 private constant WAD = 1e18;

    /// @notice Denominator the pool states its utilisation ceiling in, and the
    ///         fee shares of D20 as well.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice The leverage tiers of D52. Every position takes one of them.
    uint256 private constant LEVERAGE_LOW = 2;
    uint256 private constant LEVERAGE_MID = 3;
    uint256 private constant LEVERAGE_HIGH = 5;

    /// @notice Delay from request to target time: one slot, the same rule the
    ///         pool follows (section 7 rule 2).
    uint256 private constant TARGET_DELAY = 12;

    uint256 private constant ROUND_UP = 1;

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
    /// @param positionFeeBps f, charged on size at open and again at close
    ///        (D71 rule 1). Zero is a valid value.
    /// @param treasuryShareBps Treasury's share of every collected fee (D20).
    /// @param insuranceShareBps The insurance fund's share, routed to the pool
    ///        once the fund is at its target (D20).
    /// @param poolShareBps The pool's share. The three sum to one.
    /// @param minNotionalUsd Smallest position notional at the settled price,
    ///        so that liquidating any position pays the keeper (D57).
    /// @param maintenanceMarginBps The margin a position must keep to stay out
    ///        of liquidation, in basis points (D11, D52, O5).
    /// @param gasOpen Gas estimate an open settlement is charged against (D65).
    /// @param gasAdd Gas estimate an add settlement is charged against (D65).
    /// @param gasOverhead Gas an estimate cannot see, added to what a settler
    ///        is paid (D65).
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
        uint256 positionFeeBps;
        uint256 treasuryShareBps;
        uint256 insuranceShareBps;
        uint256 poolShareBps;
        uint256 minNotionalUsd;
        uint256 maintenanceMarginBps;
        uint256 gasOpen;
        uint256 gasAdd;
        uint256 gasOverhead;
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

    /// @notice f of D71: the fee a position pays on its size in ounces at open
    ///         and again at an owner's close, in basis points (O5).
    uint256 public immutable POSITION_FEE_BPS;

    /// @notice How a collected fee is split (D20, O3). The three sum to one.
    uint256 public immutable TREASURY_SHARE_BPS;
    uint256 public immutable INSURANCE_SHARE_BPS;
    uint256 public immutable POOL_SHARE_BPS;

    /// @notice Smallest notional a position may open with, in USD scaled by
    ///         1e18, so no position is too small to be worth liquidating
    ///         (D57, O5).
    uint256 public immutable MIN_NOTIONAL_USD;

    /// @notice The margin a position keeps to stay out of liquidation, in
    ///         basis points of its notional (D11, D52, O5).
    uint256 public immutable MAINTENANCE_MARGIN_BPS;

    /// @notice Gas an open settlement is estimated at, which fixes the smallest
    ///         execution fee a request may carry (D65, O5).
    uint256 public immutable GAS_OPEN;

    /// @notice The same for an add settlement (D65, O5).
    uint256 public immutable GAS_ADD;

    /// @notice Gas a settlement spends that `gasleft()` cannot see from inside
    ///         the call: the 21000 intrinsic cost, the calldata cost of the
    ///         report and the update, and the work after the last reading, which
    ///         is the settler's payment and the credit beside it. It is added to
    ///         what a settler is paid, and it is immutable because a settler
    ///         must be able to price a settlement before sending it (D65, O5).
    uint256 public immutable GAS_OVERHEAD;

    /// @notice How long a request stays settleable before it can expire, the
    ///         same window the pool uses (section 7 rule 4, O5).
    uint256 public immutable REQUEST_EXPIRY;
    /// @notice Whether the guardian has paused inflows (D58 rule 2).
    bool public inflowsPaused;

    /// @notice TGAUX held for pending requests and nothing else, so this equals
    ///         the manager's own TGAUX balance between operations (D66).
    uint256 public escrowedOunces;

    /// @notice ETH owed to a requester from an execution fee, waiting to be
    ///         pulled. Never pushed, so an account that refuses ETH cannot stop
    ///         a settlement (D70).
    mapping(address account => uint256 wei_) public ethCredit;

    /// @notice Identifier of the next request, so zero is never one.
    uint256 public nextRequestId = 1;

    /// @notice Identifier of the next position, so zero is never one.
    uint256 public nextPositionId = 1;

    mapping(uint256 requestId => Request request) private _requests;
    mapping(uint256 positionId => Position position) internal _positions;

    /// @dev Internal rather than private so a harness can plant a position set
    ///      and drive an advance while no open path exists yet. The paths that
    ///      will maintain both live in this contract.
    /// @notice What a request asks for. Liquidation is not a request of this
    ///         kind: it carries no execution fee and pays its keeper in TGAUX
    ///         from the fund (D39, D65).
    enum Kind {
        Open,
        Add,
        Close
    }

    /// @notice Where a request is in its lifecycle. The three terminal states
    ///         are the only ways out (I17, D70).
    enum State {
        None,
        Pending,
        Settled,
        Rejected,
        Expired
    }

    /// @notice One request. `escrowed` is the q of an open or an add and zero
    ///         for a close; `positionId` is zero for an open.
    struct Request {
        address requester;
        uint256 escrowed;
        uint256 executionFee;
        uint256 targetTime;
        uint256 positionId;
        uint256 leverage;
        Kind kind;
        State state;
    }

    /// @notice What the settled price decides about an open: its size, the fee
    ///         it owes, what joins the pool, its claim, and how the fee splits.
    struct Open {
        uint256 size;
        uint256 feeOunces;
        uint256 joined;
        uint256 claim;
        uint256 toTreasury;
        uint256 toFund;
        uint256 toPool;
    }

    /// @notice One open position, carrying exactly what the claim book was
    ///         given, so a close can hand the same four values back (D60).
    struct Position {
        address owner;
        uint256 size;
        uint256 claim;
        uint256 openPrice;
        uint256 openIndex;
        bool open;
        bool exitPending;
        bool flagged;
    }

    ClaimBook.Book internal _book;
    FeeIndex.Index internal _index;

    /// @dev What Pyth took from the value a settler sent, carried from the
    ///      oracle call to the settler's payment. It is transient because it
    ///      lives for one call: every settlement writes it before reading it,
    ///      and EIP-1153 clears it at the end of the transaction, so there is
    ///      nothing to reset and nothing to inherit.
    uint256 private transient _pythPaid;

    event InflowsPaused(address indexed guardian);
    event InflowsUnpaused(address indexed guardian);
    event OpenRequested(
        uint256 indexed id, address indexed requester, uint256 ounces, uint256 leverage, uint256 targetTime, uint256 fee
    );
    event OpenSettled(
        uint256 indexed id,
        uint256 indexed positionId,
        address indexed owner,
        uint256 size,
        uint256 claim,
        uint256 openPrice,
        uint256 feeOunces
    );
    event AddRequested(
        uint256 indexed id, uint256 indexed positionId, address indexed owner, uint256 ounces, uint256 targetTime
    );
    event AddSettled(uint256 indexed id, uint256 indexed positionId, uint256 ounces, uint256 claim, uint256 price18);
    event RequestRejected(uint256 indexed id, address indexed requester, Reason reason, uint256 price18);
    event RequestExpired(uint256 indexed id, address indexed requester, uint256 escrowed, uint256 fee);
    event FeeRouted(uint256 toTreasury, uint256 toInsuranceFund, uint256 toPool);
    event SettlerPaid(uint256 indexed id, address indexed settler, uint256 paid, uint256 credited);
    event CreditWithdrawn(address indexed account, uint256 amount);

    error ZeroAddress();
    error NotGuardian(address caller);
    error PoolHasNoShares();
    error FeeTooHighForLeverage(uint256 bps, uint256 leverage);
    error SharesDoNotSumToOne(uint256 total);
    error ZeroMinimumNotional();
    error ZeroGasEstimate();
    error ZeroAmount();
    error BadLeverage(uint256 leverage);
    error PaxgUnusable();
    error InflowsArePaused();
    error FeeBelowEstimate(uint256 sent, uint256 required);
    error NoSuchRequest(uint256 id);
    error WrongKind(uint256 id);
    error TooEarly(uint256 targetTime);
    error TooLate(uint256 expiresAt);
    error NotExpiredYet(uint256 expiresAt);
    error NotRequester(address caller, address requester);
    error NothingReceived();
    error NothingToWithdraw();
    error TransferFailed(address to, uint256 amount);
    error UnexpectedEth(address from);
    error MarginOutOfRange(uint256 bps);
    error NoSuchPosition(uint256 positionId);
    error NotPositionOwner(address caller, address owner);
    error ExitPending(uint256 positionId);

    /// @notice Why a request was rejected at its price (D70). Every one of
    ///         these is a rule the price or the state settled, so waiting could
    ///         not have helped.
    enum Reason {
        None,
        InflowsPaused,
        PaxgUnusable,
        PoolHasNoShares,
        BelowMinimumNotional,
        EntryPriceOutOfRange,
        ReserveCeiling,
        PositionClosed,
        Liquidatable,
        ClaimWouldPassNotional
    }

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
        // The open fee is f of the size, and the size is q times the leverage,
        // so the fee comes to q times f times k. Once that reaches q the fee
        // would be the whole collateral and the subtraction below would panic
        // instead of rejecting, so the bound is on the largest tier (D71).
        if (config.positionFeeBps * LEVERAGE_HIGH >= BPS_DENOMINATOR) {
            revert FeeTooHighForLeverage(config.positionFeeBps, LEVERAGE_HIGH);
        }
        if (config.treasuryShareBps + config.insuranceShareBps + config.poolShareBps != BPS_DENOMINATOR) {
            revert SharesDoNotSumToOne(config.treasuryShareBps + config.insuranceShareBps + config.poolShareBps);
        }
        // A zero minimum would let a position open too small to be worth
        // liquidating, which is the whole of D57.
        if (config.minNotionalUsd == 0) {
            revert ZeroMinimumNotional();
        }
        if (config.gasOpen == 0 || config.gasAdd == 0 || config.gasOverhead == 0) {
            revert ZeroGasEstimate();
        }
        // A zero margin would mean a position is never liquidatable and a
        // margin of the whole notional would mean it always is, so neither end
        // is a curve (D11).
        if (config.maintenanceMarginBps == 0 || config.maintenanceMarginBps >= BPS_DENOMINATOR) {
            revert MarginOutOfRange(config.maintenanceMarginBps);
        }
        POSITION_FEE_BPS = config.positionFeeBps;
        TREASURY_SHARE_BPS = config.treasuryShareBps;
        INSURANCE_SHARE_BPS = config.insuranceShareBps;
        POOL_SHARE_BPS = config.poolShareBps;
        MIN_NOTIONAL_USD = config.minNotionalUsd;
        MAINTENANCE_MARGIN_BPS = config.maintenanceMarginBps;
        GAS_OPEN = config.gasOpen;
        GAS_ADD = config.gasAdd;
        GAS_OVERHEAD = config.gasOverhead;
        REQUEST_EXPIRY = config.requestExpiry;

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

    /// @notice Receive the oracle's refund of whatever Pyth did not take. A
    ///         settlement reads this contract's balance across that call, so
    ///         the refund has to land here rather than revert.
    /// @dev Nothing else may pay this contract. Execution fees arrive as the
    ///      value on a request, so stray ETH would only sit here unowned, with
    ///      no path out: the credit ledger pays out what requests put in, and
    ///      there is no sweep and no owner to add one (D58).
    receive() external payable {
        if (msg.sender != address(SETTLEMENT_ORACLE)) {
            revert UnexpectedEth(msg.sender);
        }
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

    /// @notice Ask to open a position of `leverage` on `ounces` of TGAUX.
    /// @dev The q is escrowed here until settlement and measured by balance
    ///      difference, so a token that takes a fee on transfer cannot escrow
    ///      more than arrived (D66). The execution fee rides along in ETH and
    ///      must cover the estimate for this request type at the gas price of
    ///      this transaction (D65); more is allowed and comes back.
    ///
    ///      `paxgUsable` is read here and on no outflow path. It is an external
    ///      call into a contract that is upgradeable behind a timelock, so it
    ///      could one day revert; on an inflow a revert is the safe answer, and
    ///      on a close or a liquidation it would be the unsafe one (D50, I14).
    /// @param ounces q, the TGAUX posted as collateral.
    /// @param leverage k, one of the tiers of D52.
    /// @return id Identifier of the request.
    function requestOpen(uint256 ounces, uint256 leverage) external payable returns (uint256 id) {
        if (inflowsPaused) {
            revert InflowsArePaused();
        }
        if (ounces == 0) {
            revert ZeroAmount();
        }
        if (leverage != LEVERAGE_LOW && leverage != LEVERAGE_MID && leverage != LEVERAGE_HIGH) {
            revert BadLeverage(leverage);
        }
        if (!_paxgUsable()) {
            revert PaxgUnusable();
        }
        _requireFee(GAS_OPEN);
        LOCK.enter();

        uint256 received = _takeEscrow(msg.sender, ounces);
        id = _record(msg.sender, received, Kind.Open, 0, leverage);

        // The event reports what arrived, which is only known after the
        // transfer, and the section is held across both.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OpenRequested(id, msg.sender, received, leverage, _requests[id].targetTime, msg.value);

        LOCK.exit();
    }

    /// @notice Ask to add `ounces` of collateral to a position (D43).
    /// @dev The owner alone may ask, because an add changes that position's
    ///      claim and nobody else's. It is an inflow, so the brake and PAXG
    ///      are read here as they are on an open, and the escrow is measured
    ///      by balance difference (D58, D50, D66).
    ///
    ///      D43 rule 3: no add may be opened while an exit is pending for the
    ///      position, so a holder cannot race a close with a rescue.
    ///      `_requireNoExitPending` is that check; the close path sets the
    ///      flag it reads and the liquidation unit will set its own beside it.
    /// @param positionId The position to add to.
    /// @param ounces q, the TGAUX added.
    /// @return id Identifier of the request.
    function requestAddCollateral(uint256 positionId, uint256 ounces) external payable returns (uint256 id) {
        Position storage position = _positions[positionId];
        if (!position.open) {
            revert NoSuchPosition(positionId);
        }
        if (msg.sender != position.owner) {
            revert NotPositionOwner(msg.sender, position.owner);
        }
        if (inflowsPaused) {
            revert InflowsArePaused();
        }
        if (ounces == 0) {
            revert ZeroAmount();
        }
        if (!_paxgUsable()) {
            revert PaxgUnusable();
        }
        _requireNoExitPending(positionId);
        _requireFee(GAS_ADD);
        LOCK.enter();

        uint256 received = _takeEscrow(msg.sender, ounces);
        id = _record(msg.sender, received, Kind.Add, positionId, 0);

        // The event reports what arrived, which is only known after the
        // transfer, and the guarded section covers both.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AddRequested(id, positionId, msg.sender, received, _requests[id].targetTime);

        LOCK.exit();
    }

    /// @notice Settle a pending add against the reports for its target time.
    /// @dev Anyone may call this, as on an open (D62). A rule that the price
    ///      or the state decides rejects and refunds the q in full (D70); an
    ///      oracle failure reverts and the request waits.
    /// @param id Request to settle.
    /// @param streamsPayload The signed Data Streams report for the target.
    /// @param pythUpdate The Pyth update covering the target.
    function settleAddCollateral(uint256 id, bytes calldata streamsPayload, bytes[] calldata pythUpdate)
        external
        payable
    {
        uint256 gasAtEntry = gasleft();
        Request storage request = _pendingAt(id, Kind.Add);

        LOCK.enter();

        _advance();
        uint256 price18 = _settlePrice(request.targetTime, streamsPayload, pythUpdate);

        Reason reason = _addAt(id, request, price18);
        if (reason != Reason.None) {
            _reject(id, request, reason, price18);
        }

        _payTheSettler(id, request, gasAtEntry);

        LOCK.exit();
    }

    /// @notice Settle a pending open against the reports for its target time.
    /// @dev Anyone may call this (D62): section 7 rule 2 leaves exactly one
    ///      report for the target, so the settler chooses no price. It pays the
    ///      settler what the settlement cost it and credits the rest back.
    ///
    ///      An oracle failure reverts and the request waits, which is the one
    ///      thing that is not a rejection (section 7 rule 4). Every rule that
    ///      the price or the state decides rejects instead, refunding the q in
    ///      full (D70).
    /// @param id Request to settle.
    /// @param streamsPayload The signed Data Streams report for the target.
    /// @param pythUpdate The Pyth update covering the target.
    function settleOpen(uint256 id, bytes calldata streamsPayload, bytes[] calldata pythUpdate) external payable {
        uint256 gasAtEntry = gasleft();
        Request storage request = _pendingAt(id, Kind.Open);

        // The section covers the whole settlement, including the oracle call
        // and the settler's payment at the end, which is what D31 asks of a
        // state changing function that makes an external call. The oracle's
        // refund lands in `receive`, which takes no lock, so the section is not
        // re-entered by the refund. A settler whose fallback tries to come back
        // in finds the section held and fails its own settlement, which is the
        // only thing it can reach.
        LOCK.enter();

        _advance();
        uint256 price18 = _settlePrice(request.targetTime, streamsPayload, pythUpdate);

        Reason reason = _openAt(id, request, price18);
        if (reason != Reason.None) {
            _reject(id, request, reason, price18);
        }

        _payTheSettler(id, request, gasAtEntry);

        LOCK.exit();
    }

    /// @notice Refund a request no price ever qualified for (section 7 rule 4).
    /// @dev The requester calls it, so a keeper cannot cancel a request that is
    ///      still settleable, and the whole execution fee goes back (D65).
    /// @param id Request to expire.
    function expireRequest(uint256 id) external {
        Request storage request = _requests[id];
        if (request.state != State.Pending) {
            revert NoSuchRequest(id);
        }
        if (msg.sender != request.requester) {
            revert NotRequester(msg.sender, request.requester);
        }
        uint256 expiresAt = request.targetTime + REQUEST_EXPIRY;
        // The deadline is slot time, which post merge Ethereum fixes
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < expiresAt) {
            revert NotExpiredYet(expiresAt);
        }
        LOCK.enter();

        uint256 escrowed = request.escrowed;
        uint256 fee = request.executionFee;
        request.state = State.Expired;
        if (escrowed != 0) {
            escrowedOunces -= escrowed;
        }
        if (fee != 0) {
            ethCredit[request.requester] += fee;
        }
        // The state, the escrow total and the credit are written above, and
        // the only external call before this is taking the section, which holds
        // nothing a caller can turn against this log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RequestExpired(id, request.requester, escrowed, fee);

        if (escrowed != 0) {
            IERC20(address(GOLD)).safeTransfer(request.requester, escrowed);
        }

        LOCK.exit();
    }

    /// @notice Take ETH owed from an execution fee.
    /// @dev Pull rather than push, so an account that cannot receive ETH is its
    ///      own problem and never a settlement's (D70). It holds the shared
    ///      section like every other path that makes an external call (D31), so
    ///      a recipient's fallback cannot come back into a settlement.
    function withdrawCredit() external {
        uint256 amount = ethCredit[msg.sender];
        if (amount == 0) {
            revert NothingToWithdraw();
        }

        // The ledger is cleared before anything external happens, so a
        // recipient's fallback finds nothing left to pull, and the section
        // below refuses it a second route in anyway.
        ethCredit[msg.sender] = 0;
        LOCK.enter();

        // forge-lint: disable-next-line(reentrancy-events)
        emit CreditWithdrawn(msg.sender, amount);

        _sendEth(msg.sender, amount);

        LOCK.exit();
    }

    /// @notice Read a request, for a settler deciding whether to settle it and
    ///         for the D55 dashboard.
    function requestAt(uint256 id)
        external
        view
        returns (
            address requester,
            uint256 escrowed,
            uint256 executionFee,
            uint256 targetTime,
            uint256 positionId,
            uint256 leverage,
            Kind kind,
            State state
        )
    {
        Request storage request = _requests[id];
        return (
            request.requester,
            request.escrowed,
            request.executionFee,
            request.targetTime,
            request.positionId,
            request.leverage,
            request.kind,
            request.state
        );
    }

    /// @notice Read a position (D55).
    function positionAt(uint256 positionId)
        external
        view
        returns (address owner, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex, bool open)
    {
        Position storage position = _positions[positionId];
        return (position.owner, position.size, position.claim, position.openPrice, position.openIndex, position.open);
    }

    /// @notice Whether an exit is pending for a position, and whether the D22
    ///         fallback has flagged it (D43 rule 3, D43 rule 4).
    function positionFlags(uint256 positionId) external view returns (bool exitPending, bool flagged) {
        Position storage position = _positions[positionId];
        return (position.exitPending, position.flagged);
    }

    /// @notice Whether a position would be liquidatable at `price18` (D11).
    function liquidatableAt(uint256 positionId, uint256 price18) external view returns (bool) {
        return _isLiquidatable(_positions[positionId], price18);
    }

    /// @inheritdoc IPositionBook
    /// @dev D71 rule 6: the deposit measure also subtracts f of notional,
    ///      rounded up, because every open position will pay that much on an
    ///      owner's close. The withdrawal measure does not, because a
    ///      liquidated position pays no close fee (D29 on both sides).
    function depositClaimUsd(uint256 price18) external view returns (uint256) {
        uint256 claim = _book.depositClaimUsd(price18, indexNow());
        uint256 closeFee = _closeFeeUsdUp(price18);
        return claim > closeFee ? claim - closeFee : 0;
    }

    /// @inheritdoc IPositionBook
    /// @dev No close fee is subtracted here, which is the other half of D71
    ///      rule 6.
    function withdrawalClaimUsd(uint256 price18) external view returns (uint256) {
        return _book.withdrawalClaimUsd(price18, indexNow());
    }

    /// @notice The close fee every open position will owe at `price18`, rounded
    ///         up, which is the term D71 rule 6 adds to the deposit measure.
    function closeFeeUsd(uint256 price18) external view returns (uint256) {
        return _closeFeeUsdUp(price18);
    }

    /// @notice The smallest execution fee a request of `gasEstimate` may carry
    ///         at this transaction's gas price (D65).
    function executionFeeFloor(uint256 gasEstimate) public view returns (uint256) {
        // The gas price of the transaction asking is the only price there is to
        // quote against, which is what GMX v2 does as well.
        return gasEstimate * tx.gasprice;
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
    ///      the gold price stop in either case; outflows carry on in TGAUX, and
    ///      no outflow path reads this.
    function paxgUsable() external view returns (bool) {
        return _paxgUsable();
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

    /// @dev Pull the request's TGAUX in and count it, measuring what arrived
    ///      rather than what was asked for (D66).
    function _takeEscrow(address from, uint256 ounces) private returns (uint256 received) {
        uint256 before = GOLD.balanceOf(address(this));
        // The `from` is the caller of this contract, which is the only account
        // whose escrow this can ever take.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(address(GOLD)).safeTransferFrom(from, address(this), ounces);
        received = GOLD.balanceOf(address(this)) - before;
        if (received == 0) {
            revert NothingReceived();
        }
        escrowedOunces += received;
    }

    /// @dev Record a pending request at one slot from now, the same target rule
    ///      the pool follows (section 7 rule 2).
    function _record(address requester, uint256 escrowed, Kind kind, uint256 positionId, uint256 leverage)
        private
        returns (uint256 id)
    {
        id = nextRequestId;
        nextRequestId = id + 1;
        // The target is one slot out, in slot time as above.
        // forge-lint: disable-next-line(block-timestamp)
        _requests[id] = Request({
            requester: requester,
            escrowed: escrowed,
            executionFee: msg.value,
            targetTime: block.timestamp + TARGET_DELAY,
            positionId: positionId,
            leverage: leverage,
            kind: kind,
            state: State.Pending
        });
    }

    /// @dev A request that is pending, of the kind expected, past its target
    ///      and inside its settlement window. The window closes where expiry
    ///      opens, so the two meet at one instant and it belongs to expiry
    ///      (section 7 rule 4, r6.7).
    function _pendingAt(uint256 id, Kind kind) private view returns (Request storage request) {
        request = _requests[id];
        if (request.state != State.Pending) {
            revert NoSuchRequest(id);
        }
        if (request.kind != kind) {
            revert WrongKind(id);
        }
        // Both bounds are slot time, as above.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < request.targetTime) {
            revert TooEarly(request.targetTime);
        }
        uint256 expiresAt = request.targetTime + REQUEST_EXPIRY;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= expiresAt) {
            revert TooLate(expiresAt);
        }
    }

    /// @dev The execution fee must cover this request type's estimate at this
    ///      transaction's gas price (D65).
    function _requireFee(uint256 gasEstimate) private view {
        uint256 required = executionFeeFloor(gasEstimate);
        if (msg.value < required) {
            revert FeeBelowEstimate(msg.value, required);
        }
    }

    /// @dev The price for a target, and the Pyth fee the settlement paid out of
    ///      what the settler sent. The oracle reports that fee, which is the
    ///      only figure this contract trusts for it: the fall in its own
    ///      balance would also count any ETH forced into the oracle by
    ///      SELFDESTRUCT and refunded on top of what was sent (section 7
    ///      rule 8).
    function _settlePrice(uint256 targetTime, bytes calldata streamsPayload, bytes[] calldata pythUpdate)
        private
        returns (uint256 price18)
    {
        // The narrowing cast is the oracle's own interface: a target is a block
        // timestamp plus twelve seconds, and 64 bits hold timestamps far beyond
        // any chain this could run on, so it cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 target = uint64(targetTime);

        // The oracle is the address this contract was deployed against, the
        // value is what the settler sent for the Pyth fee, and the deviation it
        // also returns belongs to the circuit breaker of section 7 rule 6,
        // which is not written yet.
        // forge-lint: disable-next-line(reentrancy-eth,unused-return)
        (price18,, _pythPaid) = SETTLEMENT_ORACLE.settlePrice{value: msg.value}(target, streamsPayload, pythUpdate);
    }

    /// @dev Apply the open rules at `price18`. A reason other than `None` means
    ///      the request is rejected and nothing here has changed state.
    function _openAt(uint256 id, Request storage request, uint256 price18) private returns (Reason) {
        if (inflowsPaused) {
            return Reason.InflowsPaused;
        }
        if (!_paxgUsable()) {
            return Reason.PaxgUnusable;
        }
        if (POOL.shareSupply() == 0) {
            return Reason.PoolHasNoShares;
        }
        if (price18 >= ClaimBook.RANGE_TOP) {
            return Reason.EntryPriceOutOfRange;
        }

        Open memory open = _openMath(request.escrowed, request.leverage, price18);

        if (_usd(open.size, price18) < MIN_NOTIONAL_USD) {
            return Reason.BelowMinimumNotional;
        }
        // D46 bounds R after the open, not before it, so the ceiling is
        // measured against the pool this open is about to make: its own
        // collateral and its own share of the fee are already on their way in.
        // Reading `reservableOunces` here instead would refuse an open that
        // fits once its gold has landed, which is a stricter rule than the one
        // the spec states. Every figure is computed before any transfer, so a
        // breach still rejects (D70) rather than reverting inside `reserve`.
        if (!_fitsTheCeiling(open)) {
            return Reason.ReserveCeiling;
        }

        _commitOpen(id, request, open, price18);

        return Reason.None;
    }

    /// @dev Everything the settled price decides about an open, in one value so
    ///      the rules below it and the writes after it read the same figures.
    function _openMath(uint256 escrowed, uint256 leverage, uint256 price18) private view returns (Open memory open) {
        open.size = escrowed * leverage;
        // D71 rule 2: the open fee comes out of the posted q, so the claim is
        // what is left times the settled price. The fee rounds up, against the
        // position (D29).
        open.feeOunces = _feeOunces(open.size);
        open.joined = escrowed - open.feeOunces;
        open.claim = _usd(open.joined, price18);
        (open.toTreasury, open.toFund, open.toPool) = _split(open.feeOunces);
    }

    /// @dev Whether R would still sit inside u_max of the pool this open makes
    ///      (D46).
    function _fitsTheCeiling(Open memory open) private view returns (bool) {
        uint256 poolAfter = POOL.ounces() + open.joined + open.toPool;
        return (poolAfter * POOL.U_MAX_BPS()) / BPS_DENOMINATOR >= POOL.reserved() + open.size;
    }

    /// @dev Write the position, move the gold and take the reserve. The gold
    ///      goes in before R rises, which is the order D46 measures in.
    function _commitOpen(uint256 id, Request storage request, Open memory open, uint256 price18) private {
        uint256 escrowed = request.escrowed;
        address owner = request.requester;
        uint256 index = _index.value;

        request.state = State.Settled;
        escrowedOunces -= escrowed;

        uint256 positionId = nextPositionId;
        nextPositionId = positionId + 1;
        _positions[positionId] = Position({
            owner: owner,
            size: open.size,
            claim: open.claim,
            openPrice: price18,
            openIndex: index,
            open: true,
            exitPending: false,
            flagged: false
        });
        _book.add(open.size, open.claim, price18, index);

        // Every figure this reports is settled above, and the shared section is
        // held across the calls below, so nothing can reach this contract
        // between them to reorder the log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OpenSettled(id, positionId, owner, open.size, open.claim, price18, open.feeOunces);

        IERC20(address(GOLD)).safeTransfer(address(POOL), open.joined);
        _routeFee(open.toTreasury, open.toFund, open.toPool);
        // The escrow and the position are written above, before any of these
        // calls, and the section is held across all of them. The credit's
        // return value is the pool's own figure, which I1 checks on its side.
        // forge-lint: disable-next-line(reentrancy-no-eth,unused-return)
        POOL.syncCredit();
        // forge-lint: disable-next-line(reentrancy-no-eth)
        POOL.reserve(open.size);
    }

    /// @dev Apply the add rules at `price18`. A reason other than `None` means
    ///      the request is rejected and nothing here has changed state.
    function _addAt(uint256 id, Request storage request, uint256 price18) private returns (Reason) {
        // I28 as r6.17 revises it: an add is an inflow, so a pending one is
        // rejected while the brake is on, not held until it lifts.
        if (inflowsPaused) {
            return Reason.InflowsPaused;
        }
        if (!_paxgUsable()) {
            return Reason.PaxgUnusable;
        }

        uint256 positionId = request.positionId;
        Position storage position = _positions[positionId];
        if (!position.open) {
            return Reason.PositionClosed;
        }
        // D43 rule 2: a holder watching the oracle must not rescue a position
        // that is already past its liquidation level at the settled price.
        if (_isLiquidatable(position, price18)) {
            return Reason.Liquidatable;
        }

        uint256 added = _usd(request.escrowed, price18);
        // D43 rule 5: the payout bound of D46 needs C <= s * P_open, and the
        // claim book holds the same floored notional, so the two agree.
        if (position.claim + added > _usd(position.size, position.openPrice)) {
            return Reason.ClaimWouldPassNotional;
        }

        _commitAdd(id, request, position, positionId, added, price18);

        return Reason.None;
    }

    /// @dev Move the gold into the pool, raise the claim and tell the book.
    function _commitAdd(
        uint256 id,
        Request storage request,
        Position storage position,
        uint256 positionId,
        uint256 added,
        uint256 price18
    ) private {
        uint256 escrowed = request.escrowed;

        request.state = State.Settled;
        escrowedOunces -= escrowed;
        position.claim += added;
        // D43 rule 4: an add that settles proves the position healthy at a
        // settled price, so it clears the D22 fallback flag. Nothing raises
        // that flag before the liquidation unit, so for now this only ever
        // clears one that is already down.
        position.flagged = false;
        _book.addCollateral(position.openPrice, added);

        // Every figure is settled above and the guarded section covers the
        // calls below.
        // forge-lint: disable-next-line(reentrancy-events)
        emit AddSettled(id, positionId, escrowed, position.claim, price18);

        IERC20(address(GOLD)).safeTransfer(address(POOL), escrowed);
        // The escrow and the claim are written above, before the transfer, and
        // the guarded section covers both calls. The credit's return value is
        // the pool's own figure, which I1 checks on its side.
        // forge-lint: disable-next-line(reentrancy-no-eth,unused-return)
        POOL.syncCredit();
    }

    /// @dev Whether a position is past its liquidation level at `price18`
    ///      (D11, 5.4 rule 1): equity under the maintenance margin of the
    ///      notional. Equity is the claim plus the notional now, less the
    ///      notional at open and the holding fee owed, so the comparison is
    ///      written as held against owed to keep every term unsigned.
    function _isLiquidatable(Position storage position, uint256 price18) private view returns (bool) {
        uint256 size = position.size;
        uint256 feeOunces = (size * (indexNow() - position.openIndex) + WAD - ROUND_UP) / WAD;
        uint256 notional = _usd(size, price18);
        uint256 threshold = (notional * MAINTENANCE_MARGIN_BPS + BPS_DENOMINATOR - ROUND_UP) / BPS_DENOMINATOR;

        // The comparison is strict, as 5.4 rule 1 states it: equity exactly
        // at the threshold is not liquidatable. Every term leans the way D29
        // asks, the notional owed and the fee up and the notional held down,
        // so a rounding error can only ever call a position liquidatable and
        // never miss one.
        uint256 owed = _usdUp(size, position.openPrice) + _usdUp(feeOunces, price18) + threshold;
        uint256 held = position.claim + notional;

        return held < owed;
    }

    /// @dev D43 rule 3: an add cannot be opened while an exit is pending for
    ///      the position.
    function _requireNoExitPending(uint256 positionId) private view {
        if (_positions[positionId].exitPending) {
            revert ExitPending(positionId);
        }
    }

    /// @dev Ounces at a price, in USD, rounded up.
    function _usdUp(uint256 ounces, uint256 price18) private pure returns (uint256) {
        return (ounces * price18 + WAD - ROUND_UP) / WAD;
    }

    /// @dev End a request as rejected and give the escrow back in full (D70).
    function _reject(uint256 id, Request storage request, Reason reason, uint256 price18) private {
        uint256 escrowed = request.escrowed;
        address requester = request.requester;

        request.state = State.Rejected;
        if (escrowed != 0) {
            escrowedOunces -= escrowed;
        }
        // The state and the escrow are written above and the section is held,
        // so the refund below cannot come back in and repeat this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit RequestRejected(id, requester, reason, price18);

        if (escrowed != 0) {
            IERC20(address(GOLD)).safeTransfer(requester, escrowed);
        }
    }

    /// @dev How a collected fee splits between the treasury, the fund and the
    ///      pool (D20). The fund's share goes to the pool once the fund is at
    ///      its target, and the remainder of both divisions goes to the pool,
    ///      which is where an unrouted wei belongs: it is already in the pool's
    ///      hands. Separate from the transfers so a settlement can weigh the
    ///      pool's share against the D46 ceiling before moving anything.
    function _split(uint256 feeOunces) private view returns (uint256 toTreasury, uint256 toFund, uint256 toPool) {
        if (feeOunces == 0) {
            return (0, 0, 0);
        }

        toTreasury = (feeOunces * TREASURY_SHARE_BPS) / BPS_DENOMINATOR;
        toFund = INSURANCE_FUND.atTarget() ? 0 : (feeOunces * INSURANCE_SHARE_BPS) / BPS_DENOMINATOR;
        toPool = feeOunces - toTreasury - toFund;
    }

    /// @dev Move a split fee to the three places it goes (D20).
    function _routeFee(uint256 toTreasury, uint256 toFund, uint256 toPool) private {
        // The split is decided by the caller and the section is held across the
        // three transfers below, as in the settlement that calls this.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeeRouted(toTreasury, toFund, toPool);

        if (toTreasury != 0) {
            IERC20(address(GOLD)).safeTransfer(TREASURY, toTreasury);
        }
        if (toFund != 0) {
            IERC20(address(GOLD)).safeTransfer(address(INSURANCE_FUND), toFund);
            // The escrow this gold came from was released before the transfer,
            // and the credit's return value is the fund's own figure, which its
            // I1 checks on its side.
            // forge-lint: disable-next-line(reentrancy-no-eth,unused-return)
            INSURANCE_FUND.syncCredit();
        }
        if (toPool != 0) {
            IERC20(address(GOLD)).safeTransfer(address(POOL), toPool);
            // forge-lint: disable-next-line(reentrancy-no-eth,unused-return)
            POOL.syncCredit();
        }
    }

    /// @dev Pay the settler what the settlement cost it, capped at the fee the
    ///      requester deposited, and credit the rest back (D65). The settler is
    ///      `msg.sender` and chose to be here, so this one is pushed; the
    ///      requester's share is pulled.
    ///
    ///      Two sums go to the settler, and they come from different places.
    ///      The reimbursement is gas used times the gas price plus what Pyth
    ///      took, capped at the fee the requester deposited. The surplus is
    ///      whatever of the settler's own value Pyth did not take, which was
    ///      never the requester's to keep. Adding them leaves this contract
    ///      holding nothing for the request: in comes the deposited fee plus
    ///      the settler's value, out goes the Pyth fee, the reimbursement, the
    ///      surplus and the credit, and the two sides are equal.
    function _payTheSettler(uint256 id, Request storage request, uint256 gasAtEntry) private {
        uint256 fee = request.executionFee;
        uint256 pythPaid = _pythPaid;
        uint256 used = gasAtEntry - gasleft() + GAS_OVERHEAD;
        // Same gas price the floor was quoted at.
        uint256 owed = used * tx.gasprice + pythPaid;
        uint256 paid = owed > fee ? fee : owed;
        uint256 credited = fee - paid;
        uint256 surplus = msg.value - pythPaid;

        if (credited != 0) {
            ethCredit[request.requester] += credited;
        }
        // The credit is written above and the payment below is the last thing
        // this transaction does.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SettlerPaid(id, msg.sender, paid, credited);

        uint256 toSettler = paid + surplus;
        if (toSettler != 0) {
            _sendEth(msg.sender, toSettler);
        }
    }

    function _sendEth(address to, uint256 amount) private {
        // The recipient is either the caller or an account pulling its own
        // credit, never an address this contract chose, and a raw call is the
        // only way to pay an account that may be a contract.
        // forge-lint: disable-next-line(arbitrary-send-eth,low-level-calls)
        (bool sent,) = to.call{value: amount}("");
        if (!sent) {
            revert TransferFailed(to, amount);
        }
    }

    /// @dev f of a size in ounces, rounded up against the position (D29, D71).
    function _feeOunces(uint256 size) private view returns (uint256) {
        return (size * POSITION_FEE_BPS + BPS_DENOMINATOR - ROUND_UP) / BPS_DENOMINATOR;
    }

    /// @dev The close fee every open position will owe at a price, rounded up
    ///      (D71 rule 6).
    function _closeFeeUsdUp(uint256 price18) private view returns (uint256) {
        uint256 notional = POOL.reserved() * price18;
        return (notional * POSITION_FEE_BPS + BPS_DENOMINATOR * WAD - ROUND_UP) / (BPS_DENOMINATOR * WAD);
    }

    /// @dev Ounces at a price, in USD, rounded down.
    function _usd(uint256 ounces, uint256 price18) private pure returns (uint256) {
        return (ounces * price18) / WAD;
    }

    /// @dev Whether PAXG can be used at all (D50), read on inflow paths only.
    function _paxgUsable() private view returns (bool) {
        return !PAXG.isFrozen(PAXG_HOLDER) && !PAXG.paused();
    }

    /// @dev The fee curve, rebuilt from the immutables that hold it.
    function _feeParams() private view returns (FeeIndex.Params memory) {
        return
            FeeIndex.Params({floorRate: FEE_FLOOR_RATE, capRate: FEE_CAP_RATE, uMax: FEE_U_MAX, exponent: FEE_EXPONENT});
    }
}
