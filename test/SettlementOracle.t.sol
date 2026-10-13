// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../src/oracle/interfaces/IPyth.sol";
import {ReportV8} from "../src/oracle/ReportV8.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

contract SettlementOracleTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
    /// @dev D73 rule 5: the tests use 60 seconds; the real value is O5 and
    ///      measured before deployment, never written in src.
    uint256 private constant PRIMARY_AGE = 60;
    uint64 private constant NANOS = 1e9;
    uint8 private constant STREAM_DECIMALS = 18;
    uint256 private constant PYTH_FEE = 1;
    uint256 private constant EXTRA = 7;
    uint32 private constant OPEN = 2;
    uint32 private constant CLOSED = 1;
    uint32 private constant UNKNOWN = 0;
    uint256 private constant NOTHING = 0;

    /// @dev 2026-07-15 12:00 UTC, a Wednesday with the market open. The report
    ///      fields are uint32 and the target is uint64, so both widths are
    ///      declared rather than cast at every use.
    uint32 private constant TARGET = 1_784_116_800;
    /// @dev 2026-07-18 12:00 UTC, a Saturday.
    uint32 private constant SATURDAY = 1_784_376_000;
    uint32 private constant WINDOW = 12;
    uint32 private constant EXPIRY_AHEAD = 86_400;
    int192 private constant STREAM_PRICE = 4100e18;
    int64 private constant PYTH_PRICE = 4100e8;
    int32 private constant PYTH_EXPO = -8;
    /// @dev One step past the supported range, where the shift to 18 decimals
    ///      would need rounding.
    int32 private constant BAD_EXPO = -19;
    /// @dev 50 basis points under 4100, which is the band exactly.
    int64 private constant AT_BAND_PRICE = 4079.5e8;
    uint256 private constant PRICE_18 = 4100e18;

    bytes32 private constant FEED_ID = bytes32(uint256(0x0008abc));
    bytes32 private constant PYTH_ID = bytes32(uint256(0x765d2ba9));
    bytes32 private constant OTHER_ID = bytes32(uint256(0xdead));

    SettlementOracle public oracle;
    MockVerifierProxy public verifier;
    MockPyth public pyth;

    function setUp() public {
        verifier = new MockVerifierProxy();
        pyth = new MockPyth();
        pyth.setFee(PYTH_FEE);
        oracle = new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY, PRIMARY_AGE
        );
        vm.warp(TARGET);
        vm.deal(address(this), 1 ether);
    }

    function test_SettlesTheDataStreamsPriceWhenBothSourcesAgree() public {
        (uint256 price18, uint256 deviationBps) = _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET));

        assertEq(price18, PRICE_18, "the settled price is not the Data Streams price");
        assertEq(deviationBps, NOTHING, "identical prices showed a deviation");
    }

    /// @dev Data Streams bills by subscription, so the verifier is called with
    ///      no value and no parameter bytes, and only Pyth is paid. What the
    ///      caller put up beyond the Pyth fee comes back.
    function test_OnlyPythIsPaidAndTheRestComesBack() public {
        uint256 balanceBefore = address(this).balance;

        _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET));

        assertEq(pyth.received(), PYTH_FEE, "the pyth fee did not arrive");
        assertEq(verifier.received(), NOTHING, "the verifier was sent value");
        assertEq(verifier.lastParameterPayload().length, NOTHING, "the parameter bytes were not empty");
        assertEq(address(oracle).balance, NOTHING, "the oracle kept a balance");
        assertEq(balanceBefore - address(this).balance, PYTH_FEE, "the caller was not refunded");
    }

    /// @dev Section 7 rule 8, measured from msg.value: the caller gets back
    ///      exactly what it sent less the Pyth fee, whatever this contract
    ///      already held. ETH can be forced in with SELFDESTRUCT and there is
    ///      no sweep, so a refund of the balance would hand the caller ETH it
    ///      never sent and leave it unable to tell what the fee was.
    function test_TheRefundIsWhatTheCallerSentLessTheFee() public {
        uint256 stray = 1 ether;
        vm.deal(address(oracle), stray);

        ReportV8 memory report = _report();
        bytes[] memory update = _pythUpdate(PYTH_PRICE, TARGET);
        uint256 before = address(this).balance;

        // The destination is the oracle under test, not an address a caller
        // chose.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (uint256 price18,, uint256 pythPaid) =
            oracle.settlePrice{value: PYTH_FEE + EXTRA}(TARGET, abi.encode(report), update);

        assertEq(price18, PRICE_18);
        assertEq(pythPaid, PYTH_FEE, "the oracle did not report the fee Pyth charged");
        assertEq(before - address(this).balance, PYTH_FEE, "the caller was out of pocket by more than the fee");
        assertEq(address(oracle).balance, stray, "the stray ETH moved");
    }

    function test_RefusesWhenThePythFeeIsNotCovered() public {
        ReportV8 memory report = _report();
        bytes[] memory update = _pythUpdate(PYTH_PRICE, TARGET);

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.FeeNotPaid.selector, NOTHING, PYTH_FEE));
        // forge-lint: disable-next-line(unused-return)
        oracle.settlePrice(TARGET, abi.encode(report), update);
    }

    function test_RefusesAReportForAnotherFeed() public {
        ReportV8 memory report = _report();
        report.feedId = OTHER_ID;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.WrongFeed.selector, OTHER_ID, FEED_ID));
        _settle(report, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function test_RefusesAnExpiredReport() public {
        ReportV8 memory report = _report();
        report.expiresAt = TARGET - 1;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.ReportExpired.selector, report.expiresAt, TARGET));
        _settle(report, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function test_RefusesAReportThatDoesNotSpanTheTarget() public {
        ReportV8 memory early = _report();
        early.validFromTimestamp = TARGET + 1;
        early.observationsTimestamp = TARGET + WINDOW;

        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.ReportNotForTarget.selector,
                early.validFromTimestamp,
                early.observationsTimestamp,
                TARGET
            )
        );
        _settle(early, _pythUpdate(PYTH_PRICE, TARGET));

        ReportV8 memory late = _report();
        late.validFromTimestamp = TARGET - WINDOW;
        late.observationsTimestamp = TARGET - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementOracle.ReportNotForTarget.selector,
                late.validFromTimestamp,
                late.observationsTimestamp,
                TARGET
            )
        );
        _settle(late, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function test_AcceptsTheReportAtBothEndsOfItsWindow() public {
        ReportV8 memory atStart = _report();
        atStart.validFromTimestamp = TARGET;
        atStart.observationsTimestamp = TARGET + WINDOW;
        (uint256 first,) = _settle(atStart, _pythUpdate(PYTH_PRICE, TARGET));
        assertEq(first, PRICE_18);

        ReportV8 memory atEnd = _report();
        atEnd.validFromTimestamp = TARGET - WINDOW;
        atEnd.observationsTimestamp = TARGET;
        (uint256 second,) = _settle(atEnd, _pythUpdate(PYTH_PRICE, TARGET));
        assertEq(second, PRICE_18);
    }

    function test_RefusesWhenTheReportSaysTheMarketIsNotOpen() public {
        ReportV8 memory closed = _report();
        closed.marketStatus = CLOSED;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByReport.selector, CLOSED));
        _settle(closed, _pythUpdate(PYTH_PRICE, TARGET));

        ReportV8 memory unknown = _report();
        unknown.marketStatus = UNKNOWN;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByReport.selector, UNKNOWN));
        _settle(unknown, _pythUpdate(PYTH_PRICE, TARGET));
    }

    /// @dev D61: settlement reads no calendar, so a target on a Saturday is
    ///      refused by the report that covers it and by nothing else. The Pyth
    ///      side needs no market flag of its own, which is what this shows: an
    ///      update published at the target, and one published after it, both
    ///      stop at the report's market test.
    function test_RefusesAClosedMarketOnTheReportAloneWhateverPythSays() public {
        ReportV8 memory report = _reportAt(SATURDAY);
        report.marketStatus = CLOSED;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByReport.selector, CLOSED));
        _settleAt(SATURDAY, report, _pythUpdate(PYTH_PRICE, SATURDAY));

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByReport.selector, CLOSED));
        _settleAt(SATURDAY, report, _pythUpdate(PYTH_PRICE, SATURDAY + PYTH_DELAY));
    }

    /// @dev The other half of D61: a Saturday target settles when the report
    ///      says the market was open for it, because no holiday list is
    ///      consulted and no key can stop a close.
    function test_SettlesWhenOnlyTheReportSaysOpen() public {
        ReportV8 memory report = _reportAt(SATURDAY);

        (uint256 price18,) = _settleAt(SATURDAY, report, _pythUpdate(PYTH_PRICE, SATURDAY));

        assertEq(price18, PRICE_18, "a report that said open did not settle");
    }

    function test_RefusesANonPositiveStreamPrice() public {
        ReportV8 memory report = _report();
        report.midPrice = 0;

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.NonPositivePrice.selector, int256(0)));
        _settle(report, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function test_RefusesAPythUpdateBeforeTheTarget() public {
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET - 1));
    }

    function test_RefusesAPythUpdatePastTheDelay() public {
        vm.expectRevert(MockPyth.PriceFeedNotFoundWithinRange.selector);
        _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET + PYTH_DELAY + 1));
    }

    function test_AcceptsAPythUpdateAtBothEndsOfTheDelay() public {
        (uint256 first,) = _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET));
        assertEq(first, PRICE_18);

        (uint256 second,) = _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET + PYTH_DELAY));
        assertEq(second, PRICE_18);
    }

    function test_RefusesAPythUpdateForAnotherFeed() public {
        bytes[] memory update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: OTHER_ID,
                price: IPyth.Price({price: PYTH_PRICE, conf: 0, expo: PYTH_EXPO, publishTime: TARGET}),
                emaPrice: IPyth.Price({price: PYTH_PRICE, conf: 0, expo: PYTH_EXPO, publishTime: TARGET})
            })
        );

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.WrongPythFeed.selector, OTHER_ID, PYTH_ID));
        _settle(_report(), update);
    }

    function test_RefusesAnExponentThatWouldNeedRounding() public {
        bytes[] memory update = _pythUpdateWithExpo(PYTH_PRICE, TARGET, BAD_EXPO);

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.UnsupportedExponent.selector, BAD_EXPO));
        _settle(_report(), update);
    }

    function test_AcceptsADeviationAtTheBandAndRefusesOnePastIt() public {
        // 50 basis points under 4100e18 is 20.5e18, so a pyth price of
        // 4079.5 sits exactly on the band.
        int64 atBand = AT_BAND_PRICE;
        (, uint256 deviationBps) = _settle(_report(), _pythUpdate(atBand, TARGET));
        assertEq(deviationBps, BAND_BPS, "the boundary was not measured as the band");

        int64 pastBand = AT_BAND_PRICE - 1;
        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.DeviationTooWide.selector, BAND_BPS + 1, BAND_BPS));
        _settle(_report(), _pythUpdate(pastBand, TARGET));
    }

    function test_ScalesAnEightDecimalStream() public {
        SettlementOracle eight = new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, 8, BAND_BPS, PYTH_DELAY, PRIMARY_AGE
        );

        ReportV8 memory report = _report();
        report.midPrice = 4100e8;

        bytes memory payload = abi.encode(report);
        bytes[] memory update = _pythUpdate(PYTH_PRICE, TARGET);
        uint256 price18;
        uint256 deviationBps;

        // The destination is the contract under test, not an address a caller
        // chose, and paying it is how the fee split is exercised.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (price18, deviationBps,) = eight.settlePrice{value: PYTH_FEE + EXTRA}(TARGET, payload, update);

        assertEq(price18, PRICE_18, "an 8 decimal stream did not scale to 18");
        assertEq(deviationBps, NOTHING, "identical prices showed a deviation");
    }

    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(SettlementOracle.ZeroAddress.selector);
        new SettlementOracle(
            address(0), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY, PRIMARY_AGE
        );

        vm.expectRevert(SettlementOracle.ZeroId.selector);
        new SettlementOracle(
            address(verifier), address(pyth), bytes32(0), PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY, PRIMARY_AGE
        );

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BandTooWide.selector, BPS));
        new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BPS, PYTH_DELAY, PRIMARY_AGE
        );

        vm.expectRevert(SettlementOracle.ZeroPythDelay.selector);
        new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, 0, PRIMARY_AGE
        );

        // D73 rule 1: a zero age bound is rejected at deploy.
        vm.expectRevert(SettlementOracle.ZeroPrimaryAge.selector);
        new SettlementOracle(
            address(verifier), address(pyth), FEED_ID, PYTH_ID, STREAM_DECIMALS, BAND_BPS, PYTH_DELAY, 0
        );
    }

    // --- D73: staleness of the primary price --------------------------------

    function test_AgeAtTheBoundPassesAndOneSecondOverReverts() public {
        uint64 obs = uint64(TARGET + WINDOW);

        ReportV8 memory atBound = _report();
        atBound.lastUpdateTimestamp = (obs - uint64(PRIMARY_AGE)) * NANOS;
        (uint256 price18,) = _settle(atBound, _pythUpdate(PYTH_PRICE, TARGET));
        assertEq(price18, PRICE_18, "a report exactly at the age bound did not settle");

        ReportV8 memory over = _report();
        over.lastUpdateTimestamp = (obs - uint64(PRIMARY_AGE) - 1) * NANOS;
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        _settle(over, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function test_ALastUpdateAfterTheObservationCountsAsAgeZero() public {
        uint64 obs = uint64(TARGET + WINDOW);

        ReportV8 memory report = _report();
        // Updated five seconds after it was observed: the subtraction would
        // underflow, so D73 rule 2 counts it as age zero instead.
        report.lastUpdateTimestamp = (obs + 5) * NANOS;
        (uint256 price18,) = _settle(report, _pythUpdate(PYTH_PRICE, TARGET));
        assertEq(price18, PRICE_18, "a future last update was not treated as age zero");
    }

    function test_ANanosecondValueFloorsAcrossASecondBoundary() public {
        uint64 obs = uint64(TARGET + WINDOW);

        // One nanosecond short of (obs - 60) seconds. The floor drops it to
        // obs - 61 seconds, so the age is 61 and the report is stale. Were the
        // division to round up it would read obs - 60 and pass, so this is what
        // shows the floor is applied.
        ReportV8 memory report = _report();
        report.lastUpdateTimestamp = (obs - uint64(PRIMARY_AGE)) * NANOS - 1;
        vm.expectRevert(
            abi.encodeWithSelector(SettlementOracle.PrimaryReportStale.selector, PRIMARY_AGE + 1, PRIMARY_AGE)
        );
        _settle(report, _pythUpdate(PYTH_PRICE, TARGET));
    }

    function _report() private pure returns (ReportV8 memory) {
        return _reportAt(TARGET);
    }

    function _reportAt(uint32 target) private pure returns (ReportV8 memory) {
        return ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: target - WINDOW,
            observationsTimestamp: target + WINDOW,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: target + EXPIRY_AHEAD,
            // Nanoseconds, equal to the observation time, so a fresh report has
            // age zero (D73 rule 2). The staleness tests override this.
            lastUpdateTimestamp: uint64(target + WINDOW) * NANOS,
            midPrice: STREAM_PRICE,
            marketStatus: OPEN
        });
    }

    function _pythUpdate(int64 price, uint64 publishTime) private pure returns (bytes[] memory) {
        return _pythUpdateWithExpo(price, publishTime, PYTH_EXPO);
    }

    function _pythUpdateWithExpo(int64 price, uint64 publishTime, int32 expo)
        private
        pure
        returns (bytes[] memory update)
    {
        update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: PYTH_ID,
                price: IPyth.Price({price: price, conf: 0, expo: expo, publishTime: publishTime}),
                emaPrice: IPyth.Price({price: price, conf: 0, expo: expo, publishTime: publishTime})
            })
        );
    }

    function _settle(ReportV8 memory report, bytes[] memory update)
        private
        returns (uint256 price18, uint256 deviationBps)
    {
        return _settleAt(TARGET, report, update);
    }

    function _settleAt(uint32 target, ReportV8 memory report, bytes[] memory update)
        private
        returns (uint256 price18, uint256 deviationBps)
    {
        // Same as above: the oracle under test is the destination, and the
        // extra wei is there so the refund path runs on every call.
        // forge-lint: disable-next-line(arbitrary-send-eth)
        (price18, deviationBps,) = oracle.settlePrice{value: PYTH_FEE + EXTRA}(target, abi.encode(report), update);
    }

    /// @dev The oracle refunds what the Pyth fee did not use, so this contract
    ///      has to be able to receive it.
    receive() external payable {}
}
