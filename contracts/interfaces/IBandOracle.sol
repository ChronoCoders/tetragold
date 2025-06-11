// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IBandOracle
 * @dev Interface for Band Protocol price feed integration
 */
interface IBandOracle {
    struct ReferenceData {
        uint256 rate; // base/quote exchange rate, multiplied by 1e18
        uint256 lastUpdatedBase; // UNIX epoch of the last time when base price gets updated
        uint256 lastUpdatedQuote; // UNIX epoch of the last time when quote price gets updated
    }

    /**
     * @dev Returns the price data for the given base/quote pair
     * @param base the base symbol as a string
     * @param quote the quote symbol as a string
     * @return ReferenceData struct containing rate and timestamps
     */
    function getReferenceData(string memory base, string memory quote)
        external
        view
        returns (ReferenceData memory);

    /**
     * @dev Similar to getReferenceData but for multiple base/quote pairs
     * @param bases array of base symbols
     * @param quotes array of quote symbols
     * @return array of ReferenceData structs
     */
    function getReferenceDataBulk(string[] memory bases, string[] memory quotes)
        external
        view
        returns (ReferenceData[] memory);
}