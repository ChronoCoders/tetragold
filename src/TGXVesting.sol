// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TGXVesting
 * @dev Multi-beneficiary linear vesting contract for TGX allocations.
 *
 * Used for:
 * - Team + Contributors (15,000,000 TGX) - schedules created at or shortly after launch
 * - Early LP Bootstrap (8,000,000 TGX)   - schedules created on demand as LPs are onboarded
 *
 * Design:
 * - One schedule per beneficiary address (prevents accidental overwrites)
 * - Admin creates schedules via createSchedule(); TGX is pulled from admin at creation time
 * - Admin can revoke a schedule; unvested tokens return to a specified treasury address
 * - Already-vested but unclaimed tokens remain claimable after revocation
 * - Standard cliff + linear vesting: zero before cliff, then linear from cliff end to full vest
 */
contract TGXVesting is AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable tgx;

    struct Schedule {
        uint256 totalAmount; // total TGX allocated to this beneficiary
        uint256 startTime; // vesting start (cliff measured from here)
        uint64 cliff; // cliff duration in seconds (e.g., 365 days)
        uint64 duration; // linear vest duration after cliff (e.g., 1095 days)
        uint256 released; // TGX already claimed
        bool revoked;
        uint256 vestedAtRevoke; // snapshot of vested amount at revocation; claim cap after revoke
    }

    mapping(address => Schedule) public schedules;

    event ScheduleCreated(
        address indexed beneficiary, uint256 totalAmount, uint256 startTime, uint64 cliff, uint64 duration
    );
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(address indexed beneficiary, address indexed treasury, uint256 unvestedReturned);

    error TGXVesting__ZeroAddress();
    error TGXVesting__ZeroAmount();
    error TGXVesting__ScheduleExists();
    error TGXVesting__NoSchedule();
    error TGXVesting__AlreadyRevoked();
    error TGXVesting__NothingToRelease();
    error TGXVesting__InvalidDuration();

    constructor(address defaultAdmin, address _tgx) {
        if (defaultAdmin == address(0)) revert TGXVesting__ZeroAddress();
        if (_tgx == address(0)) revert TGXVesting__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        tgx = IERC20(_tgx);
    }

    /**
     * @notice Create a vesting schedule for a beneficiary.
     * @dev Pulls `amount` TGX from msg.sender - admin must approve this contract first.
     *      One schedule per address. Use a unique address per team member or LP.
     * @param beneficiary Recipient of the vested tokens
     * @param amount      Total TGX to vest
     * @param startTime   Unix timestamp from which the cliff is measured
     * @param cliff       Cliff duration in seconds (e.g., 365 days = 31536000)
     * @param duration    Linear vesting duration after cliff (e.g., 1095 days = 94608000)
     */
    function createSchedule(address beneficiary, uint256 amount, uint256 startTime, uint64 cliff, uint64 duration)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (beneficiary == address(0)) revert TGXVesting__ZeroAddress();
        if (amount == 0) revert TGXVesting__ZeroAmount();
        if (duration == 0) revert TGXVesting__InvalidDuration();
        if (schedules[beneficiary].totalAmount > 0) revert TGXVesting__ScheduleExists();

        tgx.safeTransferFrom(msg.sender, address(this), amount);

        schedules[beneficiary] = Schedule({
            totalAmount: amount,
            startTime: startTime,
            cliff: cliff,
            duration: duration,
            released: 0,
            revoked: false,
            vestedAtRevoke: 0
        });

        emit ScheduleCreated(beneficiary, amount, startTime, cliff, duration);
    }

    /**
     * @notice Revoke a vesting schedule.
     * @dev Unvested tokens at the time of revocation are returned to `treasury`.
     *      Already-vested but unclaimed tokens remain claimable by the beneficiary:
     *      the vested amount is snapshotted into vestedAtRevoke, which caps release().
     */
    function revokeSchedule(address beneficiary, address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury == address(0)) revert TGXVesting__ZeroAddress();
        Schedule storage s = schedules[beneficiary];
        if (s.totalAmount == 0) revert TGXVesting__NoSchedule();
        if (s.revoked) revert TGXVesting__AlreadyRevoked();

        uint256 vestedNow = _vestedAmount(s);
        uint256 unvested = s.totalAmount - vestedNow;

        // Snapshot the vested amount; release() is capped at this after revocation
        s.revoked = true;
        s.vestedAtRevoke = vestedNow;

        if (unvested > 0) {
            tgx.safeTransfer(treasury, unvested);
        }

        emit ScheduleRevoked(beneficiary, treasury, unvested);
    }

    /**
     * @notice Claim all currently releasable vested tokens.
     */
    function release() external {
        Schedule storage s = schedules[msg.sender];
        if (s.totalAmount == 0) revert TGXVesting__NoSchedule();

        uint256 amount = _releasableAmount(s);
        if (amount == 0) revert TGXVesting__NothingToRelease();

        s.released += amount;
        tgx.safeTransfer(msg.sender, amount);

        emit TokensReleased(msg.sender, amount);
    }

    /**
     * @notice Amount currently releasable for a beneficiary.
     */
    function releasable(address beneficiary) external view returns (uint256) {
        return _releasableAmount(schedules[beneficiary]);
    }

    /**
     * @notice Total vested amount (including already released) at the current timestamp.
     */
    function vested(address beneficiary) external view returns (uint256) {
        return _vestedAmount(schedules[beneficiary]);
    }

    // ============ Internal ============

    function _releasableAmount(Schedule storage s) internal view returns (uint256) {
        if (s.totalAmount == 0) return 0;
        return _vestedAmount(s) - s.released;
    }

    function _vestedAmount(Schedule storage s) internal view returns (uint256) {
        // After revocation, the claimable amount is frozen at the revocation snapshot
        if (s.revoked) return s.vestedAtRevoke;

        uint256 cliffEnd = s.startTime + s.cliff;
        if (block.timestamp < cliffEnd) return 0;
        if (block.timestamp >= cliffEnd + s.duration) return s.totalAmount;
        uint256 elapsed = block.timestamp - cliffEnd;
        return (s.totalAmount * elapsed) / s.duration;
    }
}
