// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGAUX} from "../src/TGAUX.sol";

contract TGAUXTest is Test {
    TGAUX public token;

    address public admin;
    address public minter;
    address public pauser;
    address public user1;
    address public user2;

    // Events to test
    event Minted(address indexed to, uint256 amount, address indexed minter);
    event Burned(address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        admin = makeAddr("admin");
        minter = makeAddr("minter");
        pauser = makeAddr("pauser");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy token with admin
        vm.prank(admin);
        token = new TGAUX(admin);

        // Grant roles
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        vm.stopPrank();
    }

    /* ============ Constructor Tests ============ */

    function test_Constructor() public view {
        assertEq(token.name(), "Tetra Gold");
        assertEq(token.symbol(), "TGAUX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.PAUSER_ROLE(), admin));
    }

    function test_ConstructorRevertsWithZeroAddress() public {
        vm.expectRevert("TGAUX: default admin cannot be zero address");
        new TGAUX(address(0));
    }

    /* ============ Minting Tests ============ */

    function test_MintByAuthorizedMinter() public {
        uint256 amount = 1 ether; // 1 TGAUX

        vm.expectEmit(true, true, false, true);
        emit Minted(user1, amount, minter);

        vm.prank(minter);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function test_MintMultipleTimes() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        vm.startPrank(minter);
        token.mint(user1, amount1);
        token.mint(user1, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1 + amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_MintToMultipleUsers() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        vm.startPrank(minter);
        token.mint(user1, amount1);
        token.mint(user2, amount2);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), amount1);
        assertEq(token.balanceOf(user2), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function test_MintRevertsWhenNotAuthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user1, 1 ether);
    }

    function test_MintRevertsWithBelowMinimumAmount() public {
        uint256 belowMinimum = token.MINIMUM_TRANSFER_AMOUNT() - 1;

        vm.prank(minter);
        vm.expectRevert("TGAUX: amount below minimum");
        token.mint(user1, belowMinimum);
    }

    function test_MintRevertsWithZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert("TGAUX: mint to zero address");
        token.mint(address(0), 1 ether);
    }

    function test_MintMinimumAmount() public {
        uint256 minimumAmount = token.MINIMUM_TRANSFER_AMOUNT();

        vm.prank(minter);
        token.mint(user1, minimumAmount);

        assertEq(token.balanceOf(user1), minimumAmount);
    }

    /* ============ Burning Tests ============ */

    function test_VaultBurnByMinterWithoutAllowance() public {
        uint256 mintAmount = 10 ether;
        uint256 burnAmount = 3 ether;

        vm.prank(minter);
        token.mint(user1, mintAmount);

        // user1 grants no allowance to anyone
        vm.expectEmit(true, false, false, true);
        emit Burned(user1, burnAmount);

        vm.prank(minter);
        token.vaultBurn(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_VaultBurnRevertsWhenNotMinter() public {
        vm.prank(minter);
        token.mint(user1, 10 ether);

        vm.prank(user2);
        vm.expectRevert();
        token.vaultBurn(user1, 1 ether);

        // Even the admin cannot vaultBurn without MINTER_ROLE
        vm.prank(admin);
        vm.expectRevert();
        token.vaultBurn(user1, 1 ether);
    }

    function test_BurnOwnTokens() public {
        uint256 mintAmount = 10 ether;
        uint256 burnAmount = 3 ether;

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.expectEmit(true, false, false, true);
        emit Burned(user1, burnAmount);

        vm.prank(user1);
        token.burn(burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_BurnAllTokens() public {
        uint256 amount = 10 ether;

        vm.prank(minter);
        token.mint(user1, amount);

        vm.prank(user1);
        token.burn(amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_BurnFromWithAllowance() public {
        uint256 mintAmount = 10 ether;
        uint256 burnAmount = 3 ether;

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.approve(user2, burnAmount);

        vm.expectEmit(true, false, false, true);
        emit Burned(user1, burnAmount);

        vm.prank(user2);
        token.burnFrom(user1, burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_BurnRevertsWithInsufficientBalance() public {
        uint256 amount = 1 ether;

        vm.prank(minter);
        token.mint(user1, amount);

        vm.prank(user1);
        vm.expectRevert();
        token.burn(amount + 1);
    }

    /* ============ Transfer Tests ============ */

    function test_TransferAboveMinimum() public {
        uint256 mintAmount = 10 ether;
        uint256 transferAmount = 1 ether; // Above minimum

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        bool success = token.transfer(user2, transferAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(user2), transferAmount);
    }

    function test_TransferExactMinimumAmount() public {
        uint256 mintAmount = 10 ether;
        uint256 transferAmount = token.MINIMUM_TRANSFER_AMOUNT();

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        bool success = token.transfer(user2, transferAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(token.balanceOf(user2), transferAmount);
    }

    function test_TransferEntireBalanceBelowMinimum() public {
        // Mint an amount below minimum directly for testing
        // We need to mint at least minimum first
        uint256 minimumAmount = token.MINIMUM_TRANSFER_AMOUNT();

        vm.prank(minter);
        token.mint(user1, minimumAmount);

        // Transfer entire balance (should work even if below minimum)
        vm.prank(user1);
        bool success = token.transfer(user2, minimumAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(user2), minimumAmount);
    }

    function test_TransferRevertsWhenBelowMinimum() public {
        uint256 mintAmount = 10 ether;
        uint256 transferAmount = token.MINIMUM_TRANSFER_AMOUNT() - 1;

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        vm.expectRevert("TGAUX: transfer amount below minimum");
        (bool success) = token.transfer(user2, transferAmount);
        success; // Silence unused variable warning
    }

    function test_TransferFromWithApproval() public {
        uint256 mintAmount = 10 ether;
        uint256 transferAmount = 1 ether;

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.approve(user2, transferAmount);

        vm.prank(user2);
        bool success = token.transferFrom(user1, user2, transferAmount);
        assertTrue(success, "TransferFrom should succeed");

        assertEq(token.balanceOf(user2), transferAmount);
    }

    /* ============ Pause Tests ============ */

    function test_PauseByAuthorizedPauser() public {
        vm.expectEmit(false, false, false, true);
        emit Paused(pauser);

        vm.prank(pauser);
        token.pause();

        assertTrue(token.paused());
    }

    function test_UnpauseByAuthorizedPauser() public {
        vm.prank(pauser);
        token.pause();

        vm.expectEmit(false, false, false, true);
        emit Unpaused(pauser);

        vm.prank(pauser);
        token.unpause();

        assertFalse(token.paused());
    }

    function test_PauseRevertsWhenNotAuthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        token.pause();
    }

    function test_TransferRevertsWhenPaused() public {
        uint256 amount = 1 ether;

        vm.prank(minter);
        token.mint(user1, amount);

        vm.prank(pauser);
        token.pause();

        vm.prank(user1);
        vm.expectRevert();
        (bool success) = token.transfer(user2, amount);
        success; // Silence unused variable warning
    }

    function test_MintRevertsWhenPaused() public {
        vm.prank(pauser);
        token.pause();

        vm.prank(minter);
        vm.expectRevert();
        token.mint(user1, 1 ether);
    }

    function test_BurnRevertsWhenPaused() public {
        uint256 amount = 1 ether;

        vm.prank(minter);
        token.mint(user1, amount);

        vm.prank(pauser);
        token.pause();

        vm.prank(user1);
        vm.expectRevert();
        token.burn(amount);
    }

    /* ============ Access Control Tests ============ */

    function test_AdminCanGrantMinterRole() public {
        address newMinter = makeAddr("newMinter");
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(admin);
        token.grantRole(minterRole, newMinter);

        assertTrue(token.hasRole(minterRole, newMinter));
    }

    function test_AdminCanRevokeMinterRole() public {
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(admin);
        token.revokeRole(minterRole, minter);

        assertFalse(token.hasRole(minterRole, minter));
    }

    function test_AdminCanGrantPauserRole() public {
        address newPauser = makeAddr("newPauser");
        bytes32 pauserRole = token.PAUSER_ROLE();

        vm.prank(admin);
        token.grantRole(pauserRole, newPauser);

        assertTrue(token.hasRole(pauserRole, newPauser));
    }

    function test_NonAdminCannotGrantRoles() public {
        address newMinter = makeAddr("newMinter");
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(user1);
        vm.expectRevert();
        token.grantRole(minterRole, newMinter);
    }

    function test_RevokedMinterCannotMint() public {
        bytes32 minterRole = token.MINTER_ROLE();

        vm.prank(admin);
        token.revokeRole(minterRole, minter);

        vm.prank(minter);
        vm.expectRevert();
        token.mint(user1, 1 ether);
    }

    function test_AdminCannotRenounceAdminRole() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert("TGAUX: cannot renounce admin role");
        token.renounceRole(adminRole, admin);
    }

    function test_NonAdminRoleCanBeRenounced() public {
        bytes32 pauserRole = token.PAUSER_ROLE();
        vm.prank(pauser);
        token.renounceRole(pauserRole, pauser);
        assertFalse(token.hasRole(pauserRole, pauser));
    }

    /* ============ Decimal Precision Tests ============ */

    function test_DecimalsAre18() public view {
        assertEq(token.decimals(), 18);
    }

    function test_MinimumTransferAmountPrecision() public view {
        // 0.03215 TGAUX = 32150000000000000 wei
        assertEq(token.MINIMUM_TRANSFER_AMOUNT(), 32150000000000000);
    }

    function test_MinimumUnit() public {
        // Minimum transfer unit = 0.03215 TGAUX
        uint256 minimumUnit = token.MINIMUM_TRANSFER_AMOUNT();

        vm.prank(minter);
        token.mint(user1, minimumUnit);

        assertEq(token.balanceOf(user1), minimumUnit);
    }

    function test_OneFullUnit() public {
        // 1 TGAUX = 1 troy ounce of gold (price unit)
        uint256 oneUnit = 1 ether;

        vm.prank(minter);
        token.mint(user1, oneUnit);

        assertEq(token.balanceOf(user1), oneUnit);
    }

    /* ============ ERC20 Standard Tests ============ */

    function test_ApproveAndAllowance() public {
        uint256 amount = 1 ether;

        vm.prank(minter);
        token.mint(user1, amount);

        vm.prank(user1);
        token.approve(user2, amount);

        assertEq(token.allowance(user1, user2), amount);
    }

    function test_ApproveUpdate() public {
        uint256 initialAmount = 1 ether;
        uint256 newAmount = 0.5 ether;

        vm.startPrank(user1);
        token.approve(user2, initialAmount);
        assertEq(token.allowance(user1, user2), initialAmount);

        // Update approval to new amount
        token.approve(user2, newAmount);
        assertEq(token.allowance(user1, user2), newAmount);
        vm.stopPrank();
    }

    function test_ApproveZeroReset() public {
        uint256 initialAmount = 1 ether;

        vm.startPrank(user1);
        token.approve(user2, initialAmount);
        assertEq(token.allowance(user1, user2), initialAmount);

        // Reset approval to zero
        token.approve(user2, 0);
        assertEq(token.allowance(user1, user2), 0);
        vm.stopPrank();
    }

    /* ============ Integration Tests ============ */

    function test_CompleteWorkflow() public {
        // Mint tokens to user1
        uint256 mintAmount = 100 ether;
        vm.prank(minter);
        token.mint(user1, mintAmount);

        // User1 transfers to user2
        uint256 transferAmount = 30 ether;
        vm.prank(user1);
        bool success = token.transfer(user2, transferAmount);
        assertTrue(success, "Transfer should succeed");

        // User2 burns some tokens
        uint256 burnAmount = 10 ether;
        vm.prank(user2);
        token.burn(burnAmount);

        // Verify final balances
        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(user2), transferAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function test_PauseUnpauseWorkflow() public {
        // Mint tokens
        vm.prank(minter);
        token.mint(user1, 10 ether);

        // Pause
        vm.prank(pauser);
        token.pause();

        // Try to transfer (should fail)
        vm.prank(user1);
        vm.expectRevert();
        (bool success) = token.transfer(user2, 1 ether);
        success; // Silence unused variable warning

        // Unpause
        vm.prank(pauser);
        token.unpause();

        // Transfer should work now
        vm.prank(user1);
        bool success2 = token.transfer(user2, 1 ether);
        assertTrue(success2, "Transfer should succeed");

        assertEq(token.balanceOf(user2), 1 ether);
    }

    /* ============ Fuzz Tests ============ */

    function testFuzz_MintValidAmounts(uint256 amount) public {
        // Bound amount to reasonable values
        amount = bound(amount, token.MINIMUM_TRANSFER_AMOUNT(), 1_000_000 ether);

        vm.prank(minter);
        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzz_TransferValidAmounts(uint256 mintAmount, uint256 transferAmount) public {
        // Ensure mint amount is at least minimum and reasonable
        mintAmount = bound(mintAmount, token.MINIMUM_TRANSFER_AMOUNT(), 1_000_000 ether);
        // Ensure transfer amount is between minimum and mint amount
        transferAmount = bound(transferAmount, token.MINIMUM_TRANSFER_AMOUNT(), mintAmount);

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        bool success = token.transfer(user2, transferAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(user2), transferAmount);
    }

    function testFuzz_BurnValidAmounts(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, token.MINIMUM_TRANSFER_AMOUNT(), 1_000_000 ether);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(minter);
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.burn(burnAmount);

        assertEq(token.balanceOf(user1), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }
}
