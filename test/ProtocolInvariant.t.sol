// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolInvariants} from "./ProtocolInvariants.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";

/// @notice The vault, the pool, the fund and the manager under one campaign,
///         with the deep default pool. The invariants it checks are the shared
///         set in ProtocolInvariants; this contract adds the base selector mix
///         and the hand driver that proves none of them pass vacuously.
/// forge-config: default.invariant.fail-on-revert = true
contract ProtocolInvariantTest is ProtocolInvariants {
    uint256 private constant SELECTORS = 12;
    uint256 private constant DRIVE_DEPOSIT = 40 ether;
    uint256 private constant DRIVE_POST = 5 ether;
    uint256 private constant DRIVE_ADD = 1 ether;
    /// @dev One slot, which a request's target sits at (section 7 rule 2).
    uint256 private constant TARGET_DELAY = 12;

    function setUp() public {
        _deployProtocol();
        handler = new ProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE, 7 days);

        bytes4[] memory selectors = new bytes4[](SELECTORS);
        selectors[0] = ProtocolHandler.lpDeposit.selector;
        selectors[1] = ProtocolHandler.requestOpen.selector;
        selectors[2] = ProtocolHandler.settleOpen.selector;
        selectors[3] = ProtocolHandler.expireOpen.selector;
        selectors[4] = ProtocolHandler.passTime.selector;
        selectors[5] = ProtocolHandler.movePrice.selector;
        selectors[6] = ProtocolHandler.movePaxg.selector;
        selectors[7] = ProtocolHandler.requestAdd.selector;
        selectors[8] = ProtocolHandler.settleAdd.selector;
        selectors[9] = ProtocolHandler.dustTheOracle.selector;
        selectors[10] = ProtocolHandler.requestClose.selector;
        selectors[11] = ProtocolHandler.settleClose.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Every invariant holds on a campaign that did nothing, so this drives
    ///      each step by hand first.
    function test_HandlerReachesEveryStep() public {
        handler.lpDeposit(0, DRIVE_DEPOSIT);
        assertGt(pool.ounces(), NOTHING, "the pool took no deposit");
        assertGt(pool.shareSupply(), NOTHING, "the pool minted no shares");

        handler.requestOpen(1, DRIVE_POST, 0);
        assertEq(handler.requests(), 1, "no open was requested");
        assertGt(manager.escrowedOunces(), NOTHING, "the request escrowed nothing");

        handler.passTime(TARGET_DELAY);
        handler.settleOpen(0);
        assertEq(handler.settlements(), 1, "the open did not settle");
        assertGt(pool.reserved(), NOTHING, "the settlement reserved nothing");

        handler.requestOpen(2, DRIVE_POST, 2);
        handler.passTime(EXPIRY * 2);
        handler.expireOpen(0);
        assertEq(handler.expiries(), 1, "the request did not expire");

        handler.requestAdd(0, DRIVE_ADD);
        assertEq(handler.adds(), 1, "no add was requested");
        handler.passTime(TARGET_DELAY);
        handler.settleAdd(0);
        assertEq(handler.addSettlements(), 1, "the add did not settle");

        handler.requestAdd(0, type(uint256).max);
        handler.passTime(TARGET_DELAY);
        handler.settleAdd(0);
        assertEq(handler.addRejections(), 1, "D43 rule 5 was never reached, so the ceiling proves nothing");
        assertEq(handler.wrongEndings(), NOTHING, "I17: an add ended somewhere else");

        handler.dustTheOracle(1 ether);
        assertGt(handler.oracleDustings(), NOTHING, "the oracle was never dusted, so this proves nothing");
        handler.requestOpen(1, DRIVE_POST, 0);
        handler.passTime(TARGET_DELAY);
        handler.settleOpen(0);
        assertEq(handler.settlements(), 2, "a settlement did not go through with stray ETH in the oracle");

        handler.movePrice(type(uint256).max);

        handler.movePaxg(true, false);
        handler.requestOpen(1, DRIVE_POST, 0);
        assertGt(handler.inflowRefusals(), NOTHING, "D50 was never tested on the request path");
        assertEq(handler.inflowsAllowedWhileUnusable(), NOTHING, "I26: an open was taken while PAXG was unusable");

        handler.movePaxg(false, false);
        handler.requestOpen(1, DRIVE_POST, 0);
        assertGt(handler.requests(), 2, "the request path did not come back");

        // Drive the close so I15b, I2 and I27 are not vacuous on it.
        handler.requestClose(0);
        assertEq(handler.closeRequests(), 1, "no close was requested");
        handler.passTime(TARGET_DELAY);
        handler.settleClose(0);
        assertEq(handler.closeSettlements(), 1, "the close did not settle");

        assertEq(handler.escrowMismatches(), NOTHING, "D66 broke during the drive");
        assertEq(handler.conservationBreaks(), NOTHING, "I1 broke during the drive");
        assertEq(handler.coverageBreaks(), NOTHING, "I15a broke during the drive");
        assertEq(handler.sideInversions(), NOTHING, "I6 broke during the drive");
        assertEq(handler.payoutAboveSize(), NOTHING, "I2 broke during the drive");
        assertEq(handler.closeLeaks(), NOTHING, "I27 broke during the drive");
    }
}
