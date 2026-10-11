// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The one call the pre revision 6 insurance fund made into a position
///         contract.
/// @dev Orphaned by the revision 6 fund, which reads no total value locked and
///      has no position contract dependency. Kept in place rather than deleted.
contract MockVaultManagerTL {
    function getTotalValueLocked() external pure returns (uint256) {
        return 0;
    }
}
