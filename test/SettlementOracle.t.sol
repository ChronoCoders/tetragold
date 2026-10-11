// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../src/oracle/interfaces/IPyth.sol";
import {ReportV8} from "../src/oracle/ReportV8.sol";
import {SettlementOracle} from "../src/oracle/SettlementOracle.sol";
import {TradingCalendar} from "../src/oracle/TradingCalendar.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

contract SettlementOracleTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant BAND_BPS = 50;
    uint64 private constant PYTH_DELAY = 30;
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
    TradingCalendar public calendar;
    MockVerifierProxy public verifier;
    MockPyth public pyth;

    address public feeQuote;

    function setUp() public {
        feeQuote = makeAddr("feeQuote");
        calendar = new TradingCalendar(makeAddr("timelock"));
        verifier = new MockVerifierProxy();
        pyth = new MockPyth();
        pyth.setFee(PYTH_FEE);
        oracle = new SettlementOracle(
            address(verifier),
            address(pyth),
            address(calendar),
            FEED_ID,
            PYTH_ID,
            feeQuote,
            STREAM_DECIMALS,
            BAND_BPS,
            PYTH_DELAY
        );
        vm.warp(TARGET);
        vm.deal(address(this), 1 ether);
    }

    function test_SettlesTheDataStreamsPriceWhenBothSourcesAgree() public {
        (uint256 price18, uint256 deviationBps) = _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET));

        assertEq(price18, PRICE_18, "the settled price is not the Data Streams price");
        assertEq(deviationBps, NOTHING, "identical prices showed a deviation");
    }

    function test_FeesSplitBetweenPythAndTheVerifierAndNothingIsKept() public {
        _settle(_report(), _pythUpdate(PYTH_PRICE, TARGET));

        assertEq(pyth.received(), PYTH_FEE, "the pyth fee did not arrive");
        assertEq(verifier.received(), EXTRA, "the rest did not reach the verifier");
        assertEq(address(oracle).balance, NOTHING, "the oracle kept a balance");
        assertEq(abi.decode(verifier.lastParameterPayload(), (address)), feeQuote);
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

    /// @dev The Pyth side of rule 3 is our own calendar (r5.3), so a target on
    ///      a Saturday is refused even when the report claims the market open.
    function test_RefusesWhenTheCalendarSaysTheMarketIsClosed() public {
        ReportV8 memory report = _reportAt(SATURDAY);

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.MarketClosedByCalendar.selector, SATURDAY));
        _settleAt(SATURDAY, report, _pythUpdate(PYTH_PRICE, SATURDAY));
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
            address(verifier), address(pyth), address(calendar), FEED_ID, PYTH_ID, feeQuote, 8, BAND_BPS, PYTH_DELAY
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
        (price18, deviationBps) = eight.settlePrice{value: PYTH_FEE + EXTRA}(TARGET, payload, update);

        assertEq(price18, PRICE_18, "an 8 decimal stream did not scale to 18");
        assertEq(deviationBps, NOTHING, "identical prices showed a deviation");
    }

    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(SettlementOracle.ZeroAddress.selector);
        new SettlementOracle(
            address(0),
            address(pyth),
            address(calendar),
            FEED_ID,
            PYTH_ID,
            feeQuote,
            STREAM_DECIMALS,
            BAND_BPS,
            PYTH_DELAY
        );

        vm.expectRevert(SettlementOracle.ZeroId.selector);
        new SettlementOracle(
            address(verifier),
            address(pyth),
            address(calendar),
            bytes32(0),
            PYTH_ID,
            feeQuote,
            STREAM_DECIMALS,
            BAND_BPS,
            PYTH_DELAY
        );

        vm.expectRevert(abi.encodeWithSelector(SettlementOracle.BandTooWide.selector, BPS));
        new SettlementOracle(
            address(verifier),
            address(pyth),
            address(calendar),
            FEED_ID,
            PYTH_ID,
            feeQuote,
            STREAM_DECIMALS,
            BPS,
            PYTH_DELAY
        );

        vm.expectRevert(SettlementOracle.ZeroPythDelay.selector);
        new SettlementOracle(
            address(verifier),
            address(pyth),
            address(calendar),
            FEED_ID,
            PYTH_ID,
            feeQuote,
            STREAM_DECIMALS,
            BAND_BPS,
            0
        );
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
            lastUpdateTimestamp: target,
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
        return oracle.settlePrice{value: PYTH_FEE + EXTRA}(target, abi.encode(report), update);
    }
}
