// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title AutomationCompatibleInterface
 * @dev Interface for Chainlink Automation (formerly Keepers)
 */
interface AutomationCompatibleInterface {
    /**
     * @notice Checks if upkeep is needed
     * @param checkData Data passed to the function (can be used for custom logic)
     * @return upkeepNeeded Boolean indicating if upkeep is needed
     * @return performData Data to be passed to performUpkeep
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice Performs the upkeep
     * @param performData Data from checkUpkeep
     */
    function performUpkeep(bytes calldata performData) external;
}
