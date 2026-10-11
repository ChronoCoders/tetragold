// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {LockAttacker} from "./mocks/LockAttacker.sol";
import {LockUser} from "./mocks/LockUser.sol";

contract ReentrancyLockTest is Test {
    ReentrancyLock public lock;
    LockAttacker public attacker;
    LockUser public user;
    LockUser public peer;

    address public stranger;

    function setUp() public {
        stranger = makeAddr("stranger");
        lock = new ReentrancyLock();
        attacker = new LockAttacker(lock);
        user = new LockUser(lock, attacker);
        peer = new LockUser(lock, attacker);
    }

    /// @dev Transient storage is cleared at the end of every transaction
    ///      (EIP-1153), and forge runs each top level call from a test body as
    ///      its own transaction, so the lock reads free at the start of every
    ///      test and cannot be observed held across two calls from here. Every
    ///      assertion about a held lock therefore runs inside one call, through
    ///      the probe contract, which is also how a guarded function sees it.
    function test_LockStartsFree() public view {
        assertEq(lock.heldBy(), address(0));
    }

    function test_EnterRecordsTheHolder() public {
        assertEq(user.holderWhileHeld(), address(user), "the holder was not recorded");
    }

    function test_SecondEnterInTheSameTransactionIsRefused() public {
        assertTrue(user.secondEnterRefused(), "the lock was taken twice in one transaction");
    }

    function test_TheHolderCanRelease() public {
        assertTrue(user.freeAfterRelease(), "the holder could not release the lock");
    }

    function test_ExitWithoutEnterIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(ReentrancyLock.NotHolder.selector, address(this), address(0)));
        lock.exit();
    }

    /// @dev The case the lock exists for: a hostile contract reached from
    ///      inside a guarded call can neither take the lock nor release it.
    function test_AHostileCalleeCanNeitherEnterNorExit() public {
        user.run();

        assertTrue(user.enterRefused(), "the attacker took the lock from inside the section");
        assertTrue(user.exitRefused(), "the attacker released a lock it did not hold");
        assertEq(lock.heldBy(), address(0), "the section was left locked");
    }

    /// @dev One guard per contract would allow this: a second protocol contract
    ///      entered while the first was mid call.
    function test_ASecondGuardedContractCannotEnterWhileTheFirstHolds() public {
        bool peerRefused = user.runAndCallPeer(peer);

        assertTrue(peerRefused, "a second contract entered the shared section");
        assertEq(peer.runs(), 0, "the peer ran inside the section");
        assertEq(lock.heldBy(), address(0), "the section was left locked");
    }

    function test_TheSectionReopensAfterARelease() public {
        user.run();
        user.run();

        assertEq(user.runs(), 2, "the second guarded call was refused");
    }
}
