// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {ReentrancyLock} from "../src/ReentrancyLock.sol";
import {TGAUX} from "../src/TGAUX.sol";
import {FundDriver} from "./mocks/FundDriver.sol";
import {VaultStub} from "./mocks/VaultStub.sol";

/// @notice The revision 6 fund: TGAUX only, bad debt cover and the keeper fee.
/// @dev `FundDriver` stands in for the position manager: it deploys the fund,
///      so it is the fund's one privileged caller, and it takes the shared lock
///      before calling in. The driver exists because a test body cannot hold a
///      transient lock across two calls, and because that is the shape the real
///      caller has.
contract InsuranceFundTest is Test {
    uint256 private constant TARGET = 100 ether;
    uint256 private constant SEED = 40 ether;
    uint256 private constant TEN = 10 ether;
    uint256 private constant ONE = 1 ether;
    uint256 private constant NOTHING = 0;

    InsuranceFund public fund;
    FundDriver public manager;
    ReentrancyLock public lock;
    VaultStub public vault;
    TGAUX public gold;

    address public treasury;
    address public pool;
    address public keeper;
    address public stranger;

    function setUp() public {
        treasury = makeAddr("treasury");
        pool = makeAddr("pool");
        keeper = makeAddr("keeper");
        stranger = makeAddr("stranger");

        vault = new VaultStub();
        gold = vault.TOKEN();
        lock = new ReentrancyLock();
        manager = new FundDriver(address(gold), treasury, address(lock), TARGET);
        fund = manager.FUND();

        vault.mint(treasury, 1000 ether);
        vm.prank(treasury);
        assertTrue(gold.approve(address(fund), type(uint256).max));
    }

    function test_ConstructorWiresTheDeployerAsThePositionManager() public view {
        assertEq(fund.POSITION_MANAGER(), address(manager));
        assertEq(address(fund.GOLD()), address(gold));
        assertEq(fund.TREASURY(), treasury);
        assertEq(address(fund.LOCK()), address(lock));
        assertEq(fund.TARGET(), TARGET);
        assertEq(fund.MIN_TRANSFER(), gold.MINIMUM_TRANSFER_AMOUNT());
        assertEq(fund.ounces(), NOTHING);
        assertFalse(fund.seeded());
    }

    function test_ConstructorRejectsBadArguments() public {
        vm.expectRevert(InsuranceFund.ZeroAddress.selector);
        new InsuranceFund(address(0), treasury, address(lock), TARGET);

        vm.expectRevert(InsuranceFund.ZeroAddress.selector);
        new InsuranceFund(address(gold), address(0), address(lock), TARGET);

        vm.expectRevert(InsuranceFund.ZeroAddress.selector);
        new InsuranceFund(address(gold), treasury, address(0), TARGET);

        vm.expectRevert(InsuranceFund.ZeroTarget.selector);
        new InsuranceFund(address(gold), treasury, address(lock), NOTHING);
    }

    function test_SeedIsTreasuryOnlyAndOnce() public {
        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.NotTreasury.selector, stranger));
        vm.prank(stranger);
        fund.seed(SEED);

        vm.prank(treasury);
        fund.seed(SEED);

        assertEq(fund.ounces(), SEED, "the seed was not credited");
        assertEq(gold.balanceOf(address(fund)), SEED, "the ounces did not arrive");
        assertTrue(fund.seeded());

        vm.prank(treasury);
        vm.expectRevert(InsuranceFund.AlreadySeeded.selector);
        fund.seed(ONE);
    }

    function test_SyncCreditTakesWhatArrivedAndNothingMore() public {
        _seed();
        vault.mint(address(fund), TEN);

        uint256 credited = _syncCredit();

        assertEq(credited, TEN, "the arrival was not credited");
        assertEq(fund.ounces(), SEED + TEN);
        assertEq(fund.ounces(), gold.balanceOf(address(fund)), "tracked and held disagree");

        uint256 second = _syncCredit();
        assertEq(second, NOTHING, "a second sync credited something twice");
    }

    function test_SyncCreditIsPositionManagerOnlyAndNeedsTheSection() public {
        _seed();

        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.NotPositionManager.selector, stranger));
        vm.prank(stranger);
        // forge-lint: disable-next-line(unused-return)
        fund.syncCredit();

        // The privileged caller, but outside the shared section.
        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.LockNotHeld.selector, address(manager), address(0)));
        // forge-lint: disable-next-line(unused-return)
        manager.syncCreditOutsideTheSection();
    }

    function test_PayToSendsWhatItHasAndReportsIt() public {
        _seed();

        uint256 paid = _payTo(pool, TEN);

        assertEq(paid, TEN);
        assertEq(gold.balanceOf(pool), TEN, "the pool was not paid");
        assertEq(fund.ounces(), SEED - TEN);
        assertEq(fund.ounces(), gold.balanceOf(address(fund)), "tracked and held disagree");
    }

    /// @dev I14: an exit path never reverts for a shortage. It pays what is
    ///      there and the caller learns the rest is uncovered.
    function test_PayToPaysPartiallyWhenShortAndNeverReverts() public {
        _seed();

        uint256 paid = _payTo(pool, SEED + TEN);

        assertEq(paid, SEED, "the fund did not pay out everything it had");
        assertEq(fund.ounces(), NOTHING);

        assertEq(_payTo(pool, TEN), NOTHING, "an empty fund paid something");
    }

    /// @dev The token refuses a transfer under one gram unless it moves a whole
    ///      balance (4.4), so a dust request pays nothing rather than reverting
    ///      and stranding the liquidation that asked.
    function test_PayToRefusesDustRatherThanReverting() public {
        _seed();
        uint256 dust = gold.MINIMUM_TRANSFER_AMOUNT() - 1;

        uint256 paid = _payTo(keeper, dust);

        assertEq(paid, NOTHING, "a dust payment was attempted");
        assertEq(fund.ounces(), SEED, "the fund lost ounces on a refused payment");
        assertEq(gold.balanceOf(keeper), NOTHING);
    }

    /// @dev The whole balance exception does apply, so a fund holding dust can
    ///      still be emptied.
    function test_PayToCanEmptyAFundHoldingOnlyDust() public {
        uint256 dust = gold.MINIMUM_TRANSFER_AMOUNT() - 1;
        _seed();
        _payTo(pool, SEED - dust);
        assertEq(fund.ounces(), dust);

        uint256 paid = _payTo(pool, dust);

        assertEq(paid, dust, "the fund could not pay out its last dust");
        assertEq(fund.ounces(), NOTHING);
    }

    function test_PayToIsPositionManagerOnlyAndNeedsTheSection() public {
        _seed();

        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.NotPositionManager.selector, stranger));
        vm.prank(stranger);
        // forge-lint: disable-next-line(unused-return)
        fund.payTo(pool, TEN);

        vm.expectRevert(abi.encodeWithSelector(InsuranceFund.LockNotHeld.selector, address(manager), address(0)));
        // forge-lint: disable-next-line(unused-return)
        manager.payToOutsideTheSection(pool, TEN);
    }

    function test_PayToRejectsTheZeroRecipient() public {
        _seed();

        vm.expectRevert(InsuranceFund.ZeroAddress.selector);
        // forge-lint: disable-next-line(unused-return)
        manager.payTo(address(0), TEN);
    }

    /// @dev D20: the target is a routing ceiling, so the fund may hold more.
    function test_TargetIsARoutingCeiling() public {
        assertEq(fund.shortfallToTarget(), TARGET);
        assertFalse(fund.atTarget());

        _seed();
        assertEq(fund.shortfallToTarget(), TARGET - SEED);

        vault.mint(address(fund), TARGET);
        _syncCredit();

        assertTrue(fund.atTarget(), "the fund did not reach its target");
        assertEq(fund.shortfallToTarget(), NOTHING, "a fund past target still asks for more");
        assertGt(fund.ounces(), TARGET, "the ceiling refused a lump credit");
    }

    function _seed() private {
        vm.prank(treasury);
        fund.seed(SEED);
    }

    function _syncCredit() private returns (uint256 credited) {
        credited = manager.syncCredit();
    }

    function _payTo(address to, uint256 amount) private returns (uint256 paid) {
        paid = manager.payTo(to, amount);
    }
}
