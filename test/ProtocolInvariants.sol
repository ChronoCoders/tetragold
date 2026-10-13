// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolDeployment} from "./ProtocolDeployment.sol";

/// @notice The cross contract invariants every protocol campaign shares. They
///         live here, apart from any one campaign's setUp and driver, so a
///         second campaign can run the exact same checks without inheriting a
///         driver that does not fit it. Each concrete campaign supplies its own
///         setUp (the handler it targets, the selectors and the LP seed).
/// @dev The handler swallows nothing: it returns early when a step has nothing
///      to act on, so a revert in a sequence is a defect.
abstract contract ProtocolInvariants is ProtocolDeployment {
    uint256 internal constant NOTHING = 0;

    /// @notice D66: the manager holds TGAUX for pending requests and nothing
    ///         else, so its balance is its escrow total.
    function invariant_D66_TheManagerHoldsOnlyItsEscrow() public view {
        assertEq(handler.escrowMismatches(), NOTHING, "D66: the manager's balance left its escrow total");
        assertEq(gold.balanceOf(address(manager)), manager.escrowedOunces(), "D66: and it disagrees right now");
    }

    /// @notice I1 across the protocol: every ounce of TGAUX is held by one of
    ///         the accounts this campaign accounts for, so none has leaked.
    function invariant_I1_EveryOunceIsAccountedFor() public view {
        assertEq(handler.conservationBreaks(), NOTHING, "I1: TGAUX left the accounted set");
    }

    /// @notice I15a: pool ounces cover the reserve at every step.
    function invariant_I15a_OuncesCoverTheReserve() public view {
        assertEq(handler.coverageBreaks(), NOTHING, "I15a: pool ounces fell under R");
        assertGe(pool.ounces(), pool.reserved(), "I15a: and they do right now");
    }

    /// @notice I15b as D46 states it: pool ounces cover the payout every open
    ///         position would take at the price in use. I15a's reserve bound
    ///         implies this only while D46 holds, so an add that pushed a
    ///         position's collateral above its open notional is caught here
    ///         where the reserve bound would not see it.
    function invariant_I15b_PoolCoversEveryPayout() public view {
        assertGe(pool.ounces(), handler.i15bPayoutOunces(), "I15b: pool ounces fell under the payouts it must make");
    }

    /// @notice I7: R stays inside u_max of pool ounces.
    function invariant_I7_ReservedStaysInsideUMax() public view {
        assertLe(pool.reserved() * 10_000, pool.ounces() * U_MAX_BPS, "I7: R rose above u_max of pool ounces");
    }

    /// @notice I6: the withdrawal measure never falls under the deposit
    ///         measure, with the close fee of D71 rule 6 in the latter.
    function invariant_I6_LowSideNeverUnderTheHighSide() public view {
        assertEq(handler.sideInversions(), NOTHING, "I6: the low side fell under the high side");
    }

    /// @notice I19: the holding fee rate never falls as utilisation rises.
    function invariant_I19_RateIsMonotonicInUtilisation() public view {
        assertEq(handler.rateInversions(), NOTHING, "I19: the rate moved against utilisation");
    }

    /// @notice I26 and D50: while PAXG is unusable no open request is taken,
    ///         and nothing else about it changes.
    function invariant_I26_NoInflowWhilePaxgIsUnusable() public view {
        assertEq(handler.inflowsAllowedWhileUnusable(), NOTHING, "I26: an open was taken while PAXG was unusable");
    }

    /// @notice I17 and D70: every request this campaign finished ended in one
    ///         of the terminal states, never back in pending.
    function invariant_I17_RequestsEndWhereTheyShould() public view {
        assertEq(handler.wrongEndings(), NOTHING, "I17: a request ended somewhere else");
    }

    /// @notice I2: a close never pays an owner more than the position's size in
    ///         ounces, which is what D46's reservation guarantees.
    function invariant_I2_PayoutNeverAboveTheSize() public view {
        assertEq(handler.payoutAboveSize(), NOTHING, "I2: a close paid above the position size");
    }

    /// @notice I27: on a close, TGAUX leaves the pool only as the owner's
    ///         payout and the treasury and fund fee shares (D71 rule 5).
    function invariant_I27_CloseMovesTgauxOnlyWhereItMay() public view {
        assertEq(handler.closeLeaks(), NOTHING, "I27: a close moved TGAUX out of the close set");
    }

    /// @notice A position carries a pending exit flag only while a close request
    ///         for it is still pending: an expired close must clear it, or the
    ///         position can never be exited (I14, D58).
    function invariant_ExitFlagFollowsAPendingClose() public view {
        assertEq(handler.exitFlagStranded(), NOTHING, "a position's exit flag outlived its close request");
    }

    /// @notice I29: between operations the ETH the manager holds is exactly the
    ///         execution fees of its pending requests plus the ETH it has
    ///         credited and not yet paid out (D65, D72). An expiry keeps the fee
    ///         rather than refunding it, so this is what catches a fee that
    ///         leaked or was double counted.
    function invariant_I29_ManagerEthMatchesFeesAndCredits() public view {
        assertEq(handler.ethMismatches(), NOTHING, "I29: the manager's ETH left the fees and credits it should hold");
    }
}
