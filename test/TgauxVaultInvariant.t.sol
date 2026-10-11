// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {LiquidityPool} from "../src/LiquidityPool.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {TgauxVault} from "../src/TgauxVault.sol";
import {TgauxVaultHandler} from "./handlers/TgauxVaultHandler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Invariants I4, I5, I11, I16 and the vault side of I20 (section 8).
/// @dev The handler returns early instead of reverting, so any revert in a
///      sequence is a defect rather than a bounds miss. Without this the
///      handler's own I4 assertion is counted as a discarded call and the
///      campaign reports green while a holder cannot get out.
/// forge-config: default.invariant.fail-on-revert = true
contract TgauxVaultInvariantTest is Test {
    uint256 private constant FEE_IN_BPS = 50;
    uint256 private constant FEE_OUT_BPS = 75;
    uint8 private constant PAXG_DECIMALS = 18;
    uint8 private constant STABLE_DECIMALS = 6;
    uint256 private constant SENTINEL_STABLE = 1_000_000e6;
    uint256 private constant SENTINEL_PAXG = 10 ether;
    uint256 private constant ACTOR = 0;
    uint256 private constant DRIVE_DEPOSIT = 100 ether;
    uint256 private constant ONE_WEI = 1;
    uint256 private constant NOTHING = 0;
    /// @dev The handler's withdrawal modes: whole balance, one wei, bounded.
    uint8 private constant MODE_WHOLE = 0;
    uint8 private constant MODE_ONE_WEI = 1;
    uint8 private constant MODE_BOUNDED = 2;
    uint256 private constant HANDLER_SELECTORS = 3;
    uint256 private constant DRIVEN_WITHDRAWALS = 3;

    TgauxVault public vault;
    TGAUX public token;
    MockERC20 public paxg;
    TgauxVaultHandler public handler;

    address public treasury;

    LiquidityPool public pool;
    InsuranceFund public insuranceFund;
    MockERC20 public usdc;
    MockERC20 public usdt;

    function setUp() public {
        treasury = makeAddr("treasury");
        paxg = new MockERC20("Paxos Gold", "PAXG", PAXG_DECIMALS);
        vault = new TgauxVault(address(paxg), treasury, FEE_IN_BPS, FEE_OUT_BPS);
        token = vault.TOKEN();

        // Sentinels for I20: contracts the vault must never touch. They are
        // the real LP and IF, funded, so the check is against the contracts
        // the invariant names rather than against stand-ins.
        usdc = new MockERC20("USD Coin", "USDC", STABLE_DECIMALS);
        usdt = new MockERC20("Tether USD", "USDT", STABLE_DECIMALS);
        pool = new LiquidityPool(address(this), address(usdc), address(usdt));
        insuranceFund = new InsuranceFund(address(token), makeAddr("treasury"), address(new ReentrancyLock()), 1 ether);

        usdc.mint(address(pool), SENTINEL_STABLE);
        usdt.mint(address(pool), SENTINEL_STABLE);
        usdc.mint(address(insuranceFund), SENTINEL_STABLE);
        paxg.mint(address(pool), SENTINEL_PAXG);
        paxg.mint(address(insuranceFund), SENTINEL_PAXG);

        handler = new TgauxVaultHandler(vault, paxg);

        bytes4[] memory selectors = new bytes4[](HANDLER_SELECTORS);
        selectors[0] = TgauxVaultHandler.deposit.selector;
        selectors[1] = TgauxVaultHandler.withdraw.selector;
        selectors[2] = TgauxVaultHandler.treasuryWithdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice I11: vault backing PAXG is never under TGAUX supply.
    function invariant_I11_BackingCoversSupply() public view {
        assertGe(vault.backingPaxg(), token.totalSupply(), "I11: backing fell under supply");
    }

    /// @notice I16: rounding on both sides never favours the user (D29).
    function invariant_I16_RoundingNeverFavoursTheUser() public view {
        uint256 bps = vault.BPS_DENOMINATOR();
        assertLe(
            handler.totalMinted() * bps,
            handler.totalReceived() * (bps - FEE_IN_BPS),
            "I16: a deposit minted more than the fee leaves"
        );
        assertLe(
            handler.totalPaid() * bps,
            handler.totalBurned() * (bps - FEE_OUT_BPS),
            "I16: a withdraw paid more than the fee leaves"
        );
    }

    /// @notice I4: every honoured withdraw paid exactly q times one minus
    ///         f_out. The liveness half, that a holder can always get out,
    ///         is asserted per call inside the handler.
    function invariant_I4_EveryWithdrawPaidItsExactShare() public view {
        assertEq(handler.totalPaid(), handler.expectedPaid(), "I4: a withdraw paid something else");
    }

    /// @notice I5: a round trip returns at most the deposit less both fees.
    function invariant_I5_RoundTripNeverReturnsMore() public view {
        uint256 bps = vault.BPS_DENOMINATOR();
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            // The actor set is four addresses fixed at construction, so this
            // read cannot grow with the campaign.
            // forge-lint: disable-next-line(calls-loop)
            address actor = handler.actorAt(i);
            // This actor's returned total is the left side of the bound, so
            // reading it per actor is the invariant rather than an aside.
            // forge-lint: disable-next-line(calls-loop)
            uint256 returned = handler.returnedPaxg(actor);
            // This actor's deposited total is the right side of the same bound.
            // forge-lint: disable-next-line(calls-loop)
            uint256 deposited = handler.depositedPaxg(actor);
            assertLe(
                returned * bps * bps,
                deposited * (bps - FEE_IN_BPS) * (bps - FEE_OUT_BPS),
                "I5: a round trip returned more than the deposit less both fees"
            );
        }
    }

    /// @notice I20, vault side: no deposit or withdraw moves a balance in the
    ///         LP or the IF, and no PAXG leaves the set of addresses the vault
    ///         accounts for.
    function invariant_I20_VaultTouchesNothingElse() public view {
        assertEq(usdc.balanceOf(address(pool)), SENTINEL_STABLE, "I20: LP usdc moved");
        assertEq(usdt.balanceOf(address(pool)), SENTINEL_STABLE, "I20: LP usdt moved");
        assertEq(usdc.balanceOf(address(insuranceFund)), SENTINEL_STABLE, "I20: IF usdc moved");
        assertEq(paxg.balanceOf(address(pool)), SENTINEL_PAXG, "I20: LP paxg moved");
        assertEq(paxg.balanceOf(address(insuranceFund)), SENTINEL_PAXG, "I20: IF paxg moved");

        uint256 accounted = paxg.balanceOf(address(vault)) + paxg.balanceOf(treasury);
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            // Same four addresses, and their PAXG is the sum under test.
            // forge-lint: disable-next-line(calls-loop)
            accounted += paxg.balanceOf(handler.actorAt(i));
        }
        assertEq(accounted, handler.paxgMinted(), "I20: PAXG left the accounted set");
    }

    /// @dev The invariants above all hold vacuously on a campaign that never
    ///      withdrew, so this drives the handler by hand and proves each path
    ///      they guard is reachable: a deposit, a partial withdrawal that
    ///      leaves a wei behind, a single wei out, and a whole balance out.
    ///
    ///      It is a plain test rather than `afterInvariant`, because forge runs
    ///      short sequences and replays shrunk ones, where a coverage claim
    ///      about the campaign is false through no fault of the code.
    function test_HandlerReachesEveryPathTheInvariantsGuard() public {
        handler.deposit(ACTOR, DRIVE_DEPOSIT);
        address actor = handler.actorAt(ACTOR);

        // The bounded mode takes everything but a wei when the seed is at the
        // top of its range, so this leaves the balance a floor would trap.
        handler.withdraw(ACTOR, type(uint256).max, MODE_BOUNDED);
        assertEq(token.balanceOf(actor), ONE_WEI, "the partial withdrawal left something else");
        assertGt(handler.weiBalancesLeft(), NOTHING, "no balance of a few wei was left behind");

        handler.deposit(ACTOR, DRIVE_DEPOSIT);
        handler.withdraw(ACTOR, NOTHING, MODE_ONE_WEI);
        assertGt(handler.weiWithdrawals(), NOTHING, "the single wei withdrawal never ran");

        handler.withdraw(ACTOR, NOTHING, MODE_WHOLE);

        assertGt(handler.deposits(), 1, "the second deposit never ran");
        assertEq(handler.withdrawals(), DRIVEN_WITHDRAWALS, "a withdrawal was lost");
        assertGt(handler.wholeBalanceExits(), NOTHING, "the whole balance exit never ran");
        assertEq(token.balanceOf(actor), NOTHING, "the actor did not get out");
    }
}
