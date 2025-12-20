// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockAavePool
 * @notice Mock Aave V3 Pool for testing InsuranceFund yield generation
 */
contract MockAavePool {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public supplied;
    mapping(address => uint256) public yieldRate; // Basis points per call (e.g., 10 = 0.1%)

    event Supply(address indexed asset, uint256 amount, address indexed onBehalfOf);
    event Withdraw(address indexed asset, uint256 amount, address indexed to);

    /**
     * @notice Supply assets to the pool
     * @param asset Asset to supply
     * @param amount Amount to supply
     * @param onBehalfOf Address that will receive the aTokens
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /* referralCode */)
        external
    {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        supplied[asset] += amount;
        emit Supply(asset, amount, onBehalfOf);
    }

    /**
     * @notice Withdraw assets from the pool
     * @param asset Asset to withdraw
     * @param amount Amount to withdraw
     * @param to Address that will receive the assets
     * @return Amount withdrawn (including yield)
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(supplied[asset] >= amount, "MockAavePool: insufficient liquidity");

        // Calculate yield earned
        uint256 yield = (amount * yieldRate[asset]) / 10000;
        uint256 totalWithdrawal = amount + yield;

        supplied[asset] -= amount;

        // Transfer principal + yield
        IERC20(asset).safeTransfer(to, totalWithdrawal);

        emit Withdraw(asset, totalWithdrawal, to);
        return totalWithdrawal;
    }

    /**
     * @notice Set yield rate for testing (basis points per withdrawal)
     * @param asset Asset address
     * @param rate Yield rate in basis points (e.g., 100 = 1%)
     */
    function setYieldRate(address asset, uint256 rate) external {
        yieldRate[asset] = rate;
    }

    /**
     * @notice Get supplied balance for an asset
     * @param asset Asset address
     * @return Supplied balance
     */
    function getSupplied(address asset) external view returns (uint256) {
        return supplied[asset];
    }

    /**
     * @notice Fund the pool with tokens for yield payouts
     * @param asset Asset address
     * @param amount Amount to fund
     */
    function fundPool(address asset, uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }
}
