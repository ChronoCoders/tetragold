// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CounterpartyPool} from "../../src/CounterpartyPool.sol";
import {InsuranceFund} from "../../src/InsuranceFund.sol";
import {IPyth} from "../../src/oracle/interfaces/IPyth.sol";
import {PositionManager} from "../../src/PositionManager.sol";
import {ReportV8} from "../../src/oracle/ReportV8.sol";
import {TGAUX} from "../../src/TGAUX.sol";
import {TgauxVault} from "../../src/TgauxVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPaxg} from "../mocks/MockPaxg.sol";
import {PositionManagerHarness} from "../mocks/PositionManagerHarness.sol";

/// @notice Drives the vault, the pool, the fund and the manager together.
/// @dev Every step is a real call through a real entry point, including the
///      oracle, so the campaign exercises section 7 rather than a stand in for
///      it. The reports are built here because a settlement cannot happen
///      without one.
///
///      The ghosts record what this handler moved rather than what a contract
///      reported, so the conservation check below is not the protocol agreeing
///      with itself.
contract ProtocolHandler is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant TARGET_DELAY = 12;
    uint256 private constant ACTORS = 3;
    uint256 private constant MIN_POST = 0.5 ether;
    uint256 private constant MAX_POST = 50 ether;
    uint256 private constant MIN_PRICE = 3000e18;
    uint256 private constant MAX_PRICE = 5000e18;
    uint256 private immutable MAX_STEP;
    uint256 private constant TIERS = 3;
    uint32 private constant WINDOW = 12;
    uint32 private constant EXPIRY_AHEAD = 86_400;
    uint32 private constant OPEN_STATUS = 2;
    int32 private constant PYTH_EXPO = -8;
    uint256 private constant PYTH_SCALE = 1e10;
    uint256 private constant GAS_PRICE = 2 gwei;

    PositionManagerHarness public immutable MANAGER;
    CounterpartyPool public immutable POOL;
    InsuranceFund public immutable FUND;
    TgauxVault public immutable VAULT;
    TGAUX public immutable GOLD;
    MockERC20 public immutable PAXG;
    MockPaxg public immutable PAXG_READING;
    address public immutable TREASURY;
    bytes32 private immutable FEED_ID;
    bytes32 private immutable PYTH_ID;
    uint256 private immutable PYTH_FEE;

    address[ACTORS] private _actors;
    uint256[] private _pending;
    uint256[] private _pendingAdds;
    uint256[] private _open;

    uint256 public price = 4000e18;

    uint256 public mintedGold;
    uint256 public requests;
    uint256 public settlements;
    uint256 public rejections;
    uint256 public expiries;

    /// @notice The add path, counted apart from the open path so a campaign
    ///         cannot look green on adds it never made (D43).
    /// @notice Times ETH was forced into the oracle, so a campaign cannot
    ///         look green on a path it never put a balance in front of.
    uint256 public oracleDustings;

    uint256 public adds;
    uint256 public addSettlements;
    uint256 public addRejections;

    /// @notice Open requests refused while PAXG was unusable, which D50 and
    ///         I26 require, and the ones that went through anyway.
    uint256 public inflowRefusals;
    uint256 public inflowsAllowedWhileUnusable;

    uint256 public escrowMismatches;
    uint256 public conservationBreaks;
    uint256 public coverageBreaks;
    uint256 public sideInversions;
    uint256 public rateInversions;
    uint256 public wrongEndings;

    uint256 private _lastUtilisation;
    uint256 private _lastRate;

    constructor(
        PositionManagerHarness manager,
        MockERC20 paxg,
        MockPaxg paxgReading,
        bytes32 feedId,
        bytes32 pythId,
        uint256 pythFee,
        uint256 maxStep
    ) {
        MANAGER = manager;
        MAX_STEP = maxStep;
        POOL = manager.POOL();
        FUND = manager.INSURANCE_FUND();
        VAULT = TgauxVault(manager.PAXG_HOLDER());
        GOLD = manager.GOLD();
        PAXG = paxg;
        PAXG_READING = paxgReading;
        TREASURY = manager.TREASURY();
        FEED_ID = feedId;
        PYTH_ID = pythId;
        PYTH_FEE = pythFee;

        for (uint256 i = 0; i < ACTORS; i++) {
            _actors[i] = address(uint160(uint256(keccak256(abi.encodePacked("protocol actor", i)))));
        }
    }

    function actorCount() external pure returns (uint256) {
        return ACTORS;
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    /// @notice The D46 payout the pool must be able to make for every open
    ///         position at the price in use, summed in ounces. For each the
    ///         payout is max(0, C + s * (P - P_open) - fee) / P, with the
    ///         holding fee s * (I_now - I_open) priced at P. This is the
    ///         deposit side of D48, never the withdrawal side, which keeps
    ///         C minus fee for a loser and can sit above pool ounces.
    function i15bPayoutOunces() external view returns (uint256 total) {
        uint256 idxNow = MANAGER.indexNow();
        uint256 p = price;
        uint256 count = _open.length;
        for (uint256 i = 0; i < count; i++) {
            (, uint256 size, uint256 claim, uint256 openPrice, uint256 openIndex, bool isOpen) =
                MANAGER.positionAt(_open[i]);
            if (!isOpen) {
                continue;
            }
            uint256 assets = claim + (size * p) / WAD;
            uint256 feeUsd = (((size * (idxNow - openIndex)) / WAD) * p) / WAD;
            uint256 liabilities = (size * openPrice) / WAD + feeUsd;
            if (assets > liabilities) {
                total += ((assets - liabilities) * WAD) / p;
            }
        }
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function pendingAddCount() external view returns (uint256) {
        return _pendingAdds.length;
    }

    function passTime(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, MAX_STEP));
        _check();
    }

    function movePrice(uint256 seed) external {
        price = bound(seed, MIN_PRICE, MAX_PRICE);
        _check();
    }

    /// @dev An LP deposit through the harness, which stands in for the manager's
    ///      own LP path until the unit that writes it (D69).
    function lpDeposit(uint256 actorSeed, uint256 amountSeed) external {
        address lp = _actor(actorSeed);
        uint256 amount = bound(amountSeed, MIN_POST, MAX_POST);
        _fund(lp, amount);

        vm.prank(lp);
        assertTrue(GOLD.approve(address(POOL), amount));
        uint256 id = MANAGER.seedRequest(lp, amount);

        vm.warp(vm.getBlockTimestamp() + TARGET_DELAY);
        // forge-lint: disable-next-line(unused-return)
        MANAGER.seedSettle(id, price);

        _check();
    }

    function requestOpen(uint256 actorSeed, uint256 amountSeed, uint8 tier) external {
        uint256[TIERS] memory tiers = [uint256(2), 3, 5];
        address trader = _actor(actorSeed);
        uint256 amount = bound(amountSeed, MIN_POST, MAX_POST);
        _fund(trader, amount);

        uint256 fee = MANAGER.GAS_OPEN() * GAS_PRICE;
        vm.deal(trader, trader.balance + fee);

        vm.prank(trader);
        assertTrue(GOLD.approve(address(MANAGER), amount));

        // D50 and I26: an inflow is refused while PAXG is unusable. The
        // request is made either way, so the refusal is a checked claim rather
        // than a step the campaign quietly skips.
        bool usable = MANAGER.paxgUsable();

        vm.prank(trader);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try MANAGER.requestOpen{value: fee}(amount, tiers[tier % TIERS]) returns (uint256 id) {
            if (!usable) {
                inflowsAllowedWhileUnusable += 1;
            }
            _pending.push(id);
            requests += 1;
        } catch {
            if (usable) {
                assertTrue(false, "an open request was refused while PAXG was usable");
            }
            inflowRefusals += 1;
        }

        _check();
    }

    /// @dev Anyone may settle (D62), and a rule failure rejects rather than
    ///      reverting (D70), so this records which of the two happened.
    function settleOpen(uint256 idSeed) external {
        uint256 count = _pending.length;
        if (count == 0) {
            return;
        }
        uint256 at = idSeed % count;
        uint256 id = _pending[at];

        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 targetTime,,,, PositionManager.State before) = MANAGER.requestAt(id);
        if (before != PositionManager.State.Pending) {
            _drop(at);
            return;
        }
        if (vm.getBlockTimestamp() < targetTime || vm.getBlockTimestamp() >= targetTime + MANAGER.REQUEST_EXPIRY()) {
            return;
        }

        uint256 positionsBefore = MANAGER.nextPositionId();
        vm.deal(address(this), address(this).balance + PYTH_FEE);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        MANAGER.settleOpen{value: PYTH_FEE}(id, abi.encode(_report(targetTime)), _pythUpdate(targetTime));

        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State after_) = MANAGER.requestAt(id);
        if (after_ == PositionManager.State.Settled) {
            settlements += 1;
            _open.push(positionsBefore);
        } else if (after_ == PositionManager.State.Rejected) {
            rejections += 1;
        } else {
            wrongEndings += 1;
        }

        _drop(at);
        _check();
    }

    function expireOpen(uint256 idSeed) external {
        uint256 count = _pending.length;
        if (count == 0) {
            return;
        }
        uint256 at = idSeed % count;
        uint256 id = _pending[at];

        // forge-lint: disable-next-line(unused-return)
        (address requester,,, uint256 targetTime,,,, PositionManager.State state) = MANAGER.requestAt(id);
        if (state != PositionManager.State.Pending) {
            _drop(at);
            return;
        }
        if (vm.getBlockTimestamp() < targetTime + MANAGER.REQUEST_EXPIRY()) {
            return;
        }

        vm.prank(requester);
        MANAGER.expireRequest(id);
        expiries += 1;

        _drop(at);
        _check();
    }

    /// @dev D43: the owner of an open position adds collateral to it. The
    ///      amount is bounded wide enough that some adds pass the notional
    ///      ceiling of D43 rule 5 and are rejected, which is the half of the
    ///      path a tight bound would hide.
    function requestAdd(uint256 positionSeed, uint256 amountSeed) external {
        uint256 count = _open.length;
        if (count == 0) {
            return;
        }
        uint256 positionId = _open[positionSeed % count];
        // forge-lint: disable-next-line(unused-return)
        (address owner,,,,, bool open) = MANAGER.positionAt(positionId);
        if (!open) {
            return;
        }

        uint256 amount = bound(amountSeed, MIN_POST, MAX_POST);
        _fund(owner, amount);

        uint256 fee = MANAGER.GAS_ADD() * GAS_PRICE;
        vm.deal(owner, owner.balance + fee);

        vm.prank(owner);
        assertTrue(GOLD.approve(address(MANAGER), amount));

        bool usable = MANAGER.paxgUsable();

        vm.prank(owner);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try MANAGER.requestAddCollateral{value: fee}(positionId, amount) returns (uint256 id) {
            if (!usable) {
                inflowsAllowedWhileUnusable += 1;
            }
            _pendingAdds.push(id);
            adds += 1;
        } catch {
            if (usable) {
                assertTrue(false, "an add request was refused while PAXG was usable");
            }
            inflowRefusals += 1;
        }

        _check();
    }

    function settleAdd(uint256 idSeed) external {
        uint256 count = _pendingAdds.length;
        if (count == 0) {
            return;
        }
        uint256 at = idSeed % count;
        uint256 id = _pendingAdds[at];

        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 targetTime,,,, PositionManager.State before) = MANAGER.requestAt(id);
        if (before != PositionManager.State.Pending) {
            _dropAdd(at);
            return;
        }
        if (vm.getBlockTimestamp() < targetTime || vm.getBlockTimestamp() >= targetTime + MANAGER.REQUEST_EXPIRY()) {
            return;
        }

        vm.deal(address(this), address(this).balance + PYTH_FEE);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        MANAGER.settleAddCollateral{value: PYTH_FEE}(id, abi.encode(_report(targetTime)), _pythUpdate(targetTime));

        // forge-lint: disable-next-line(unused-return)
        (,,,,,,, PositionManager.State after_) = MANAGER.requestAt(id);
        if (after_ == PositionManager.State.Settled) {
            addSettlements += 1;
        } else if (after_ == PositionManager.State.Rejected) {
            addRejections += 1;
        } else {
            wrongEndings += 1;
        }

        _dropAdd(at);
        _check();
    }

    /// @dev ETH can be forced into the settlement oracle with SELFDESTRUCT,
    ///      and the oracle has no sweep, so from here on every settlement in
    ///      the sequence runs with a balance sitting in it. No settlement may
    ///      notice: this campaign reverts on revert, so one that did would
    ///      fail the run.
    function dustTheOracle(uint256 seed) external {
        vm.deal(address(MANAGER.SETTLEMENT_ORACLE()), bound(seed, 1, 1 ether));
        oracleDustings += 1;
        _check();
    }

    /// @dev D50: PAXG can stop being usable at any time, and only inflows may
    ///      notice. Nothing here asserts the brake, which is the manager's own
    ///      test.
    function movePaxg(bool frozen, bool paused) external {
        PAXG_READING.setFrozen(address(VAULT), frozen);
        PAXG_READING.setPaused(paused);
        _check();
    }

    function _check() internal {
        if (GOLD.balanceOf(address(MANAGER)) != MANAGER.escrowedOunces()) {
            escrowMismatches += 1;
        }

        uint256 held = GOLD.balanceOf(address(POOL)) + GOLD.balanceOf(address(FUND)) + GOLD.balanceOf(address(MANAGER))
            + GOLD.balanceOf(TREASURY);
        for (uint256 i = 0; i < ACTORS; i++) {
            held += GOLD.balanceOf(_actors[i]);
        }
        if (held != GOLD.totalSupply()) {
            conservationBreaks += 1;
        }

        if (POOL.ounces() < POOL.reserved()) {
            coverageBreaks += 1;
        }
        if (MANAGER.withdrawalClaimUsd(price) < MANAGER.depositClaimUsd(price)) {
            sideInversions += 1;
        }

        uint256 utilisation = POOL.utilisationBps();
        uint256 rate = MANAGER.currentRate();
        if (utilisation > _lastUtilisation && rate < _lastRate) {
            rateInversions += 1;
        }
        if (utilisation < _lastUtilisation && rate > _lastRate) {
            rateInversions += 1;
        }
        _lastUtilisation = utilisation;
        _lastRate = rate;
    }

    function _fund(address to, uint256 ounces) private {
        PAXG.mint(address(this), ounces);
        assertTrue(PAXG.approve(address(VAULT), ounces));
        uint256 minted = VAULT.deposit(ounces);
        mintedGold += minted;
        assertTrue(GOLD.transfer(to, minted));
    }

    function _report(uint256 target) private view returns (ReportV8 memory) {
        return ReportV8({
            feedId: FEED_ID,
            validFromTimestamp: uint32(target) - WINDOW,
            observationsTimestamp: uint32(target) + WINDOW,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: uint32(target) + EXPIRY_AHEAD,
            lastUpdateTimestamp: uint32(target),
            midPrice: int192(int256(price)),
            marketStatus: OPEN_STATUS
        });
    }

    function _pythUpdate(uint256 target) private view returns (bytes[] memory update) {
        int64 pythPrice = int64(int256(price / PYTH_SCALE));
        update = new bytes[](1);
        update[0] = abi.encode(
            IPyth.PriceFeed({
                id: PYTH_ID,
                price: IPyth.Price({price: pythPrice, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)}),
                emaPrice: IPyth.Price({price: pythPrice, conf: 0, expo: PYTH_EXPO, publishTime: uint64(target)})
            })
        );
    }

    function _dropAdd(uint256 at) private {
        uint256 last = _pendingAdds.length - 1;
        if (at != last) {
            _pendingAdds[at] = _pendingAdds[last];
        }
        _pendingAdds.pop();
    }

    function _drop(uint256 at) private {
        uint256 last = _pending.length - 1;
        if (at != last) {
            _pending[at] = _pending[last];
        }
        _pending.pop();
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % ACTORS];
    }

    receive() external payable {}
}
