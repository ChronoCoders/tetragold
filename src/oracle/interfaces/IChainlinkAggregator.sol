// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IChainlinkAggregator
 * @notice The part of a Chainlink push feed the D22 fallback reads, copied from
 *         upstream rather than imported.
 * @dev Copied from chainlink-evm@b723176,
 *      `contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol:6` and
 *      `:16-19`. Upstream calls it `AggregatorV3Interface` and carries a lint
 *      disable for the missing prefix; the name here takes the prefix instead.
 *
 *      Used for the Ethereum XAU/USD feed, which updates on a 0.3% move or
 *      every 86400 seconds (11.4). The fallback bounds the round's age itself,
 *      because neither value is enforced on chain.
 */
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
