// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyLock} from "../../src/ReentrancyLock.sol";

/// @notice Stands in for a hostile contract reached from inside a guarded call.
/// @dev It tries both ways out of the critical section: taking the lock, which
///      is the reentrancy itself, and releasing someone else's lock, which
///      would open the section for a second call.
contract LockAttacker {
    ReentrancyLock public immutable LOCK;

    constructor(ReentrancyLock lock) {
        LOCK = lock;
    }

    function attack() external returns (bool enterRefused, bool exitRefused) {
        try LOCK.enter() {
            enterRefused = false;
        } catch {
            enterRefused = true;
        }
        try LOCK.exit() {
            exitRefused = false;
        } catch {
            exitRefused = true;
        }
    }
}
