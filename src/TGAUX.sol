// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TGAUX
 * @notice A gold token backed one to one by PAXG held in the TGAUX vault.
 * @dev One TGAUX is one troy ounce of PAXG that the vault holds. It tracks PAXG,
 *      not an oracle price, and nothing here reads a price (D1).
 *
 *      The vault deploys this token in its own constructor, so VAULT is the
 *      deployer and is immutable. Only the vault mints and burns, against PAXG
 *      deposited or released, and there is no role, no admin, no transfer pause
 *      and no setter of any kind (D26). Supply can therefore change only through
 *      the vault, and transfers cannot be stopped by anyone.
 */
contract TGAUX is ERC20 {
    /// @notice The only account that may mint or burn.
    address public immutable VAULT;

    /// @notice Minimum amount to mint or transfer: 0.03215 TGAUX, which is
    ///         1.0000 g at 31.1035 g per troy ounce (4.4).
    uint256 public constant MINIMUM_TRANSFER_AMOUNT = 32_150_000_000_000_000;

    /// @notice Decimals of this token, fixed at the ERC20 default.
    uint8 private constant DECIMALS = 18;

    /// @notice The caller is not the vault.
    error NotVault(address caller);

    /// @notice The amount is under the minimum and is not a whole balance.
    error BelowMinimum(uint256 amount);

    /// @dev The deployer is the vault, which removes the misconfiguration a
    ///      constructor argument would allow and leaves nothing to set later.
    constructor() ERC20("Tetra Gold", "TGAUX") {
        VAULT = msg.sender;
    }

    /// @notice Mint `amount` to `to` against PAXG the vault received.
    function mint(address to, uint256 amount) external {
        if (msg.sender != VAULT) {
            revert NotVault(msg.sender);
        }
        if (amount < MINIMUM_TRANSFER_AMOUNT) {
            revert BelowMinimum(amount);
        }
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` against PAXG the vault releases.
    /// @dev No minimum and no allowance. The vault applies the withdraw minimum
    ///      and its whole balance exception (4.4) before it calls this, and the
    ///      vault is the only caller, so an allowance would add nothing.
    function burn(address from, uint256 amount) external {
        if (msg.sender != VAULT) {
            revert NotVault(msg.sender);
        }
        _burn(from, amount);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @dev A mint or a burn carries any amount, because the vault decides it.
    ///      A transfer between accounts carries at least the minimum, unless it
    ///      moves the sender's whole balance, so a holder left below the minimum
    ///      can still leave the token (4.4).
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount < MINIMUM_TRANSFER_AMOUNT && amount != balanceOf(from)) {
            revert BelowMinimum(amount);
        }
        super._update(from, to, amount);
    }
}
