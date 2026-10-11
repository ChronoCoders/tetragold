// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TgauxVault} from "../src/TgauxVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {ReenteringPaxg} from "./mocks/ReenteringPaxg.sol";

contract TgauxVaultTest is Test {
    uint256 private constant BPS = 10_000;
    uint256 private constant FEE_IN_BPS = 50;
    uint256 private constant FEE_OUT_BPS = 75;
    uint8 private constant PAXG_DECIMALS = 18;
    uint256 private constant ONE = 1 ether;
    uint256 private constant TEN = 10 ether;
    uint256 private constant HUNDRED = 100 ether;
    uint256 private constant NOTHING = 0;
    uint256 private constant ONE_WEI = 1;
    /// @dev Transfer fee the fee on transfer mock charges, in basis points.
    uint256 private constant MOCK_FEE_BPS = 100;
    /// @dev The values D41 fixes for deployment: no entry fee, 5 bps on exit.
    uint256 private constant D41_FEE_IN_BPS = 0;
    uint256 private constant D41_FEE_OUT_BPS = 5;
    /// @dev What ten PAXG becomes on the way out under D41, and the fee kept.
    uint256 private constant D41_TEN_OUT = 9.995 ether;
    uint256 private constant D41_TEN_FEE = 0.005 ether;

    TgauxVault public vault;
    TGAUX public token;
    MockERC20 public paxg;

    address public treasury;
    address public alice;
    address public bob;

    function setUp() public {
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        paxg = new MockERC20("Paxos Gold", "PAXG", PAXG_DECIMALS);
        vault = new TgauxVault(address(paxg), treasury, FEE_IN_BPS, FEE_OUT_BPS);
        token = vault.TOKEN();

        paxg.mint(alice, HUNDRED);
        paxg.mint(bob, HUNDRED);
    }

    function test_ConstructorWiresTheTokenToThisVault() public view {
        assertEq(token.VAULT(), address(vault));
        assertEq(address(vault.PAXG()), address(paxg));
        assertEq(vault.TREASURY(), treasury);
        assertEq(vault.FEE_IN_BPS(), FEE_IN_BPS);
        assertEq(vault.FEE_OUT_BPS(), FEE_OUT_BPS);
        assertEq(vault.treasuryFeePaxg(), NOTHING);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(TgauxVault.ZeroAddress.selector);
        new TgauxVault(address(0), treasury, FEE_IN_BPS, FEE_OUT_BPS);

        vm.expectRevert(TgauxVault.ZeroAddress.selector);
        new TgauxVault(address(paxg), address(0), FEE_IN_BPS, FEE_OUT_BPS);
    }

    /// @dev A fee of the whole amount would mint or pay nothing, which is the
    ///      exit liveness I14 forbids.
    function test_ConstructorRejectsAWholeAmountFee() public {
        vm.expectRevert(abi.encodeWithSelector(TgauxVault.FeeTooHigh.selector, BPS));
        new TgauxVault(address(paxg), treasury, BPS, FEE_OUT_BPS);

        vm.expectRevert(abi.encodeWithSelector(TgauxVault.FeeTooHigh.selector, BPS));
        new TgauxVault(address(paxg), treasury, FEE_IN_BPS, BPS);
    }

    function test_DepositMintsTheAmountLessTheEntryFee() public {
        uint256 expectedMinted = (TEN * (BPS - FEE_IN_BPS)) / BPS;
        uint256 expectedFee = TEN - expectedMinted;

        vm.startPrank(alice);
        assertTrue(paxg.approve(address(vault), TEN));
        uint256 minted = vault.deposit(TEN);
        vm.stopPrank();

        assertEq(minted, expectedMinted);
        assertEq(token.balanceOf(alice), expectedMinted);
        assertEq(token.totalSupply(), expectedMinted);
        assertEq(vault.treasuryFeePaxg(), expectedFee);
        assertEq(paxg.balanceOf(address(vault)), TEN);
        assertEq(vault.backingPaxg(), expectedMinted);
    }

    /// @dev 4.1 step 1: the credit follows what arrived, not what was asked
    ///      for, so a PAXG that starts charging a transfer fee cannot inflate
    ///      supply above backing.
    function test_DepositMeasuresWhatArrivedNotWhatWasSent() public {
        MockFeeOnTransferERC20 feePaxg = new MockFeeOnTransferERC20("Paxos Gold", "PAXG", PAXG_DECIMALS);
        TgauxVault feeVault = new TgauxVault(address(feePaxg), treasury, FEE_IN_BPS, FEE_OUT_BPS);
        TGAUX feeToken = feeVault.TOKEN();
        feePaxg.mint(alice, HUNDRED);
        feePaxg.setFeeBps(MOCK_FEE_BPS);

        // The mock divides before this test multiplies, on purpose: the point
        // is to reproduce the token's own order of operations.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 arrived = TEN - ((TEN * MOCK_FEE_BPS) / BPS);
        uint256 expectedMinted = (arrived * (BPS - FEE_IN_BPS)) / BPS;

        vm.startPrank(alice);
        assertTrue(feePaxg.approve(address(feeVault), TEN));
        uint256 minted = feeVault.deposit(TEN);
        vm.stopPrank();

        assertEq(minted, expectedMinted);
        assertEq(feeToken.totalSupply(), expectedMinted);
        assertGe(feeVault.backingPaxg(), feeToken.totalSupply());
    }

    function test_DepositRevertsWhenNothingArrives() public {
        MockFeeOnTransferERC20 feePaxg = new MockFeeOnTransferERC20("Paxos Gold", "PAXG", PAXG_DECIMALS);
        TgauxVault feeVault = new TgauxVault(address(feePaxg), treasury, FEE_IN_BPS, FEE_OUT_BPS);
        feePaxg.mint(alice, HUNDRED);
        feePaxg.setFeeBps(BPS);

        vm.startPrank(alice);
        assertTrue(feePaxg.approve(address(feeVault), TEN));
        vm.expectRevert(TgauxVault.NothingReceived.selector);
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        feeVault.deposit(TEN);
        vm.stopPrank();
    }

    /// @dev The 1 gram minimum of 4.4 reaches a deposit through the token.
    function test_DepositRevertsUnderTheOneGramMinimum() public {
        uint256 tiny = token.MINIMUM_TRANSFER_AMOUNT() - ONE_WEI;

        vm.startPrank(alice);
        assertTrue(paxg.approve(address(vault), tiny));
        vm.expectRevert(abi.encodeWithSelector(TGAUX.BelowMinimum.selector, (tiny * (BPS - FEE_IN_BPS)) / BPS));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        vault.deposit(tiny);
        vm.stopPrank();
    }

    function test_WithdrawPaysTheBurnLessTheExitFee() public {
        _deposit(alice, TEN);
        uint256 held = token.balanceOf(alice);
        uint256 feeBefore = vault.treasuryFeePaxg();
        uint256 expectedPaid = (held * (BPS - FEE_OUT_BPS)) / BPS;

        vm.prank(alice);
        uint256 paid = vault.withdraw(held);

        assertEq(paid, expectedPaid);
        assertEq(paxg.balanceOf(alice), HUNDRED - TEN + expectedPaid);
        assertEq(token.totalSupply(), NOTHING);
        assertEq(vault.treasuryFeePaxg(), feeBefore + (held - expectedPaid));
        assertEq(vault.backingPaxg(), NOTHING);
    }

    /// @dev I4: the holder, not the depositor. Bob never deposited.
    function test_AnyHolderCanWithdraw() public {
        _deposit(alice, TEN);
        uint256 held = token.balanceOf(alice);

        vm.prank(alice);
        assertTrue(token.transfer(bob, held));

        uint256 expectedPaid = (held * (BPS - FEE_OUT_BPS)) / BPS;
        vm.prank(bob);
        uint256 paid = vault.withdraw(held);

        assertEq(paid, expectedPaid);
        assertEq(paxg.balanceOf(bob), HUNDRED + expectedPaid);
    }

    /// @dev The exit half of 4.4: a balance left under the minimum must still
    ///      be able to leave, or the minimum traps it.
    function test_WithdrawWholeBalanceBelowMinimum() public {
        _deposit(alice, TEN);
        uint256 minimum = token.MINIMUM_TRANSFER_AMOUNT();
        uint256 held = token.balanceOf(alice);
        uint256 dust = minimum - 1;

        vm.prank(alice);
        uint256 first = vault.withdraw(held - dust);
        assertGt(first, NOTHING);
        assertEq(token.balanceOf(alice), dust);

        vm.prank(alice);
        uint256 paid = vault.withdraw(dust);

        assertEq(paid, (dust * (BPS - FEE_OUT_BPS)) / BPS);
        assertEq(token.balanceOf(alice), NOTHING);
    }

    function test_WithdrawRevertsUnderTheMinimumWithMoreHeld() public {
        _deposit(alice, TEN);
        uint256 under = token.MINIMUM_TRANSFER_AMOUNT() - 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TgauxVault.BelowMinimum.selector, under));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        vault.withdraw(under);
    }

    function test_WithdrawRevertsOnZero() public {
        _deposit(alice, TEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TgauxVault.BelowMinimum.selector, NOTHING));
        // This call reverts by design, so no value comes back.
        // forge-lint: disable-next-line(unused-return)
        vault.withdraw(NOTHING);
    }

    function test_TreasuryTakesOnlyItsFees() public {
        _deposit(alice, TEN);
        uint256 fees = vault.treasuryFeePaxg();
        assertGt(fees, NOTHING);

        vm.prank(treasury);
        vault.withdrawTreasuryFees(treasury, fees);

        assertEq(paxg.balanceOf(treasury), fees);
        assertEq(vault.treasuryFeePaxg(), NOTHING);
        assertEq(vault.backingPaxg(), token.totalSupply());
    }

    /// @dev 4.3: backing is out of the treasury's reach, so a request for more
    ///      than the tracked fees is refused rather than served from backing.
    function test_TreasuryCannotReachBacking() public {
        _deposit(alice, TEN);
        uint256 fees = vault.treasuryFeePaxg();
        uint256 tooMuch = fees + 1;

        vm.prank(treasury);
        vm.expectRevert(abi.encodeWithSelector(TgauxVault.AmountExceedsTreasuryFees.selector, tooMuch, fees));
        vault.withdrawTreasuryFees(treasury, tooMuch);
    }

    function test_TreasuryWithdrawIsTreasuryOnly() public {
        _deposit(alice, TEN);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TgauxVault.NotTreasury.selector, alice));
        vault.withdrawTreasuryFees(alice, ONE_WEI);
    }

    function test_TreasuryWithdrawRejectsZeroRecipient() public {
        _deposit(alice, TEN);

        vm.prank(treasury);
        vm.expectRevert(TgauxVault.ZeroAddress.selector);
        vault.withdrawTreasuryFees(address(0), ONE_WEI);
    }

    function test_ZeroFeesAreOneForOne() public {
        TgauxVault freeVault = new TgauxVault(address(paxg), treasury, NOTHING, NOTHING);
        TGAUX freeToken = freeVault.TOKEN();

        vm.startPrank(alice);
        assertTrue(paxg.approve(address(freeVault), TEN));
        uint256 minted = freeVault.deposit(TEN);
        uint256 paid = freeVault.withdraw(minted);
        vm.stopPrank();

        assertEq(minted, TEN);
        assertEq(paid, TEN);
        assertEq(freeVault.treasuryFeePaxg(), NOTHING);
        assertEq(freeToken.totalSupply(), NOTHING);
    }

    /// @dev D31: the guard holds while PAXG has control inside the transfer.
    function test_ReentrantPaxgIsRefused() public {
        ReenteringPaxg hostile = new ReenteringPaxg("Paxos Gold", "PAXG", PAXG_DECIMALS);
        TgauxVault hostileVault = new TgauxVault(address(hostile), treasury, FEE_IN_BPS, FEE_OUT_BPS);
        hostile.mint(alice, HUNDRED);
        hostile.arm(hostileVault);

        vm.startPrank(alice);
        assertTrue(hostile.approve(address(hostileVault), TEN));
        uint256 minted = hostileVault.deposit(TEN);
        vm.stopPrank();
        assertGt(minted, NOTHING);

        assertTrue(hostile.reentryTried(), "the callback never ran, so nothing was proved");
        assertTrue(hostile.reentryRefused(), "the vault let a reentrant deposit through");
    }

    /// @dev D41: f_in is zero and f_out is 5 basis points, so ten PAXG in
    ///      mints ten TGAUX, and ten TGAUX out pays 9.995 PAXG with 0.005 left
    ///      as treasury fee PAXG. The numbers are written out rather than
    ///      recomputed from the constants, so a change to either fee fails here
    ///      instead of recomputing itself into agreement.
    function test_D41FeesMintOneForOneAndChargeFiveBpsOnExit() public {
        TgauxVault d41 = new TgauxVault(address(paxg), treasury, D41_FEE_IN_BPS, D41_FEE_OUT_BPS);
        TGAUX d41Token = d41.TOKEN();

        vm.startPrank(alice);
        assertTrue(paxg.approve(address(d41), TEN));
        uint256 minted = d41.deposit(TEN);
        vm.stopPrank();

        assertEq(minted, TEN, "a deposit at f_in of zero is one for one");
        assertEq(d41Token.balanceOf(alice), TEN);
        assertEq(d41.treasuryFeePaxg(), NOTHING, "f_in of zero took a fee");
        assertEq(d41.backingPaxg(), TEN);

        vm.prank(alice);
        uint256 paid = d41.withdraw(TEN);

        assertEq(paid, D41_TEN_OUT, "f_out of 5 bps did not pay 9.995 PAXG");
        assertEq(d41.treasuryFeePaxg(), D41_TEN_FEE, "the exit fee was not credited");
        assertEq(d41Token.totalSupply(), NOTHING);
        assertEq(d41.backingPaxg(), NOTHING, "backing was left stranded");
        assertEq(paxg.balanceOf(alice), HUNDRED - TEN + D41_TEN_OUT);
    }

    function testFuzz_DepositThenWithdrawNeverReturnsMore(uint256 amount) public {
        amount = bound(amount, token.MINIMUM_TRANSFER_AMOUNT() * 2, HUNDRED);

        vm.startPrank(alice);
        assertTrue(paxg.approve(address(vault), amount));
        uint256 minted = vault.deposit(amount);
        uint256 paid = vault.withdraw(minted);
        vm.stopPrank();

        assertLe(paid * BPS * BPS, amount * (BPS - FEE_IN_BPS) * (BPS - FEE_OUT_BPS));
        assertGe(vault.backingPaxg(), token.totalSupply());
    }

    function _deposit(address who, uint256 amount) private {
        vm.startPrank(who);
        assertTrue(paxg.approve(address(vault), amount));
        uint256 minted = vault.deposit(amount);
        vm.stopPrank();
        assertGt(minted, NOTHING);
    }
}
