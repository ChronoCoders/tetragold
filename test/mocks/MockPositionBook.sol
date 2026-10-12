// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CounterpartyPool} from "../../src/CounterpartyPool.sol";
import {IPositionBook} from "../../src/interfaces/IPositionBook.sol";

/// @notice Stands in for the position manager: it deploys the pool, so it is
///         the privileged caller, it answers the two D48 claim measures, and it
///         wraps every guarded call in the shared section.
/// @dev The wrapping is why this exists rather than a plain stub. Foundry runs
///      with call isolation on, so a test taking the lock and calling the pool
///      on the next line would find the lock free again; inside one call frame
///      both happen together, which is also the shape of the real caller.
///
///      The claim measures are set by the test rather than computed, because
///      the pool is under test here and the position arithmetic is not.
contract MockPositionBook is IPositionBook {
    CounterpartyPool public immutable POOL;

    uint256 private _depositClaimUsd;
    uint256 private _withdrawalClaimUsd;

    constructor(address gold, address lock, uint256 uMaxBps, uint256 requestExpiry) {
        POOL = new CounterpartyPool(gold, lock, uMaxBps, requestExpiry);
    }

    /// @notice The front door of D69: every request arrives through here and
    ///         carries the LP it is made for.
    function requestDeposit(address lp, uint256 depositOunces) external returns (uint256 id) {
        POOL.LOCK().enter();
        id = POOL.requestDeposit(lp, depositOunces);
        POOL.LOCK().exit();
    }

    function requestWithdrawal(address lp, uint256 shares) external returns (uint256 id) {
        POOL.LOCK().enter();
        id = POOL.requestWithdrawal(lp, shares);
        POOL.LOCK().exit();
    }

    function expire(uint256 id, address caller) external {
        POOL.LOCK().enter();
        POOL.expire(id, caller);
        POOL.LOCK().exit();
    }

    function requestDepositOutsideTheSection(address lp, uint256 depositOunces) external returns (uint256 id) {
        id = POOL.requestDeposit(lp, depositOunces);
    }

    function expireOutsideTheSection(uint256 id, address caller) external {
        POOL.expire(id, caller);
    }

    function setClaims(uint256 depositClaim, uint256 withdrawalClaim) external {
        _depositClaimUsd = depositClaim;
        _withdrawalClaimUsd = withdrawalClaim;
    }

    function depositClaimUsd(uint256) external view returns (uint256) {
        return _depositClaimUsd;
    }

    function withdrawalClaimUsd(uint256) external view returns (uint256) {
        return _withdrawalClaimUsd;
    }

    function settleDeposit(uint256 id, uint256 price18) external returns (uint256 shares) {
        POOL.LOCK().enter();
        shares = POOL.settleDeposit(id, price18);
        POOL.LOCK().exit();
    }

    function settleWithdrawal(uint256 id, uint256 price18) external returns (uint256 paid) {
        POOL.LOCK().enter();
        paid = POOL.settleWithdrawal(id, price18);
        POOL.LOCK().exit();
    }

    function syncCredit() external returns (uint256 credited) {
        POOL.LOCK().enter();
        credited = POOL.syncCredit();
        POOL.LOCK().exit();
    }

    function payOut(address to, uint256 requested) external returns (uint256 paid) {
        POOL.LOCK().enter();
        paid = POOL.payOut(to, requested);
        POOL.LOCK().exit();
    }

    function reserve(uint256 size) external {
        POOL.LOCK().enter();
        POOL.reserve(size);
        POOL.LOCK().exit();
    }

    function release(uint256 size) external {
        POOL.LOCK().enter();
        POOL.release(size);
        POOL.LOCK().exit();
    }

    /// @notice Close a position the way the manager must order it: the reserve
    ///         is released before the payout, so pool ounces never dip under R
    ///         between the two calls.
    function closePosition(address to, uint256 payout, uint256 releaseSize) external returns (uint256 paid) {
        POOL.LOCK().enter();
        if (releaseSize != 0) {
            POOL.release(releaseSize);
        }
        paid = POOL.payOut(to, payout);
        POOL.LOCK().exit();
    }

    function settleDepositOutsideTheSection(uint256 id, uint256 price18) external returns (uint256 shares) {
        shares = POOL.settleDeposit(id, price18);
    }

    function payOutOutsideTheSection(address to, uint256 requested) external returns (uint256 paid) {
        paid = POOL.payOut(to, requested);
    }

    function reserveOutsideTheSection(uint256 size) external {
        POOL.reserve(size);
    }
}
