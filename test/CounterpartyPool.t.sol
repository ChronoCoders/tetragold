// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {LPToken} from "../src/LPToken.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {MockPositionBook} from "./mocks/MockPositionBook.sol";
import {VaultStub} from "./mocks/VaultStub.sol";

contract CounterpartyPoolTest is Test {
    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant BPS = 10_000;
    uint256 private constant EXPIRY = 600;
    uint256 private constant DELAY = 12;
    uint256 private constant PRICE = 2000e18;
    uint256 private constant HUNDRED = 100 ether;
    uint256 private constant TEN = 10 ether;
    uint256 private constant ONE = 1 ether;
    uint256 private constant ONE_WEI = 1;
    uint256 private constant NOTHING = 0;
    uint256 private constant FIRST_ID = 1;
    /// @dev Enough to put the claim far above anything the pool holds.
    uint256 private constant HUGE_CLAIM_MULTIPLE = 1000;

    CounterpartyPool public pool;
    MockPositionBook public book;
    ReentrancyLock public lock;
    VaultStub public vault;
    TGAUX public gold;
    LPToken public shares;

    address public guardian;
    address public alice;
    address public bob;
    address public trader;
    address public stranger;

    function setUp() public {
        guardian = makeAddr("guardian");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        trader = makeAddr("trader");
        stranger = makeAddr("stranger");

        vault = new VaultStub();
        gold = vault.TOKEN();
        lock = new ReentrancyLock();
        book = new MockPositionBook(address(gold), address(lock), U_MAX_BPS, EXPIRY);
        pool = book.POOL();
        shares = pool.SHARES();

        vault.mint(alice, HUNDRED);
        vault.mint(bob, HUNDRED);
        vault.mint(trader, HUNDRED);
    }

    function test_ConstructorWiresTheDeployerAndItsOwnShareToken() public view {
        assertEq(address(pool.POSITION_MANAGER()), address(book));
        assertEq(address(pool.GOLD()), address(gold));
        assertEq(address(pool.LOCK()), address(lock));
        assertEq(pool.U_MAX_BPS(), U_MAX_BPS);
        assertEq(pool.REQUEST_EXPIRY(), EXPIRY);
        assertEq(shares.LIQUIDITY_POOL(), address(pool), "the pool is not its share token's only minter");
        assertEq(pool.ounces(), NOTHING);
        assertEq(pool.nextRequestId(), FIRST_ID);
    }

    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(CounterpartyPool.ZeroAddress.selector);
        new CounterpartyPool(address(0), address(lock), U_MAX_BPS, EXPIRY);

        vm.expectRevert(CounterpartyPool.ZeroAddress.selector);
        new CounterpartyPool(address(gold), address(0), U_MAX_BPS, EXPIRY);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.UMaxTooHigh.selector, NOTHING));
        new CounterpartyPool(address(gold), address(lock), NOTHING, EXPIRY);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.UMaxTooHigh.selector, BPS + 1));
        new CounterpartyPool(address(gold), address(lock), BPS + 1, EXPIRY);

        vm.expectRevert(CounterpartyPool.ZeroExpiry.selector);
        new CounterpartyPool(address(gold), address(lock), U_MAX_BPS, NOTHING);
    }

    /// @dev D48: the first deposit is one share per ounce, which the virtual
    ///      share and virtual asset give without a special case for it.
    function test_FirstDepositIsOneSharePerOunce() public {
        uint256 id = _requestDeposit(alice, TEN);
        uint256 minted = book.settleDeposit(id, PRICE);

        assertEq(minted, TEN, "the first deposit was not one share per ounce");
        assertEq(shares.balanceOf(alice), TEN);
        assertEq(pool.ounces(), TEN, "the deposit did not join pool ounces");
        assertEq(pool.escrowedOunces(), NOTHING, "the escrow was not released");
        assertEq(gold.balanceOf(address(pool)), TEN);
    }

    /// @dev The donation this guards against: an LP deposits, then sends gold
    ///      straight to the pool to inflate the share price before the next
    ///      deposit prices. The virtual share and virtual asset keep the second
    ///      depositor's shares above zero, and the donor cannot take the
    ///      donation back out: its own shares are worth less than it put in.
    function test_DonationDoesNotRoundTheNextDepositToNothing() public {
        uint256 first = _requestDeposit(alice, ONE);
        uint256 donorShares = book.settleDeposit(first, PRICE);

        vm.prank(alice);
        assertTrue(gold.transfer(address(pool), TEN));
        assertEq(book.syncCredit(), TEN, "the donation did not land in pool ounces");

        uint256 second = _requestDeposit(bob, TEN);
        uint256 minted = book.settleDeposit(second, PRICE);

        assertGt(minted, NOTHING, "the donation rounded the second deposit to nothing");
        assertLt(minted, TEN, "the donation was not priced in at all");

        uint256 out = _requestWithdrawal(alice, donorShares);
        uint256 back = book.settleWithdrawal(out, PRICE);
        assertLt(back, ONE + TEN, "the donor took back more than it deposited and donated");
    }

    /// @dev A donation large enough to price a deposit at zero shares is
    ///      refused rather than taking the deposit for nothing.
    function test_DepositThatWouldMintNothingIsRefused() public {
        uint256 first = _requestDeposit(alice, ONE);
        assertEq(book.settleDeposit(first, PRICE), ONE, "the first deposit was not one share per ounce");

        vm.prank(trader);
        assertTrue(gold.transfer(address(pool), HUNDRED));
        assertEq(book.syncCredit(), HUNDRED, "the donation did not land in pool ounces");

        uint256 second = _requestDeposit(bob, ONE_WEI);

        vm.expectRevert(CounterpartyPool.MintedNothing.selector);
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        book.settleDeposit(second, PRICE);
    }

    /// @dev I6: the deposit value is never below the withdrawal value, because
    ///      the withdrawal measure counts collateral a trader has not lost yet.
    function test_DepositValueIsNeverBelowWithdrawalValue() public {
        uint256 id = _requestDeposit(alice, HUNDRED);
        assertGt(book.settleDeposit(id, PRICE), NOTHING, "the deposit minted nothing");

        book.setClaims(10_000e18, 40_000e18);

        assertEq(pool.depositValue(PRICE), HUNDRED - 5 ether, "the deposit value is not ounces less its claim");
        assertEq(pool.withdrawalValue(PRICE), HUNDRED - 20 ether, "the withdrawal value is not ounces less its claim");
        assertGe(pool.depositValue(PRICE), pool.withdrawalValue(PRICE), "I6: the high side fell under the low side");
    }

    /// @dev D29: the deposit measure rounds its ounces down and the withdrawal
    ///      measure rounds up, so both leave the LP already in the pool the
    ///      better side of a remainder.
    function test_ClaimRoundingFavoursTheStandingLp() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");

        book.setClaims(PRICE + 1, PRICE + 1);

        assertEq(pool.depositValue(PRICE), TEN - ONE, "the deposit claim did not round down");
        assertEq(pool.withdrawalValue(PRICE), TEN - ONE - ONE_WEI, "the withdrawal claim did not round up");
    }

    /// @dev A claim above pool ounces prices the pool at nothing rather than
    ///      reverting, so a withdrawal can still settle.
    function test_ValueSaturatesAtNothing() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");

        book.setClaims(PRICE * HUGE_CLAIM_MULTIPLE, PRICE * HUGE_CLAIM_MULTIPLE);

        assertEq(pool.depositValue(PRICE), NOTHING);
        assertEq(pool.withdrawalValue(PRICE), NOTHING);
    }

    function test_WithdrawalPaysAtTheLowSideAndBurnsItsShares() public {
        uint256 id = _requestDeposit(alice, TEN);
        uint256 minted = book.settleDeposit(id, PRICE);

        uint256 out = _requestWithdrawal(alice, minted);
        uint256 paid = book.settleWithdrawal(out, PRICE);

        assertEq(paid, TEN, "the withdrawal did not return the ounces behind the shares");
        assertEq(gold.balanceOf(alice), HUNDRED, "the LP did not get its gold back");
        assertEq(shares.totalSupply(), NOTHING, "the escrowed shares were not burnt");
        assertEq(pool.escrowedShares(), NOTHING);
        assertEq(pool.ounces(), NOTHING);
    }

    /// @dev D13: a withdrawal that would leave R above u_max of what is left
    ///      reverts, and the request stays pending so it can settle later.
    function test_WithdrawalThatBreaksCoverageWaits() public {
        uint256 id = _requestDeposit(alice, TEN);
        uint256 minted = book.settleDeposit(id, PRICE);
        book.reserve((TEN * U_MAX_BPS) / BPS);

        uint256 out = _requestWithdrawal(alice, minted);

        vm.expectRevert(
            abi.encodeWithSelector(CounterpartyPool.WithdrawalBreaksCoverage.selector, (TEN * U_MAX_BPS) / BPS, NOTHING)
        );
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        book.settleWithdrawal(out, PRICE);

        // Only the state field is under test here.
        // forge-lint: disable-next-line(unused-return)
        (,,,, CounterpartyPool.State state) = pool.requestAt(out);
        assertEq(uint256(state), uint256(CounterpartyPool.State.Pending), "the refused request did not stay pending");

        book.release((TEN * U_MAX_BPS) / BPS);
        assertEq(book.settleWithdrawal(out, PRICE), TEN, "the request could not settle once the reserve went");
    }

    /// @dev I7: R cannot rise above u_max of pool ounces.
    function test_ReserveStopsAtUMax() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");
        uint256 ceiling = (TEN * U_MAX_BPS) / BPS;

        book.reserve(ceiling);
        assertEq(pool.reserved(), ceiling);
        assertEq(pool.utilisationBps(), U_MAX_BPS, "utilisation is not R over pool ounces");
        assertEq(pool.reservableOunces(), NOTHING);

        vm.expectRevert(
            abi.encodeWithSelector(CounterpartyPool.ReserveBreaksCoverage.selector, ceiling + ONE_WEI, ceiling)
        );
        book.reserve(ONE_WEI);
    }

    function test_ReleaseLowersReservedAndRefusesMoreThanItHolds() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");
        book.reserve(ONE);

        book.release(ONE_WEI);
        assertEq(pool.reserved(), ONE - ONE_WEI);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotReserved.selector, ONE, ONE - ONE_WEI));
        book.release(ONE);
    }

    /// @dev I14: a payout never reverts for a shortage. It reports what it paid.
    function test_PayOutPaysWhatItHasAndNeverReverts() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");

        assertEq(book.payOut(trader, ONE), ONE);
        assertEq(gold.balanceOf(trader), HUNDRED + ONE);

        uint256 paid = book.payOut(trader, HUNDRED * 100);

        assertEq(paid, TEN - ONE, "a short payout did not pay what the pool held");
        assertEq(pool.ounces(), NOTHING);
        assertEq(book.payOut(trader, ONE), NOTHING, "an empty pool paid something");
    }

    function test_PayOutRejectsTheZeroRecipient() public {
        vm.expectRevert(CounterpartyPool.ZeroAddress.selector);
        // forge-lint: disable-next-line(unused-return)
        book.payOut(address(0), ONE);
    }

    function test_SyncCreditTakesWhatArrivedPastBothTrackedTotals() public {
        uint256 pending = _requestDeposit(alice, TEN);

        vm.prank(trader);
        assertTrue(gold.transfer(address(pool), ONE));

        assertEq(book.syncCredit(), ONE, "the credit did not measure the arrival");
        assertEq(pool.ounces(), ONE, "the escrowed deposit was credited as pool ounces");
        assertEq(pool.escrowedOunces(), TEN, "the escrow moved");
        assertEq(book.syncCredit(), NOTHING, "a second credit took something twice");

        // No share exists yet, so the escrowed deposit prices at one share per
        // ounce and the credited ounce is a windfall to this first LP (D48).
        assertEq(book.settleDeposit(pending, PRICE), TEN, "the escrow could not settle");
        assertEq(pool.ounces(), TEN + ONE, "the credit and the deposit did not both land");
    }

    function test_GuardedCallsArePositionManagerOnlyAndNeedTheSection() public {
        uint256 id = _requestDeposit(alice, TEN);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotPositionManager.selector, stranger));
        vm.prank(stranger);
        // forge-lint: disable-next-line(unused-return)
        pool.settleDeposit(id, PRICE);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.LockNotHeld.selector, address(book), address(0)));
        // forge-lint: disable-next-line(unused-return)
        book.settleDepositOutsideTheSection(id, PRICE);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.LockNotHeld.selector, address(book), address(0)));
        // forge-lint: disable-next-line(unused-return)
        book.payOutOutsideTheSection(trader, ONE);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.LockNotHeld.selector, address(book), address(0)));
        book.reserveOutsideTheSection(ONE);
    }

    /// @dev D69: the manager is the only entry point. Every one of the three
    ///      request facing calls refuses a caller that is not it, and refuses
    ///      the manager itself without the shared section.
    function test_EveryEntryPointIsManagerOnlyAndNeedsTheSection() public {
        uint256 id = _requestDeposit(alice, TEN);

        vm.startPrank(alice);
        assertTrue(gold.approve(address(pool), TEN));
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotPositionManager.selector, alice));
        // This call reverts by design, so no identifier comes back.
        // forge-lint: disable-next-line(unused-return)
        pool.requestDeposit(alice, TEN);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotPositionManager.selector, alice));
        // forge-lint: disable-next-line(unused-return)
        pool.requestWithdrawal(alice, TEN);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotPositionManager.selector, alice));
        pool.expire(id, alice);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.LockNotHeld.selector, address(book), address(0)));
        // forge-lint: disable-next-line(unused-return)
        book.requestDepositOutsideTheSection(alice, TEN);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.LockNotHeld.selector, address(book), address(0)));
        book.expireOutsideTheSection(id, alice);
    }

    /// @dev D69: the request carries the LP it was made for, not the caller.
    ///      The manager is the caller, so a request that read `msg.sender`
    ///      would name the manager and let it expire the LP's request.
    function test_ARequestNamesTheLpItWasMadeFor() public {
        uint256 id = _requestDeposit(alice, TEN);

        // forge-lint: disable-next-line(unused-return)
        (address lp,,,,) = pool.requestAt(id);
        assertEq(lp, alice, "the request named someone other than the LP");
        assertEq(gold.balanceOf(alice), HUNDRED - TEN, "the gold did not come from the LP");

        uint256 minted = book.settleDeposit(id, PRICE);
        assertEq(shares.balanceOf(alice), minted, "the shares went to someone other than the LP");
        assertEq(shares.balanceOf(address(book)), NOTHING, "the manager held shares");
        assertEq(gold.balanceOf(address(book)), NOTHING, "the manager held gold");
    }

    /// @dev D58 and D69: the brake moved to the manager with the front door, so
    ///      this contract carries no guardian and no pause at all. Absence is
    ///      asserted against the deployed bytecode: the pool has no fallback,
    ///      so a call to a selector it does not carry has to fail.
    function test_ThePoolCarriesNoBrakeAtAll() public {
        string[4] memory gone = ["pauseInflows()", "unpauseInflows()", "inflowsPaused()", "GUARDIAN()"];

        for (uint256 i = 0; i < gone.length; i++) {
            // One call per removed selector is the test, and a raw call is the
            // only way to reach a function the type does not have.
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(pool).call(abi.encodeWithSignature(gone[i]));
            assertFalse(ok, gone[i]);
        }
    }

    /// @dev I17: a request settles at most once or expires at most once.
    function test_RequestSettlesOrExpiresExactlyOnce() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(book.settleDeposit(id, PRICE), TEN, "the deposit minted something other than its ounces");

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NoSuchRequest.selector, id));
        // forge-lint: disable-next-line(unused-return)
        book.settleDeposit(id, PRICE);

        vm.warp(block.timestamp + DELAY + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NoSuchRequest.selector, id));
        book.expire(id, alice);
    }

    function test_ExpiryRefundsTheEscrowAndOnlyAfterTheDeadline() public {
        uint256 id = _requestDeposit(alice, TEN);
        assertEq(pool.escrowedOunces(), TEN);

        // Only the target time is under test here.
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 targetTime,,) = pool.requestAt(id);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotExpiredYet.selector, targetTime + EXPIRY));
        book.expire(id, alice);

        vm.warp(targetTime + EXPIRY);
        book.expire(id, alice);

        assertEq(gold.balanceOf(alice), HUNDRED, "the escrow was not refunded");
        assertEq(pool.escrowedOunces(), NOTHING);
        assertEq(pool.ounces(), NOTHING, "the refund went to pool ounces");
    }

    function test_ExpiryReturnsEscrowedSharesAndIsOwnerOnly() public {
        uint256 id = _requestDeposit(alice, TEN);
        uint256 minted = book.settleDeposit(id, PRICE);
        uint256 out = _requestWithdrawal(alice, minted);

        vm.warp(block.timestamp + DELAY + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotRequestOwner.selector, bob, alice));
        book.expire(out, bob);

        book.expire(out, alice);

        assertEq(shares.balanceOf(alice), minted, "the shares were not returned");
        assertEq(pool.escrowedShares(), NOTHING);
        assertEq(pool.ounces(), TEN, "the pool paid out on an expiry");
    }

    /// @dev Section 7 rule 2: a request cannot settle before its target slot.
    function test_SettlementWaitsForTheTargetSlot() public {
        uint256 requestedAt = block.timestamp;
        uint256 id = _requestDeposit(alice, TEN);
        // Only the target time is under test here.
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 targetTime,,) = pool.requestAt(id);
        assertEq(targetTime, requestedAt + DELAY, "the target is not one slot out");

        vm.warp(targetTime - 1);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.TooEarly.selector, targetTime));
        // forge-lint: disable-next-line(unused-return)
        book.settleDeposit(id, PRICE);

        vm.warp(targetTime);
        assertEq(book.settleDeposit(id, PRICE), TEN);
    }

    /// @dev Section 7 rule 4: the window runs from the target up to the expiry
    ///      and stops there. One second earlier settles.
    function test_SettlementSucceedsTheSecondBeforeTheDeadline() public {
        uint256 id = _requestDeposit(alice, TEN);
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 targetTime,,) = pool.requestAt(id);

        vm.warp(targetTime + EXPIRY - 1);

        assertEq(book.settleDeposit(id, PRICE), TEN, "the last second of the window did not settle");
    }

    /// @dev At the deadline both kinds are refused with the deadline error, and
    ///      the request is still there for an expiry.
    function test_SettlementAtTheDeadlineIsRefusedForBothKinds() public {
        uint256 funded = _requestDeposit(alice, TEN);
        uint256 minted = book.settleDeposit(funded, PRICE);
        uint256 deposit = _requestDeposit(bob, TEN);
        uint256 withdrawal = _requestWithdrawal(alice, minted);
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 depositTarget,,) = pool.requestAt(deposit);
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 withdrawalTarget,,) = pool.requestAt(withdrawal);

        vm.warp(depositTarget + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.TooLate.selector, depositTarget + EXPIRY));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        book.settleDeposit(deposit, PRICE);

        vm.warp(withdrawalTarget + EXPIRY);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.TooLate.selector, withdrawalTarget + EXPIRY));
        // forge-lint: disable-next-line(unused-return)
        book.settleWithdrawal(withdrawal, PRICE);

        // forge-lint: disable-next-line(unused-return)
        (,,,, CounterpartyPool.State state) = pool.requestAt(deposit);
        assertEq(uint256(state), uint256(CounterpartyPool.State.Pending), "the refused request did not stay pending");
    }

    /// @dev The instant settlement gives up is the instant expiry takes, so the
    ///      two meet with no gap and no overlap.
    function test_ExpiryTakesTheInstantSettlementGivesUp() public {
        uint256 id = _requestDeposit(alice, TEN);
        // forge-lint: disable-next-line(unused-return)
        (,, uint256 targetTime,,) = pool.requestAt(id);
        uint256 deadline = targetTime + EXPIRY;

        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.NotExpiredYet.selector, deadline));
        book.expire(id, alice);

        vm.warp(deadline);
        book.expire(id, alice);

        assertEq(gold.balanceOf(alice), HUNDRED, "the escrow was not refunded at the deadline");
        assertEq(pool.escrowedOunces(), NOTHING);
    }

    function test_SettlementRefusesTheWrongKindAndAZeroPrice() public {
        uint256 id = _requestDeposit(alice, TEN);

        vm.expectRevert(abi.encodeWithSelector(CounterpartyPool.WrongKind.selector, id));
        // forge-lint: disable-next-line(unused-return)
        book.settleWithdrawal(id, PRICE);

        vm.expectRevert(CounterpartyPool.ZeroPrice.selector);
        // forge-lint: disable-next-line(unused-return)
        book.settleDeposit(id, NOTHING);
    }

    function test_RequestsRefuseZeroAmounts() public {
        vm.expectRevert(CounterpartyPool.ZeroAmount.selector);
        // forge-lint: disable-next-line(unused-return)
        book.requestDeposit(alice, NOTHING);

        vm.expectRevert(CounterpartyPool.ZeroAmount.selector);
        // forge-lint: disable-next-line(unused-return)
        book.requestWithdrawal(alice, NOTHING);

        vm.expectRevert(CounterpartyPool.ZeroAddress.selector);
        // forge-lint: disable-next-line(unused-return)
        book.requestDeposit(address(0), TEN);
    }

    /// @dev The LP approves the pool and the manager makes the call (D69), so
    ///      the gold still moves from the LP straight into the escrow.
    function _requestDeposit(address lp, uint256 amount) private returns (uint256 id) {
        vm.prank(lp);
        assertTrue(gold.approve(address(pool), amount));
        id = book.requestDeposit(lp, amount);
        vm.warp(block.timestamp + DELAY);
    }

    function _requestWithdrawal(address lp, uint256 amount) private returns (uint256 id) {
        vm.prank(lp);
        assertTrue(shares.approve(address(pool), amount));
        id = book.requestWithdrawal(lp, amount);
        vm.warp(block.timestamp + DELAY);
    }
}
