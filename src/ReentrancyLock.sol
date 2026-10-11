// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ReentrancyLock
 * @notice One reentrancy guard shared by the vault, the position contract, the
 *         counterparty pool and the insurance fund (D31).
 * @dev A guard inside each contract cannot see a call that leaves one of them
 *      and comes back through another. This one is a separate contract that all
 *      of them hold as an immutable address, so the whole set is one critical
 *      section.
 *
 *      The flag lives in transient storage, so it is cleared at the end of
 *      every transaction (EIP-1153). That is what lets this contract have no
 *      owner, no registry of callers and no initialiser: a stranger who calls
 *      `enter` blocks nothing but their own transaction, and `exit` is
 *      restricted to whoever is holding, so nobody can clear the flag out from
 *      under a call in flight.
 */
contract ReentrancyLock {
    /// @dev Cleared at the end of each transaction by the EVM, not by a caller.
    address private transient _holder;

    /// @notice The lock is already held, which means this call reentered.
    error Held(address holder);

    /// @notice Only the account that took the lock may release it.
    error NotHolder(address caller, address holder);

    /// @notice Take the lock for the rest of this transaction.
    function enter() external {
        address current = _holder;
        if (current != address(0)) {
            revert Held(current);
        }
        _holder = msg.sender;
    }

    /// @notice Release the lock. Only the holder may call this.
    function exit() external {
        address current = _holder;
        if (current != msg.sender) {
            revert NotHolder(msg.sender, current);
        }
        _holder = address(0);
    }

    /// @notice Who holds the lock in this transaction, or the zero address.
    function heldBy() external view returns (address) {
        return _holder;
    }
}
