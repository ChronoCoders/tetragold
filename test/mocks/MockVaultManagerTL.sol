// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVaultManager} from "../../src/InsuranceFund.sol";

/// @notice The one call the insurance fund makes into a position contract.
/// @dev Zero total value locked, which is what the timelock test needs: it
///      exercises parameter changes, not coverage arithmetic.
contract MockVaultManagerTL is IVaultManager {
    function getTotalValueLocked() external pure returns (uint256) {
        return 0;
    }
}
