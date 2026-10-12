// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FeeIndex} from "../../src/libraries/FeeIndex.sol";

/// @notice Holds one fee index in storage and exposes the library over it.
/// @dev The library is internal, so it needs a contract to live in, and keeping
///      the index behind external calls is what lets the gas test measure one
///      operation at a time and the campaign drive it.
contract FeeIndexHarness {
    using FeeIndex for FeeIndex.Index;

    FeeIndex.Index private _index;
    FeeIndex.Params private _params;

    constructor(FeeIndex.Params memory curve, uint256 asOf) {
        FeeIndex.validate(curve);
        _params = curve;
        _index.start(asOf);
    }

    function advance(uint256 reserved, uint256 poolOunces, uint256 asOf) external returns (uint256) {
        return _index.advance(reserved, poolOunces, _params, asOf);
    }

    function rate(uint256 reserved, uint256 poolOunces) external view returns (uint256) {
        return FeeIndex.rate(reserved, poolOunces, _params);
    }

    function increment(uint256 rateValue, uint256 elapsed) external pure returns (uint256) {
        return FeeIndex.increment(rateValue, elapsed);
    }

    function value() external view returns (uint256) {
        return _index.value;
    }

    function lastAdvance() external view returns (uint256) {
        return _index.lastAdvance;
    }

    function params() external view returns (FeeIndex.Params memory) {
        return _params;
    }
}
