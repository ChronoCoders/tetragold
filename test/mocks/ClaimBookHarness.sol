// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClaimBook} from "../../src/libraries/ClaimBook.sol";

/// @notice Holds one claim book in storage and exposes the library over it.
/// @dev The library is internal, so it needs a contract to live in. Keeping the
///      book behind external calls is also what lets the gas test measure one
///      operation at a time, and what lets the invariant campaign drive it.
contract ClaimBookHarness {
    using ClaimBook for ClaimBook.Book;

    ClaimBook.Book private _book;

    function add(uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) external {
        _book.add(size, claim, openPrice, openIndex);
    }

    function remove(uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) external {
        _book.remove(size, claim, openPrice, openIndex);
    }

    function addCollateral(uint256 openPrice, uint256 extraClaim) external {
        _book.addCollateral(openPrice, extraClaim);
    }

    function depositClaimUsd(uint256 price, uint256 index) external view returns (uint256) {
        return _book.depositClaimUsd(price, index, ClaimBook.BPS_DENOMINATOR);
    }

    function depositClaimUsd(uint256 price, uint256 index, uint256 poolShareBps) external view returns (uint256) {
        return _book.depositClaimUsd(price, index, poolShareBps);
    }

    function withdrawalClaimUsd(uint256 price, uint256 index) external view returns (uint256) {
        return _book.withdrawalClaimUsd(price, index, ClaimBook.BPS_DENOMINATOR);
    }

    function withdrawalClaimUsd(uint256 price, uint256 index, uint256 poolShareBps) external view returns (uint256) {
        return _book.withdrawalClaimUsd(price, index, poolShareBps);
    }

    function reserved() external view returns (uint256) {
        return _book.reserved;
    }

    function notionalDebt() external view returns (uint256) {
        return _book.notionalDebt;
    }

    function feeBasisDown() external view returns (uint256) {
        return _book.feeBasisDown;
    }

    function feeBasisUp() external view returns (uint256) {
        return _book.feeBasisUp;
    }

    function claimTotal() external view returns (uint256) {
        return _book.claimTotal;
    }

    function accruedFeeOunces(uint256 index) external view returns (uint256) {
        return _book.accruedFeeOunces(index);
    }

    function bucketTotals(uint256 bucketIndex) external view returns (uint256 size, uint256 notional) {
        return _book.totalsInBucket(bucketIndex);
    }
}
