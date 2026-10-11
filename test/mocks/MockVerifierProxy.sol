// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stands in for the Data Streams verifier proxy.
/// @dev The real proxy checks signatures and returns the report bytes. This
///      returns the payload unchanged, so a test builds the report it wants to
///      put in front of the consumer, and records what fee reached it.
// It is paid like the real proxy and never pays out, which is all a test needs.
// forge-lint: disable-next-line(locked-ether)
contract MockVerifierProxy {
    uint256 public received;
    bytes public lastParameterPayload;

    function verify(bytes calldata payload, bytes calldata parameterPayload) external payable returns (bytes memory) {
        received += msg.value;
        lastParameterPayload = parameterPayload;
        return payload;
    }
}
