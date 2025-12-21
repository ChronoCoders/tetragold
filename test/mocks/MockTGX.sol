// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTGX
 * @notice Mock Tetra Gold Governance token for testing
 */
contract MockTGX is ERC20 {
    constructor() ERC20("Tetra Gold Governance", "TGX") {
        _mint(msg.sender, 100_000_000 * 10 ** 18); // 100M total supply
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
