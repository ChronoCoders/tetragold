// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {SettlementHandler} from "./handlers/SettlementHandler.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// @notice I10 and I12 over the settlement oracle (section 8).
/// @dev I10: nothing settles while either source says the market is closed.
///      I12: every settlement used the report and the update for its target
///      time. The handler also tracks the rule 3 band, which costs nothing to
///      assert beside them.
/// @dev The handler swallows every refusal itself and never reverts, so a
///      revert inside a sequence is a defect rather than a bounds miss.
/// forge-config: default.invariant.fail-on-revert = true
contract SettlementInvariantTest is Test {
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
    uint8 private constant STREAM_DECIMALS = 18;
    uint256 private constant PYTH_FEE = 1;
    uint256 private constant HANDLER_FUNDING = 10 ether;
    /// @dev 2026-07-13 00:00 UTC, a Monday inside open hours.
    uint32 private constant START = 1_783_900_800;
    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));
    uint32 private constant STEP = 1 hours;
    uint32 private constant OPEN_STATUS = 2;
    uint32 private constant CLOSED_STATUS = 1;
    uint32 private constant COVERING_WINDOW = 1;
    int64 private constant NO_SKEW = 0;
    /// @dev The publish seed is taken modulo the span, and this value is the
    ///      one that lands the update exactly on the target time.
    uint64 private constant PUBLISH_AT_TARGET = 30;

    SettlementOracle public oracle;
    MockVerifierProxy public verifier;
    MockPyth public pyth;
    SettlementHandler public handler;

    function setUp() public {
        verifier = new MockVerifierProxy();
        pyth = new MockPyth();
        pyth.setFee(PYTH_FEE);
        oracle = new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY
        );

        vm.warp(START);
        handler = new SettlementHandler(oracle, START, PYTH_FEE);
        vm.deal(address(handler), HANDLER_FUNDING);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SettlementHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev I10 and D61: the report's own market flag is the whole test in
    ///      settlement, so this is the only closed state a campaign can see.
    function invariant_I10_NoSettlementWhileTheReportSaysClosed() public view {
        assertEq(handler.successesWithReportClosed(), 0, "I10: a price settled while the report said closed");
    }

    function invariant_I12_EverySettlementUsedTheReportForTheTarget() public view {
        assertEq(
            handler.successesOutsideReportWindow(), 0, "I12: a price settled from a report that did not span the target"
        );
        assertEq(
            handler.successesWithPythBeforeTarget(),
            0,
            "I12: a price settled from an update published before the target"
        );
        assertEq(
            handler.successesWithPythPastDelay(), 0, "I12: a price settled from an update published past the delay"
        );
    }

    function invariant_Rule3_NoSettlementOutsideTheBand() public view {
        assertEq(handler.successesOutsideBand(), 0, "rule 3: a price settled outside the deviation band");
    }

    /// @dev Every assertion above holds on a campaign that settled nothing, so
    ///      this proves by hand that the accepting path is reachable and that
    ///      refusals happen, before the campaign is believed.
    function test_HandlerSettlesAndRefuses() public {
        // The publish seed is an absolute timestamp, so it lands on the target
        // rather than wherever the bound happens to map a small number.
        handler.settle(STEP, OPEN_STATUS, COVERING_WINDOW, PUBLISH_AT_TARGET, NO_SKEW);
        assertEq(handler.successes(), 1, "the accepting path never ran");

        handler.settle(STEP, CLOSED_STATUS, COVERING_WINDOW, PUBLISH_AT_TARGET, NO_SKEW);
        assertEq(handler.attempts(), 2, "the second call did not run");
        assertEq(handler.successes(), 1, "a report that said closed was settled");
    }
}
