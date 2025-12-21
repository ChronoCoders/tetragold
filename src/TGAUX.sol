// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TGAUX
 * @dev Tetra Gold token implementation
 *
 * Token represents ownership of physical gold:
 * - 1 TGAUX = 1 troy ounce of gold = 31.1035 grams
 * - Minimum transferable amount: 0.03215 TGAUX (approximately 1 gram)
 *
 * Features:
 * - ERC-20 standard with 18 decimals
 * - Dynamic supply (minted on-demand by authorized VaultManager)
 * - Burnable (users can burn their own tokens)
 * - Pausable (emergency stop functionality)
 * - Non-upgradeable (immutable for security)
 * - Access control for minting and pausing operations
 */
contract TGAUX is ERC20, ERC20Burnable, ERC20Pausable, AccessControl {
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Minimum transfer amount: 0.03215 TGAUX (1 gram equivalent)
    // 1 troy ounce = 31.1035 grams
    // 1 gram = 1/31.1035 troy ounce = 0.03215 TGAUX
    uint256 public constant MINIMUM_TRANSFER_AMOUNT = 32_150_000_000_000_000; // 0.03215 * 10^18

    // Custom events
    event Minted(address indexed to, uint256 amount, address indexed minter);
    event Burned(address indexed from, uint256 amount);

    /**
     * @dev Constructor sets up roles and token metadata
     * @param defaultAdmin Address that will be granted DEFAULT_ADMIN_ROLE
     */
    constructor(address defaultAdmin) ERC20("Tetra Gold", "TGAUX") {
        require(defaultAdmin != address(0), "TGAUX: default admin cannot be zero address");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
    }

    /**
     * @dev Mints new tokens to a specified address
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint (in wei, 18 decimals)
     *
     * Requirements:
     * - Caller must have MINTER_ROLE
     * - Amount must be at least MINIMUM_TRANSFER_AMOUNT
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(amount >= MINIMUM_TRANSFER_AMOUNT, "TGAUX: amount below minimum");
        require(to != address(0), "TGAUX: mint to zero address");

        _mint(to, amount);
        emit Minted(to, amount, msg.sender);
    }

    /**
     * @dev Burns tokens from the caller's account
     * @param amount Amount of tokens to burn
     *
     * Overrides ERC20Burnable to add custom event
     */
    function burn(uint256 amount) public override {
        super.burn(amount);
        emit Burned(msg.sender, amount);
    }

    /**
     * @dev Burns tokens from a specified account with allowance
     * @param account Account to burn tokens from
     * @param amount Amount of tokens to burn
     *
     * Overrides ERC20Burnable to add custom event
     */
    function burnFrom(address account, uint256 amount) public override {
        super.burnFrom(account, amount);
        emit Burned(account, amount);
    }

    /**
     * @dev Pauses all token transfers
     *
     * Requirements:
     * - Caller must have PAUSER_ROLE
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers
     *
     * Requirements:
     * - Caller must have PAUSER_ROLE
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Enforces minimum transfer amount
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param amount Amount being transferred
     *
     * Overrides ERC20 transfer hook to enforce minimum transfer amount
     * Exception: Allows transfers of exact balance (to enable complete withdrawals)
     */
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Minting and burning can be any amount (handled in mint function and burn is user's choice)
        // For transfers, enforce minimum unless transferring entire balance
        if (from != address(0) && to != address(0)) {
            // Allow transfer of full balance even if below minimum
            if (amount < MINIMUM_TRANSFER_AMOUNT && amount != balanceOf(from)) {
                revert("TGAUX: transfer amount below minimum");
            }
        }

        super._update(from, to, amount);
    }

    /**
     * @dev Returns the number of decimals used for token amounts
     * @return uint8 Number of decimals (18)
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC165-supportsInterface}
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
