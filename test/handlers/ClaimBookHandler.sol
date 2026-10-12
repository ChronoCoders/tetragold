// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ClaimBook} from "../../src/libraries/ClaimBook.sol";
import {ClaimBookHarness} from "../mocks/ClaimBookHarness.sol";

/// @notice Drives the claim book and keeps a shadow list of the same positions.
/// @dev Every step checks all four counters and both measures against the
///      shadow list before returning, so a defect is caught at the step that
///      caused it rather than at the end of a sequence. The checks raise
///      counters instead of reverting, because a revert inside a handler is
///      swallowed by the campaign.
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
    uint256 private constant MEASURE_SLACK = 4;
    uint256 private constant TIERS = 3;

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

    uint256 public opens;
    uint256 public closes;
    uint256 public collateralAdds;
    uint256 public indexMoves;

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

    function _check() private {
        (uint256 size, uint256 debt, uint256 basis, uint256 claims) = _counters();
        if (
            BOOK.reserved() != size || BOOK.notionalDebt() != debt || BOOK.feeBasis() != basis
                || BOOK.claimTotal() != claims
        ) {
            counterMismatches += 1;
        }

        (uint256 high, uint256 low, uint256 sizeInBucket) = _reference();
        uint256 count = _open.length;
        uint256 up = MEASURE_SLACK + count;
        uint256 down = MEASURE_SLACK + (2 * count + 2) * (price / WAD + 1);
        uint256 bucketError = (sizeInBucket * WIDTH) / WAD;

        uint256 deposit = BOOK.depositClaimUsd(price, index);
        uint256 withdrawal = BOOK.withdrawalClaimUsd(price, index);

        if (deposit > high + up || deposit + down < high) {
            depositMismatches += 1;
        }
        if (withdrawal + down < low || withdrawal > low + bucketError + up) {
            withdrawalMismatches += 1;
        }
        if (withdrawal + down < deposit) {
            sideInversions += 1;
        }
    }

    function _counters() private view returns (uint256 size, uint256 debt, uint256 basis, uint256 claims) {
        for (uint256 i = 0; i < _open.length; i++) {
            Shadow memory p = _open[i];
            size += p.size;
            debt += (p.size * p.openPrice) / WAD - p.claim;
            basis += (p.size * p.openIndex) / WAD;
            claims += p.claim;
        }
    }

    function _reference() private view returns (uint256 high, uint256 low, uint256 sizeInBucket) {
        int256 highSum = 0;
        int256 lowSum = 0;
        uint256 bucket = ClaimBook.bucketOf(price);

        for (uint256 i = 0; i < _open.length; i++) {
            Shadow memory p = _open[i];
            uint256 fee = _feeUsd(p.size, index - p.openIndex, price);
            int256 equity = _signed(p.claim) + _signed((p.size * price) / WAD) - _signed((p.size * p.openPrice) / WAD)
                - _signed(fee);
            int256 withCollateral = _signed(p.claim) - _signed(fee);

            highSum += equity;
            lowSum += equity > withCollateral ? equity : withCollateral;

            if (ClaimBook.bucketOf(p.openPrice) == bucket) {
                sizeInBucket += p.size;
            }
        }

        high = _unsigned(highSum);
        low = _unsigned(lowSum);
    }

    /// @dev The holding fee of D53 in USD: ounces first, then USD, because the
    ///      fee is a real quantity in ounces and rounds there.
    function _feeUsd(uint256 size, uint256 indexGap, uint256 price) private pure returns (uint256) {
        // forge-lint: disable-next-line(divide-before-multiply)
        return (((size * indexGap) / WAD) * price) / WAD;
    }

    /// @dev Every value cast here is a USD or ounce amount far under the signed
    ///      range, and the bound is checked rather than assumed.
    function _signed(uint256 value) private view returns (int256) {
        // The signed maximum written as an unsigned bound, which loses nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertLe(value, uint256(type(int256).max), "a shadow term left the signed range");
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
}
