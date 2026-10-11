// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TGAUX} from "../../src/TGAUX.sol";

/// @notice Stands in for TgauxVault in the token's own tests.
/// @dev It deploys the token, so it is the token's immutable vault and the only
///      account that can mint or burn. It holds no PAXG and tracks nothing: the
///      vault's own accounting is tested against the real vault.
contract VaultStub {
    TGAUX public immutable TOKEN;

    constructor() {
        TOKEN = new TGAUX();
    }

    function mint(address to, uint256 amount) external {
        TOKEN.mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        TOKEN.burn(from, amount);
    }
}
