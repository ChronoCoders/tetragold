// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockLiquidityPool
 * @dev Mock liquidity pool for testing VaultManager
 */
contract MockLiquidityPool {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public totalBorrowed;
    bool public shouldFailBorrow;

    event Borrowed(uint256 amount, address indexed token);
    event Repaid(uint256 amount, address indexed token);

    /**
     * @dev Borrows tokens (transfers to caller)
     * @param amount Amount to borrow
     * @param token Token address
     */
    function borrow(uint256 amount, address token) external {
        require(!shouldFailBorrow, "MockLiquidityPool: borrow failed");
        totalBorrowed[token] += amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Borrowed(amount, token);
    }

    /**
     * @dev Deposits tokens to the pool (for testing)
     * @param amount Amount to deposit
     * @param token Token address
     */
    function deposit(uint256 amount, address token) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Sets whether borrows should fail
     * @param _shouldFail True to make borrows fail
     */
    function setShouldFailBorrow(bool _shouldFail) external {
        shouldFailBorrow = _shouldFail;
    }

    /**
     * @dev Receives repayment (automatically called when tokens are transferred)
     */
    receive() external payable {}
}
