// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC20 that burns part of every transfer between accounts.
/// @dev Stands in for a PAXG that starts charging a transfer fee, which is the
///      case 4.1 measures a deposit by balance difference to survive.
contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public feeBps;

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (amount * feeBps) / BPS_DENOMINATOR;
            super._update(from, address(0), fee);
            super._update(from, to, amount - fee);
            return;
        }
        super._update(from, to, amount);
    }
}
