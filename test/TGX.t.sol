// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGX} from "../src/TGX.sol";

contract TGXTest is Test {
    TGX public tgx;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public user = makeAddr("user");

    function setUp() public {
        tgx = new TGX(admin, treasury);
    }

    function test_Constructor() public view {
        assertEq(tgx.name(), "Tetra Gold Governance");
        assertEq(tgx.symbol(), "TGX");
        assertEq(tgx.decimals(), 18);
        assertEq(tgx.totalSupply(), tgx.MAX_SUPPLY());
        assertEq(tgx.balanceOf(treasury), tgx.MAX_SUPPLY());
        assertTrue(tgx.hasRole(tgx.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_MaxSupplyIs100M() public view {
        assertEq(tgx.MAX_SUPPLY(), 100_000_000e18);
    }

    function test_TreasuryReceivesFullSupply() public view {
        assertEq(tgx.balanceOf(treasury), 100_000_000e18);
    }

    function test_ConstructorRevertsWithZeroAdmin() public {
        vm.expectRevert(TGX.TGX__ZeroAddress.selector);
        new TGX(address(0), treasury);
    }

    function test_ConstructorRevertsWithZeroTreasury() public {
        vm.expectRevert(TGX.TGX__ZeroAddress.selector);
        new TGX(admin, address(0));
    }

    function test_BurnReducesSupply() public {
        uint256 burnAmount = 1_000_000e18;
        vm.prank(treasury);
        tgx.burn(burnAmount);

        assertEq(tgx.totalSupply(), tgx.MAX_SUPPLY() - burnAmount);
        assertEq(tgx.balanceOf(treasury), tgx.MAX_SUPPLY() - burnAmount);
    }

    function test_BurnFrom() public {
        uint256 amount = 500_000e18;
        vm.prank(treasury);
        tgx.approve(user, amount);

        vm.prank(user);
        tgx.burnFrom(treasury, amount);

        assertEq(tgx.totalSupply(), tgx.MAX_SUPPLY() - amount);
    }

    function test_Transfer() public {
        uint256 amount = 10_000e18;
        vm.prank(treasury);
        tgx.transfer(user, amount);
        assertEq(tgx.balanceOf(user), amount);
    }

    function test_CannotRenounceAdminRole() public {
        bytes32 adminRole = tgx.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert("TGX: cannot renounce admin role");
        tgx.renounceRole(adminRole, admin);
    }

    function test_NonAdminRoleCanBeRenounced() public {
        // Grant a non-admin role and verify it can be renounced
        bytes32 customRole = keccak256("SOME_ROLE");
        vm.prank(admin);
        tgx.grantRole(customRole, user);

        vm.prank(user);
        tgx.renounceRole(customRole, user);
        assertFalse(tgx.hasRole(customRole, user));
    }

    function test_AdminCanGrantAndRevokeRoles() public {
        bytes32 customRole = keccak256("CUSTOM");
        vm.startPrank(admin);
        tgx.grantRole(customRole, user);
        assertTrue(tgx.hasRole(customRole, user));
        tgx.revokeRole(customRole, user);
        assertFalse(tgx.hasRole(customRole, user));
        vm.stopPrank();
    }

    function testFuzz_TransferDoesNotExceedSupply(uint256 amount) public {
        amount = bound(amount, 1, tgx.MAX_SUPPLY());
        vm.prank(treasury);
        tgx.transfer(user, amount);
        assertEq(tgx.balanceOf(user) + tgx.balanceOf(treasury), tgx.MAX_SUPPLY());
    }
}
