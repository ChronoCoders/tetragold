// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBook} from "../../src/libraries/ClaimBook.sol";
import {ClaimBookHarness} from "../mocks/ClaimBookHarness.sol";

/// @notice Drives the claim book and keeps a shadow list of the same positions.
/// @dev Every step checks all five counters and both measures against the
///      shadow list before returning, so a defect is caught at the step that
///      caused it rather than at the end of a sequence. The checks raise
///      counters instead of reverting, because a revert inside a handler is
///      swallowed by the campaign.
///
///      The measures are compared against an exact reference, scaled so that
///      nothing in the reference rounds, and the direction is asserted rather
///      than a slack: the deposit measure never above exact, the withdrawal
///      measure never below it (D29, D60 rule 4 and rule 8).
///
///      A move step walks the fee split, and each measure is read at its share
///      (D74): the deposit measure at the largest, pool plus fund, and the
///      withdrawal measure at the smallest, the pool alone. The reference scales
///      its fee term by the same share, so a defect that reads the wrong share,
///      or none, moves a measure off exact and is caught here.
///
///      The fee index only ever rises, as a cumulative rate index must (D53),
///      and a position opens at whatever it is then.
contract ClaimBookHandler is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant WIDTH = 1e18;
    uint256 private constant MIN_SIZE = 0.001 ether;
    uint256 private constant MAX_SIZE = 200 ether;
    uint256 private constant MIN_PRICE = 100e18;
    uint256 private constant MAX_PRICE = 20_000e18;
    uint256 private constant MAX_INDEX_STEP = 0.001e18;
    /// @dev One unit of the 1e18 scale squared, which clears both divisions in
    ///      the exact reference.
    uint256 private constant SCALE = 1e36;
    /// @dev The basis-point denominator the pool share is stated in. The exact
    ///      reference is carried in a domain scaled by it as well, so the fee
    ///      term can be multiplied by a share without a division rounding (D74).
    uint256 private constant BPS = 10_000;
    uint256 private constant TIERS = 3;

    struct Counters {
        uint256 size;
        uint256 debt;
        uint256 basisDown;
        uint256 basisUp;
        uint256 claims;
    }

    struct Shadow {
        uint256 size;
        uint256 claim;
        uint256 openPrice;
        uint256 openIndex;
    }

    ClaimBookHarness public immutable BOOK;

    Shadow[] private _open;

    uint256 public index;
    uint256 public price = 4000e18;

    /// @dev The fee split the measures are read at (D20, D74). The deposit
    ///      measure takes the largest pool share, pool plus fund, and the
    ///      withdrawal measure the smallest, the pool alone. Both start at a
    ///      split that leaves a treasury cut, so the scaling is on from the
    ///      first step; a move step walks them, including the two edges.
    uint256 public poolShareBps = 3000;
    uint256 public insuranceShareBps = 3000;

    uint256 public opens;
    uint256 public closes;
    uint256 public collateralAdds;
    uint256 public indexMoves;
    uint256 public shareMoves;

    uint256 public counterMismatches;
    uint256 public depositMismatches;
    uint256 public withdrawalMismatches;
    uint256 public sideInversions;

    constructor(ClaimBookHarness harness) {
        BOOK = harness;
    }

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    function openPosition(uint256 sizeSeed, uint256 priceSeed, uint8 tier) external {
        uint256[TIERS] memory tiers = [uint256(2), 3, 5];
        uint256 size = bound(sizeSeed, MIN_SIZE, MAX_SIZE);
        uint256 openPrice = bound(priceSeed, MIN_PRICE, MAX_PRICE);
        uint256 claim = ((size * openPrice) / WAD) / tiers[tier % TIERS];

        // The shadow follows the call because the call is what it mirrors, and
        // the book is a harness that calls nothing back.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        BOOK.add(size, claim, openPrice, index);
        _open.push(Shadow({size: size, claim: claim, openPrice: openPrice, openIndex: index}));
        opens += 1;

        _check();
    }

    function closePosition(uint256 seed) external {
        uint256 count = _open.length;
        if (count == 0) {
            return;
        }
        uint256 at = seed % count;
        Shadow memory p = _open[at];

        // Same as the open path above.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        BOOK.remove(p.size, p.claim, p.openPrice, p.openIndex);
        _open[at] = _open[count - 1];
        _open.pop();
        closes += 1;

        _check();
    }

    /// @dev D43 rule 5 keeps the claim inside the notional, so the extra is
    ///      bounded by the room the position still has.
    function addCollateral(uint256 seed, uint256 amountSeed) external {
        uint256 count = _open.length;
        if (count == 0) {
            return;
        }
        uint256 at = seed % count;
        Shadow memory p = _open[at];
        uint256 room = (p.size * p.openPrice) / WAD - p.claim;
        if (room == 0) {
            return;
        }
        uint256 extra = bound(amountSeed, 1, room);

        // Same as the open and close paths: the shadow follows the call.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        BOOK.addCollateral(p.openPrice, extra);
        _open[at].claim = p.claim + extra;
        collateralAdds += 1;

        _check();
    }

    function moveIndex(uint256 seed) external {
        index += bound(seed, 0, MAX_INDEX_STEP);
        indexMoves += 1;

        _check();
    }

    function movePrice(uint256 seed) external {
        price = bound(seed, MIN_PRICE, MAX_PRICE);

        _check();
    }

    /// @dev D20: the three shares sum to the denominator, so a pool share and a
    ///      fund share inside the room the pool left fixes the treasury share as
    ///      the rest. The bounds reach both edges, a zero fund share and a zero
    ///      treasury share, where the largest share equals the smallest or the
    ///      whole.
    function moveShares(uint256 poolSeed, uint256 fundSeed) external {
        uint256 pool = bound(poolSeed, 0, BPS);
        poolShareBps = pool;
        insuranceShareBps = bound(fundSeed, 0, BPS - pool);
        shareMoves += 1;

        _check();
    }

    function _check() private {
        Counters memory want = _counters();
        if (
            BOOK.reserved() != want.size || BOOK.notionalDebt() != want.debt || BOOK.feeBasisDown() != want.basisDown
                || BOOK.feeBasisUp() != want.basisUp || BOOK.claimTotal() != want.claims
        ) {
            counterMismatches += 1;
        }

        uint256 largest = poolShareBps + insuranceShareBps;
        uint256 smallest = poolShareBps;

        (int256 high, int256 low, uint256 sizeInBucket) = _exact(largest, smallest);
        uint256 count = _open.length;
        // Four rounding weis a measure is allowed off its exact value: a gross
        // and a fee rounding on each side, one of the fee ones being the share
        // multiply D74 adds. The per-position term covers the fee basis kept to
        // a wei of ounces a position. All of it is carried in the SCALE and BPS
        // domain the exact reference and both measures sit in.
        int256 slack = _signed(4 + count + (count + 1) * (price / WAD + 1)) * _signed(SCALE) * _signed(BPS);
        int256 bucketError = _signed((sizeInBucket * WIDTH) / WAD) * _signed(SCALE) * _signed(BPS);

        int256 deposit = _signed(BOOK.depositClaimUsd(price, index, largest)) * _signed(SCALE) * _signed(BPS);
        int256 withdrawal = _signed(BOOK.withdrawalClaimUsd(price, index, smallest)) * _signed(SCALE) * _signed(BPS);

        if (deposit > (high > 0 ? high : int256(0)) || deposit + slack < high) {
            depositMismatches += 1;
        }
        if (withdrawal < low || withdrawal > low + bucketError + slack) {
            withdrawalMismatches += 1;
        }
        if (withdrawal + slack + bucketError < deposit) {
            sideInversions += 1;
        }
    }

    /// @dev D60 rule 8: the notional rounds up into D and the fee basis is kept
    ///      both ways, so the shadow sums each of them the way the library does.
    function _counters() private view returns (Counters memory want) {
        for (uint256 i = 0; i < _open.length; i++) {
            Shadow memory p = _open[i];
            want.size += p.size;
            want.debt += _up(p.size, p.openPrice) - p.claim;
            want.basisDown += (p.size * p.openIndex) / WAD;
            want.basisUp += _up(p.size, p.openIndex);
            want.claims += p.claim;
        }
    }

    function _up(uint256 a, uint256 b) private pure returns (uint256) {
        return (a * b + WAD - 1) / WAD;
    }

    /// @dev The exact measures over the shadow list, scaled by SCALE and by BPS
    ///      so that neither a division nor the share multiply rounds. The fee
    ///      term is the only one a share touches, so it is multiplied by the
    ///      share and the rest by the denominator (D74). The deposit measure
    ///      takes `largest`, the withdrawal measure `smallest`. Signed, because
    ///      either sum can be negative before the floor at zero.
    function _exact(uint256 largest, uint256 smallest)
        private
        view
        returns (int256 high, int256 low, uint256 sizeInBucket)
    {
        uint256 bucket = ClaimBook.bucketOf(price);

        for (uint256 i = 0; i < _open.length; i++) {
            Shadow memory p = _open[i];
            int256 claimTerm = _signed(p.claim) * _signed(SCALE);
            int256 feeTerm = _signed(p.size) * _signed(index - p.openIndex) * _signed(price);
            int256 move = _signed(p.size) * (_signed(price) - _signed(p.openPrice)) * _signed(WAD);

            high += (claimTerm + move) * _signed(BPS) - feeTerm * _signed(largest);
            low += claimTerm * _signed(BPS) - feeTerm * _signed(smallest) + (move > 0 ? move * _signed(BPS) : int256(0));

            if (ClaimBook.bucketOf(p.openPrice) == bucket) {
                sizeInBucket += p.size;
            }
        }
    }

    /// @dev Every value cast here is a USD or ounce amount far under the signed
    ///      range, and the bound is checked rather than assumed.
    function _signed(uint256 value) private pure returns (int256) {
        // The signed maximum written as an unsigned bound, which loses nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(value, uint256(type(int256).max), "a shadow term left the signed range");
        // The bound above is what the rule asks for, checked on the line before.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }
}
