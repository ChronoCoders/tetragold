// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title MockBandOracle
 * @dev Mock implementation of Band Protocol oracle for testing
 */
contract MockBandOracle {
    struct ReferenceData {
        uint256 rate;
        uint256 lastUpdatedBase;
        uint256 lastUpdatedQuote;
    }

    mapping(string => mapping(string => ReferenceData)) private referenceData;
    
    event ReferenceDataUpdated(
        string indexed base,
        string indexed quote,
        uint256 rate,
        uint256 lastUpdatedBase,
        uint256 lastUpdatedQuote
    );

    constructor(uint256 _initialPrice) {
        // Initialize XAU/USD pair
        referenceData["XAU"]["USD"] = ReferenceData({
            rate: _initialPrice,
            lastUpdatedBase: block.timestamp,
            lastUpdatedQuote: block.timestamp
        });
    }

    function getReferenceData(string memory base, string memory quote)
        external
        view
        returns (ReferenceData memory)
    {
        return referenceData[base][quote];
    }

    function getReferenceDataBulk(string[] memory bases, string[] memory quotes)
        external
        view
        returns (ReferenceData[] memory)
    {
        require(bases.length == quotes.length, "Array length mismatch");
        
        ReferenceData[] memory results = new ReferenceData[](bases.length);
        for (uint256 i = 0; i < bases.length; i++) {
            results[i] = referenceData[bases[i]][quotes[i]];
        }
        
        return results;
    }

    // Test helper functions
    function updateReferenceData(
        string memory base,
        string memory quote,
        uint256 rate
    ) external {
        referenceData[base][quote] = ReferenceData({
            rate: rate,
            lastUpdatedBase: block.timestamp,
            lastUpdatedQuote: block.timestamp
        });
        
        emit ReferenceDataUpdated(base, quote, rate, block.timestamp, block.timestamp);
    }

    function simulatePriceMovement(
        string memory base,
        string memory quote,
        uint256 basePrice,
        uint256 maxVariation
    ) external {
        // Generate pseudo-random price movement
        uint256 variation = uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty))) % (maxVariation * 2);
        uint256 newPrice;
        
        if (variation > maxVariation) {
            newPrice = basePrice + (variation - maxVariation);
        } else {
            newPrice = basePrice > variation ? basePrice - variation : basePrice;
        }
        
        updateReferenceData(base, quote, newPrice);
    }
}