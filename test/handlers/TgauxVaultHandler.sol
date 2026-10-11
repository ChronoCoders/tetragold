// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TGAUX} from "../../src/TGAUX.sol";
import {TgauxVault} from "../../src/TgauxVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Drives the vault for the invariant suite and records what it saw.
/// @dev I4 is a claim about each call, that a holder can get out and is paid
///      q times one minus f_out, so it is asserted here where the call happens
///      rather than in an invariant function that only sees the end state.
///
///      Actors never send TGAUX to each other. That is what lets I5 be read per
///      actor: every TGAUX an actor holds came from that actor's own deposits.
contract TgauxVaultHandler is Test {
    uint256 private constant ACTOR_COUNT = 4;
    uint256 private constant MAX_DEPOSIT = 1000 ether;
    uint256 private constant ONE_WEI = 1;
    /// @dev Two wei is the smallest deposit that still mints at this suite's
    ///      entry fee of 50 basis points; one wei rounds to nothing minted and
    ///      the vault refuses it (4.1, 4.4).
    uint256 private constant MIN_DEPOSIT = 2;
    uint256 private constant MODES = 3;

    TgauxVault public immutable VAULT;
    TGAUX public immutable TOKEN;
    MockERC20 public immutable PAXG;
    address public immutable TREASURY;

    address[ACTOR_COUNT] private _actors;

    /// @notice PAXG this handler created, which is the whole supply the
    ///         conservation half of I20 accounts for.
    uint256 public paxgMinted;

    uint256 public totalReceived;
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public totalPaid;
    uint256 public expectedPaid;

    uint256 public deposits;
    uint256 public withdrawals;

    /// @notice Withdrawals of a single wei, the amount a floor would refuse.
    uint256 public weiWithdrawals;

    /// @notice Withdrawals that took an actor's whole balance.
    uint256 public wholeBalanceExits;

    /// @notice Withdrawals that left a balance of a few wei behind, which a
    ///         floor would then have trapped.
    uint256 public weiBalancesLeft;

    mapping(address => uint256) public depositedPaxg;
    mapping(address => uint256) public returnedPaxg;

    constructor(TgauxVault vault, MockERC20 paxg) {
        VAULT = vault;
        TOKEN = vault.TOKEN();
        PAXG = paxg;
        TREASURY = vault.TREASURY();

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            _actors[i] = address(uint160(uint256(keccak256(abi.encodePacked("tgaux actor", i)))));
        }
    }

    function actorCount() external pure returns (uint256) {
        return ACTOR_COUNT;
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, MIN_DEPOSIT, MAX_DEPOSIT);

        PAXG.mint(actor, amount);
        paxgMinted += amount;

        uint256 vaultBefore = PAXG.balanceOf(address(VAULT));
        vm.startPrank(actor);
        assertTrue(PAXG.approve(address(VAULT), amount));
        uint256 minted = VAULT.deposit(amount);
        vm.stopPrank();

        uint256 received = PAXG.balanceOf(address(VAULT)) - vaultBefore;
        totalReceived += received;
        totalMinted += minted;
        depositedPaxg[actor] += received;
        deposits++;
    }

    /// @param mode Picks between the three withdrawal shapes I4 has to hold
    ///        for: the whole balance, a single wei, and an amount in between.
    ///        A floor on the amount would refuse the second and strand what the
    ///        third leaves behind, so each is counted and the invariant asserts
    ///        the campaign reached all three (4.4, r6.4).
    function withdraw(uint256 actorSeed, uint256 amountSeed, uint8 mode) external {
        address actor = _actor(actorSeed);
        uint256 balance = TOKEN.balanceOf(actor);
        if (balance == 0) {
            return;
        }

        uint256 amount;
        if (mode % MODES == 0 || balance == ONE_WEI) {
            amount = balance;
            wholeBalanceExits++;
        } else if (mode % MODES == 1) {
            amount = ONE_WEI;
            weiWithdrawals++;
        } else {
            amount = bound(amountSeed, ONE_WEI, balance - ONE_WEI);
        }

        if (balance - amount != 0 && balance - amount < MIN_DEPOSIT) {
            weiBalancesLeft++;
        }

        uint256 bps = VAULT.BPS_DENOMINATOR();
        uint256 expected = (amount * (bps - VAULT.FEE_OUT_BPS())) / bps;
        uint256 paxgBefore = PAXG.balanceOf(actor);

        vm.prank(actor);
        try VAULT.withdraw(amount) returns (uint256 paid) {
            assertEq(paid, expected, "I4: the payout was not q times one minus f_out");
            assertEq(PAXG.balanceOf(actor) - paxgBefore, paid, "I4: the PAXG did not arrive");
            totalBurned += amount;
            totalPaid += paid;
            expectedPaid += expected;
            returnedPaxg[actor] += paid;
            withdrawals++;
        } catch {
            assertTrue(false, "I4: a holder with a withdrawable balance could not withdraw");
        }
    }

    function treasuryWithdraw(uint256 amount) external {
        uint256 available = VAULT.treasuryFeePaxg();
        if (available == 0) {
            return;
        }
        amount = bound(amount, 1, available);

        vm.prank(TREASURY);
        VAULT.withdrawTreasuryFees(TREASURY, amount);
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % ACTOR_COUNT];
    }
}
