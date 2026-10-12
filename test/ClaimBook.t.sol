// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBook} from "../src/libraries/ClaimBook.sol";
import {ClaimBookHarness} from "./mocks/ClaimBookHarness.sol";

/// @notice The two D48 claim measures of D60, against a brute force sum over
///         the same positions.
/// @dev Every property test builds a position set, asks the book, and asks the
///      test's own loop over the positions. The book is the thing under test,
///      so the loop is the reference and never the other way about.
///
///      The reference for the withdrawal measure is the sum of
///      max(e_i, C_i - fee_i) with no floor at zero per position, because D60
///      rule 2 drops that floor on purpose: it binds only past bankruptcy,
///      where liquidation removes the position. The sum as a whole is still
///      floored, which both the library and the reference do.
///
///      Two rounding bounds, both stated rather than guessed:
///      upward, a measure may exceed the reference by one wei per position,
///      because the library divides the aggregate once where the reference
///      divides per position, and floor of a sum is at least the sum of
///      floors;
///      downward, a measure may fall under the reference by two wei of ounces
///      per position plus two for the aggregate, turned into USD at the price.
///      The derivation, writing x_i for s_i times the index and y_i for s_i
///      times the position's own opening index, both over one unit of scale:
///      the library's fee is ceil(sum x_i) less sum floor(y_i), the reference's
///      is sum floor(x_i - y_i), and the difference between them is at least
///      zero and at most 2n + 1 wei of ounces. One of the two wei per position
///      is the library's floored J and the other is the reference's own
///      per position flooring. Both roundings make the fee the library
///      subtracts larger, which favours the LPs already in the pool, and that
///      is what D29 asks of a rounding choice.
///
///      The withdrawal measure carries one more error on top, from D60 rule 2:
///      the bucket holding the price counts its whole size from that bucket's
///      low edge, so the measure can be up to the bucket width times that size
///      above the reference.
contract ClaimBookTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant WIDTH = 1e18;
    uint256 private constant BUCKETS = 262_144;
    uint256 private constant RANGE_TOP = BUCKETS * WIDTH;
    uint256 private constant NOTHING = 0;
    uint256 private constant ONE_WEI = 1;

    /// @dev One per rounded division inside a measure.
    uint256 private constant MEASURE_SLACK = 4;

    uint256 private constant SIZE_ONE = 1 ether;
    uint256 private constant SIZE_TWO = 2 ether;
    uint256 private constant SIZE_THREE = 3 ether;
    uint256 private constant SIZE_SEVEN = 7 ether;
    uint256 private constant SIZE_TEN = 10 ether;
    uint256 private constant ENTRY = 4000e18;
    uint256 private constant ENTRY_HIGH = 5000e18;
    uint256 private constant ABOVE_ENTRY = 4100e18;
    uint256 private constant BELOW_ENTRY = 3900e18;
    uint256 private constant CLAIM_SEVEN = 9000e18;
    uint256 private constant CLAIM_TEN = 20_000e18;
    uint256 private constant CLAIM_TWO = 1000e18;
    uint256 private constant CLAIM_THREE = 2000e18;
    uint256 private constant CLAIM_SUM = 3000e18;
    uint256 private constant EXTRA_COLLATERAL = 5000e18;
    uint256 private constant INDEX_AT_OPEN = 0.01e18;
    uint256 private constant INDEX_NOW = 0.03e18;
    uint256 private constant HALF = 2;
    /// @dev One wei above one unit of scale, so that multiplying two of them
    ///      and dividing by the scale leaves a remainder.
    uint256 private constant ROUND_WIDE = 1e18 + 1;
    /// @dev Half of the floored notional of a position of that size at that
    ///      price, which is 1e18 + 2.
    uint256 private constant ROUND_CLAIM = 5e17 + 1;
    /// @dev The three figures those roundings produce: two wei of USD from the
    ///      partial bucket, two wei of ounces of fee at an index of one wei,
    ///      and the three wei of USD that fee is worth.
    uint256 private constant ROUND_PARTIAL = 2;
    uint256 private constant ROUND_FEE_OUNCES = 2;
    uint256 private constant ROUND_FEE_USD = 3;
    uint256 private constant TIERS = 3;

    uint256 private constant MIN_SIZE = 0.001 ether;
    uint256 private constant MAX_SIZE = 500 ether;
    uint256 private constant MIN_PRICE = 100e18;
    uint256 private constant MAX_PRICE = 20_000e18;
    uint256 private constant MAX_INDEX = 0.2e18;
    uint256 private constant MAX_POSITIONS = 12;

    struct Position {
        uint256 size;
        uint256 claim;
        uint256 openPrice;
        uint256 openIndex;
    }

    ClaimBookHarness private book;
    Position[] private positions;

    function setUp() public {
        book = new ClaimBookHarness();
    }

    function test_EmptyBookMeasuresNothing() public view {
        assertEq(book.depositClaimUsd(MIN_PRICE, NOTHING), NOTHING, "an empty book had a deposit claim");
        assertEq(book.withdrawalClaimUsd(MIN_PRICE, NOTHING), NOTHING, "an empty book had a withdrawal claim");
        assertEq(book.reserved(), NOTHING);
    }

    /// @dev One position at 2x: C is half the notional, so at the entry price
    ///      equity is C and the realised loss term is zero.
    function test_OnePositionAtItsEntryPrice() public {
        uint256 size = SIZE_TEN;
        uint256 openPrice = ENTRY;
        uint256 claim = (size * openPrice) / WAD / HALF;
        _add(Position({size: size, claim: claim, openPrice: openPrice, openIndex: NOTHING}));

        assertEq(book.depositClaimUsd(openPrice, NOTHING), claim, "equity at the entry price was not the claim");
        assertEq(book.withdrawalClaimUsd(openPrice, NOTHING), claim, "the low side at the entry price was not C");
    }

    /// @dev Above the entry price the deposit measure counts the gain and the
    ///      withdrawal measure counts it too, because it is realised for the
    ///      pool as a liability either way.
    function test_GainAboveTheEntryPriceCountsOnBothSides() public {
        uint256 size = SIZE_TEN;
        uint256 openPrice = ENTRY;
        uint256 claim = (size * openPrice) / WAD / HALF;
        _add(Position({size: size, claim: claim, openPrice: openPrice, openIndex: NOTHING}));

        uint256 price = ABOVE_ENTRY;
        uint256 gain = (size * (price - openPrice)) / WAD;
        // The entry sits in the bucket below the price, so only the rounding of
        // the aggregate division is in play here, not the bucket error.
        uint256 low = book.withdrawalClaimUsd(price, NOTHING);

        assertEq(book.depositClaimUsd(price, NOTHING), claim + gain, "the gain was not in the high side");
        assertApproxEqAbs(low, claim + gain, MEASURE_SLACK, "the gain was not in the low side");
    }

    /// @dev Below the entry price the trader's loss is unrealised, so only the
    ///      deposit measure counts it. That gap is I6.
    function test_LossBelowTheEntryPriceCountsOnlyOnTheHighSide() public {
        uint256 size = SIZE_TEN;
        uint256 openPrice = ENTRY;
        uint256 claim = (size * openPrice) / WAD / HALF;
        _add(Position({size: size, claim: claim, openPrice: openPrice, openIndex: NOTHING}));

        uint256 price = BELOW_ENTRY;
        uint256 loss = (size * (openPrice - price)) / WAD;

        assertEq(book.depositClaimUsd(price, NOTHING), claim - loss, "the loss was not taken off the high side");
        assertEq(book.withdrawalClaimUsd(price, NOTHING), claim, "the low side counted an unrealised loss");
    }

    function test_FeeLowersBothMeasures() public {
        uint256 size = SIZE_TEN;
        uint256 openPrice = ENTRY;
        uint256 claim = (size * openPrice) / WAD / HALF;
        _add(Position({size: size, claim: claim, openPrice: openPrice, openIndex: INDEX_AT_OPEN}));

        uint256 index = INDEX_NOW;
        uint256 fee = _feeUsd(size, index - INDEX_AT_OPEN, openPrice);

        assertApproxEqAbs(
            book.depositClaimUsd(openPrice, index), claim - fee, MEASURE_SLACK, "the fee was not in the high side"
        );
        assertApproxEqAbs(
            book.withdrawalClaimUsd(openPrice, index), claim - fee, MEASURE_SLACK, "the fee was not in the low side"
        );
    }

    function test_RemoveUndoesAdd() public {
        Position memory p = Position({size: SIZE_SEVEN, claim: CLAIM_SEVEN, openPrice: ENTRY, openIndex: INDEX_AT_OPEN});
        _add(p);
        uint256 reservedAfterAdd = book.reserved();

        book.remove(p.size, p.claim, p.openPrice, p.openIndex);

        assertEq(reservedAfterAdd, p.size, "the add did not reserve");
        assertEq(book.reserved(), NOTHING, "R survived the removal");
        assertEq(book.notionalDebt(), NOTHING, "D survived the removal");
        assertEq(book.feeBasis(), NOTHING, "J survived the removal");
        assertEq(book.claimTotal(), NOTHING, "sumC survived the removal");
        (uint256 bucketSize, uint256 bucketNotional) = book.bucketTotals(ClaimBook.bucketOf(p.openPrice));
        assertEq(bucketSize, NOTHING, "the bucket kept a size");
        assertEq(bucketNotional, NOTHING, "the bucket kept a notional");
    }

    /// @dev A removal that does not match its add is caught by whichever guard
    ///      it reaches first: a counter when the aggregate cannot cover it, and
    ///      the tree when the counters still can but the bucket is empty.
    function test_RemoveWithOtherValuesIsRefused() public {
        uint256 size = SIZE_SEVEN;
        uint256 claim = CLAIM_SEVEN;
        uint256 low = ENTRY;
        uint256 high = ENTRY_HIGH;
        _add(Position({size: size, claim: claim, openPrice: low, openIndex: INDEX_AT_OPEN}));
        _add(Position({size: size, claim: claim, openPrice: high, openIndex: INDEX_AT_OPEN}));

        vm.expectRevert(abi.encodeWithSelector(ClaimBook.RemoveBeyondBook.selector, size * HALF + 1, size * HALF));
        book.remove(size * HALF + 1, claim, low, INDEX_AT_OPEN);

        book.remove(size, claim, low, INDEX_AT_OPEN);

        // The counters still hold the second position, so this one gets as far
        // as the tree and finds the first position's bucket empty.
        vm.expectRevert(abi.encodeWithSelector(ClaimBook.RemoveBeyondNode.selector, ClaimBook.bucketOf(low)));
        book.remove(size, claim, low, INDEX_AT_OPEN);
    }

    /// @dev D43: collateral moves D and sumC and leaves the size, the entry
    ///      price and the tree alone, so the low side rises by exactly dC.
    function test_AddCollateralMovesTheClaimAndNothingElse() public {
        Position memory p = Position({size: SIZE_TEN, claim: CLAIM_TEN, openPrice: ENTRY, openIndex: NOTHING});
        _add(p);
        uint256 beforeDebt = book.notionalDebt();
        (uint256 beforeSize, uint256 beforeNotional) = book.bucketTotals(ClaimBook.bucketOf(p.openPrice));
        uint256 lowBefore = book.withdrawalClaimUsd(p.openPrice, NOTHING);

        uint256 extra = EXTRA_COLLATERAL;
        book.addCollateral(p.openPrice, extra);

        assertEq(book.claimTotal(), p.claim + extra, "sumC did not take the collateral");
        assertEq(book.notionalDebt(), beforeDebt - extra, "D did not fall by the collateral");
        assertEq(book.reserved(), p.size, "the collateral changed the size");
        (uint256 afterSize, uint256 afterNotional) = book.bucketTotals(ClaimBook.bucketOf(p.openPrice));
        assertEq(afterSize, beforeSize, "the collateral moved the bucket size");
        assertEq(afterNotional, beforeNotional, "the collateral moved the bucket notional");
        assertEq(book.withdrawalClaimUsd(p.openPrice, NOTHING), lowBefore + extra, "the low side missed the extra");
    }

    function test_RejectsBadArguments() public {
        vm.expectRevert(ClaimBook.ZeroSize.selector);
        book.add(NOTHING, 1, ENTRY, NOTHING);

        vm.expectRevert(ClaimBook.ZeroPrice.selector);
        book.add(SIZE_ONE, 1, NOTHING, NOTHING);

        vm.expectRevert(abi.encodeWithSelector(ClaimBook.EntryPriceOutOfRange.selector, RANGE_TOP));
        book.add(SIZE_ONE, 1, RANGE_TOP, NOTHING);

        uint256 notional = (SIZE_ONE * ENTRY) / WAD;
        vm.expectRevert(abi.encodeWithSelector(ClaimBook.ClaimAboveNotional.selector, notional + 1, notional));
        book.add(SIZE_ONE, notional + 1, ENTRY, NOTHING);

        vm.expectRevert(ClaimBook.ZeroPrice.selector);
        // forge-lint: disable-next-line(unused-return)
        book.depositClaimUsd(NOTHING, NOTHING);

        vm.expectRevert(ClaimBook.ZeroPrice.selector);
        // forge-lint: disable-next-line(unused-return)
        book.withdrawalClaimUsd(NOTHING, NOTHING);
    }

    /// @dev D60 rule 5: the last entry price the tree can hold is one wei under
    ///      the top, and it lands in the last bucket.
    function test_TheRangeLimitIsTheLastBucket() public {
        uint256 last = RANGE_TOP - ONE_WEI;
        assertEq(ClaimBook.bucketOf(last), BUCKETS, "the last price is not in the last bucket");

        uint256 size = SIZE_ONE;
        _add(Position({size: size, claim: NOTHING, openPrice: last, openIndex: NOTHING}));

        // Only the size half of the bucket is under test here.
        // forge-lint: disable-next-line(unused-return)
        (uint256 bucketSize,) = book.bucketTotals(BUCKETS);
        assertEq(bucketSize, size, "the last bucket did not take the position");

        // The entry is a wei under the top of its own bucket and the price is
        // the entry, so this is the worst the bucket error of D60 rule 2 can
        // be: the whole width times the size, counted in favour of the LPs who
        // stay. The true term is zero.
        uint256 worstBucketError = (size * WIDTH) / WAD;
        assertEq(
            book.withdrawalClaimUsd(last, NOTHING),
            worstBucketError - ONE_WEI,
            "the bucket error at the range limit was not the width times the size"
        );
    }

    /// @dev A price at or above the top of the range puts every bucket below
    ///      it, which is a read and not an error: only an entry is refused.
    function test_APriceAboveTheRangeCountsEveryBucket() public {
        _add(Position({size: SIZE_ONE, claim: NOTHING, openPrice: ENTRY, openIndex: NOTHING}));

        uint256 gain = (SIZE_ONE * (RANGE_TOP - ENTRY)) / WAD;

        assertEq(book.withdrawalClaimUsd(RANGE_TOP, NOTHING), gain, "a price above the range lost the prefix");
    }

    /// @dev On a bucket edge the bucket holding the price is the one starting
    ///      there, so a position at that exact price contributes nothing and
    ///      one a wei below contributes its full term.
    function test_APriceOnABucketEdge() public {
        uint256 edge = ENTRY;
        _add(Position({size: SIZE_TWO, claim: NOTHING, openPrice: edge, openIndex: NOTHING}));
        _add(Position({size: SIZE_TWO, claim: NOTHING, openPrice: edge - ONE_WEI, openIndex: NOTHING}));

        uint256 fromBelow = (SIZE_TWO * ONE_WEI) / WAD;

        assertEq(book.withdrawalClaimUsd(edge, NOTHING), fromBelow, "the edge counted the position sitting on it");
    }

    function test_APriceBelowEveryEntryCountsNoGain() public {
        _add(Position({size: SIZE_TWO, claim: CLAIM_TWO, openPrice: ENTRY, openIndex: NOTHING}));
        _add(Position({size: SIZE_THREE, claim: CLAIM_THREE, openPrice: ENTRY_HIGH, openIndex: NOTHING}));

        assertEq(book.withdrawalClaimUsd(MIN_PRICE, NOTHING), CLAIM_SUM, "a price under every entry showed a gain");
    }

    /// @dev D29 and D60 rule 4: the direction of every rounding, pinned
    ///      exactly rather than inside a slack, because a slack cannot tell one
    ///      direction from the other. Every figure below is worked out by hand
    ///      from one position whose arithmetic has a remainder at each step:
    ///
    ///        s = C_WIDE, P_open = P_WIDE, both one wei above one unit
    ///        s * P_open = 1e36 + 2e18 + 1, so the notional floors to 1e18 + 2
    ///        and the wei of remainder stays with the pool
    ///        C is half of that notional, 5e17 + 1, so D is 5e17 + 1
    ///
    ///      At the entry price with no fee the deposit measure is therefore
    ///      exactly C, and the withdrawal measure is C plus the two wei its
    ///      partial bucket rounds up to. With the index one wei above zero the
    ///      fee rounds up to two wei of ounces for the deposit measure, worth
    ///      three wei of USD, and down to one and one for the withdrawal
    ///      measure. Turning any of those four roundings around changes one of
    ///      these four numbers.
    function test_RoundingGoesAgainstTheUserOnBothMeasures() public {
        uint256 size = ROUND_WIDE;
        uint256 claim = ROUND_CLAIM;
        _add(Position({size: size, claim: claim, openPrice: ROUND_WIDE, openIndex: NOTHING}));

        assertEq(book.notionalDebt(), claim, "the notional did not floor to twice the claim");
        assertEq(book.depositClaimUsd(ROUND_WIDE, NOTHING), claim, "the deposit measure did not round down");
        assertEq(
            book.withdrawalClaimUsd(ROUND_WIDE, NOTHING),
            claim + ROUND_PARTIAL,
            "the withdrawal measure did not round up"
        );

        assertEq(book.accruedFeeOunces(ONE_WEI), ROUND_FEE_OUNCES, "the fee in ounces did not round up");
        assertEq(
            book.depositClaimUsd(ROUND_WIDE, ONE_WEI), claim - ROUND_FEE_USD, "the deposit measure took the smaller fee"
        );
        assertEq(
            book.withdrawalClaimUsd(ROUND_WIDE, ONE_WEI),
            claim + ROUND_PARTIAL - ONE_WEI,
            "the withdrawal measure took the larger fee"
        );
    }

    function testFuzz_BothMeasuresMatchTheBruteForceSum(uint256 seed, uint8 count, uint256 priceSeed, uint256 indexSeed)
        public
    {
        uint256 total = bound(count, 1, MAX_POSITIONS);
        uint256 index = bound(indexSeed, 0, MAX_INDEX);
        for (uint256 i = 0; i < total; i++) {
            _add(_randomPosition(uint256(keccak256(abi.encode(seed, i))), index));
        }
        uint256 price = bound(priceSeed, MIN_PRICE, MAX_PRICE);

        _assertMeasures(price, index);
    }

    function testFuzz_MeasuresHoldAtEveryPriceAroundTheEntries(uint256 seed, uint8 count) public {
        uint256 total = bound(count, 1, MAX_POSITIONS);
        for (uint256 i = 0; i < total; i++) {
            _add(_randomPosition(uint256(keccak256(abi.encode(seed, i))), 0));
        }

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 entry = positions[i].openPrice;
            _assertMeasures(entry, 0);
            _assertMeasures(entry + WIDTH, 0);
            if (entry > WIDTH) {
                _assertMeasures(entry - WIDTH, 0);
            }
        }
    }

    function _randomPosition(uint256 seed, uint256 index) private pure returns (Position memory p) {
        uint256[TIERS] memory tiers = [HALF, uint256(3), uint256(5)];
        p.size = _bounded(seed, MIN_SIZE, MAX_SIZE);
        p.openPrice = _bounded(uint256(keccak256(abi.encode(seed, "price"))), MIN_PRICE, MAX_PRICE);
        uint256 leverage = tiers[seed % TIERS];
        p.claim = ((p.size * p.openPrice) / WAD) / leverage;
        p.openIndex = index == 0 ? 0 : _bounded(uint256(keccak256(abi.encode(seed, "index"))), 0, index);
    }

    function _bounded(uint256 seed, uint256 low, uint256 high) private pure returns (uint256) {
        return low + (seed % (high - low + 1));
    }

    /// @dev The holding fee of D53 in USD: ounces first, then USD, because the
    ///      fee is a real quantity in ounces and rounds there. Multiplying
    ///      before dividing would compute a different number from the one the
    ///      library and the protocol use.
    function _feeUsd(uint256 size, uint256 indexGap, uint256 price) private pure returns (uint256) {
        // forge-lint: disable-next-line(divide-before-multiply)
        return (((size * indexGap) / WAD) * price) / WAD;
    }

    /// @dev Every value cast here is a USD or ounce amount far under the signed
    ///      range, and the bound is checked rather than assumed.
    function _signed(uint256 value) private pure returns (int256) {
        // The signed maximum written as an unsigned bound, which loses nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(value, uint256(type(int256).max), "a reference term left the signed range");
        // The bound above is what the rule asks for, checked on the line before.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }

    /// @dev The aggregate floor at zero, which the library has as well.
    function _unsigned(int256 value) private pure returns (uint256) {
        // Negative never reaches the cast; it is turned into zero instead.
        // forge-lint: disable-next-line(unsafe-typecast)
        return value > 0 ? uint256(value) : 0;
    }

    function _add(Position memory p) private {
        // The fuzz tests fill the book from a loop whose length is bounded by
        // MAX_POSITIONS, and the book under test is the only callee.
        // forge-lint: disable-next-line(calls-loop)
        book.add(p.size, p.claim, p.openPrice, p.openIndex);
        positions.push(p);
    }

    /// @dev The reference sums, computed over the positions this test holds.
    function _reference(uint256 price, uint256 index)
        private
        view
        returns (uint256 high, uint256 low, uint256 sizeInBucket)
    {
        int256 highSum = 0;
        int256 lowSum = 0;
        uint256 bucket = ClaimBook.bucketOf(price);

        for (uint256 i = 0; i < positions.length; i++) {
            Position memory p = positions[i];
            uint256 fee = _feeUsd(p.size, index - p.openIndex, price);
            int256 equity = _signed(p.claim) + _signed((p.size * price) / WAD) - _signed((p.size * p.openPrice) / WAD)
                - _signed(fee);
            highSum += equity;

            int256 withCollateral = _signed(p.claim) - _signed(fee);
            lowSum += equity > withCollateral ? equity : withCollateral;

            if (ClaimBook.bucketOf(p.openPrice) == bucket) {
                sizeInBucket += p.size;
            }
        }

        high = _unsigned(highSum);
        low = _unsigned(lowSum);
    }

    function _assertMeasures(uint256 price, uint256 index) private view {
        (uint256 high, uint256 low, uint256 sizeInBucket) = _reference(price, index);
        uint256 count = positions.length;
        uint256 up = MEASURE_SLACK + count;
        uint256 down = MEASURE_SLACK + (2 * count + 2) * (price / WAD + 1);
        uint256 bucketError = (sizeInBucket * WIDTH) / WAD;

        // Reached from the loop over entry prices in one of the fuzz tests,
        // over the same bounded set, and again the callee is the book itself.
        // forge-lint: disable-next-line(calls-loop)
        uint256 deposit = book.depositClaimUsd(price, index);
        // forge-lint: disable-next-line(calls-loop)
        uint256 withdrawal = book.withdrawalClaimUsd(price, index);

        assertLe(deposit, high + up, "the deposit measure rose above the reference");
        assertGe(deposit + down, high, "the deposit measure fell under the reference");
        assertGe(withdrawal + down, low, "the withdrawal measure fell under the reference");
        assertLe(withdrawal, low + bucketError + up, "the withdrawal measure rose past the bucket error");
        assertGe(withdrawal + down, deposit, "I6: the low side fell under the high side");
    }
}
