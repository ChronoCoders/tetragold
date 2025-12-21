// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LPToken
 * @dev ERC20 token representing liquidity provider shares in a pool
 */
contract LPToken is ERC20 {
    address public immutable liquidityPool;

    error LPToken__OnlyPool();

    modifier onlyPool() {
        if (msg.sender != liquidityPool) revert LPToken__OnlyPool();
        _;
    }

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        liquidityPool = msg.sender;
    }

    /**
     * @dev Mints LP tokens to an address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /**
     * @dev Burns LP tokens from an address
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external onlyPool {
        _burn(from, amount);
    }
}
