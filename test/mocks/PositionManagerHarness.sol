// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ClaimBook} from "../../src/libraries/ClaimBook.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {ReentrancyLock} from "../../src/ReentrancyLock.sol";

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

    /// @notice Make an LP deposit request on the pool, the way the manager's
    ///         own LP request path will (D69).
    /// @dev The pool takes requests from this contract alone, and the LP facing
    ///      half of that lives in a later unit. Until it exists these two are
    ///      how a test gives the pool ounces and shares, which the empty pool
    ///      rule of D48 requires before any position can open. They are two
    ///      calls rather than one because the pool's target time has to pass
    ///      between them and only the test can move the clock.
    function seedRequest(address lp, uint256 ounces) external returns (uint256 id) {
        ReentrancyLock lock = LOCK;

        lock.enter();
        id = POOL.requestDeposit(lp, ounces);
        lock.exit();
    }

    /// @notice Credit gold that arrived at the insurance fund, which the fee
    ///         routing does for itself and a test needs to do to fill the fund
    ///         past its target.
    function pokeSyncFund() external returns (uint256 credited) {
        ReentrancyLock lock = LOCK;

        lock.enter();
        credited = INSURANCE_FUND.syncCredit();
        lock.exit();
    }

    /// @notice Set the two position flags that the close and the liquidation
    ///         paths will set, so the rules reading them can be tested before
    ///         those paths exist (D43 rule 3, D43 rule 4).
    function pokeFlags(uint256 positionId, bool exitPending, bool flagged) external {
        Position storage position = _positions[positionId];
        position.exitPending = exitPending;
        position.flagged = flagged;
    }

    /// @notice Write a position straight into the manager, so a test can put
    ///         one exactly on a rule's edge.
    /// @dev The open path cannot reach every state: s, C and the fee index all
    ///      come out of one settled price together. This writes no claim book
    ///      entry, so it is for reading the position rules and nothing else.
    function pokePosition(address owner, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex)
        external
        returns (uint256 positionId)
    {
        positionId = nextPositionId;
        nextPositionId = positionId + 1;
        _positions[positionId] = Position({
            owner: owner,
            size: size,
            claim: claim,
            openPrice: openPrice,
            openIndex: openIndex,
            open: true,
            exitPending: false,
            flagged: false
        });
    }

    /// @notice Take a position off the books the way a close will, so a
    ///         settlement against a position that is gone can be tested.
    function pokeClose(uint256 positionId) external {
        _positions[positionId].open = false;
    }

    function seedSettle(uint256 id, uint256 price18) external returns (uint256 shares) {
        ReentrancyLock lock = LOCK;

        lock.enter();
        (shares,) = POOL.settleDeposit(id, price18);
        lock.exit();
    }
}
