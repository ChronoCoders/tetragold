// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {OracleAggregator} from "../src/OracleAggregator.sol";
import {InsuranceFund} from "../src/InsuranceFund.sol";
import {MockChainlinkOracle} from "./mocks/MockChainlinkOracle.sol";
import {MockBandOracle} from "./mocks/MockBandOracle.sol";
import {MockAPI3Oracle} from "./mocks/MockAPI3Oracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

contract MockVaultManagerTL {
    function getTotalValueLocked() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title TimelockTest
 * @notice Verifies that the slow governance parameters (oracle thresholds and
 *         the insurance-fund target percentage) can be placed behind a 48h
 *         TimelockController via PARAM_ROLE, while emergency pause remains on the
 *         fast admin role. Demonstrates: direct calls are blocked once the EOA
 *         renounces PARAM_ROLE, scheduled changes cannot execute before the
 *         delay, and execute succeeds after the delay elapses.
 */
contract TimelockTest is Test {
    uint256 internal constant DELAY = 48 hours;

    TimelockController internal timelock;
    OracleAggregator internal oracle;
    InsuranceFund internal fund;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal executor = makeAddr("executor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        // Timelock: proposer schedules, executor executes, admin bootstraps then
        // is renounced inside the constructor (admin == address(0)).
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new TimelockController(DELAY, proposers, executors, address(0));

        // Oracle aggregator with three mock feeds.
        MockChainlinkOracle chainlink = new MockChainlinkOracle(8);
        MockBandOracle band = new MockBandOracle();
        MockAPI3Oracle api3 = new MockAPI3Oracle();
        vm.prank(admin);
        oracle = new OracleAggregator(admin, address(chainlink), address(band), address(api3));

        // Insurance fund with light mocks.
        MockAavePool aave = new MockAavePool();
        MockVaultManagerTL vault = new MockVaultManagerTL();
        vm.prank(admin);
        fund = new InsuranceFund(admin, address(vault), address(this), address(aave));

        // Hand PARAM_ROLE to the timelock and have the admin renounce it, so the
        // only path to changing these parameters is through the 48h timelock.
        vm.startPrank(admin);
        oracle.grantRole(oracle.PARAM_ROLE(), address(timelock));
        oracle.renounceRole(oracle.PARAM_ROLE(), admin);
        fund.grantRole(fund.PARAM_ROLE(), address(timelock));
        fund.renounceRole(fund.PARAM_ROLE(), admin);
        vm.stopPrank();
    }

    function test_AdminCannotSetThresholdDirectlyAfterRenounce() public {
        bytes32 paramRole = oracle.PARAM_ROLE();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, paramRole)
        );
        oracle.setCircuitBreakerThreshold(800);
    }

    function test_TimelockSetsCircuitBreakerThresholdAfterDelay() public {
        bytes memory data = abi.encodeCall(OracleAggregator.setCircuitBreakerThreshold, (800));
        bytes32 salt = bytes32("cb");

        vm.prank(proposer);
        timelock.schedule(address(oracle), 0, data, bytes32(0), salt, DELAY);

        // Cannot execute before the delay elapses.
        vm.prank(executor);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY);

        vm.prank(executor);
        timelock.execute(address(oracle), 0, data, bytes32(0), salt);

        assertEq(oracle.circuitBreakerThreshold(), 800);
    }

    function test_TimelockSetsPriceDeviationAfterDelay() public {
        bytes memory data = abi.encodeCall(OracleAggregator.setPriceDeviation, (300));
        bytes32 salt = bytes32("pd");

        vm.prank(proposer);
        timelock.schedule(address(oracle), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(oracle), 0, data, bytes32(0), salt);

        assertEq(oracle.priceDeviationThreshold(), 300);
    }

    function test_TimelockSetsTargetPercentageAfterDelay() public {
        bytes memory data = abi.encodeCall(InsuranceFund.updateTargetPercentage, (200));
        bytes32 salt = bytes32("tp");

        vm.prank(proposer);
        timelock.schedule(address(fund), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(executor);
        timelock.execute(address(fund), 0, data, bytes32(0), salt);

        assertEq(fund.targetPercentage(), 200);
    }

    function test_NonProposerCannotSchedule() public {
        bytes memory data = abi.encodeCall(OracleAggregator.setCircuitBreakerThreshold, (800));
        vm.prank(stranger);
        vm.expectRevert();
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32("x"), DELAY);
    }

    function test_EmergencyPauseStaysImmediate() public {
        // Pause is on ADMIN_ROLE / DEFAULT_ADMIN_ROLE, untouched by the timelock,
        // so the admin can still pause instantly without waiting out the delay.
        vm.prank(admin);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.prank(admin);
        fund.pause();
        assertTrue(fund.paused());
    }
}
