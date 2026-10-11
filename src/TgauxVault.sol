// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TGAUX} from "./TGAUX.sol";

/**
 * @title TgauxVault
 * @notice Holds the PAXG that backs TGAUX, one to one minus fees (section 4).
 * @dev The vault deploys TGAUX in this constructor, so it is the token's
 *      immutable vault and the only account that can mint or burn it (D26).
 *
 *      Deposit and withdraw are one step each. Nothing here reads a price, asks
 *      whether a market is open, caps a size or can be paused, because TGAUX
 *      tracks the PAXG the vault holds rather than an oracle (D1, 4.1, 4.2).
 *
 *      Fees are immutable constructor parameters with no setter, so the terms a
 *      holder deposited under cannot be rewritten underneath them (O5 leaves
 *      the values open, not the ability to change them later).
 *
 *      I11: backing PAXG is the vault's PAXG balance less `treasuryFeePaxg`,
 *      and it never falls below TGAUX supply, because a deposit adds exactly
 *      what it mints and a withdraw releases at most what it burns.
 */
contract TgauxVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fee denominator: fees are given in basis points.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The gold the vault holds.
    IERC20 public immutable PAXG;

    /// @notice The token this vault deployed and alone can mint and burn.
    TGAUX public immutable TOKEN;

    /// @notice The only account that may withdraw treasury fee PAXG.
    address public immutable TREASURY;

    /// @notice Entry fee in basis points, f_in (4.1).
    uint256 public immutable FEE_IN_BPS;

    /// @notice Exit fee in basis points, f_out (4.2, D40).
    uint256 public immutable FEE_OUT_BPS;

    /// @notice PAXG held for the treasury. It is not backing (4.3) and is the
    ///         only PAXG the treasury may take out.
    uint256 public treasuryFeePaxg;

    event Deposited(address indexed account, uint256 paxgReceived, uint256 minted, uint256 fee);
    event Withdrawn(address indexed account, uint256 burned, uint256 paxgPaid, uint256 fee);
    event TreasuryFeesWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error FeeTooHigh(uint256 bps);
    error NothingReceived();
    error BelowMinimum(uint256 amount);
    error NotTreasury(address caller);
    error AmountExceedsTreasuryFees(uint256 amount, uint256 available);

    /// @param paxg The PAXG contract.
    /// @param treasury The account that may withdraw treasury fee PAXG.
    /// @param feeInBps Entry fee in basis points, f_in.
    /// @param feeOutBps Exit fee in basis points, f_out.
    constructor(address paxg, address treasury, uint256 feeInBps, uint256 feeOutBps) {
        if (paxg == address(0) || treasury == address(0)) {
            revert ZeroAddress();
        }
        // A fee of the whole amount would mint or pay nothing and would break
        // the exit liveness I14 asks for, so the denominator is the ceiling.
        if (feeInBps >= BPS_DENOMINATOR) {
            revert FeeTooHigh(feeInBps);
        }
        if (feeOutBps >= BPS_DENOMINATOR) {
            revert FeeTooHigh(feeOutBps);
        }

        PAXG = IERC20(paxg);
        TREASURY = treasury;
        FEE_IN_BPS = feeInBps;
        FEE_OUT_BPS = feeOutBps;
        TOKEN = new TGAUX();
    }

    /// @notice PAXG that backs TGAUX supply: the balance less treasury fees (4.3).
    function backingPaxg() public view returns (uint256) {
        return PAXG.balanceOf(address(this)) - treasuryFeePaxg;
    }

    /// @notice Deposit PAXG and receive TGAUX for what the vault actually got.
    /// @dev The amount credited is measured as a balance difference, so a PAXG
    ///      transfer fee introduced later cannot inflate supply (4.1 step 1).
    ///      `minted` rounds down and the fee takes the remainder, so rounding
    ///      cannot favour the depositor (D29, I16).
    /// @param amount PAXG to pull from the caller.
    /// @return minted TGAUX minted to the caller.
    function deposit(uint256 amount) external nonReentrant returns (uint256 minted) {
        uint256 balanceBefore = PAXG.balanceOf(address(this));
        PAXG.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = PAXG.balanceOf(address(this)) - balanceBefore;
        if (received == 0) {
            revert NothingReceived();
        }

        minted = (received * (BPS_DENOMINATOR - FEE_IN_BPS)) / BPS_DENOMINATOR;
        uint256 fee = received - minted;
        treasuryFeePaxg += fee;
        emit Deposited(msg.sender, received, minted, fee);

        // The guard is held across this call and the callee is the token this
        // vault deployed, so there is no path back in before the state settles.
        // The rule fires for any external call inside a nonReentrant function,
        // whatever the ordering: measured against a probe whose every state
        // write precedes the call, and silent only when the guard is removed,
        // which D31 requires. Ordering cannot clear it.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        TOKEN.mint(msg.sender, minted);
    }

    /// @notice Burn TGAUX and receive PAXG for it, less the exit fee.
    /// @dev Any holder may call this, not only the account that deposited (I4).
    ///      The payout rounds down and the fee takes the remainder, which goes
    ///      to treasury fee PAXG rather than staying as backing nobody can
    ///      reach (D40, I16).
    /// @param amount TGAUX to burn.
    /// @return paid PAXG sent to the caller.
    function withdraw(uint256 amount) external nonReentrant returns (uint256 paid) {
        // 4.4: the minimum applies, except to a holder leaving with a whole
        // balance that the minimum would otherwise trap.
        // `<` rather than `!=` against the balance: an amount over the balance
        // is allowed through here and the burn below refuses it, which keeps
        // the comparison off a strict equality with an external value.
        if (amount == 0 || (amount < TOKEN.MINIMUM_TRANSFER_AMOUNT() && amount < TOKEN.balanceOf(msg.sender))) {
            revert BelowMinimum(amount);
        }

        paid = (amount * (BPS_DENOMINATOR - FEE_OUT_BPS)) / BPS_DENOMINATOR;
        uint256 fee = amount - paid;
        treasuryFeePaxg += fee;
        emit Withdrawn(msg.sender, amount, paid, fee);

        // Same as the deposit, including why the rule cannot be cleared by
        // ordering: the guard is held across both calls, and the burn runs
        // before the PAXG leaves, so supply never trails backing.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        TOKEN.burn(msg.sender, amount);
        PAXG.safeTransfer(msg.sender, paid);
    }

    /// @notice Send treasury fee PAXG to `to`. Backing is out of reach (4.3).
    /// @param to Recipient of the fee PAXG.
    /// @param amount PAXG to send, at most `treasuryFeePaxg`.
    function withdrawTreasuryFees(address to, uint256 amount) external nonReentrant {
        if (msg.sender != TREASURY) {
            revert NotTreasury(msg.sender);
        }
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount > treasuryFeePaxg) {
            revert AmountExceedsTreasuryFees(amount, treasuryFeePaxg);
        }

        treasuryFeePaxg -= amount;
        emit TreasuryFeesWithdrawn(to, amount);

        PAXG.safeTransfer(to, amount);
    }
}
