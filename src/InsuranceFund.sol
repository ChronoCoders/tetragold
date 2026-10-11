// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ReentrancyLock} from "./ReentrancyLock.sol";
import {TGAUX} from "./TGAUX.sol";

/**
 * @title InsuranceFund
 * @notice Holds TGAUX and covers bad debt for the counterparty pool (D49).
 * @dev Rewritten for revision 6. It holds TGAUX only, never USDC and never
 *      Aave (D25, D49), and it does one thing: when a close or a liquidation
 *      leaves a position's equity below zero, it sends the pool up to that many
 *      ounces, and whatever it cannot cover the pool absorbs.
 *
 *      Under D20 as revised in r6.1 a realised trader loss never passes through
 *      here: the collateral joined the pool at open, so the part the trader
 *      lost is already in the pool. Only the fund's share of fees and penalties
 *      arrives, up to `TARGET`, which is a routing ceiling rather than a cap on
 *      what the fund may hold.
 *
 *      It also pays the keeper fee per liquidation (D39).
 *
 *      There is no role, no admin and no setter. The position manager is the
 *      deployer, as the vault is for TGAUX, and the treasury and the target are
 *      constructor arguments. Nothing here can be reconfigured later.
 */
contract InsuranceFund {
    using SafeERC20 for TGAUX;

    /// @notice The only token this fund holds.
    TGAUX public immutable GOLD;

    /// @notice The only account that may credit or spend the fund. It is the
    ///         deployer, which makes the edge immutable and unsettable.
    address public immutable POSITION_MANAGER;

    /// @notice The account that seeds the fund at launch (D49, O11).
    address public immutable TREASURY;

    /// @notice The guard shared with the vault, the position contract and the
    ///         pool (D31).
    ReentrancyLock public immutable LOCK;

    /// @notice Ounces the fund routes towards before the rest flows to the
    ///         pool (D20, O11).
    uint256 public immutable TARGET;

    /// @notice Ounces the fund holds, tracked rather than read from the token.
    uint256 public ounces;

    /// @notice Whether the launch seed has been taken.
    bool public seeded;

    event Seeded(uint256 ounces);
    event Credited(uint256 credited, uint256 total);
    event Paid(address indexed to, uint256 requested, uint256 paid);

    error ZeroAddress();
    error ZeroTarget();
    error ZeroAmount();
    error NotTreasury(address caller);
    error NotPositionManager(address caller);
    error LockNotHeld(address caller, address holder);
    error AlreadySeeded();

    constructor(address gold, address treasury, address lock, uint256 target) {
        if (gold == address(0) || treasury == address(0) || lock == address(0)) {
            revert ZeroAddress();
        }
        if (target == 0) {
            revert ZeroTarget();
        }

        GOLD = TGAUX(gold);
        POSITION_MANAGER = msg.sender;
        TREASURY = treasury;
        LOCK = ReentrancyLock(lock);
        TARGET = target;
    }

    /// @notice Take the launch seed from the treasury, once (D49).
    /// @param amount Ounces to pull.
    function seed(uint256 amount) external {
        if (msg.sender != TREASURY) {
            revert NotTreasury(msg.sender);
        }
        if (seeded) {
            revert AlreadySeeded();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }

        // A user facing entry point opens the shared critical section; the
        // functions the position manager calls join the one it already holds.
        // Taking the section is itself an external call, and the state this
        // function writes follows it by construction.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        LOCK.enter();

        seeded = true;
        uint256 before = GOLD.balanceOf(address(this));
        // The arrival has to be measured, so the credit follows the transfer.
        // The section is held across it and the token is this protocol's own,
        // with no transfer hook to reenter from.
        GOLD.safeTransferFrom(TREASURY, address(this), amount);
        uint256 arrived = GOLD.balanceOf(address(this)) - before;
        ounces += arrived;

        // The event reports what arrived, which is only known after the
        // transfer, and nothing on chain reads it.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Seeded(arrived);
        LOCK.exit();
    }

    /// @notice Credit TGAUX that has already arrived (D20).
    /// @dev Measured as a balance difference rather than taken on trust, so the
    ///      tracked total cannot drift from the token balance (I1).
    /// @return credited Ounces taken into the fund by this call.
    function syncCredit() external returns (uint256 credited) {
        _onlyPositionManagerInsideTheSection();

        credited = GOLD.balanceOf(address(this)) - ounces;
        if (credited != 0) {
            ounces += credited;
            emit Credited(credited, ounces);
        }
    }

    /// @notice Send up to `requested` ounces to `to` (D34, D49, D39).
    /// @dev Never reverts for a shortage, which is what I14 asks of every exit
    ///      path: it pays what it has and reports it. Any amount goes out, down
    ///      to one wei, because the token carries no minimum (4.4, r6.4).
    /// @param to Recipient: the pool for bad debt cover, the keeper for its fee.
    /// @param requested Ounces asked for.
    /// @return paid Ounces actually sent.
    function payTo(address to, uint256 requested) external returns (uint256 paid) {
        _onlyPositionManagerInsideTheSection();
        if (to == address(0)) {
            revert ZeroAddress();
        }

        paid = requested > ounces ? ounces : requested;

        if (paid != 0) {
            ounces -= paid;
            emit Paid(to, requested, paid);
            GOLD.safeTransfer(to, paid);
        } else {
            emit Paid(to, requested, 0);
        }
    }

    /// @notice Ounces still to route here before the rest goes to the pool.
    function shortfallToTarget() external view returns (uint256) {
        return ounces >= TARGET ? 0 : TARGET - ounces;
    }

    /// @notice Whether the fund has reached its routing target.
    function atTarget() external view returns (bool) {
        return ounces >= TARGET;
    }

    /// @dev The position manager must be inside the shared section when it
    ///      calls in, which is what makes the guard shared rather than a
    ///      convention: the fund refuses work that is not inside one.
    function _onlyPositionManagerInsideTheSection() private view {
        if (msg.sender != POSITION_MANAGER) {
            revert NotPositionManager(msg.sender);
        }
        address holder = LOCK.heldBy();
        if (holder != msg.sender) {
            revert LockNotHeld(msg.sender, holder);
        }
    }
}
