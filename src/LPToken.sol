// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LPToken
 * @notice Share token of the counterparty pool: one holding is a claim on the
 *         pool's ounces, valued per D48.
 * @dev The pool deploys this in its own constructor, so the pool is the
 *      immutable minter and burner and there is no role, no admin and no
 *      setter. Supply can change only through the pool.
 */
contract LPToken is ERC20 {
    /// @notice The only account that may mint or burn.
    address public immutable LIQUIDITY_POOL;

    /// @notice The caller is not the pool.
    error LPToken__OnlyPool();

    modifier onlyPool() {
        _onlyPool();
        _;
    }

    constructor(string memory tokenName, string memory tokenSymbol) ERC20(tokenName, tokenSymbol) {
        LIQUIDITY_POOL = msg.sender;
    }

    /// @notice Mint `amount` shares to `to`.
    /// @param to Recipient of the shares.
    /// @param amount Shares to mint.
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /// @notice Burn `amount` shares from `from`.
    /// @param from Account to burn from.
    /// @param amount Shares to burn.
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }

    /// @dev The check lives in a function rather than in the modifier body so
    ///      that it is one jump at each use site instead of a second copy of
    ///      the comparison and the revert.
    function _onlyPool() private view {
        if (msg.sender != LIQUIDITY_POOL) {
            revert LPToken__OnlyPool();
        }
    }
}
