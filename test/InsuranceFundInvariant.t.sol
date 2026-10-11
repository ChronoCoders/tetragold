// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {FundHandler} from "./handlers/FundHandler.sol";
import {VaultStub} from "./mocks/VaultStub.sol";

/// @notice The fund's side of I1, I2, I14, I16 and I27 (section 8).
/// @dev The handler catches the one call that is allowed to fail, so any other
///      revert in a sequence is a defect.
/// forge-config: default.invariant.fail-on-revert = true
contract InsuranceFundInvariantTest is Test {
    uint256 private constant TARGET = 100 ether;
    uint256 private constant ONE = 1 ether;
    uint256 private constant SEED = 10 ether;
    uint256 private constant ARRIVAL = 5 ether;
    uint256 private constant NOTHING = 0;

    InsuranceFund public fund;
    FundHandler public handler;
    ReentrancyLock public lock;
    VaultStub public vault;
    TGAUX public gold;

    function setUp() public {
        vault = new VaultStub();
        gold = vault.TOKEN();
        lock = new ReentrancyLock();
        handler = new FundHandler(vault, lock, makeAddr("treasury"), TARGET);
        fund = handler.FUND();

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = FundHandler.seedFund.selector;
        selectors[1] = FundHandler.arrive.selector;
        selectors[2] = FundHandler.pay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I1: what the fund says it holds is what it holds.
    function invariant_I1_TrackedOuncesEqualTheBalance() public view {
        assertEq(gold.balanceOf(address(fund)), fund.ounces(), "I1: tracked and held disagree");
    }

    /// @notice I2: the fund never pays out more than reached it.
    function invariant_I2_PaidNeverExceedsWhatArrived() public view {
        assertLe(
            handler.paidTotal(),
            handler.seededTotal() + handler.arrivedTotal(),
            "I2: the fund paid out more than it ever took in"
        );
    }

    /// @notice I14: the fund's exit path never reverts, whatever it holds.
    function invariant_I14_PayNeverReverts() public view {
        assertEq(handler.payFailures(), NOTHING, "I14: a payment reverted instead of paying what it had");
    }

    /// @notice I16: rounding and refusal never favour the recipient.
    function invariant_I16_NeverPaysMoreThanAskedOrHeld() public view {
        assertEq(handler.overpaidCalls(), NOTHING, "I16: a payment exceeded the request");
        assertEq(handler.paidPastHoldings(), NOTHING, "I16: a payment exceeded the holdings");
    }

    /// @notice I27: ounces leave the fund only through a payment.
    /// @dev Stated as an addition on both sides rather than as a subtraction:
    ///      a defect that pays out more than arrived makes the subtracted form
    ///      underflow, and the panic then replaces every invariant's own
    ///      message with an arithmetic error.
    ///
    ///      The right side counts what the handler put in, so a defect that
    ///      moves part of an arrival out and credits the remainder breaks this
    ///      sum. Taking the credit from `syncCredit`'s return value would
    ///      instead balance against the fund's own understated figure, which
    ///      is why the second assertion compares the two.
    function invariant_I27_OuncesLeaveOnlyThroughAPayment() public view {
        assertEq(
            fund.ounces() + handler.paidTotal(),
            handler.seededTotal() + handler.arrivedTotal(),
            "I27: the fund's ounces moved outside seed, credit and payment"
        );
        assertEq(handler.miscreditedCalls(), NOTHING, "I27: a credit differed from what arrived");
    }

    /// @dev Every assertion above holds on a campaign that did nothing, so this
    ///      drives each path by hand first.
    function test_HandlerReachesSeedCreditAndPay() public {
        handler.seedFund(SEED);
        assertTrue(fund.seeded(), "the seed path never ran");

        handler.arrive(ARRIVAL);
        assertEq(handler.arrivedTotal(), ARRIVAL, "the credit path never ran");
        assertEq(fund.ounces(), SEED + ARRIVAL, "the credit did not reach the fund");

        handler.pay(0, ONE);
        assertGt(handler.paidTotal(), NOTHING, "the payment path never ran");

        handler.pay(1, 1_000_000 ether);
        assertEq(handler.payFailures(), NOTHING, "an oversized request reverted");
    }
}
