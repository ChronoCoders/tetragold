// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPaxg} from "../mocks/MockPaxg.sol";
import {PositionManagerHarness} from "../mocks/PositionManagerHarness.sol";
import {ProtocolHandler} from "./ProtocolHandler.sol";

/// @notice ProtocolHandler with a wider price swing and a shorter time step.
///         The fall between an add and the payout is what turns a claim that
///         outgrew its notional into a shortfall the pool cannot cover, and the
///         3000 to 5000 band of the base handler is too narrow to open that gap
///         against the reserve slack. The 1 to 1200 second step, passed as the
///         base handler's maxStep, keeps a request inside its settle window so
///         an add actually settles; the base handler's 1 to 7 day step almost
///         never lands there. Everything else, the escrow, the oracle, the
///         ghosts, is the base handler unchanged.
contract TightProtocolHandler is ProtocolHandler {
    uint256 private constant WIDE_MIN_PRICE = 1500e18;
    uint256 private constant WIDE_MAX_PRICE = 6000e18;
    uint256 private constant SHORT_STEP = 1200;

    constructor(
        PositionManagerHarness manager,
        MockERC20 paxg,
        MockPaxg paxgReading,
        bytes32 feedId,
        bytes32 pythId,
        uint256 pythFee
    ) ProtocolHandler(manager, paxg, paxgReading, feedId, pythId, pythFee, SHORT_STEP) {}

    function moveWidePrice(uint256 seed) external {
        price = bound(seed, WIDE_MIN_PRICE, WIDE_MAX_PRICE);
        _check();
    }
}
