// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "./MockERC20.sol";
import {TgauxVault} from "../../src/TgauxVault.sol";

/// @notice A PAXG that calls back into the vault from inside its own transfer.
/// @dev D31 asks for a reentrancy guard. This is how the guard is shown to
///      hold: the callback is made where a hostile token would make it, and the
///      mock records whether the vault refused.
contract ReenteringPaxg is MockERC20 {
    TgauxVault public vault;
    bool public reentryRefused;
    bool public reentryTried;

    constructor(string memory name, string memory symbol, uint8 decimals_) MockERC20(name, symbol, decimals_) {}

    function arm(TgauxVault target) external {
        vault = target;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(vault) != address(0)) {
            reentryTried = true;
            try vault.deposit(value) {
                reentryRefused = false;
            } catch {
                reentryRefused = true;
            }
        }
        return super.transferFrom(from, to, value);
    }
}
