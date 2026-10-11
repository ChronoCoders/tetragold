// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LPToken} from "../src/LPToken.sol";

/**
 * @title LPTokenTest
 * @notice The share token is normally deployed by the counterparty pool, which
 *         becomes its only minter and burner. Here the test contract deploys it
 *         directly, so the test contract is that pool.
 */
contract LPTokenTest is Test {
    uint256 private constant MINTED = 1000e18;
    uint256 private constant BURNED = 400e18;
    uint256 private constant LEFT = 600e18;
    uint256 private constant SMALL_BURN = 100e18;

    LPToken internal token;
    address internal user;
    address internal stranger;

    function setUp() public {
        user = makeAddr("user");
        stranger = makeAddr("stranger");
        token = new LPToken("Tetra Gold LP", "TGLP");
    }

    function test_PoolIsDeployer() public view {
        assertEq(token.LIQUIDITY_POOL(), address(this));
    }

    function test_PoolCanMintAndBurn() public {
        token.mint(user, MINTED);
        assertEq(token.balanceOf(user), MINTED);
        assertEq(token.totalSupply(), MINTED);

        token.burn(user, BURNED);

        assertEq(token.balanceOf(user), LEFT);
        assertEq(token.totalSupply(), LEFT);
    }

    function test_MintRevertsForNonPool() public {
        vm.prank(stranger);
        vm.expectRevert(LPToken.LPToken__OnlyPool.selector);
        token.mint(user, MINTED);
    }

    function test_BurnRevertsForNonPool() public {
        token.mint(user, MINTED);

        vm.prank(stranger);
        vm.expectRevert(LPToken.LPToken__OnlyPool.selector);
        token.burn(user, SMALL_BURN);

        assertEq(token.balanceOf(user), MINTED, "a stranger burnt a holder's shares");
    }

    /// @dev A holder may move shares freely; only minting and burning are the
    ///      pool's, which is what the counterparty pool's escrow relies on.
    function test_HolderCanTransferShares() public {
        token.mint(user, MINTED);

        vm.prank(user);
        assertTrue(token.transfer(stranger, BURNED));

        assertEq(token.balanceOf(stranger), BURNED);
        assertEq(token.balanceOf(user), LEFT);
    }
}
