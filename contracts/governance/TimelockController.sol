// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TetraGoldTimelock
 * @dev Timelock controller for TetraGold governance with 48-hour delay
 */
contract TetraGoldTimelock is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours; // 48-hour minimum delay
    uint256 public constant MAX_DELAY = 30 days;  // 30-day maximum delay

    constructor(
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(MIN_DELAY, proposers, executors, admin) {
        // Constructor automatically sets up the timelock with minimum delay
    }

    /**
     * @dev Override to enforce minimum and maximum delay constraints
     */
    function updateDelay(uint256 newDelay) external override {
        require(newDelay >= MIN_DELAY, "Delay too short");
        require(newDelay <= MAX_DELAY, "Delay too long");
        super.updateDelay(newDelay);
    }
}