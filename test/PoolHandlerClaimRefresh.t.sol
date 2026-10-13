// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../src/CounterpartyPool.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {IPositionBook} from "../src/interfaces/IPositionBook.sol";
import {PoolHandler} from "./handlers/PoolHandler.sol";

/// @notice Regression for the stale claim the pool campaign shrank to. A close
///         after a price move left the stand in book reporting a deposit claim
///         fixed at the pre close reserve, so I15b read a claim the pool never
///         owed. The handler now caps its claims at the live reserve in open
///         and close, so a claim can never sit above what the reserve allows.
contract PoolHandlerClaimRefreshTest is Test {
    uint256 private constant U_MAX_BPS = 8000;
    uint256 private constant EXPIRY = 300;
    uint256 private constant WAD = 1e18;

    CounterpartyPool private pool;
    PoolHandler private handler;

    function setUp() public {
        ReentrancyLock lock = new ReentrancyLock();
        handler = new PoolHandler(lock, U_MAX_BPS);
        pool = handler.POOL();
    }

    /// @dev The campaign's own sequence, replayed exactly: a settled deposit,
    ///      an open, a move to the ceiling price that sets the claim to the
    ///      reserve, then a close that frees most of the reserve. Before the
    ///      fix the claim stayed at the pre close reserve and the pool's ounces
    ///      fell under it; after it the claim follows the reserve down.
    function test_CloseAfterAMovePriceKeepsI15b() public {
        handler.requestDeposit(500000000000000001, 4455);
        handler.passTime(1657);
        handler.settle(61);
        handler.open(365, false);
        handler.movePrice(type(uint256).max);
        handler.close(2762e64, type(uint256).max);

        uint256 price = handler.price();
        uint256 claimOunces = (IPositionBook(address(handler.BOOK())).depositClaimUsd(price) * WAD) / price;
        assertGe(pool.ounces(), claimOunces, "I15b: a close after a move left a claim above pool ounces");
    }
}
