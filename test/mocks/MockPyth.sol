// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPyth} from "../../src/oracle/interfaces/IPyth.sol";

/// @notice Stands in for the Pyth contract on Ethereum.
/// @dev It enforces the publish time window the real implementation enforces
///      (`Pyth.sol:242-245` in pyth-crosschain, commit 709e742), because the
///      consumer leans on that window for the uniqueness of the update for T.
///      A mock
///      that accepted anything would leave that reliance untested.
// It is paid like the real contract and never pays out, which is all a test
// needs from it.
// forge-lint: disable-next-line(locked-ether)
contract MockPyth is IPyth {
    uint256 public fee;
    uint256 public received;

    error PriceFeedNotFoundWithinRange();

    function setFee(uint256 newFee) external {
        fee = newFee;
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return fee;
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (IPyth.PriceFeed[] memory feeds) {
        received += msg.value;
        feeds = new IPyth.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            IPyth.PriceFeed memory feed = abi.decode(updateData[i], (IPyth.PriceFeed));
            if (feed.price.publishTime < minPublishTime || feed.price.publishTime > maxPublishTime) {
                // The real implementation refuses the whole call when a
                // requested feed has no update inside the window, so the revert
                // belongs inside the loop here too.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert PriceFeedNotFoundWithinRange();
            }
            feeds[i] = feed;
        }
    }
}
