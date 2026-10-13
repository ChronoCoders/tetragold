// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolInvariants} from "./ProtocolInvariants.sol";
import {ProtocolHandler} from "./handlers/ProtocolHandler.sol";
import {TightProtocolHandler} from "./handlers/TightProtocolHandler.sol";

/// @notice The same invariants as ProtocolInvariantTest, run against a pool
///         held tight: one small LP deposit, a wide price band and a step mix
///         weighted toward adds. The base campaign keeps a deep pool, where the
///         reserve slack hides a claim that outgrew its notional; this one
///         leaves no slack, so I15b sees the shortfall a broken D46 lets in.
/// forge-config: default.invariant.fail-on-revert = true
contract TightProtocolInvariantTest is ProtocolInvariants {
    uint256 private constant SMALL_LP = 3 ether;
    uint256 private constant ADD_WEIGHT = 4;
    uint256 private constant TIGHT_SELECTORS = 10 + 2 * ADD_WEIGHT;

    function setUp() public {
        _deployProtocol();
        TightProtocolHandler tight = new TightProtocolHandler(manager, paxg, paxgReading, FEED_ID, PYTH_ID, PYTH_FEE);
        handler = tight;

        tight.lpDeposit(0, SMALL_LP);

        bytes4[] memory selectors = new bytes4[](TIGHT_SELECTORS);
        selectors[0] = ProtocolHandler.requestOpen.selector;
        selectors[1] = ProtocolHandler.settleOpen.selector;
        selectors[2] = ProtocolHandler.passTime.selector;
        selectors[3] = TightProtocolHandler.moveWidePrice.selector;
        selectors[4] = ProtocolHandler.expireOpen.selector;
        selectors[5] = ProtocolHandler.dustTheOracle.selector;
        selectors[6] = ProtocolHandler.requestClose.selector;
        selectors[7] = ProtocolHandler.settleClose.selector;
        selectors[8] = ProtocolHandler.expireClose.selector;
        selectors[9] = ProtocolHandler.expireAdd.selector;
        for (uint256 i = 0; i < ADD_WEIGHT; i++) {
            selectors[10 + i] = ProtocolHandler.requestAdd.selector;
            selectors[10 + ADD_WEIGHT + i] = ProtocolHandler.settleAdd.selector;
        }
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }
}
