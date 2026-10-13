// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {PositionManager} from "../src/PositionManager.sol";
import {ProtocolDeployment} from "./ProtocolDeployment.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";

/// @notice A hand sequence that D46 must stop, pinned so it cannot drift. The
///         owner of a position tries to add far more collateral than its open
///         notional allows, then the price falls. D46 rejects the add on clean
///         code, so the pool still covers every payout; with the two D46 layers
///         broken the add settles, the claim outgrows the gold behind it, and
///         I15b is the claim that sees it while the reserve bound of I15a does
///         not.
contract ProtocolI15bRegressionTest is ProtocolDeployment {
    uint256 private constant TARGET_DELAY = 12;
    uint8 private constant TIER_5X = 2;
    bytes32 private constant REJECTED_SIG = keccak256("RequestRejected(uint256,address,uint8,uint256)");

    function setUp() public {
        _deployProtocol();
        handler = new ProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE, 7 days);
    }

    function test_AnAddPastTheNotionalCannotOutrunThePool() public {
        handler.movePrice(5000e18);
        handler.lpDeposit(0, 5.5 ether);
        handler.requestOpen(1, 1 ether, TIER_5X);
        handler.passTime(TARGET_DELAY);
        handler.settleOpen(0);

        handler.requestAdd(0, 50 ether);
        handler.passTime(TARGET_DELAY);

        vm.recordLogs();
        handler.settleAdd(0);
        PositionManager.Reason reason = _rejectionReason(vm.getRecordedLogs());

        handler.movePrice(3000e18);

        assertGe(pool.ounces(), pool.reserved(), "I15a: the reserve bound holds either way");
        assertGe(
            pool.ounces(), handler.i15bPayoutOunces(), "I15b: the add outran the gold behind it and the pool cannot pay"
        );
        assertEq(
            uint8(reason),
            uint8(PositionManager.Reason.ClaimWouldPassNotional),
            "D46 rule 5 is what rejected the add, so the cap is the guard"
        );
    }

    function _rejectionReason(Vm.Log[] memory logs) private pure returns (PositionManager.Reason) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == REJECTED_SIG) {
                (uint8 reason,) = abi.decode(logs[i].data, (uint8, uint256));
                return PositionManager.Reason(reason);
            }
        }
        return PositionManager.Reason.None;
    }
}
