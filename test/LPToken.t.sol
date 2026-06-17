// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LPToken} from "../src/LPToken.sol";

/**
 * @title LPTokenTest
 * @notice The LPToken is normally constructed by LiquidityPool, which becomes its
 *         sole minter/burner. Here the test contract deploys it directly, so the
 *         test contract is the authorized pool.
 */
contract LPTokenTest is Test {
    LPToken internal token;
    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        token = new LPToken("Tetra Gold LP", "TGLP");
    }

    function test_PoolIsDeployer() public view {
        assertEq(token.liquidityPool(), address(this));
    }

    function test_PoolCanMintAndBurn() public {
        token.mint(user, 1_000e18);
        assertEq(token.balanceOf(user), 1_000e18);

        token.burn(user, 400e18);
        assertEq(token.balanceOf(user), 600e18);
    }

    function test_MintRevertsForNonPool() public {
        vm.prank(stranger);
        vm.expectRevert(LPToken.LPToken__OnlyPool.selector);
        token.mint(user, 1_000e18);
    }

    function test_BurnRevertsForNonPool() public {
        token.mint(user, 1_000e18);
        vm.prank(stranger);
        vm.expectRevert(LPToken.LPToken__OnlyPool.selector);
        token.burn(user, 100e18);
    }
}
