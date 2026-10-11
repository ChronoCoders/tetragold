// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title IVerifierProxy
 * @notice The one Data Streams verifier call this protocol makes, copied from
 *         upstream rather than imported.
 * @dev Copied from chainlink-evm@b723176,
 *      `contracts/src/v0.8/llo-feeds/v0.5.1/VerifierProxy.sol:132-144`, where
 *      the return value is unnamed. The fee manager call at `:139` runs only
 *      when a fee manager is set, so the expiry check inside the fee manager
 *      (`v0.3.0/FeeManager.sol:274-275`) is conditional and a consumer cannot
 *      rely on it. Section 7 rule 7 therefore checks the report's expiresAt
 *      itself.
 *
 *      `verify` is payable: whatever fee the proxy bills is forwarded from the
 *      caller, and this protocol holds no balance to pay it from.
 */
interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}
