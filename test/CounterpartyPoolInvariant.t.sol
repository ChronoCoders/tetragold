// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {LPToken} from "../src/LPToken.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TgauxVault} from "../src/TgauxVault.sol";
import {IPositionBook} from "../src/interfaces/IPositionBook.sol";
import {PoolHandler} from "./handlers/PoolHandler.sol";

/// @notice The pool's side of I1, I2, I6, I7, I14, I15a, I15b, I16, I17, I20,
///         I27 and I28 (section 8).
/// @dev The handler catches only the two calls that are allowed to fail, a
///      withdrawal that would break coverage and a deposit request under the
///      brake, so any other revert in a sequence is a defect.
/// forge-config: default.invariant.fail-on-revert = true
contract CounterpartyPoolInvariantTest is Test {
    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant BPS = 10_000;
    uint256 private constant EXPIRY = 600;
    uint256 private constant WAD = 1e18;
    uint256 private constant NOTHING = 0;
    uint256 private constant DRIVE_DEPOSIT = 50 ether;
    uint256 private constant DRIVE_PRICE = 2000e18;
    uint256 private constant DRIVE_SIZE = 10 ether;
    uint256 private constant LOW_PRICE = 500e18;
    uint256 private constant HIGH_PRICE = 8000e18;
    uint256 private constant SELECTORS = 9;
    /// @dev Past the target slot and past the expiry that follows it.
    uint256 private constant PAST_EXPIRY = 1200;

    CounterpartyPool public pool;
    PoolHandler public handler;
    ReentrancyLock public lock;
    TgauxVault public vault;
    TGAUX public gold;
    LPToken public shares;

    function setUp() public {
        lock = new ReentrancyLock();
        handler = new PoolHandler(lock, makeAddr("guardian"), U_MAX_BPS, EXPIRY);
        pool = handler.POOL();
        vault = handler.VAULT();
        gold = handler.GOLD();
        shares = handler.SHARES();

        bytes4[] memory selectors = new bytes4[](SELECTORS);
        selectors[0] = PoolHandler.requestDeposit.selector;
        selectors[1] = PoolHandler.requestWithdrawal.selector;
        selectors[2] = PoolHandler.settle.selector;
        selectors[3] = PoolHandler.expireOne.selector;
        selectors[4] = PoolHandler.open.selector;
        selectors[5] = PoolHandler.close.selector;
        selectors[6] = PoolHandler.passTime.selector;
        selectors[7] = PoolHandler.movePrice.selector;
        selectors[8] = PoolHandler.switchBrake.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I1: what the pool says it holds is what it holds, on both sides
    ///         of its escrow.
    function invariant_I1_TrackedOuncesAndSharesEqualTheBalances() public view {
        assertEq(
            gold.balanceOf(address(pool)),
            pool.ounces() + pool.escrowedOunces(),
            "I1: tracked gold and held gold disagree"
        );
        assertEq(
            shares.balanceOf(address(pool)),
            pool.escrowedShares(),
            "I1: tracked escrowed shares and held shares disagree"
        );
    }

    /// @notice I2: no payout exceeds what was asked or what the pool held.
    function invariant_I2_NoPayoutExceedsTheRequestOrTheHoldings() public view {
        assertEq(handler.overpaidCalls(), NOTHING, "I2: a payout exceeded the request or the holdings");
    }

    /// @notice I6: the deposit value is never below the withdrawal value, at
    ///         the campaign's price and at both ends of the band.
    function invariant_I6_DepositValueNeverBelowWithdrawalValue() public view {
        assertGe(pool.depositValue(handler.price()), pool.withdrawalValue(handler.price()), "I6: high side under low");
        assertGe(pool.depositValue(LOW_PRICE), pool.withdrawalValue(LOW_PRICE), "I6: high side under low at the floor");
        assertGe(
            pool.depositValue(HIGH_PRICE), pool.withdrawalValue(HIGH_PRICE), "I6: high side under low at the ceiling"
        );
    }

    /// @notice I7: R stays inside u_max of pool ounces, and the check that
    ///         keeps it there refused every reserve that would have broken it.
    function invariant_I7_ReservedStaysInsideUMax() public view {
        assertLe(pool.reserved() * BPS, pool.ounces() * U_MAX_BPS, "I7: R rose above u_max of pool ounces");
        assertEq(handler.reserveOvershootsAllowed(), NOTHING, "I7: a reserve past u_max went through");
    }

    /// @notice I14: the payout path never reverts for a shortage.
    function invariant_I14_PayOutNeverReverts() public view {
        assertEq(handler.payOutFailures(), NOTHING, "I14: a close reverted instead of paying what the pool had");
    }

    /// @notice I15a: pool ounces cover the reserve in every state.
    function invariant_I15a_OuncesCoverTheReserve() public view {
        assertGe(pool.ounces(), pool.reserved(), "I15a: pool ounces fell under R");
    }

    /// @notice I15b: pool ounces cover the deposit measure claims at the price
    ///         in use, which under D46 follows from I15a.
    function invariant_I15b_OuncesCoverTheClaims() public view {
        uint256 price = handler.price();
        uint256 claimOunces = (IPositionBook(address(handler.BOOK())).depositClaimUsd(price) * WAD) / price;
        assertGe(pool.ounces(), claimOunces, "I15b: pool ounces fell under the claims they must pay");
    }

    /// @notice I16: every settlement priced exactly as D48 says, in both
    ///         directions. Asserted per call in the handler, because an
    ///         invariant on end state cannot see one mispriced settlement that
    ///         a later one cancels out.
    function invariant_I16_EverySettlementPricedExactly() public view {
        assertEq(handler.mispricedDeposits(), NOTHING, "I16: a deposit minted something other than its share");
        assertEq(handler.mispricedWithdrawals(), NOTHING, "I16: a withdrawal paid something other than its share");
    }

    /// @notice I17: a request leaves pending exactly once, and a refused
    ///         withdrawal stays pending rather than being consumed.
    function invariant_I17_RequestsReachOneFinalStateOnce() public view {
        assertEq(handler.doubleFinals(), NOTHING, "I17: a request left pending more than once or not at all");
    }

    /// @notice Section 7 rule 4: at or after the expiry only expiry remains, so
    ///         no settlement past that instant was allowed through.
    function invariant_Rule4_SettlementStopsAtTheExpiry() public view {
        assertEq(handler.lateSettlementsAllowed(), NOTHING, "rule 4: a settlement past the expiry went through");
    }

    /// @notice I20, pool side: nothing the pool does changes vault backing.
    function invariant_I20_PoolNeverTouchesVaultBacking() public view {
        assertGe(vault.backingPaxg(), gold.totalSupply(), "I20: pool activity broke the vault's backing");
        assertEq(vault.treasuryFeePaxg(), NOTHING, "I20: pool activity credited a vault fee");
    }

    /// @notice I27, pool side: ounces leave the pool only as a payout or a
    ///         settled withdrawal, and arrive only as a settled deposit or a
    ///         credit.
    function invariant_I27_OuncesMoveOnlyThroughTheNamedPaths() public view {
        assertEq(
            pool.ounces() + handler.paidOutTotal() + handler.withdrawnTotal(),
            handler.depositsSettled() + handler.creditedTotal(),
            "I27: the pool's ounces moved outside settlement, credit and payout"
        );
        assertEq(
            pool.escrowedOunces() + handler.depositsSettled() + handler.refundedOut(),
            handler.escrowedIn(),
            "I27: escrowed ounces moved outside settlement and refund"
        );
    }

    /// @notice I28: the brake never blocked an outflow and no guardian call
    ///         moved a balance.
    function invariant_I28_TheBrakeOnlyStopsInflows() public view {
        assertEq(handler.brakeBlockedAnOutflow(), NOTHING, "I28: the brake stopped an outflow");
        assertEq(handler.guardianMovedABalance(), NOTHING, "I28: a guardian call moved a balance");
    }

    /// @dev Every assertion above holds on a campaign that did nothing, so this
    ///      drives each path by hand: a deposit, an open, a close, a
    ///      withdrawal, an expiry and the brake.
    function test_HandlerReachesEveryPathTheInvariantsGuard() public {
        handler.movePrice(DRIVE_PRICE);
        handler.requestDeposit(0, DRIVE_DEPOSIT);
        handler.passTime(EXPIRY);
        handler.settle(0);
        assertGt(handler.settledDeposits(), NOTHING, "no deposit settled");

        handler.open(DRIVE_SIZE, false);
        assertGt(handler.opens(), NOTHING, "no position opened");
        assertGt(pool.reserved(), NOTHING, "nothing was reserved");

        handler.open(DRIVE_SIZE, true);
        assertGt(handler.reserveRefusals(), NOTHING, "the reserve ceiling was never tested");
        assertEq(handler.reserveOvershootsAllowed(), NOTHING, "I7: a reserve past u_max went through");

        handler.moveClaims(type(uint256).max, type(uint256).max);
        assertGt(pool.depositValue(DRIVE_PRICE), NOTHING, "the claims swallowed the whole pool");

        handler.close(type(uint256).max, type(uint256).max);
        assertGt(handler.closes(), NOTHING, "no position closed");
        assertEq(pool.reserved(), NOTHING, "the reserve was not released");

        handler.requestWithdrawal(0, type(uint256).max);
        handler.passTime(EXPIRY);
        handler.settle(0);
        assertGt(handler.settledWithdrawals(), NOTHING, "no withdrawal settled");

        handler.requestDeposit(1, DRIVE_DEPOSIT);
        handler.passTime(PAST_EXPIRY);
        handler.settle(0);
        assertGt(handler.lateSettlementRefusals(), NOTHING, "the settlement deadline was never tested");
        assertEq(handler.lateSettlementsAllowed(), NOTHING, "rule 4: a settlement past the expiry went through");

        handler.expireOne(0);
        assertGt(handler.expiries(), NOTHING, "no request expired");

        handler.switchBrake(true);
        handler.requestDeposit(2, DRIVE_DEPOSIT);
        assertGt(handler.brakeRefusals(), NOTHING, "the brake never refused a deposit request");

        handler.requestWithdrawal(0, type(uint256).max);
        handler.passTime(EXPIRY);
        handler.settle(0);
        handler.close(type(uint256).max, type(uint256).max);
        assertEq(handler.brakeBlockedAnOutflow(), NOTHING, "I28: the brake stopped an outflow");

        handler.switchBrake(false);
        assertEq(handler.guardianMovedABalance(), NOTHING, "a guardian call moved a balance");
    }
}
