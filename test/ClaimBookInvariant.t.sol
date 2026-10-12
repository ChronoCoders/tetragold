// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBookHandler} from "./handlers/ClaimBookHandler.sol";
import {ClaimBookHarness} from "./mocks/ClaimBookHarness.sol";

/// @notice The claim book against a shadow list of the same positions (D60).
/// @dev The handler checks every counter and both measures after each step, so
///      these read its tallies. Nothing here is allowed to revert: the handler
///      returns early when a step has nothing to act on.
/// forge-config: default.invariant.fail-on-revert = true
contract ClaimBookInvariantTest is Test {
    uint256 private constant NOTHING = 0;
    uint256 private constant SELECTORS = 5;
    uint256 private constant DRIVE_SIZE = 10 ether;
    uint256 private constant DRIVE_PRICE = 4000e18;

    ClaimBookHarness public harness;
    ClaimBookHandler public handler;

    function setUp() public {
        harness = new ClaimBookHarness();
        handler = new ClaimBookHandler(harness);

        bytes4[] memory selectors = new bytes4[](SELECTORS);
        selectors[0] = ClaimBookHandler.openPosition.selector;
        selectors[1] = ClaimBookHandler.closePosition.selector;
        selectors[2] = ClaimBookHandler.addCollateral.selector;
        selectors[3] = ClaimBookHandler.moveIndex.selector;
        selectors[4] = ClaimBookHandler.movePrice.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice D60 rule 1: the four counters are the sums they claim to be.
    function invariant_CountersMatchThePositions() public view {
        assertEq(handler.counterMismatches(), NOTHING, "a counter disagreed with the positions it sums");
    }

    /// @notice D60 rule 1 and rule 4: the deposit measure is the sum of equity
    ///         inside the stated rounding bound.
    function invariant_DepositMeasureMatchesTheSum() public view {
        assertEq(handler.depositMismatches(), NOTHING, "the deposit measure left its rounding bound");
    }

    /// @notice D60 rule 2 and rule 4: the withdrawal measure is the sum of
    ///         max(equity, claim less fee) inside the rounding bound and the
    ///         bucket error.
    function invariant_WithdrawalMeasureMatchesTheSum() public view {
        assertEq(handler.withdrawalMismatches(), NOTHING, "the withdrawal measure left its bound");
    }

    /// @notice I6 and D60 rule 3: the low side never falls under the high side.
    function invariant_I6_LowSideNeverUnderTheHighSide() public view {
        assertEq(handler.sideInversions(), NOTHING, "I6: the low side fell under the high side");
    }

    /// @dev Each assertion above holds on a campaign that did nothing, so this
    ///      drives every step by hand first.
    function test_HandlerReachesEveryStep() public {
        handler.openPosition(DRIVE_SIZE, DRIVE_PRICE, 0);
        handler.openPosition(DRIVE_SIZE, DRIVE_PRICE * 2, 2);
        assertEq(handler.openCount(), 2, "the open path did not run twice");

        handler.addCollateral(0, type(uint256).max);
        assertGt(handler.collateralAdds(), NOTHING, "the collateral path never ran");

        handler.moveIndex(type(uint256).max);
        assertGt(handler.index(), NOTHING, "the index never moved");

        handler.movePrice(DRIVE_PRICE);
        assertEq(handler.price(), DRIVE_PRICE, "the price never moved");

        handler.closePosition(0);
        assertEq(handler.openCount(), 1, "the close path never ran");

        assertEq(handler.counterMismatches(), NOTHING, "a counter disagreed during the drive");
        assertEq(handler.depositMismatches(), NOTHING, "the deposit measure left its bound during the drive");
        assertEq(handler.withdrawalMismatches(), NOTHING, "the withdrawal measure left its bound during the drive");
        assertEq(handler.sideInversions(), NOTHING, "I6 broke during the drive");
    }
}
