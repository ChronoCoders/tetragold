// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {VaultStub} from "./mocks/VaultStub.sol";

contract TGAUXTest is Test {
    uint256 private constant ONE = 1 ether;
    uint256 private constant TWO = 2 ether;
    uint256 private constant FOUR = 4 ether;
    uint256 private constant FIVE = 5 ether;
    uint256 private constant SIX = 6 ether;
    uint256 private constant NINE = 9 ether;
    uint256 private constant TEN = 10 ether;
    uint256 private constant FUZZ_CEILING = 1_000_000 ether;
    uint256 private constant ONE_WEI = 1;
    uint256 private constant THREE_WEI = 3;
    uint256 private constant NOTHING = 0;

    TGAUX public token;
    VaultStub public vault;

    address public user1;
    address public user2;
    address public stranger;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        stranger = makeAddr("stranger");

        vault = new VaultStub();
        token = vault.TOKEN();
    }

    function test_VaultIsTheDeployer() public view {
        assertEq(token.VAULT(), address(vault));
    }

    function test_MetadataAndEmptySupply() public view {
        assertEq(token.name(), "Tetra Gold");
        assertEq(token.symbol(), "TGAUX");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), NOTHING);
    }

    function test_MintByVault() public {
        vault.mint(user1, ONE);

        assertEq(token.balanceOf(user1), ONE);
        assertEq(token.totalSupply(), ONE);
    }

    function test_MintMultipleTimes() public {
        vault.mint(user1, ONE);
        vault.mint(user1, TWO);

        assertEq(token.balanceOf(user1), ONE + TWO);
        assertEq(token.totalSupply(), ONE + TWO);
    }

    function test_MintToMultipleUsers() public {
        vault.mint(user1, ONE);
        vault.mint(user2, FOUR);

        assertEq(token.balanceOf(user1), ONE);
        assertEq(token.balanceOf(user2), FOUR);
        assertEq(token.totalSupply(), FIVE);
    }

    function test_MintRevertsWhenCallerIsNotTheVault() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.NotVault.selector, stranger));
        token.mint(user1, ONE);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.NotVault.selector, user1));
        token.mint(user1, ONE);
    }

    /// @dev 4.4 carries no minimum from r6.4, so one wei mints.
    function test_MintAcceptsOneWei() public {
        vault.mint(user1, ONE_WEI);

        assertEq(token.balanceOf(user1), ONE_WEI);
        assertEq(token.totalSupply(), ONE_WEI);
    }

    /// @dev The token adds no zero address check of its own, so this asserts
    ///      the error OpenZeppelin's _mint already raises.
    function test_MintToZeroAddressRevertsInERC20() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vault.mint(address(0), ONE);
    }

    function test_BurnByVaultNeedsNoAllowance() public {
        vault.mint(user1, TEN);
        assertEq(token.allowance(user1, address(vault)), NOTHING);

        vault.burn(user1, FOUR);

        assertEq(token.balanceOf(user1), SIX);
        assertEq(token.totalSupply(), SIX);
    }

    function test_BurnRevertsWhenCallerIsNotTheVault() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.NotVault.selector, user1));
        token.burn(user1, ONE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.NotVault.selector, stranger));
        token.burn(user1, ONE);
    }

    /// @dev A balance leaves one wei at a time, so nothing can be trapped by
    ///      the size of what is left (4.4).
    function test_BurnDownToNothingOneWeiAtATime() public {
        vault.mint(user1, THREE_WEI);

        vault.burn(user1, ONE_WEI);
        assertEq(token.balanceOf(user1), THREE_WEI - ONE_WEI);
        vault.burn(user1, ONE_WEI);
        vault.burn(user1, ONE_WEI);

        assertEq(token.balanceOf(user1), NOTHING);
        assertEq(token.totalSupply(), NOTHING);
    }

    function test_BurnRevertsBeyondBalance() public {
        vault.mint(user1, ONE);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, ONE, TWO));
        vault.burn(user1, TWO);
    }

    function test_TransferAboveMinimum() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.transfer(user2, ONE));

        assertEq(token.balanceOf(user1), NINE);
        assertEq(token.balanceOf(user2), ONE);
    }

    /// @dev The transfer half of 4.4: one wei moves, and it moves whether or
    ///      not it is the sender's whole balance, because no exception is
    ///      carrying it any more.
    function test_TransferMovesOneWeiFromAnyBalance() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.transfer(user2, ONE_WEI));

        assertEq(token.balanceOf(user1), TEN - ONE_WEI);
        assertEq(token.balanceOf(user2), ONE_WEI);

        vm.prank(user2);
        assertTrue(token.transfer(user1, ONE_WEI));

        assertEq(token.balanceOf(user2), NOTHING);
    }

    function test_TransferFromWithApproval() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.approve(user2, ONE));

        vm.prank(user2);
        // The spender moving the owner's balance is the behaviour under test,
        // not an unchecked send of someone else's funds.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        assertTrue(token.transferFrom(user1, user2, ONE));

        assertEq(token.balanceOf(user2), ONE);
        assertEq(token.allowance(user1, user2), NOTHING);
    }

    /// @dev The spender's path has no floor of its own either, and it spends
    ///      exactly the allowance it used.
    function test_TransferFromMovesOneWei() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.approve(user2, TEN));

        vm.prank(user2);
        // The spender moving the owner's balance is the behaviour under test.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        assertTrue(token.transferFrom(user1, user2, ONE_WEI));

        assertEq(token.balanceOf(user2), ONE_WEI);
        assertEq(token.allowance(user1, user2), TEN - ONE_WEI);
    }

    function test_ApproveAndAllowance() public {
        vm.prank(user1);
        assertTrue(token.approve(user2, FIVE));

        assertEq(token.allowance(user1, user2), FIVE);
    }

    function test_ApproveUpdate() public {
        vm.startPrank(user1);
        assertTrue(token.approve(user2, FIVE));
        assertTrue(token.approve(user2, TWO));
        vm.stopPrank();

        assertEq(token.allowance(user1, user2), TWO);
    }

    function test_ApproveZeroReset() public {
        vm.startPrank(user1);
        assertTrue(token.approve(user2, FIVE));
        assertTrue(token.approve(user2, NOTHING));
        vm.stopPrank();

        assertEq(token.allowance(user1, user2), NOTHING);
    }

    function test_MintTransferBurnWorkflow() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.transfer(user2, FOUR));

        vault.burn(user1, SIX);
        vault.burn(user2, FOUR);

        assertEq(token.totalSupply(), NOTHING);
        assertEq(token.balanceOf(user1), NOTHING);
        assertEq(token.balanceOf(user2), NOTHING);
    }

    /// @dev D26 removed the roles, the transfer pause and `vaultBurn`, the
    ///      rewrite removed ERC20Burnable, and r6.4 removed the minimum.
    ///      Absence is asserted against the deployed bytecode rather than
    ///      against the source: the token has no fallback, so a call to a
    ///      selector it does not carry has to fail.
    function test_RemovedSurfaceHasNoSelector() public {
        string[3] memory goneNoArgs = ["pause()", "unpause()", "MINIMUM_TRANSFER_AMOUNT()"];
        string[4] memory goneWithArgs =
            ["vaultBurn(address,uint256)", "grantRole(bytes32,address)", "burn(uint256)", "burnFrom(address,uint256)"];

        for (uint256 i = 0; i < goneNoArgs.length; i++) {
            // One call per removed selector is what the test is for, and a raw
            // call is the only way to reach a function the type does not have.
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(token).call(abi.encodeWithSignature(goneNoArgs[i]));
            assertFalse(ok, goneNoArgs[i]);
        }

        for (uint256 i = 0; i < goneWithArgs.length; i++) {
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(token).call(abi.encodeWithSignature(goneWithArgs[i], NOTHING, NOTHING));
            assertFalse(ok, goneWithArgs[i]);
        }
    }

    function testFuzz_MintValidAmounts(uint256 amount) public {
        amount = bound(amount, ONE_WEI, FUZZ_CEILING);

        vault.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function testFuzz_TransferValidAmounts(uint256 minted, uint256 sent) public {
        minted = bound(minted, ONE_WEI, FUZZ_CEILING);
        sent = bound(sent, ONE_WEI, minted);
        vault.mint(user1, minted);

        vm.prank(user1);
        assertTrue(token.transfer(user2, sent));

        assertEq(token.balanceOf(user1), minted - sent);
        assertEq(token.balanceOf(user2), sent);
    }

    function testFuzz_BurnByVault(uint256 minted, uint256 burned) public {
        minted = bound(minted, ONE_WEI, FUZZ_CEILING);
        burned = bound(burned, NOTHING, minted);
        vault.mint(user1, minted);

        vault.burn(user1, burned);

        assertEq(token.balanceOf(user1), minted - burned);
        assertEq(token.totalSupply(), minted - burned);
    }
}
