// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ClaimBook} from "../src/libraries/ClaimBook.sol";
import {ClaimBookHarness} from "./mocks/ClaimBookHarness.sol";

/// @notice Measures what one claim book operation costs (D60 rule 6).
/// @dev These are the first measured inputs for the keeper fee and the minimum
///      position size (O5, D39, D57), so the numbers are taken around a single
///      external call and reported rather than asserted against a guess. Only
///      the two upper bounds are asserted, and they are the EIP-170 era limits
///      a keeper has to live inside rather than targets.
///
///      The project runs foundry with `isolate = true`, so every call below is
///      its own transaction and no access list carries over between them. That
///      is the production shape as well, where each settlement is its own
///      transaction, and it means every read here is a cold read at 2100 gas a
///      slot. The difference between the two add figures is therefore a fresh
///      slot at 20000 against an already written one at 5000 (EIP-2929,
///      EIP-2200), not warm against cold.
///
///      The walk lengths are counted in the test rather than asserted from the
///      tree's shape, so each figure carries the number of slots that produced
///      it.
contract ClaimBookGasTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant NOTHING = 0;
    uint256 private constant SIZE = 10 ether;
    uint256 private constant INDEX = 0.01e18;
    uint256 private constant EXTRA = 100e18;

    /// @dev Prices chosen for the walk each one produces. A gold price near
    ///      4000 USD lands in bucket 4001, which is odd and therefore takes the
    ///      full 18 levels. Bucket 262144 is a power of two and takes one.
    ///      Bucket 1 is the deepest at 19.
    uint256 private constant PRICE_FIRST = 1;
    uint256 private constant PRICE_REAL = 4000e18;
    uint256 private constant PRICE_TOP = 262_143e18;

    uint256 private constant OPEN_CEILING = 600_000;
    uint256 private constant READ_CEILING = 150_000;

    /// @dev Each cold figure is taken on a book that has never been touched, so
    ///      a measurement does not inherit another one's warm slots.
    function test_GasForEveryOperation() public {
        uint256 claim = (SIZE * PRICE_REAL) / WAD / 2;

        uint256 coldReal = _coldAdd(PRICE_REAL);
        uint256 coldTop = _coldAdd(PRICE_TOP);
        uint256 coldFirst = _coldAdd(PRICE_FIRST);

        ClaimBookHarness book = new ClaimBookHarness();
        book.add(SIZE, claim, PRICE_REAL, INDEX);
        uint256 warmAdd = _add(book, SIZE, claim, PRICE_REAL, INDEX);
        uint256 collateral = _addCollateral(book, PRICE_REAL, EXTRA);
        uint256 warmRemove = _remove(book, SIZE, claim, PRICE_REAL, INDEX);

        ClaimBookHarness filled = new ClaimBookHarness();
        filled.add(SIZE, claim, PRICE_REAL, INDEX);
        filled.add(SIZE, (SIZE * PRICE_TOP) / WAD / 2, PRICE_TOP, INDEX);
        filled.add(SIZE, NOTHING, PRICE_FIRST, INDEX);

        uint256 depositRead = _depositClaim(filled, PRICE_REAL, INDEX);
        uint256 coldReadReal = _withdrawalClaim(filled, PRICE_REAL, INDEX);
        uint256 warmReadReal = _withdrawalClaim(filled, PRICE_REAL, INDEX);
        uint256 coldReadTop = _withdrawalClaim(filled, PRICE_TOP, INDEX);
        uint256 coldReadFirst = _withdrawalClaim(filled, PRICE_FIRST, INDEX);

        console2.log("levels written, bucket 4001  ", _levels(ClaimBook.bucketOf(PRICE_REAL)));
        console2.log("levels written, bucket 262144", _levels(ClaimBook.bucketOf(PRICE_TOP)));
        console2.log("levels written, bucket 1     ", _levels(ClaimBook.bucketOf(PRICE_FIRST)));
        console2.log("nodes read, price 4000       ", _nodes(ClaimBook.bucketOf(PRICE_REAL) - 1));
        console2.log("nodes read, price 262143     ", _nodes(ClaimBook.bucketOf(PRICE_TOP) - 1));
        console2.log("nodes read, price 1 wei      ", _nodes(ClaimBook.bucketOf(PRICE_FIRST) - 1));

        console2.log("add            fresh slots, bucket 4001  ", coldReal);
        console2.log("add            fresh slots, bucket 262144", coldTop);
        console2.log("add            fresh slots, bucket 1     ", coldFirst);
        console2.log("add            written slots, bucket 4001", warmAdd);
        console2.log("remove         written slots, bucket 4001", warmRemove);
        console2.log("addCollateral  no tree write             ", collateral);
        console2.log("depositClaimUsd  four counters           ", depositRead);
        console2.log("withdrawalClaimUsd  price 4000           ", coldReadReal);
        console2.log("withdrawalClaimUsd  price 4000 again     ", warmReadReal);
        console2.log("withdrawalClaimUsd  price 262143         ", coldReadTop);
        console2.log("withdrawalClaimUsd  price 1 wei          ", coldReadFirst);

        assertLt(coldFirst, OPEN_CEILING, "an open into fresh buckets cost more than the stated ceiling");
        assertLt(coldReadTop, READ_CEILING, "the deepest withdrawal read cost more than the stated ceiling");
        assertLt(depositRead, coldReadReal, "the constant time measure was not cheaper than the tree walk");
        assertLt(warmAdd, coldReal, "a write to slots already written was not cheaper than a fresh one");
        assertEq(warmReadReal, coldReadReal, "two reads of the same price in one test differed");
    }

    /// @dev Slots an `add` writes: the bucket plus one Fenwick node per level.
    function _levels(uint256 bucketIndex) private pure returns (uint256 levels) {
        levels = 1;
        uint256 node = bucketIndex;
        while (node <= ClaimBook.BUCKET_COUNT) {
            levels += 1;
            unchecked {
                node += node & (~node + 1);
            }
        }
    }

    /// @dev Nodes a prefix sum reads, which is the bit count of the index.
    function _nodes(uint256 index) private pure returns (uint256 nodes) {
        uint256 node = index;
        while (node != 0) {
            nodes += 1;
            unchecked {
                node -= node & (~node + 1);
            }
        }
    }

    function _coldAdd(uint256 openPrice) private returns (uint256) {
        ClaimBookHarness fresh = new ClaimBookHarness();
        return _add(fresh, SIZE, (SIZE * openPrice) / WAD / 2, openPrice, INDEX);
    }

    function _add(ClaimBookHarness book, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex)
        private
        returns (uint256)
    {
        uint256 before = gasleft();
        book.add(size, claim, openPrice, openIndex);
        return before - gasleft();
    }

    function _remove(ClaimBookHarness book, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex)
        private
        returns (uint256)
    {
        uint256 before = gasleft();
        book.remove(size, claim, openPrice, openIndex);
        return before - gasleft();
    }

    function _addCollateral(ClaimBookHarness book, uint256 openPrice, uint256 extra) private returns (uint256) {
        uint256 before = gasleft();
        book.addCollateral(openPrice, extra);
        return before - gasleft();
    }

    function _depositClaim(ClaimBookHarness book, uint256 price, uint256 index) private view returns (uint256) {
        uint256 before = gasleft();
        // The measurement is the point of the call, so the value it returns is
        // read and dropped on purpose.
        // forge-lint: disable-next-line(unused-return)
        book.depositClaimUsd(price, index);
        return before - gasleft();
    }

    function _withdrawalClaim(ClaimBookHarness book, uint256 price, uint256 index) private view returns (uint256) {
        uint256 before = gasleft();
        // forge-lint: disable-next-line(unused-return)
        book.withdrawalClaimUsd(price, index);
        return before - gasleft();
    }
}
