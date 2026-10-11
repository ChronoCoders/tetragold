// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IChainlinkAggregator} from "../src/oracle/interfaces/IChainlinkAggregator.sol";
import {IPyth} from "../src/oracle/interfaces/IPyth.sol";
import {IVerifierProxy} from "../src/oracle/interfaces/IVerifierProxy.sol";

/// @notice Holds the local copies of three upstream interfaces to the upstream
///         wire format, which is the only part of them this protocol relies on.
/// @dev A local copy can drift from the contract it names, and the drift is
///      silent: the call just reverts on a chain nobody tests against. These
///      tests pin the selectors and the one struct layout that is decoded, so
///      an edit to a parameter type fails here instead.
contract OracleInterfacesTest is Test {
    /// @dev Found in the bytecode of the Pyth implementation on Ethereum,
    ///      0x3f38404a2e3cb949bcdfa19a5c3bdf3fe375feb0 (spec 11.10), and
    ///      recomputed from the signature here.
    bytes4 private constant PARSE_UNIQUE_SELECTOR = 0xaccca7f9;
    bytes4 private constant GET_UPDATE_FEE_SELECTOR = 0xd47eed45;
    bytes4 private constant VERIFY_SELECTOR = 0xf7e83aee;
    bytes4 private constant LATEST_ROUND_DATA_SELECTOR = 0xfeaf968c;

    function test_SelectorsMatchUpstream() public pure {
        assertEq(
            IPyth.parsePriceFeedUpdatesUnique.selector,
            PARSE_UNIQUE_SELECTOR,
            "parsePriceFeedUpdatesUnique(bytes[],bytes32[],uint64,uint64)"
        );
        assertEq(IPyth.getUpdateFee.selector, GET_UPDATE_FEE_SELECTOR, "getUpdateFee(bytes[])");
        assertEq(IVerifierProxy.verify.selector, VERIFY_SELECTOR, "verify(bytes,bytes)");
        assertEq(IChainlinkAggregator.latestRoundData.selector, LATEST_ROUND_DATA_SELECTOR, "latestRoundData()");
    }

    /// @dev The returned PriceFeed is decoded by the compiler from this local
    ///      copy, so a field of the wrong type or in the wrong order would read
    ///      another field's bytes. This compares the struct's encoding against
    ///      the flat tuple upstream declares: id, then price and emaPrice as
    ///      (int64, uint64, int32, uint256) each. Every value is named, so the
    ///      two sides cannot drift into agreement through a copied literal.
    function test_PriceFeedLayoutMatchesUpstream() public pure {
        bytes32 id = bytes32(uint256(0xfeed));
        int64 price = -1234;
        uint64 conf = 7;
        int32 expo = -8;
        uint256 publishTime = 1_760_000_000;
        int64 emaPrice = 4321;
        uint64 emaConf = 9;
        int32 emaExpo = -5;
        uint256 emaPublishTime = 1_760_000_012;

        IPyth.PriceFeed memory feed = IPyth.PriceFeed({
            id: id,
            price: IPyth.Price({price: price, conf: conf, expo: expo, publishTime: publishTime}),
            emaPrice: IPyth.Price({price: emaPrice, conf: emaConf, expo: emaExpo, publishTime: emaPublishTime})
        });

        bytes memory flat = abi.encode(id, price, conf, expo, publishTime, emaPrice, emaConf, emaExpo, emaPublishTime);

        assertEq(abi.encode(feed), flat, "the PriceFeed layout drifted from upstream");
    }
}
