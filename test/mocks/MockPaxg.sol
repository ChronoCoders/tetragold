// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPaxg} from "../../src/interfaces/IPaxg.sol";

/// @notice Stands in for PAXG's two D50 readings.
/// @dev It implements the interface the manager holds, so a change to that
///      interface breaks this mock rather than letting it drift.
contract MockPaxg is IPaxg {
    mapping(address account => bool frozen) private _frozen;
    bool private _paused;

    function setFrozen(address account, bool frozen) external {
        _frozen[account] = frozen;
    }

    function setPaused(bool paused_) external {
        _paused = paused_;
    }

    function isFrozen(address who) external view returns (bool) {
        return _frozen[who];
    }

    function paused() external view returns (bool) {
        return _paused;
    }
}
