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
            handler.seededTotal() + handler.creditedTotal(),
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
    function invariant_I27_OuncesLeaveOnlyThroughAPayment() public view {
        assertEq(
            fund.ounces(),
            handler.seededTotal() + handler.creditedTotal() - handler.paidTotal(),
            "I27: the fund's ounces moved outside seed, credit and payment"
        );
    }

    /// @dev Every assertion above holds on a campaign that did nothing, so this
    ///      drives each path by hand first.
    function test_HandlerReachesSeedCreditAndPay() public {
        handler.seedFund(10 ether);
        assertTrue(fund.seeded(), "the seed path never ran");

        handler.arrive(5 ether);
        assertGt(handler.creditedTotal(), NOTHING, "the credit path never ran");

        handler.pay(0, ONE);
        assertGt(handler.paidTotal(), NOTHING, "the payment path never ran");

        handler.pay(1, 1_000_000 ether);
        assertEq(handler.payFailures(), NOTHING, "an oversized request reverted");
    }
}
