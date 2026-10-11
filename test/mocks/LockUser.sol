// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyLock} from "../../src/ReentrancyLock.sol";
import {LockAttacker} from "./LockAttacker.sol";

/// @notice Stands in for one of the four protocol contracts that share the lock.
/// @dev It takes the lock, makes an external call while holding it, and
///      releases it, which is the shape every guarded function has.
contract LockUser {
    ReentrancyLock public immutable LOCK;
    LockAttacker public immutable ATTACKER;

    bool public enterRefused;
    bool public exitRefused;
    uint256 public runs;

    constructor(ReentrancyLock lock, LockAttacker attacker) {
        LOCK = lock;
        ATTACKER = attacker;
    }

    function run() external {
        LOCK.enter();
        (enterRefused, exitRefused) = ATTACKER.attack();
        runs += 1;
        LOCK.exit();
    }

    /// @dev Forge runs each top level call from a test body as its own
    ///      transaction, so transient state cannot be observed across two of
    ///      them. These three read the lock from inside one call, which is also
    ///      how a guarded function sees it.
    function holderWhileHeld() external returns (address holder) {
        LOCK.enter();
        holder = LOCK.heldBy();
        LOCK.exit();
    }

    function secondEnterRefused() external returns (bool refused) {
        LOCK.enter();
        try LOCK.enter() {
            refused = false;
        } catch {
            refused = true;
        }
        LOCK.exit();
    }

    function freeAfterRelease() external returns (bool free) {
        LOCK.enter();
        LOCK.exit();
        free = LOCK.heldBy() == address(0);
    }

    /// @dev A second guarded contract calling in while the first holds the lock
    ///      is what a cross contract reentrancy looks like.
    function runAndCallPeer(LockUser peer) external returns (bool peerRefused) {
        LOCK.enter();
        try peer.run() {
            peerRefused = false;
        } catch {
            peerRefused = true;
        }
        LOCK.exit();
    }
}
