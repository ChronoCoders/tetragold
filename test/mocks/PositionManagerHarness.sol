// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClaimBook} from "../../src/libraries/ClaimBook.sol";
import {PositionManager} from "../../src/PositionManager.sol";

/// @notice Reaches the manager's internal paths while no public path leads to
///         them yet.
/// @dev The open and close paths will maintain the claim book and advance the
///      index. Until they exist this plants a position set and drives an
///      advance directly, so the claim measures and the index view are tested
///      against real state rather than against an empty book.
contract PositionManagerHarness is PositionManager {
    using ClaimBook for ClaimBook.Book;

    constructor(Config memory config) PositionManager(config) {}

    function pokeAdvance() external {
        _advance();
    }

    function pokeRequireSharesExist() external view {
        _requireSharesExist();
    }

    function recordPosition(uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) external {
        _book.add(size, claim, openPrice, openIndex);
    }

    function dropPosition(uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex) external {
        _book.remove(size, claim, openPrice, openIndex);
    }
}
