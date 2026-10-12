// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionBook} from "./interfaces/IPositionBook.sol";
import {LPToken} from "./LPToken.sol";
import {ReentrancyLock} from "./ReentrancyLock.sol";
import {TGAUX} from "./TGAUX.sol";

/**
 * @title CounterpartyPool
 * @notice The pool that stands opposite every position. It holds TGAUX, lends
 *         nothing and values its shares in ounces (D44, D46, D48).
 * @dev Deployed by the position manager, which is therefore immutable here and
 *      is also the position book the pool reads its claim measures from. The
 *      pool deploys its own share token, so nothing can mint shares but the
 *      pool (D24).
 *
 *      Ounces are tracked rather than read from the token, and escrowed deposit
 *      ounces are tracked apart from pool ounces, because both sit in the same
 *      token balance: I1 for the pool is `balanceOf == ounces + escrowedOunces`.
 *
 *      The position manager is the only entry point (D69). Every request,
 *      LP deposits and withdrawals included, arrives through it, so each
 *      request function takes the LP's address as a parameter rather than
 *      trusting its caller. That address cannot be spoofed: only the manager
 *      can call, and the manager passes its own `msg.sender`. The gold and the
 *      shares still move from that LP straight into this contract's escrow, so
 *      the LP approves the pool and nothing sits in the manager.
 *
 *      Deposits and withdrawals are requests settled at a later price (D13,
 *      section 7 rule 1). A request records its target time and nothing else
 *      about the price, so the keeper that settles it has no choice of price.
 *      It can be settled from that target time until the expiry that follows
 *      it, and not after: the price is fixed at the target but pool and
 *      position state are read at settlement, so an open window would let a
 *      keeper hold an old price against later state (section 7 rule 4).
 *      Settlement and expiry meet at one instant, the expiry itself, which
 *      belongs to expiry alone. Only expiry cancels a request (I17).
 *
 *      There is no guardian brake here. It moved to the manager with the front
 *      door (D58, D69): a deposit request is the one inflow this contract ever
 *      had, and the manager now owns the call that makes it.
 *
 *      Reserved ounces R live here, so the coverage check of I15a and the
 *      withdrawal check of D13 are both local reads.
 */
contract CounterpartyPool {
    using SafeERC20 for IERC20;

    /// @notice Fee and ratio denominator: bounds are given in basis points.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Delay from request to target time: one slot (section 7 rule 2).
    uint256 public constant TARGET_DELAY = 12;

    /// @notice One unit of the 18 decimal scale both ounces and the price use.
    uint256 private constant WAD = 1e18;

    /// @notice Virtual share and virtual asset, against a donation that
    ///         inflates the share price before the second deposit. This is
    ///         OpenZeppelin's ERC4626 defence with a decimals offset of zero
    ///         (`ERC4626.sol:23-40` in the vendored library), which also makes
    ///         the first deposit one share per ounce.
    uint256 private constant VIRTUAL = 1;

    /// @notice What a request is for.
    enum Kind {
        Deposit,
        Withdrawal
    }

    /// @notice Where a request is in the state machine of I17.
    enum State {
        None,
        Pending,
        Settled,
        Expired
    }

    /// @notice One LP request. `amount` is ounces for a deposit and shares for
    ///         a withdrawal, and it is what the escrow holds.
    struct Request {
        address lp;
        uint256 amount;
        uint256 targetTime;
        Kind kind;
        State state;
    }

    /// @notice The gold the pool holds.
    TGAUX public immutable GOLD;

    /// @notice The share token this pool deployed and alone can mint and burn.
    LPToken public immutable SHARES;

    /// @notice The position manager, which deployed this pool, drives every
    ///         settlement and answers the D48 claim measures.
    IPositionBook public immutable POSITION_MANAGER;

    /// @notice The guard shared with the vault, the fund and the position
    ///         manager (D31).
    ReentrancyLock public immutable LOCK;

    /// @notice Upper bound on utilisation u = R / pool ounces, in basis points,
    ///         at most one (D46, O5).
    uint256 public immutable U_MAX_BPS;

    /// @notice How long a request stays settleable before it can expire (O5).
    uint256 public immutable REQUEST_EXPIRY;

    /// @notice Pool ounces: LP deposits plus trader collateral plus retained
    ///         losses and fees, less payouts (section 6).
    uint256 public ounces;

    /// @notice Reserved ounces R = sum of s_i over open positions (D46).
    uint256 public reserved;

    /// @notice Deposit ounces held in escrow for pending requests. They are not
    ///         pool ounces and no share is priced against them.
    uint256 public escrowedOunces;

    /// @notice Shares held in escrow for pending withdrawal requests. They are
    ///         burnt on settlement and returned on expiry.
    uint256 public escrowedShares;

    /// @notice Identifier of the next request, so zero is never a request.
    uint256 public nextRequestId = 1;

    mapping(uint256 requestId => Request request) private _requests;

    event DepositRequested(uint256 indexed id, address indexed lp, uint256 ounces, uint256 targetTime);
    event WithdrawalRequested(uint256 indexed id, address indexed lp, uint256 shares, uint256 targetTime);
    event DepositSettled(
        uint256 indexed id, address indexed lp, uint256 ounces, uint256 shares, uint256 price18, uint256 value
    );
    event WithdrawalSettled(
        uint256 indexed id, address indexed lp, uint256 shares, uint256 ounces, uint256 price18, uint256 value
    );
    event RequestExpired(uint256 indexed id, address indexed lp, uint256 amount);
    event Credited(uint256 credited, uint256 total);
    event PaidOut(address indexed to, uint256 requested, uint256 paid, uint256 total);
    event Reserved(uint256 added, uint256 total);
    event Released(uint256 removed, uint256 total);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroPrice();
    error UMaxTooHigh(uint256 bps);
    error ZeroExpiry();
    error NotPositionManager(address caller);
    error NotRequestOwner(address caller, address lp);
    error LockNotHeld(address caller, address holder);
    error NoSuchRequest(uint256 id);
    error WrongKind(uint256 id);
    error TooEarly(uint256 targetTime);
    error TooLate(uint256 expiresAt);
    error NotExpiredYet(uint256 expiresAt);
    error MintedNothing();
    error NothingReceived();
    error PayoutAboveOunces(uint256 paid, uint256 held);
    error WithdrawalBreaksCoverage(uint256 reservedOunces, uint256 allowed);
    error ReserveBreaksCoverage(uint256 reservedOunces, uint256 allowed);
    error NotReserved(uint256 removed, uint256 reservedOunces);

    /// @param gold The TGAUX token.
    /// @param lock The shared reentrancy guard.
    /// @param uMaxBps Upper bound on u in basis points, at most 10000 (D46).
    /// @param requestExpiry Seconds after the target time a request may expire.
    constructor(address gold, address lock, uint256 uMaxBps, uint256 requestExpiry) {
        if (gold == address(0) || lock == address(0)) {
            revert ZeroAddress();
        }
        if (uMaxBps == 0 || uMaxBps > BPS_DENOMINATOR) {
            revert UMaxTooHigh(uMaxBps);
        }
        if (requestExpiry == 0) {
            revert ZeroExpiry();
        }

        GOLD = TGAUX(gold);
        POSITION_MANAGER = IPositionBook(msg.sender);
        LOCK = ReentrancyLock(lock);
        U_MAX_BPS = uMaxBps;
        REQUEST_EXPIRY = requestExpiry;
        SHARES = new LPToken("Tetra Gold LP", "TGLP");
    }

    /// @notice Escrow `depositOunces` of `lp`'s gold and ask to be priced at
    ///         the next slot.
    /// @dev Position manager only, inside the shared section, because the
    ///      manager is the front door for every request and holds the lock when
    ///      it calls in (D69, D31). The escrow is measured as a balance
    ///      difference, so a token that takes a fee on transfer cannot credit
    ///      more than arrived.
    /// @param lp The LP the request is made for, whose gold moves and who alone
    ///        can expire it. The manager passes its own caller, and nothing
    ///        else can reach this function, so the address cannot be spoofed.
    /// @param depositOunces TGAUX to pull from `lp`.
    /// @return id Identifier of the request.
    function requestDeposit(address lp, uint256 depositOunces) external returns (uint256 id) {
        _onlyPositionManagerInsideTheSection();
        if (lp == address(0)) {
            revert ZeroAddress();
        }
        if (depositOunces == 0) {
            revert ZeroAmount();
        }

        uint256 before = GOLD.balanceOf(address(this));
        // The `from` is deliberately not `msg.sender`: D69 makes the manager
        // the only caller and has it pass its own caller as `lp`, so the gold
        // moves from the LP and never through the manager. Two things bound it:
        // nothing but the manager can reach this function, and the LP's own
        // allowance to this pool is still required, so no amount moves that the
        // LP did not approve. What this does trust is the manager naming the
        // right LP, which is the trust D69 places in it.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(address(GOLD)).safeTransferFrom(lp, address(this), depositOunces);
        uint256 received = GOLD.balanceOf(address(this)) - before;
        if (received == 0) {
            revert NothingReceived();
        }

        id = _record(lp, received, Kind.Deposit);
        escrowedOunces += received;
        // The event reports what arrived, which is only known after the
        // transfer, and the section the manager holds covers both, so no call
        // can reach this contract between them and reorder the log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit DepositRequested(id, lp, received, _requests[id].targetTime);
    }

    /// @notice Escrow `shares` of `lp`'s shares and ask to be priced at the
    ///         next slot.
    /// @dev Position manager only, inside the section, as the deposit request
    ///      above (D69). An LP's shares move from the LP, not from the manager.
    /// @param lp The LP the request is made for, as above.
    /// @param shares Shares to escrow.
    /// @return id Identifier of the request.
    function requestWithdrawal(address lp, uint256 shares) external returns (uint256 id) {
        _onlyPositionManagerInsideTheSection();
        if (lp == address(0)) {
            revert ZeroAddress();
        }
        if (shares == 0) {
            revert ZeroAmount();
        }

        // Same as the deposit request above: the manager names the LP, the
        // LP's allowance to this pool still gates the amount, and the shares
        // never pass through the manager.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(address(SHARES)).safeTransferFrom(lp, address(this), shares);

        id = _record(lp, shares, Kind.Withdrawal);
        escrowedShares += shares;
        // The identifier in the event is assigned after the escrow arrives, and
        // the section covers both, as above.
        // forge-lint: disable-next-line(reentrancy-events)
        emit WithdrawalRequested(id, lp, shares, _requests[id].targetTime);
    }

    /// @notice Price a pending deposit at `price18` and mint its shares.
    /// @dev Position manager only, inside the shared section, because the price
    ///      comes from the settlement the manager is running. Not stopped by
    ///      the brake: the ounces are already escrowed and refusing to price
    ///      them would leave the LP waiting for an expiry (D58).
    /// @param id Request to settle.
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    /// @return shares Shares minted to the LP.
    function settleDeposit(uint256 id, uint256 price18) external returns (uint256 shares) {
        _onlyPositionManagerInsideTheSection();
        Request storage request = _pendingAt(id, Kind.Deposit);

        uint256 value = _valueAt(price18, true);
        uint256 supply = SHARES.totalSupply();
        // One share per ounce while no share exists (D48). Without this the
        // first LP into a pool that already holds trader collateral would be
        // priced against that collateral and get close to nothing for its
        // deposit. It also settles the donation case before the first deposit:
        // gold sent in early belongs to whoever deposits first, not to the
        // sender.
        shares = supply == 0 ? request.amount : (request.amount * (supply + VIRTUAL)) / (value + VIRTUAL);
        if (shares == 0) {
            revert MintedNothing();
        }

        request.state = State.Settled;
        escrowedOunces -= request.amount;
        ounces += request.amount;
        emit DepositSettled(id, request.lp, request.amount, shares, price18, value);

        SHARES.mint(request.lp, shares);
    }

    /// @notice Price a pending withdrawal at `price18` and pay its ounces.
    /// @dev The coverage check of D13 runs after the payout. A withdrawal that
    ///      would break it reverts and the request stays pending, so the LP can
    ///      settle it later or let it expire: reserved ounces cannot leave, and
    ///      LP withdrawal has no liveness guarantee (D54, I14 excludes it).
    /// @param id Request to settle.
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    /// @return paid Ounces sent to the LP.
    function settleWithdrawal(uint256 id, uint256 price18) external returns (uint256 paid) {
        _onlyPositionManagerInsideTheSection();
        Request storage request = _pendingAt(id, Kind.Withdrawal);

        uint256 value = _valueAt(price18, false);
        paid = (request.amount * (value + VIRTUAL)) / (SHARES.totalSupply() + VIRTUAL);
        // The escrowed shares are still in supply, and the value is already
        // pool ounces less a claim, so a payout above pool ounces is arithmetic
        // that cannot happen in a sound state. It is named rather than left to
        // underflow below, because a panic would say nothing about which figure
        // was wrong.
        if (paid > ounces) {
            revert PayoutAboveOunces(paid, ounces);
        }

        uint256 left = ounces - paid;
        uint256 allowed = (left * U_MAX_BPS) / BPS_DENOMINATOR;
        if (reserved > allowed) {
            revert WithdrawalBreaksCoverage(reserved, allowed);
        }

        address lp = request.lp;
        uint256 shares = request.amount;
        request.state = State.Settled;
        escrowedShares -= shares;
        ounces = left;
        emit WithdrawalSettled(id, lp, shares, paid, price18, value);

        SHARES.burn(address(this), shares);
        if (paid != 0) {
            IERC20(address(GOLD)).safeTransfer(lp, paid);
        }
    }

    /// @notice Cancel a request that outlived its expiry and return its escrow.
    /// @dev Only expiry cancels, and a request settles or expires exactly once
    ///      (I17, section 7 rule 4). Position manager only, inside the section,
    ///      so that the manager can refund the execution fee it holds for the
    ///      request in the same call (D65, D69).
    ///
    ///      The rule itself is unchanged: only the LP the request was made for
    ///      can expire it, so a keeper cannot cancel a request the LP still
    ///      wants settled. The manager vouches for that address by passing its
    ///      own caller, and nothing else can reach this function.
    /// @param id Request to expire.
    /// @param caller The account the manager was called by.
    function expire(uint256 id, address caller) external {
        _onlyPositionManagerInsideTheSection();

        Request storage request = _requests[id];
        if (request.state != State.Pending) {
            revert NoSuchRequest(id);
        }
        if (caller != request.lp) {
            revert NotRequestOwner(caller, request.lp);
        }
        uint256 expiresAt = request.targetTime + REQUEST_EXPIRY;
        // Expiry is a deadline in slot time, which post merge Ethereum fixes
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < expiresAt) {
            revert NotExpiredYet(expiresAt);
        }

        uint256 amount = request.amount;
        Kind kind = request.kind;
        request.state = State.Expired;
        emit RequestExpired(id, request.lp, amount);

        if (kind == Kind.Deposit) {
            escrowedOunces -= amount;
            IERC20(address(GOLD)).safeTransfer(request.lp, amount);
        } else {
            escrowedShares -= amount;
            IERC20(address(SHARES)).safeTransfer(request.lp, amount);
        }
    }

    /// @notice Take into pool ounces whatever TGAUX arrived since the last
    ///         count: trader collateral at open, retained losses, penalties and
    ///         the pool's share of fees (D20, D45, D51).
    /// @dev Measured as a balance difference against both tracked totals rather
    ///      than taken on trust, so the pool's books cannot drift from the
    ///      token balance (I1).
    /// @return credited Ounces taken into the pool by this call.
    function syncCredit() external returns (uint256 credited) {
        _onlyPositionManagerInsideTheSection();

        credited = GOLD.balanceOf(address(this)) - ounces - escrowedOunces;
        if (credited != 0) {
            ounces += credited;
            emit Credited(credited, ounces);
        }
    }

    /// @notice Send up to `requested` ounces to `to` as a position payout or a
    ///         residual equity payment (D47, D51).
    /// @dev Never reverts for a shortage, which is what I14 asks of close and
    ///      liquidation: it pays what it has and reports it. D46 proves a payout
    ///      always fits inside the position's own reserve, so a short payment
    ///      here is a defect elsewhere that I2 and I15a would have caught, not
    ///      a state this path is allowed to create silently.
    ///      Ordering, which this contract cannot enforce on its own: the
    ///      position manager releases a closing position's reserve before it
    ///      pays the position out, or pool ounces dip under R between the two
    ///      calls. I15a is asserted over whole operations for that reason, and
    ///      checking it here instead would mean reverting a close, which I14
    ///      forbids.
    /// @param to Recipient: the position owner, for a close payout or for the
    ///        residual equity a liquidation leaves them (D51). Never the
    ///        keeper, whose fixed fee comes from the insurance fund (D39).
    /// @param requested Ounces asked for.
    /// @return paid Ounces actually sent.
    function payOut(address to, uint256 requested) external returns (uint256 paid) {
        _onlyPositionManagerInsideTheSection();
        if (to == address(0)) {
            revert ZeroAddress();
        }

        paid = requested > ounces ? ounces : requested;
        ounces -= paid;
        emit PaidOut(to, requested, paid, ounces);

        if (paid != 0) {
            IERC20(address(GOLD)).safeTransfer(to, paid);
        }
    }

    /// @notice Reserve `size` ounces for a position being opened (D46).
    /// @dev Refuses the open that would put R above u_max of pool ounces, which
    ///      is the I7 check at the only place R can rise.
    /// @param size Ounces to reserve, s for the position.
    function reserve(uint256 size) external {
        _onlyPositionManagerInsideTheSection();
        if (size == 0) {
            revert ZeroAmount();
        }

        uint256 next = reserved + size;
        uint256 allowed = (ounces * U_MAX_BPS) / BPS_DENOMINATOR;
        if (next > allowed) {
            revert ReserveBreaksCoverage(next, allowed);
        }

        reserved = next;
        emit Reserved(size, next);
    }

    /// @notice Release `size` reserved ounces as a position closes (D46).
    /// @dev Lowering R cannot break coverage, so there is no check here beyond
    ///      the one that keeps the counter honest.
    /// @param size Ounces to release.
    function release(uint256 size) external {
        _onlyPositionManagerInsideTheSection();
        if (size > reserved) {
            revert NotReserved(size, reserved);
        }

        reserved -= size;
        emit Released(size, reserved);
    }

    /// @notice Pool value in ounces a deposit is priced against: pool ounces
    ///         less the D48 deposit claim measure converted at `price18`.
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    function depositValue(uint256 price18) external view returns (uint256) {
        return _valueAt(price18, true);
    }

    /// @notice Pool value in ounces a withdrawal is priced against: pool ounces
    ///         less the D48 withdrawal claim measure converted at `price18`.
    ///         It is never above `depositValue` at the same price (I6).
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    function withdrawalValue(uint256 price18) external view returns (uint256) {
        return _valueAt(price18, false);
    }

    /// @notice Utilisation u = R / pool ounces, in basis points (D46, D53).
    /// @dev Zero pool ounces reads as zero rather than reverting, because this
    ///      is a dashboard figure as well as a bound (D55).
    function utilisationBps() external view returns (uint256) {
        if (ounces == 0) {
            return 0;
        }
        return (reserved * BPS_DENOMINATOR) / ounces;
    }

    /// @notice Ounces that may still be reserved before u_max is reached.
    function reservableOunces() external view returns (uint256) {
        uint256 allowed = (ounces * U_MAX_BPS) / BPS_DENOMINATOR;
        return allowed > reserved ? allowed - reserved : 0;
    }

    /// @notice Share supply, which with `ounces` and `reserved` is every figure
    ///         the D55 dashboard needs from this contract.
    function shareSupply() external view returns (uint256) {
        return SHARES.totalSupply();
    }

    /// @notice Read a request, for the dashboard and for a keeper deciding
    ///         whether to settle or to leave it to expire (D55, D56).
    function requestAt(uint256 id)
        external
        view
        returns (address lp, uint256 amount, uint256 targetTime, Kind kind, State state)
    {
        Request storage request = _requests[id];
        return (request.lp, request.amount, request.targetTime, request.kind, request.state);
    }

    function _record(address lp, uint256 amount, Kind kind) private returns (uint256 id) {
        id = nextRequestId;
        nextRequestId = id + 1;
        // The target is one slot after the request, in slot time as above.
        // forge-lint: disable-next-line(block-timestamp)
        _requests[id] = Request({
            lp: lp, amount: amount, targetTime: block.timestamp + TARGET_DELAY, kind: kind, state: State.Pending
        });
    }

    function _pendingAt(uint256 id, Kind kind) private view returns (Request storage request) {
        request = _requests[id];
        if (request.state != State.Pending) {
            revert NoSuchRequest(id);
        }
        if (request.kind != kind) {
            revert WrongKind(id);
        }
        // The target time is the earliest a report can cover, and the expiry
        // that follows it is the first instant that belongs to `expire`
        // instead, so the two meet without a gap and without an overlap. Both
        // are deadlines in slot time, which post merge Ethereum fixes
        // (consensus-specs specs/bellatrix/beacon-chain.md:446 at 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < request.targetTime) {
            revert TooEarly(request.targetTime);
        }
        uint256 expiresAt = request.targetTime + REQUEST_EXPIRY;
        // The deadline is slot time as well, for the same reason as the target
        // above (consensus-specs specs/bellatrix/beacon-chain.md:446 at
        // 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= expiresAt) {
            revert TooLate(expiresAt);
        }
    }

    /// @dev `forDeposit` picks the claim measure, and with it the rounding: the
    ///      deposit measure rounds its ounces down so the value it leaves is
    ///      the larger one, and the withdrawal measure rounds up so the value
    ///      it leaves is the smaller one. Both directions give the LP who is
    ///      already in the pool the better side of the rounding (D29).
    ///
    ///      The subtraction saturates at zero. The withdrawal measure counts
    ///      collateral that has not been lost yet, so it can exceed pool ounces
    ///      in a state where fees have eaten into it, and a revert there would
    ///      stop every withdrawal rather than price it at nothing.
    function _valueAt(uint256 price18, bool forDeposit) private view returns (uint256) {
        if (price18 == 0) {
            revert ZeroPrice();
        }

        uint256 claimUsd =
            forDeposit ? POSITION_MANAGER.depositClaimUsd(price18) : POSITION_MANAGER.withdrawalClaimUsd(price18);
        // Both figures carry the same 18 decimal scale, so the scale has to be
        // restored after the division to land back in ounces.
        uint256 scaled = claimUsd * WAD;
        uint256 claimOunces = forDeposit ? scaled / price18 : (scaled + price18 - 1) / price18;

        return ounces > claimOunces ? ounces - claimOunces : 0;
    }

    function _onlyPositionManagerInsideTheSection() private view {
        if (msg.sender != address(POSITION_MANAGER)) {
            revert NotPositionManager(msg.sender);
        }
        address holder = LOCK.heldBy();
        if (holder != msg.sender) {
            revert LockNotHeld(msg.sender, holder);
        }
    }
}
