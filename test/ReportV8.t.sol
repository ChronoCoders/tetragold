// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReportV8} from "../src/oracle/ReportV8.sol";

/// @notice Pins the local v8 report layout to the upstream schema.
/// @dev The verifier hands back ABI encoded report bytes, so the decode is only
///      as good as this struct: a field of the wrong width or in the wrong
///      place would read another field's bytes and still return a number. Each
///      field carries a value unlike every other, so a swapped pair shows up as
///      a changed value rather than passing unnoticed.
contract ReportV8Test is Test {
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008));
    uint32 private constant VALID_FROM = 1_760_000_000;
    uint32 private constant OBSERVATIONS = 1_760_000_012;
    uint192 private constant NATIVE_FEE = 3_000_000_000_000;
    uint192 private constant LINK_FEE = 4_000_000_000_000;
    uint32 private constant EXPIRES_AT = 1_760_086_400;
    uint64 private constant LAST_UPDATE = 1_760_000_011;
    int192 private constant MID_PRICE = 4100e18;
    uint32 private constant MARKET_STATUS = 2;

    function test_LayoutMatchesTheV8Schema() public pure {
        ReportV8 memory report = ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: VALID_FROM,
            observationsTimestamp: OBSERVATIONS,
            nativeFee: NATIVE_FEE,
            linkFee: LINK_FEE,
            expiresAt: EXPIRES_AT,
            lastUpdateTimestamp: LAST_UPDATE,
            midPrice: MID_PRICE,
            marketStatus: MARKET_STATUS
        });

        bytes memory flat = abi.encode(
            FEED_ID, VALID_FROM, OBSERVATIONS, NATIVE_FEE, LINK_FEE, EXPIRES_AT, LAST_UPDATE, MID_PRICE, MARKET_STATUS
        );

        assertEq(abi.encode(report), flat, "the v8 layout drifted from the schema");
    }

    /// @dev The round trip the consumer performs on the verifier's response,
    ///      which is where a layout error would surface in production.
    function test_DecodeReturnsEveryFieldUnchanged() public pure {
        bytes memory encoded = abi.encode(
            FEED_ID, VALID_FROM, OBSERVATIONS, NATIVE_FEE, LINK_FEE, EXPIRES_AT, LAST_UPDATE, MID_PRICE, MARKET_STATUS
        );

        ReportV8 memory report = abi.decode(encoded, (ReportV8));

        assertEq(report.feedId, FEED_ID);
        assertEq(report.validFromTimestamp, VALID_FROM);
        assertEq(report.observationsTimestamp, OBSERVATIONS);
        assertEq(report.nativeFee, NATIVE_FEE);
        assertEq(report.linkFee, LINK_FEE);
        assertEq(report.expiresAt, EXPIRES_AT);
        assertEq(report.lastUpdateTimestamp, LAST_UPDATE);
        assertEq(report.midPrice, MID_PRICE);
        assertEq(report.marketStatus, MARKET_STATUS);
    }
}
