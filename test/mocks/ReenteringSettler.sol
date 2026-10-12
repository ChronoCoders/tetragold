// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PositionManager} from "../../src/PositionManager.sol";

/// @notice A settler whose fallback tries to re-enter the manager while it is
///         being paid.
/// @dev The manager pays the settler with the shared section still held (D31),
///      so the reentry finds the lock taken. It comes back in through
///      `requestOpen` rather than through the settlement it is in the middle
///      of, because that settlement has already left the pending state and
///      would be refused by the state machine before the lock was ever
///      consulted. This way the lock is the thing under test.
///
///      `bubble` picks which half of the claim a test is making: pass it on to
///      fail this settler's own settlement, or swallow it to let the settlement
///      finish and leave the refusal readable afterwards.
contract ReenteringSettler {
    PositionManager private immutable MANAGER;

    uint256 private _ounces;
    uint256 private _leverage;
    uint256 private _fee;
    bool private _armed;
    bool private _bubble;

    /// @notice The revert data the reentry came back with, for the test to read.
    bytes public lastReason;

    error ReenteredAndWasRefused();

    constructor(PositionManager manager) {
        MANAGER = manager;
    }

    function settle(
        uint256 id,
        bytes calldata payload,
        bytes[] calldata update,
        uint256 pythFee,
        uint256 ounces,
        uint256 leverage,
        uint256 requestFee,
        bool bubble
    ) external payable {
        _ounces = ounces;
        _leverage = leverage;
        _fee = requestFee;
        _armed = true;
        _bubble = bubble;
        MANAGER.settleOpen{value: pythFee}(id, payload, update);
    }

    receive() external payable {
        if (!_armed) {
            return;
        }
        _armed = false;

        (bool ok, bytes memory reason) =
            address(MANAGER).call{value: _fee}(abi.encodeCall(PositionManager.requestOpen, (_ounces, _leverage)));
        lastReason = reason;
        // Bubbling makes this settler's own settlement fail, which is the half
        // of the claim about what a reentry can reach. Swallowing lets the
        // settlement finish, which is the half that leaves the recorded reason
        // readable: a reverted call takes its own storage writes with it.
        if (!ok && _bubble) {
            revert ReenteredAndWasRefused();
        }
    }
}
