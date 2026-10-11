// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {InsuranceFund} from "../../src/InsuranceFund.sol";
import {ReentrancyLock} from "../../src/ReentrancyLock.sol";
import {TGAUX} from "../../src/TGAUX.sol";
import {FundDriver} from "../mocks/FundDriver.sol";
import {VaultStub} from "../mocks/VaultStub.sol";

/// @notice Drives the insurance fund the way the position manager will: it
///         deploys the fund, so it is the privileged caller, and every call
///         runs inside the shared section.
/// @dev The ghosts record what each call asked for and what the handler itself
///      moved, never the fund's answer about itself. A credit ghost taken from
///      `syncCredit`'s return value would follow a defect that skims the
///      arrival and reports the remainder, so the ghost is the amount minted
///      into the fund and the returned figure is only compared against it.
///
///      Every guarded call goes through `FundDriver` rather than being wrapped
///      here. Foundry runs with call isolation on, so each call this handler
///      makes is its own transaction and transient storage does not survive
///      between them: taking the lock here and calling the fund on the next
///      line would find the lock free. Inside the driver both happen in one
///      call, which is also the shape of the real caller.
contract FundHandler is Test {
    uint256 private constant MIN_MOVE = 0.05 ether;
    uint256 private constant MAX_MOVE = 500 ether;
    uint256 private constant RECIPIENTS = 3;

    InsuranceFund public immutable FUND;
    FundDriver public immutable DRIVER;
    ReentrancyLock public immutable LOCK;
    TGAUX public immutable GOLD;
    VaultStub public immutable VAULT;
    address public immutable TREASURY;

    address[RECIPIENTS] private _recipients;

    uint256 public seededTotal;
    uint256 public arrivedTotal;
    uint256 public miscreditedCalls;
    uint256 public paidTotal;
    uint256 public payCalls;
    uint256 public payFailures;
    uint256 public overpaidCalls;
    uint256 public paidPastHoldings;
    uint256 public dustRefusals;

    // A zero treasury would make every seed revert, which a test would notice
    // at once; the handler is not a deployment script.
    // forge-lint: disable-next-line(missing-zero-check)
    constructor(VaultStub vault, ReentrancyLock lock, address treasury, uint256 target) {
        TREASURY = treasury;
        VAULT = vault;
        GOLD = vault.TOKEN();
        LOCK = lock;
        DRIVER = new FundDriver(address(vault.TOKEN()), treasury, address(lock), target);
        FUND = DRIVER.FUND();

        _recipients[0] = address(uint160(uint256(keccak256("pool"))));
        _recipients[1] = address(uint160(uint256(keccak256("keeper"))));
        _recipients[2] = address(uint160(uint256(keccak256("other"))));
    }

    function seedFund(uint256 amount) external {
        if (FUND.seeded()) {
            return;
        }
        amount = bound(amount, MIN_MOVE, MAX_MOVE);
        VAULT.mint(TREASURY, amount);
        vm.startPrank(TREASURY);
        assertTrue(GOLD.approve(address(FUND), amount));
        FUND.seed(amount);
        vm.stopPrank();
        seededTotal += amount;
    }

    /// @dev Fees and penalties arriving as a transfer, credited afterwards.
    function arrive(uint256 amount) external {
        amount = bound(amount, MIN_MOVE, MAX_MOVE);
        VAULT.mint(address(FUND), amount);
        arrivedTotal += amount;

        // forge-lint: disable-next-line(reentrancy-no-eth)
        uint256 credited = DRIVER.syncCredit();
        if (credited != amount) {
            miscreditedCalls += 1;
        }
    }

    function pay(uint256 whichSeed, uint256 requested) external {
        address to = _recipients[whichSeed % RECIPIENTS];
        requested = bound(requested, 0, MAX_MOVE);
        uint256 held = FUND.ounces();
        payCalls += 1;

        // The driver's whole call is one transaction, so a revert inside it
        // leaves no lock to release here.
        try DRIVER.payTo(to, requested) returns (uint256 paid) {
            if (paid > requested) {
                overpaidCalls += 1;
            }
            if (paid > held) {
                paidPastHoldings += 1;
            }
            if (paid == 0 && requested != 0 && held != 0) {
                dustRefusals += 1;
            }
            paidTotal += paid;
        } catch {
            payFailures += 1;
        }
    }
}
