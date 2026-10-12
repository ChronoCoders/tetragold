// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../../src/CounterpartyPool.sol";
import {LPToken} from "../../src/LPToken.sol";
import {ReentrancyLock} from "../../src/ReentrancyLock.sol";
import {TGAUX} from "../../src/TGAUX.sol";
import {TgauxVault} from "../../src/TgauxVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPositionBook} from "../mocks/MockPositionBook.sol";

/// @notice Drives the counterparty pool the way the protocol will: LPs request
///         and the position manager settles, opens and closes.
/// @dev The ghosts record what this handler moved, never what the pool reported
///      about itself, so the identity invariants are not balanced against the
///      pool's own arithmetic.
///
///      The book's claim measures are not free: a real book's claim on a
///      position is at most s_i * P (D46), and the withdrawal measure is never
///      the smaller of the two (D48). `moveClaims` keeps both, so a failure of
///      I6 or I15b is the pool's and not the stand in's.
///
///      Every call goes through `MockPositionBook`, which is the pool's
///      deployer, its position book and, from D69, the front door every request
///      arrives by. Foundry runs with call isolation
///      on, so taking the shared lock here and calling the pool on the next
///      line would find the lock free.
contract PoolHandler is Test {
    uint256 private constant ACTORS = 3;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    uint256 private constant MIN_MOVE = 0.01 ether;
    uint256 private constant MAX_MOVE = 200 ether;
    uint256 private constant MIN_PRICE = 500e18;
    uint256 private constant MAX_PRICE = 8000e18;
    uint256 private constant MAX_STEP = 1200;
    uint256 private constant SELECTOR_BYTES = 4;

    CounterpartyPool public immutable POOL;
    MockPositionBook public immutable BOOK;
    ReentrancyLock public immutable LOCK;
    TgauxVault public immutable VAULT;
    TGAUX public immutable GOLD;
    LPToken public immutable SHARES;
    MockERC20 public immutable PAXG;

    address[ACTORS] private _lps;
    uint256[] private _pending;

    /// @notice Price every settlement in this campaign has used so far, which
    ///         the claim measures are kept consistent with.
    uint256 public price = 2000e18;

    uint256 public escrowedIn;
    uint256 public refundedOut;
    uint256 public depositsSettled;
    uint256 public creditedTotal;
    uint256 public paidOutTotal;
    uint256 public withdrawnTotal;

    uint256 public depositRequests;
    uint256 public withdrawalRequests;
    uint256 public settledDeposits;
    uint256 public settledWithdrawals;
    uint256 public expiries;
    uint256 public opens;
    uint256 public closes;
    uint256 public coverageRejections;
    uint256 public reserveRefusals;
    uint256 public rejections;
    uint256 public lateSettlementRefusals;

    uint256 public payOutFailures;
    uint256 public overpaidCalls;
    uint256 public mispricedDeposits;
    uint256 public mispricedWithdrawals;
    /// @notice Requests that did not land in the terminal state their path
    ///         produces, and rejections of requests that should have settled.
    uint256 public wrongEndings;
    uint256 public wrongRejections;
    uint256 public reserveOvershootsAllowed;

    /// @notice Requests tried from outside the manager and refused, which is
    ///         what D69 requires, and the ones let through, which is the
    ///         defect. The first is counted so the second cannot be green for
    ///         want of an attempt.
    uint256 public outsideCallsRefused;
    uint256 public outsideCallsAllowed;
    uint256 public lateSettlementsAllowed;

    constructor(ReentrancyLock lock, uint256 uMaxBps, uint256 requestExpiry) {
        LOCK = lock;
        PAXG = new MockERC20("Paxos Gold", "PAXG", 18);
        VAULT = new TgauxVault(address(PAXG), makeAddr("vault treasury"), 0, 0);
        GOLD = VAULT.TOKEN();
        BOOK = new MockPositionBook(address(GOLD), address(lock), uMaxBps, requestExpiry);
        POOL = BOOK.POOL();
        SHARES = POOL.SHARES();

        for (uint256 i = 0; i < ACTORS; i++) {
            _lps[i] = address(uint160(uint256(keccak256(abi.encodePacked("pool lp", i)))));
        }
    }

    function lpCount() external pure returns (uint256) {
        return ACTORS;
    }

    function lpAt(uint256 index) external view returns (address) {
        return _lps[index];
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    /// @dev Requests only become settleable a slot later and only expire after
    ///      the expiry, so the campaign has to be able to move the clock.
    function passTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, MAX_STEP));
    }

    function movePrice(uint256 seed) external {
        price = bound(seed, MIN_PRICE, MAX_PRICE);
        _reprice(seed);
    }

    /// @dev Keeps the stand in book honest: a claim is at most s * P and the
    ///      withdrawal measure is never below the deposit measure.
    function moveClaims(uint256 depositSeed, uint256 extraSeed) external {
        _setClaims(depositSeed, extraSeed);
    }

    /// @dev D69: the LP approves the pool and the manager makes the call, so
    ///      the gold moves from the LP into the escrow and the request names
    ///      the LP rather than the caller.
    function requestDeposit(uint256 lpSeed, uint256 amount) external {
        address lp = _lpAt(lpSeed);
        amount = bound(amount, MIN_MOVE, MAX_MOVE);
        _fund(lp, amount);

        vm.prank(lp);
        assertTrue(GOLD.approve(address(POOL), amount));

        // D69: the same call from the LP itself must be refused, which is the
        // half of I28 the pool can still state for itself.
        vm.prank(lp);
        // forge-lint: disable-next-line(unused-return)
        try POOL.requestDeposit(lp, amount) returns (uint256) {
            outsideCallsAllowed += 1;
        } catch {
            outsideCallsRefused += 1;
        }

        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 id = BOOK.requestDeposit(lp, amount);

        _pending.push(id);
        escrowedIn += amount;
        depositRequests += 1;
    }

    function requestWithdrawal(uint256 lpSeed, uint256 shareSeed) external {
        address lp = _lpAt(lpSeed);
        uint256 held = SHARES.balanceOf(lp);
        if (held == 0) {
            return;
        }
        uint256 amount = bound(shareSeed, 1, held);

        vm.prank(lp);
        assertTrue(SHARES.approve(address(POOL), amount));

        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 id = BOOK.requestWithdrawal(lp, amount);

        _pending.push(id);
        withdrawalRequests += 1;
    }

    /// @dev One settle path for both kinds, so the fuzzer cannot settle only
    ///      the easy one. It asserts the price the pool used per call, which is
    ///      where I16 lives: an invariant reading end state cannot see a single
    ///      mispriced settlement that a later one cancels out.
    function settle(uint256 idSeed) external {
        (uint256 id, uint256 index) = _pickPending(idSeed);
        if (id == 0) {
            return;
        }
        // Only the fields this path acts on are read; the rest have their own
        // assertions in the unit tests.
        // forge-lint: disable-next-line(unused-return)
        (, uint256 amount, uint256 targetTime, CounterpartyPool.Kind kind,) = POOL.requestAt(id);
        // The target is a deadline in slot time, which post merge Ethereum
        // fixes (consensus-specs specs/bellatrix/beacon-chain.md:446 at
        // 9a8fdd0).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < targetTime) {
            return;
        }
        // Past the expiry the request belongs to `expire` alone (section 7 rule
        // 4), so the attempt is made on purpose and the refusal is counted. A
        // campaign that only ever settled in time would say nothing about the
        // deadline.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= targetTime + POOL.REQUEST_EXPIRY()) {
            _settleTooLate(id, kind);
            return;
        }

        if (kind == CounterpartyPool.Kind.Deposit) {
            _settleDeposit(id, index, amount);
        } else {
            _settleWithdrawal(id, index, amount);
        }
    }

    function expireOne(uint256 idSeed) external {
        (uint256 id, uint256 index) = _pickPending(idSeed);
        if (id == 0) {
            return;
        }
        // Same reason as the settle path above.
        // forge-lint: disable-next-line(unused-return)
        (address lp, uint256 amount, uint256 targetTime, CounterpartyPool.Kind kind,) = POOL.requestAt(id);
        // Same deadline in slot time as above.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < targetTime + POOL.REQUEST_EXPIRY()) {
            return;
        }

        // The ghosts below follow the call because the call is what they
        // record, and the shared lock the pool takes stops a reentry. Both
        // lines are external calls, so both carry the allow.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        // forge-lint: disable-next-line(reentrancy-no-eth)
        BOOK.expire(id, lp);

        _drop(index);
        expiries += 1;
        if (kind == CounterpartyPool.Kind.Deposit) {
            refundedOut += amount;
        }
    }

    /// @dev An open as D45 and D46 describe it: the trader's collateral joins
    ///      the pool and s ounces are reserved against it.
    /// @param overshoot Asks for more than u_max leaves room for. I7 is a
    ///        claim about the only place R can rise, so a campaign that never
    ///        asks for too much proves nothing about the check that refuses it.
    function open(uint256 sizeSeed, bool overshoot) external {
        uint256 room = POOL.reservableOunces();
        if (overshoot) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            try BOOK.reserve(room + 1 + bound(sizeSeed, 0, MAX_MOVE)) {
                reserveOvershootsAllowed += 1;
            } catch {
                reserveRefusals += 1;
            }
            return;
        }
        if (room < MIN_MOVE) {
            return;
        }
        uint256 size = bound(sizeSeed, MIN_MOVE, room);
        uint256 collateral = size / 2;

        _fund(address(POOL), collateral);
        // The ghost is the credit the pool reports here on purpose: the handler
        // minted the collateral straight into the pool, and I27 balances this
        // figure against the pool's own ounces, so a credit the pool
        // understates shows up as a break in that identity.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        creditedTotal += BOOK.syncCredit();
        BOOK.reserve(size);
        opens += 1;
    }

    /// @dev A close in the order the pool cannot enforce for itself: the
    ///      reserve goes first, then the payout, so pool ounces never dip
    ///      under R between the two.
    function close(uint256 sizeSeed, uint256 payoutSeed) external {
        uint256 held = POOL.reserved();
        if (held == 0) {
            return;
        }
        uint256 size = bound(sizeSeed, 1, held);
        uint256 payout = bound(payoutSeed, 0, size);
        uint256 ouncesBefore = POOL.ounces();

        try BOOK.closePosition(_lps[0], payout, size) returns (uint256 paid) {
            if (paid > payout || paid > ouncesBefore) {
                overpaidCalls += 1;
            }
            paidOutTotal += paid;
            closes += 1;
        } catch {
            payOutFailures += 1;
        }
    }

    /// @dev D70: a deposit this price would mint nothing for is rejected and
    ///      refunded rather than left pending, so the ghosts record it as an
    ///      escrow that came back.
    function _settleDeposit(uint256 id, uint256 index, uint256 amount) private {
        uint256 supply = SHARES.totalSupply();
        uint256 value = POOL.depositValue(price);
        uint256 expected = supply == 0 ? amount : (amount * (supply + 1)) / (value + 1);

        // Same as the credit path: the ghosts follow the call deliberately.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (uint256 minted, bool rejected) = BOOK.settleDeposit(id, price);

        if (rejected) {
            if (expected != 0) {
                wrongRejections += 1;
            }
            _drop(index);
            refundedOut += amount;
            rejections += 1;
            _endedOnce(id, CounterpartyPool.State.Rejected);
            return;
        }

        // The exact figure is the I16 claim, so an approximate comparison
        // would let a rounding defect through.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (minted != expected) {
            mispricedDeposits += 1;
        }

        _drop(index);
        depositsSettled += amount;
        settledDeposits += 1;
        _endedOnce(id, CounterpartyPool.State.Settled);
    }

    /// @dev D13 as revised and D70: a withdrawal that would leave R above
    ///      u_max of what is left is rejected and the shares go back, so this
    ///      records it as an ending rather than as a request still waiting.
    function _settleWithdrawal(uint256 id, uint256 index, uint256 shares) private {
        uint256 value = POOL.withdrawalValue(price);
        uint256 expected = (shares * (value + 1)) / (SHARES.totalSupply() + 1);
        uint256 ouncesBefore = POOL.ounces();

        // forge-lint: disable-next-line(reentrancy-no-eth)
        (uint256 paid, bool rejected) = BOOK.settleWithdrawal(id, price);

        if (rejected) {
            _drop(index);
            rejections += 1;
            coverageRejections += 1;
            _endedOnce(id, CounterpartyPool.State.Rejected);
            return;
        }

        // The exact figure is the I16 claim, as above.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (paid != expected) {
            mispricedWithdrawals += 1;
        }
        if (paid > ouncesBefore) {
            overpaidCalls += 1;
        }
        withdrawnTotal += paid;
        settledWithdrawals += 1;
        _drop(index);
        _endedOnce(id, CounterpartyPool.State.Settled);
    }

    /// @dev I17 as revised by D70: the request must have left pending for the
    ///      one terminal state this path produces, and a second attempt would
    ///      now be refused by that state.
    function _endedOnce(uint256 id, CounterpartyPool.State want) private {
        // Only the state field answers this question.
        // forge-lint: disable-next-line(unused-return)
        (,,,, CounterpartyPool.State state) = POOL.requestAt(id);
        if (state != want) {
            wrongEndings += 1;
        }
    }

    /// @dev A settlement at or after the expiry must be refused with the pool's
    ///      own deadline error. Anything else, including success, is a defect.
    function _settleTooLate(uint256 id, CounterpartyPool.Kind kind) private {
        if (kind == CounterpartyPool.Kind.Deposit) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            try BOOK.settleDeposit(id, price) returns (uint256, bool) {
                lateSettlementsAllowed += 1;
            } catch (bytes memory reason) {
                _countLateRefusal(reason);
            }
        } else {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            try BOOK.settleWithdrawal(id, price) returns (uint256, bool) {
                lateSettlementsAllowed += 1;
            } catch (bytes memory reason) {
                _countLateRefusal(reason);
            }
        }
    }

    function _countLateRefusal(bytes memory reason) private {
        if (_selectorOf(reason) == CounterpartyPool.TooLate.selector) {
            lateSettlementRefusals += 1;
            return;
        }
        assertTrue(false, "a settlement past the expiry failed for another reason");
    }

    /// @dev The first four bytes of revert data, which name the error. A shorter
    ///      payload carries no selector and matches nothing.
    function _selectorOf(bytes memory reason) private pure returns (bytes4) {
        if (reason.length < SELECTOR_BYTES) {
            return bytes4(0);
        }
        // The length is checked on the line above, so this reads a whole
        // selector; the arguments after it are not part of the comparison.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason);
    }

    function _pickPending(uint256 seed) private view returns (uint256 id, uint256 index) {
        uint256 count = _pending.length;
        if (count == 0) {
            return (0, 0);
        }
        index = seed % count;
        id = _pending[index];
    }

    function _drop(uint256 index) private {
        uint256 last = _pending.length - 1;
        if (index != last) {
            _pending[index] = _pending[last];
        }
        _pending.pop();
    }

    function _reprice(uint256 seed) private {
        _setClaims(seed, seed >> 128);
    }

    function _setClaims(uint256 depositSeed, uint256 extraSeed) private {
        uint256 ceiling = (POOL.reserved() * price) / WAD;
        uint256 depositClaim = bound(depositSeed, 0, ceiling);
        uint256 withdrawalClaim = bound(extraSeed, depositClaim, ceiling);
        BOOK.setClaims(depositClaim, withdrawalClaim);
    }

    function _fund(address to, uint256 amount) private {
        PAXG.mint(address(this), amount);
        assertTrue(PAXG.approve(address(VAULT), amount));
        uint256 minted = VAULT.deposit(amount);
        assertTrue(GOLD.transfer(to, minted));
    }

    function _lpAt(uint256 seed) private view returns (address) {
        return _lps[seed % ACTORS];
    }
}
