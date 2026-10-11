// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {InsuranceFund} from "../../src/InsuranceFund.sol";
import {ReentrancyLock} from "../../src/ReentrancyLock.sol";

/// @notice Stands in for the position manager against the insurance fund.
/// @dev It deploys the fund, so it is the fund's one privileged caller, and it
///      wraps each call in the shared section the way the real caller will.
///      Everything happens inside one of its functions on purpose: forge runs
///      each top level call from a test body as its own transaction, so a test
///      cannot hold a transient lock across two of them.
contract FundDriver {
    InsuranceFund public immutable FUND;
    ReentrancyLock public immutable LOCK;

    constructor(address gold, address treasury, address lock, uint256 target) {
        LOCK = ReentrancyLock(lock);
        FUND = new InsuranceFund(gold, treasury, lock, target);
    }

    function syncCredit() external returns (uint256 credited) {
        LOCK.enter();
        credited = FUND.syncCredit();
        LOCK.exit();
    }

    function payTo(address to, uint256 amount) external returns (uint256 paid) {
        LOCK.enter();
        paid = FUND.payTo(to, amount);
        LOCK.exit();
    }

    /// @dev The privileged caller, but outside the shared section.
    function syncCreditOutsideTheSection() external returns (uint256) {
        return FUND.syncCredit();
    }

    function payToOutsideTheSection(address to, uint256 amount) external returns (uint256) {
        return FUND.payTo(to, amount);
    }
}
