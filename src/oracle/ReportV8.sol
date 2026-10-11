// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @notice A Data Streams report in schema v8, the RWA schema that carries a
 *         market status.
 * @dev Copied from smartcontractkit/chainlink-local@af2b3da7e84e141695389739bb137680d0942d1c,
 *      `src/data-streams/ReportVersions.sol:125-137`, and cross checked field
 *      for field against the Chainlink reference page
 *      https://docs.chain.link/data-streams/reference/report-schema-v8 (read
 *      2026-10-11). The two agree on every name, type and position.
 *
 *      Not in chainlink-evm@b723176: that tree carries no Solidity report
 *      struct, and its only `marketStatus` is the v4 Go schema at
 *      `pkg/report/mercury/v4/types.go:21-29`. v8 is the right version for this
 *      stream because the report version is the first two bytes of the feed id
 *      (`llo-feeds/v0.3.0/FeeManager.sol:50` for the mask,
 *      `:367-371` for `_getReportVersion`) and the XAU/USD stream id begins
 *      0x0008.
 *
 *      `marketStatus` is 0 unknown, 1 closed, 2 open. `midPrice` carries 8 or
 *      18 decimals depending on the stream, which is why the consumer is told
 *      the stream's decimals rather than assuming them.
 */
struct ReportV8 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    uint64 lastUpdateTimestamp;
    int192 midPrice;
    uint32 marketStatus;
}
