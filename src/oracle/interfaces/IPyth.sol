// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IPyth
 * @notice The part of Pyth this protocol calls, copied from upstream rather
 *         than imported, so the repository takes on no new dependency.
 * @dev Declarations copied from pyth-crosschain@709e742:
 *      `target_chains/ethereum/sdk/solidity/IPyth.sol:93-95` for
 *      `getUpdateFee`, `:204-209` for `parsePriceFeedUpdatesUnique`, and
 *      `target_chains/ethereum/sdk/solidity/PythStructs.sol:13-31` for both
 *      structs. Upstream writes `uint` where this writes `uint256`, which is
 *      the same type under another spelling.
 *
 *      Why the unique variant: the implementation accepts an update only when
 *      its publish time is at or after minPublishTime, at or before
 *      maxPublishTime, and the previous publish time is before minPublishTime
 *      (`target_chains/ethereum/contracts/contracts/pyth/Pyth.sol:242-245`).
 *      That is what makes the update for a target time the first one at or
 *      after it, with no choice left to the caller (section 7 rule 2).
 *
 *      The structs are declared inside this interface rather than in a
 *      `PythStructs` contract. A struct's ABI encoding follows its field types
 *      and order, not where it is declared, and the interface test holds this
 *      copy to the upstream layout.
 */
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    struct PriceFeed {
        bytes32 id;
        Price price;
        Price emaPrice;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PriceFeed[] memory priceFeeds);
}
