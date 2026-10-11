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
    uint256 private constant NOTHING = 0;

    /// @dev One troy ounce in grams, scaled by 1e18, for the 4.4 check.
    uint256 private constant TROY_OUNCE_GRAMS = 31_103_500_000_000_000_000;
    uint256 private constant ONE_GRAM = 1e18;
    uint256 private constant GRAM_TOLERANCE = 1e15;
    uint256 private constant EXPECTED_MINIMUM = 32_150_000_000_000_000;

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

    function test_MintRevertsBelowMinimum() public {
        uint256 under = token.MINIMUM_TRANSFER_AMOUNT() - ONE_WEI;

        vm.expectRevert(abi.encodeWithSelector(TGAUX.BelowMinimum.selector, under));
        vault.mint(user1, under);
    }

    function test_MintAtMinimum() public {
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        vault.mint(user1, minimum);

        assertEq(token.balanceOf(user1), minimum);
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

    /// @dev The exit path of 4.4: a holder left under the minimum must still be
    ///      able to leave, so a burn carries no minimum of its own.
    function test_BurnWholeBalanceBelowMinimum() public {
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        vault.mint(user1, minimum);
        vault.burn(user1, ONE_WEI);

        vault.burn(user1, minimum - ONE_WEI);

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

    function test_TransferExactMinimum() public {
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.transfer(user2, minimum));

        assertEq(token.balanceOf(user2), minimum);
    }

    /// @dev The transfer half of 4.4.
    function test_TransferWholeBalanceBelowMinimum() public {
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        vault.mint(user1, minimum);
        vault.burn(user1, ONE_WEI);
        uint256 left = token.balanceOf(user1);
        assertLt(left, minimum);

        vm.prank(user1);
        assertTrue(token.transfer(user2, left));

        assertEq(token.balanceOf(user1), NOTHING);
        assertEq(token.balanceOf(user2), left);
    }

    function test_TransferRevertsBelowMinimum() public {
        vault.mint(user1, TEN);
        uint256 under = token.MINIMUM_TRANSFER_AMOUNT() - ONE_WEI;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.BelowMinimum.selector, under));
        // This call reverts by design, so there is no return value to check.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(user2, under);
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

    /// @dev The minimum lives in the update hook, so the spender's path is held
    ///      to it as well, not only a direct transfer.
    function test_TransferFromRevertsBelowMinimum() public {
        vault.mint(user1, TEN);

        vm.prank(user1);
        assertTrue(token.approve(user2, TEN));
        uint256 under = token.MINIMUM_TRANSFER_AMOUNT() - ONE_WEI;

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(TGAUX.BelowMinimum.selector, under));
        // Same reason as above: the owner's balance is moved on purpose here,
        // and the call reverts by design, so no return value comes back.
        // forge-lint: disable-next-line(arbitrary-send-erc20,erc20-unchecked-transfer)
        token.transferFrom(user1, user2, under);
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

    /// @dev 0.03215 troy ounces is one gram to within a thousandth of a gram,
    ///      which is what 4.4 fixes the minimum to.
    function test_MinimumIsOneGram() public view {
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        assertEq(minimum, EXPECTED_MINIMUM);

        uint256 grams = (minimum * TROY_OUNCE_GRAMS) / ONE_GRAM;
        assertApproxEqAbs(grams, ONE_GRAM, GRAM_TOLERANCE);
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

    /// @dev D26 removed the roles, the transfer pause and `vaultBurn`, and the
    ///      rewrite removed ERC20Burnable. Absence is asserted against the
    ///      deployed bytecode rather than against the source: the token has no
    ///      fallback, so a call to a selector it does not carry has to fail.
    function test_RemovedSurfaceHasNoSelector() public {
        string[6] memory gone = [
            "pause()",
            "unpause()",
            "vaultBurn(address,uint256)",
            "grantRole(bytes32,address)",
            "burn(uint256)",
            "burnFrom(address,uint256)"
        ];

        for (uint256 i = 0; i < gone.length; i++) {
            bytes memory payload =
                i < 2 ? abi.encodeWithSignature(gone[i]) : abi.encodeWithSignature(gone[i], NOTHING, NOTHING);
            // One call per removed selector is what the test is for, and a raw
            // call is the only way to reach a function the type does not have.
            // forge-lint: disable-next-line(calls-loop,low-level-calls)
            (bool ok,) = address(token).call(payload);
            assertFalse(ok, gone[i]);
        }
    }

    function testFuzz_MintValidAmounts(uint256 amount) public {
        amount = bound(amount, token.MINIMUM_TRANSFER_AMOUNT(), FUZZ_CEILING);

        vault.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function testFuzz_TransferValidAmounts(uint256 minted, uint256 sent) public {
        minted = bound(minted, token.MINIMUM_TRANSFER_AMOUNT(), FUZZ_CEILING);
        sent = bound(sent, token.MINIMUM_TRANSFER_AMOUNT(), minted);
        vault.mint(user1, minted);

        vm.prank(user1);
        assertTrue(token.transfer(user2, sent));

        assertEq(token.balanceOf(user1), minted - sent);
        assertEq(token.balanceOf(user2), sent);
    }

    function testFuzz_BurnByVault(uint256 minted, uint256 burned) public {
        minted = bound(minted, token.MINIMUM_TRANSFER_AMOUNT(), FUZZ_CEILING);
        burned = bound(burned, NOTHING, minted);
        vault.mint(user1, minted);

        vault.burn(user1, burned);

        assertEq(token.balanceOf(user1), minted - burned);
        assertEq(token.totalSupply(), minted - burned);
    }
}
