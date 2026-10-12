// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ClaimBook
 * @notice The two D48 claim measures over every open position, in constant time
 *         for the deposit measure and one tree walk for the withdrawal measure,
 *         without visiting a position (D60).
 * @dev Equity is linear in the price, so the deposit measure is a plain sum and
 *      needs only three running counters:
 *
 *          e_i(P) = C_i + s_i * (P - P_open,i) - s_i * (I - I_open,i) * P
 *          sum e_i(P) = P * R - D - P * (I * R - J)
 *          R = sum s_i, D = sum (s_i * P_open,i - C_i), J = sum s_i * I_open,i
 *
 *      This is GMX v1's construction: `guaranteedUsd` holds sum (size minus
 *      collateral) (`Vault.sol:607-608`, `:1188`, `:1193`) and pool value is
 *      that plus (pool less reserved) times price (`GlpManager.sol:170-173`),
 *      gmx-contracts fe55c4b.
 *
 *      The withdrawal measure drops each position's unrealised loss, so it has
 *      a kink at every entry price:
 *
 *          sum C - P * (I * R - J) + sum over P_open,i < P of s_i * (P - P_open,i)
 *
 *      The kinks never move, so the last sum comes from a Fenwick tree over
 *      entry price buckets. Buckets fully below the one holding P are exact. In
 *      the bucket holding P every position counts from that bucket's low edge,
 *      which is at least its true term and at most its size times the bucket
 *      width above it, so the error is bounded by the width times the size in
 *      that one bucket and always favours the LPs who stay (D29, D60 rule 2).
 *
 *      Units, all scaled by 1e18: s and R in ounces, P in USD per ounce, C, D
 *      and the two measures in USD, I and J in ounces per ounce of size.
 *
 *      Rounding (D29, D60 rule 4): the deposit measure rounds down as a whole
 *      and the withdrawal measure rounds up as a whole, so each added term
 *      rounds down and each subtracted term rounds up, or the other way about.
 *      J is stored as the sum of each position's floored contribution, which is
 *      what the deposit measure needs, because a smaller J makes the fee it
 *      subtracts larger. The withdrawal measure therefore carries a fee term up
 *      to one wei of USD per open position larger than exact, which lowers it
 *      by that much; the bucket error above dominates it.
 *
 *      A measure is reported as zero when the sum is negative. For the deposit
 *      measure that is D48's floor; for the withdrawal measure it is reached
 *      only when accrued fees exceed every claim, which is past bankruptcy for
 *      every position at once.
 *
 *      No contract uses this yet. It is written and measured first because the
 *      cost per open and per close is an input to the keeper fee and the
 *      minimum position size (O5, D39, D57).
 */
library ClaimBook {
    /// @notice One unit of the 1e18 scale every figure here carries.
    uint256 internal constant WAD = 1e18;

    /// @notice Bucket width, one USD of entry price (D60 rule 5, O5).
    uint256 internal constant BUCKET_WIDTH = 1e18;

    /// @notice Buckets in the tree, 2 ** 18 (D60 rule 5, O5).
    uint256 internal constant BUCKET_COUNT = 262_144;

    /// @notice First entry price the tree cannot hold. The highest whole dollar
    ///         entry price is therefore 262,143 USD, and an open at or above
    ///         the top is refused rather than bucketed wrongly, because no
    ///         contract can be changed later (D58, D60 rule 5).
    uint256 internal constant RANGE_TOP = BUCKET_COUNT * BUCKET_WIDTH;

    uint256 private constant HALF_SHIFT = 128;
    uint256 private constant HALF_MASK = type(uint128).max;
    uint256 private constant ROUND_UP = 1;

    /// @notice Running totals and the tree over entry prices.
    /// @dev `tree` holds the Fenwick nodes and `bucketTotals` the per bucket
    ///      sums, so the bucket holding the price is one read instead of a
    ///      second walk. Each slot packs the size sum in its low 128 bits and
    ///      the notional sum in its high 128 bits.
    struct Book {
        uint256 reserved;
        uint256 notionalDebt;
        uint256 feeBasis;
        uint256 claimTotal;
        mapping(uint256 node => uint256 packed) tree;
        mapping(uint256 bucketIndex => uint256 packed) bucketTotals;
    }

    /// @notice A node or a bucket would hold more than its half slot.
    error NodeOverflow(uint256 node);

    /// @notice A removal asked for more than the node holds, so the values did
    ///         not match the ones used at `add`.
    error RemoveBeyondNode(uint256 node);

    /// @notice A removal asked for more than a counter holds, for the same
    ///         reason as above.
    error RemoveBeyondBook(uint256 asked, uint256 held);

    /// @notice The entry price is at or above the top of the tree's range.
    error EntryPriceOutOfRange(uint256 openPrice);

    /// @notice The claim exceeds the position's notional, which D46 and D43
    ///         rule 5 forbid and which D would have to go negative to hold.
    error ClaimAboveNotional(uint256 claim, uint256 notional);

    /// @notice The fee index given is below one a position opened at.
    error IndexBelowOpen(uint256 accrued, uint256 feeBasis);

    /// @notice The tree's prefix sums disagree with each other.
    error PrefixInconsistent(uint256 gross, uint256 notional);

    error ZeroSize();
    error ZeroPrice();
    error ZeroAmount();

    /// @notice Record a position of `size` ounces with claim `claim`, opened at
    ///         `openPrice` with the fee index at `openIndex`.
    /// @dev One caller today, the position manager's open path once it exists,
    ///      which is what the rule about a single use reads as inlinable. It is
    ///      the library's entry point and inlining it into that one call site
    ///      would put the tree's arithmetic back in the contract D63 wants it
    ///      out of.
    /// @param size s_i, ounces.
    /// @param claim C_i, USD.
    /// @param openPrice P_open,i, USD per ounce.
    /// @param openIndex I_open,i, ounces per ounce of size.
    // forge-lint: disable-next-line(internal-function-used-once)
    function add(Book storage book, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) internal {
        uint256 notional = _position(size, claim, openPrice);
        uint256 basis = _basis(size, openIndex);

        book.reserved += size;
        book.notionalDebt += notional - claim;
        book.feeBasis += basis;
        book.claimTotal += claim;

        _move(book, _bucketOf(openPrice), size, notional, true);
    }

    /// @notice Drop a position again. It must be called with the same four
    ///         values that recorded it, or a counter or a node underflows and
    ///         the call reverts rather than leaving the book wrong.
    /// @dev The close and liquidation paths are the one caller, as for `add`.
    // forge-lint: disable-next-line(internal-function-used-once)
    function remove(Book storage book, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) internal {
        uint256 notional = _position(size, claim, openPrice);
        uint256 basis = _basis(size, openIndex);

        book.reserved = _take(book.reserved, size);
        book.notionalDebt = _take(book.notionalDebt, notional - claim);
        book.feeBasis = _take(book.feeBasis, basis);
        book.claimTotal = _take(book.claimTotal, claim);

        _move(book, _bucketOf(openPrice), size, notional, false);
    }

    /// @notice Add `extraClaim` USD of collateral to a position opened at
    ///         `openPrice` (D43).
    /// @dev Neither the size nor the entry price moves, so the tree is
    ///      untouched and only the two USD counters change. The price is still
    ///      taken and checked, because a price the tree could not hold means
    ///      the caller is not describing a position this book recorded.
    ///
    ///      One caller, the D43 add collateral path, as for `add`.
    // forge-lint: disable-next-line(internal-function-used-once)
    function addCollateral(Book storage book, uint256 openPrice, uint256 extraClaim) internal {
        if (openPrice >= RANGE_TOP) {
            revert EntryPriceOutOfRange(openPrice);
        }
        if (extraClaim == 0) {
            revert ZeroAmount();
        }

        book.notionalDebt = _take(book.notionalDebt, extraClaim);
        book.claimTotal += extraClaim;
    }

    /// @notice The deposit measure of D48 at `price` with the fee index at
    ///         `index`: the plain sum of equity, rounded down, zero if negative.
    /// @dev The pool asks for this through the position book interface, so it
    ///      has one caller by design (D60 rule 7).
    // forge-lint: disable-next-line(internal-function-used-once)
    function depositClaimUsd(Book storage book, uint256 price, uint256 index) internal view returns (uint256) {
        if (price == 0) {
            revert ZeroPrice();
        }

        uint256 gross = _mulDown(price, book.reserved);
        uint256 owed = book.notionalDebt + _mulUp(price, _feeOunces(book, index, true));

        return gross > owed ? gross - owed : 0;
    }

    /// @notice The withdrawal measure of D48 at `price` with the fee index at
    ///         `index`: claims less accrued fees plus realised trader losses,
    ///         rounded up, zero if negative.
    /// @dev The other half of the position book interface, so one caller too.
    // forge-lint: disable-next-line(internal-function-used-once)
    function withdrawalClaimUsd(Book storage book, uint256 price, uint256 index) internal view returns (uint256) {
        if (price == 0) {
            revert ZeroPrice();
        }

        (uint256 sizeBelow, uint256 notionalBelow, uint256 sizeAt, uint256 lowEdge) = _below(book, price);
        uint256 gross = _mulUp(price, sizeBelow);
        if (gross < notionalBelow) {
            revert PrefixInconsistent(gross, notionalBelow);
        }

        uint256 gain = gross - notionalBelow + _mulUp(price - lowEdge, sizeAt);
        uint256 owed = _mulDown(price, _feeOunces(book, index, false));
        uint256 total = book.claimTotal + gain;

        return total > owed ? total - owed : 0;
    }

    /// @notice Accrued fees in ounces at `index`, rounded up, which is what the
    ///         deposit measure subtracts.
    /// @dev Read by the dashboard of D55 rather than by another function here.
    // forge-lint: disable-next-line(internal-function-used-once)
    function accruedFeeOunces(Book storage book, uint256 index) internal view returns (uint256) {
        return _feeOunces(book, index, true);
    }

    /// @notice The bucket `openPrice` falls in, 1-indexed.
    function bucketOf(uint256 openPrice) internal pure returns (uint256) {
        return _bucketOf(openPrice);
    }

    /// @notice Size and notional recorded in one bucket.
    /// @dev A D55 figure as well, and the only way to see one bucket from
    ///      outside the library.
    // forge-lint: disable-next-line(internal-function-used-once)
    function totalsInBucket(Book storage book, uint256 bucketIndex)
        internal
        view
        returns (uint256 size, uint256 notional)
    {
        return _unpack(book.bucketTotals[bucketIndex]);
    }

    /// @dev One position's notional and fee basis, both floored, and the two
    ///      checks every caller has to pass: a size and a price the tree can
    ///      hold, and a claim inside the notional (D46, D43 rule 5), which is
    ///      what keeps D from going negative.
    function _position(uint256 size, uint256 claim, uint256 openPrice) private pure returns (uint256 notional) {
        if (size == 0) {
            revert ZeroSize();
        }
        if (openPrice == 0) {
            revert ZeroPrice();
        }
        if (openPrice >= RANGE_TOP) {
            revert EntryPriceOutOfRange(openPrice);
        }

        notional = _mulDown(size, openPrice);
        if (claim > notional) {
            revert ClaimAboveNotional(claim, notional);
        }
    }

    /// @dev One position's share of J, floored. Add and remove fold it the same
    ///      way, so a removal that passes the values it was added with takes
    ///      back exactly what it put in.
    function _basis(uint256 size, uint256 openIndex) private pure returns (uint256) {
        return _mulDown(size, openIndex);
    }

    function _take(uint256 held, uint256 asked) private pure returns (uint256) {
        if (asked > held) {
            revert RemoveBeyondBook(asked, held);
        }
        return held - asked;
    }

    /// @dev Accrued fees in ounces: I * R less J, the sum of each position's
    ///      own I_open times its size. `up` picks the rounding of the one
    ///      division, so the deposit measure can take the larger fee and the
    ///      withdrawal measure the smaller one.
    function _feeOunces(Book storage book, uint256 index, bool up) private view returns (uint256) {
        uint256 accrued = up ? _mulUp(index, book.reserved) : _mulDown(index, book.reserved);
        if (accrued < book.feeBasis) {
            revert IndexBelowOpen(accrued, book.feeBasis);
        }
        return accrued - book.feeBasis;
    }

    /// @dev The prefix sums over every bucket strictly below the one holding
    ///      `price`, that bucket's own sums, and its low edge. A price at or
    ///      above the range puts every bucket below it and leaves no partial
    ///      bucket, which is correct rather than an error: only an entry price
    ///      out of range is refused.
    function _below(Book storage book, uint256 price)
        private
        view
        returns (uint256 sizeBelow, uint256 notionalBelow, uint256 sizeAt, uint256 lowEdge)
    {
        if (price >= RANGE_TOP) {
            (sizeBelow, notionalBelow) = _prefix(book, BUCKET_COUNT);
            return (sizeBelow, notionalBelow, 0, 0);
        }

        uint256 index = _bucketOf(price);
        (sizeBelow, notionalBelow) = _prefix(book, index - 1);
        (sizeAt,) = _unpack(book.bucketTotals[index]);
        lowEdge = (index - 1) * BUCKET_WIDTH;
    }

    function _bucketOf(uint256 openPrice) private pure returns (uint256) {
        return openPrice / BUCKET_WIDTH + 1;
    }

    /// @dev Add to or subtract from the bucket and from every Fenwick node that
    ///      covers it. The low bit walk is the tree's own arithmetic and cannot
    ///      overflow for a node inside the range, so it is unchecked to keep
    ///      the cost of a level down.
    function _move(Book storage book, uint256 index, uint256 size, uint256 notional, bool adding) private {
        book.bucketTotals[index] = _shift(book.bucketTotals[index], size, notional, adding, index);

        uint256 node = index;
        while (node <= BUCKET_COUNT) {
            book.tree[node] = _shift(book.tree[node], size, notional, adding, node);
            unchecked {
                node += node & (~node + 1);
            }
        }
    }

    function _prefix(Book storage book, uint256 index) private view returns (uint256 size, uint256 notional) {
        uint256 node = index;
        while (node != 0) {
            (uint256 nodeSize, uint256 nodeNotional) = _unpack(book.tree[node]);
            size += nodeSize;
            notional += nodeNotional;
            unchecked {
                node -= node & (~node + 1);
            }
        }
    }

    function _shift(uint256 packed, uint256 size, uint256 notional, bool adding, uint256 node)
        private
        pure
        returns (uint256)
    {
        (uint256 heldSize, uint256 heldNotional) = _unpack(packed);

        if (adding) {
            heldSize += size;
            heldNotional += notional;
            if (heldSize > HALF_MASK || heldNotional > HALF_MASK) {
                // Reached from the walk over the tree's levels, which the rule
                // reads as a loop. Stopping there is the point: a node that
                // cannot hold its sum would make every prefix that crosses it
                // wrong, so the open has to fail rather than continue.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert NodeOverflow(node);
            }
        } else {
            if (size > heldSize || notional > heldNotional) {
                // Same walk, same reason: a removal that does not match what
                // was added must leave the tree alone rather than wrap a node.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert RemoveBeyondNode(node);
            }
            heldSize -= size;
            heldNotional -= notional;
        }

        return (heldNotional << HALF_SHIFT) | heldSize;
    }

    function _unpack(uint256 packed) private pure returns (uint256 size, uint256 notional) {
        size = packed & HALF_MASK;
        notional = packed >> HALF_SHIFT;
    }

    function _mulDown(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b) / WAD;
    }

    function _mulUp(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b + WAD - ROUND_UP) / WAD;
    }
}
