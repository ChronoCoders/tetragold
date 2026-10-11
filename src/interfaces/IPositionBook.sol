// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPositionBook
/// @notice The two claim measures of D48, read by the counterparty pool to
///         value its shares, plus the pool's own view of who may drive it.
/// @dev The position manager implements this and deploys the pool, so the pool
///      holds one address for both roles and needs no setter. The pool never
///      iterates positions itself: the book owns the position set and answers
///      with a single USD total at the price it is given (D48, D55).
///
///      Both measures are sums over open positions at `price18`, in USD scaled
///      by 1e18. They differ only in the claim each position contributes, and
///      the withdrawal measure is never the smaller of the two, which is what
///      keeps I6 true.
interface IPositionBook {
    /// @notice Sum of max(0, equity_i) at `price18`, the measure a deposit is
    ///         priced against (D48 high side).
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    function depositClaimUsd(uint256 price18) external view returns (uint256);

    /// @notice Sum of max(0, equity_i, C_i - fees_i) at `price18`, the measure a
    ///         withdrawal is priced against (D48 low side). It does not count a
    ///         trader's unrealised loss until the loss is realised, so it is at
    ///         least the deposit measure and the value it yields is at most the
    ///         deposit value (I6).
    /// @param price18 Settled price, USD per ounce, scaled by 1e18.
    function withdrawalClaimUsd(uint256 price18) external view returns (uint256);
}
