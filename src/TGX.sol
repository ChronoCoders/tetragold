// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TGX
 * @dev Tetra Gold governance and fee-sharing token.
 *
 * Supply model:
 * - Hard cap: 100,000,000 TGX
 * - 100% minted at deployment to the treasury multisig
 * - No post-genesis minting — the treasury distributes to vesting and
 *   emissions contracts after deployment
 *
 * Utility:
 * - Stake in FeeDistributor to earn 30% of protocol fee revenue (USDC/USDT)
 * - Governance weight over protocol parameters via company multisig + timelock
 */
contract TGX is ERC20, ERC20Burnable, AccessControl {
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    error TGX__ZeroAddress();

    event GenesisAllocation(address indexed treasury, uint256 amount);

    /**
     * @param defaultAdmin Address granted DEFAULT_ADMIN_ROLE (company multisig)
     * @param treasury     Address receiving the full 100,000,000 TGX genesis mint
     */
    constructor(address defaultAdmin, address treasury) ERC20("Tetra Gold Governance", "TGX") {
        if (defaultAdmin == address(0)) revert TGX__ZeroAddress();
        if (treasury == address(0)) revert TGX__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        _mint(treasury, MAX_SUPPLY);
        emit GenesisAllocation(treasury, MAX_SUPPLY);
    }

    /**
     * @dev Prevents DEFAULT_ADMIN_ROLE from being renounced, which would
     *      permanently remove the ability to manage protocol governance.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        require(role != DEFAULT_ADMIN_ROLE, "TGX: cannot renounce admin role");
        super.renounceRole(role, callerConfirmation);
    }
}
