// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPaxg
/// @notice The two PAXG calls D50 reads to decide whether PAXG is usable,
///         copied rather than imported.
/// @dev Both are in the deployed implementation behind the PAXG proxy at
///      0x45804880De22913dAFE09f4980848ECE6EcbAf78. The implementation bytecode
///      at block 26166268 carries the selectors `isFrozen(address)` 0xe5839836
///      and `paused()` 0x5c975abb, and both were called successfully, returning
///      false (spec 11.7). The signatures here were checked against those two
///      selectors rather than taken from a document: `cast sig` gives
///      0xe5839836 and 0x5c975abb for exactly these two declarations. Paxos
///      names the first in its own README ("The list of frozen addresses is
///      available in isFrozen(address who)").
///
///      PAXG is upgradeable through a proxy admin with a 24 hour minimum delay
///      (11.7), so these two could change. That is watched rather than assumed
///      away (D58 rule 4), and a reading that reverts is treated as unusable by
///      the caller rather than as usable.
interface IPaxg {
    /// @notice Whether Paxos has frozen `who`.
    function isFrozen(address who) external view returns (bool);

    /// @notice Whether all PAXG transfers are paused.
    function paused() external view returns (bool);
}
