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
///      Every guarded call goes through `MockPositionBook`, which is both the
///      pool's deployer and the position book. Foundry runs with call isolation
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
    address public immutable GUARDIAN;

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
    uint256 public coverageRefusals;
    uint256 public brakeRefusals;
    uint256 public brakeSwitches;
    uint256 public reserveRefusals;

    uint256 public payOutFailures;
    uint256 public overpaidCalls;
    uint256 public mispricedDeposits;
    uint256 public mispricedWithdrawals;
    uint256 public doubleFinals;
    uint256 public brakeBlockedAnOutflow;
    uint256 public guardianMovedABalance;
    uint256 public reserveOvershootsAllowed;

    // A zero guardian would make the brake unreachable, which the pool's own
    // constructor test covers; this handler is not a deployment script.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(ReentrancyLock lock, address guardian, uint256 uMaxBps, uint256 requestExpiry) {
        LOCK = lock;
        GUARDIAN = guardian;
        PAXG = new MockERC20("Paxos Gold", "PAXG", 18);
        VAULT = new TgauxVault(address(PAXG), makeAddr("vault treasury"), 0, 0);
        GOLD = VAULT.TOKEN();
        BOOK = new MockPositionBook(address(GOLD), address(lock), guardian, uMaxBps, requestExpiry);
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

    function requestDeposit(uint256 lpSeed, uint256 amount) external {
        address lp = _lpAt(lpSeed);
        amount = bound(amount, MIN_MOVE, MAX_MOVE);
        _fund(lp, amount);

        vm.startPrank(lp);
        assertTrue(GOLD.approve(address(POOL), amount));
        if (POOL.inflowsPaused()) {
            try POOL.requestDeposit(amount) {
                assertTrue(false, "I28: a deposit request went through while the brake was on");
            } catch {
                brakeRefusals += 1;
            }
            vm.stopPrank();
            return;
        }
        uint256 id = POOL.requestDeposit(amount);
        vm.stopPrank();

        _pending.push(id);
        escrowedIn += amount;
        depositRequests += 1;
    }

    /// @dev I28: a withdrawal request is an outflow and the brake must not
    ///      reach it, so a refusal is recorded rather than letting the revert
    ///      end the sequence with no attribution.
    function requestWithdrawal(uint256 lpSeed, uint256 shareSeed) external {
        address lp = _lpAt(lpSeed);
        uint256 held = SHARES.balanceOf(lp);
        if (held == 0) {
            return;
        }
        uint256 amount = bound(shareSeed, 1, held);

        vm.prank(lp);
        assertTrue(SHARES.approve(address(POOL), amount));
        vm.prank(lp);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try POOL.requestWithdrawal(amount) returns (uint256 id) {
            _pending.push(id);
            withdrawalRequests += 1;
        } catch (bytes memory reason) {
            _countBrakeOrFail(reason, "a withdrawal request reverted");
        }
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
        vm.prank(lp);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try POOL.expire(id) {
            _drop(index);
            expiries += 1;
            if (kind == CounterpartyPool.Kind.Deposit) {
                refundedOut += amount;
            }
        } catch (bytes memory reason) {
            _countBrakeOrFail(reason, "an expiry reverted");
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
        } catch (bytes memory reason) {
            if (_isBrake(reason)) {
                brakeBlockedAnOutflow += 1;
            } else {
                payOutFailures += 1;
            }
        }
    }

    /// @dev I28: the guardian may switch the brake and nothing else. Every
    ///      figure the pool tracks is read on both sides of the call, as one
    ///      hash so that the comparison is a single exact check.
    function switchBrake(bool on) external {
        bytes32 before = _fingerprint();

        vm.prank(GUARDIAN);
        if (on) {
            POOL.pauseInflows();
        } else {
            POOL.unpauseInflows();
        }
        brakeSwitches += 1;

        // Strict equality is the claim: I28 says a guardian call changes no
        // balance at all, so any difference, however small, is the defect.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (_fingerprint() != before) {
            guardianMovedABalance += 1;
        }
    }

    function _settleDeposit(uint256 id, uint256 index, uint256 amount) private {
        uint256 supply = SHARES.totalSupply();
        uint256 value = POOL.depositValue(price);
        uint256 expected = supply == 0 ? amount : (amount * (supply + 1)) / (value + 1);
        if (expected == 0) {
            return;
        }

        // Same as the credit path: the ghosts follow the call deliberately.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try BOOK.settleDeposit(id, price) returns (uint256 minted) {
            // The exact figure is the I16 claim, so an approximate comparison
            // would let a rounding defect through.
            // forge-lint: disable-next-line(incorrect-strict-equality)
            if (minted != expected) {
                mispricedDeposits += 1;
            }

            _drop(index);
            depositsSettled += amount;
            settledDeposits += 1;
            _settledOnce(id);
        } catch (bytes memory reason) {
            // Settling ounces already escrowed is not an inflow the brake may
            // stop (D58), so a refusal here is the defect I28 names.
            _countBrakeOrFail(reason, "a deposit settlement reverted");
        }
    }

    function _settleWithdrawal(uint256 id, uint256 index, uint256 shares) private {
        uint256 value = POOL.withdrawalValue(price);
        uint256 expected = (shares * (value + 1)) / (SHARES.totalSupply() + 1);
        uint256 ouncesBefore = POOL.ounces();

        // forge-lint: disable-next-line(reentrancy-no-eth)
        try BOOK.settleWithdrawal(id, price) returns (uint256 paid) {
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
            _settledOnce(id);
        } catch (bytes memory reason) {
            if (_isBrake(reason)) {
                brakeBlockedAnOutflow += 1;
                return;
            }
            // D13: a withdrawal that would leave R above u_max of what is left
            // waits. The request stays pending, which the state read asserts.
            // forge-lint: disable-next-line(unused-return)
            (,,,, CounterpartyPool.State state) = POOL.requestAt(id);
            if (state != CounterpartyPool.State.Pending) {
                doubleFinals += 1;
            }
            coverageRefusals += 1;
        }
    }

    /// @dev I17: the pool's own state machine must have moved this request out
    ///      of pending exactly once, which a second attempt would now refuse.
    function _settledOnce(uint256 id) private {
        // Only the state field answers this question.
        // forge-lint: disable-next-line(unused-return)
        (,,,, CounterpartyPool.State state) = POOL.requestAt(id);
        if (state != CounterpartyPool.State.Settled) {
            doubleFinals += 1;
        }
    }

    /// @dev The brake refusing an outflow is an I28 defect with a name, so it
    ///      is counted; anything else reverting is a defect with none, and the
    ///      assertion ends the sequence where it happened.
    function _countBrakeOrFail(bytes memory reason, string memory what) private {
        if (_isBrake(reason)) {
            brakeBlockedAnOutflow += 1;
            return;
        }
        assertTrue(false, what);
    }

    function _isBrake(bytes memory reason) private pure returns (bool) {
        if (reason.length != SELECTOR_BYTES) {
            return false;
        }
        // The length is checked on the line above, so this cast reads the whole
        // revert payload and truncates nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason) == CounterpartyPool.InflowsArePaused.selector;
    }

    /// @dev Every figure the pool tracks, in one value. A guardian call must
    ///      leave all of them alone (I28).
    function _fingerprint() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                GOLD.balanceOf(address(POOL)),
                SHARES.balanceOf(address(POOL)),
                POOL.ounces(),
                POOL.reserved(),
                POOL.escrowedOunces(),
                POOL.escrowedShares(),
                SHARES.totalSupply()
            )
        );
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
