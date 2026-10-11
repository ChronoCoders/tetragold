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
 *
 *      No minimum on any amount (4.4, revised r6.4). A minimum made the
 *      protocol's own small payments impossible: the keeper fee, residual
 *      equity under a gram after a liquidation and small pool withdrawals all
 *      move amounts that a floor would refuse.
 */
contract TGAUX is ERC20 {
    /// @notice The only account that may mint or burn.
    address public immutable VAULT;

    /// @notice Decimals of this token, fixed at the ERC20 default.
    uint8 private constant DECIMALS = 18;

    /// @notice The caller is not the vault.
    error NotVault(address caller);

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
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` against PAXG the vault releases.
    /// @dev No allowance: the vault is the only caller, so one would add
    ///      nothing.
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
}
