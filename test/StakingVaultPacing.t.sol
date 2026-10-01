// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakingVault} from "src/StakingVault.sol";

contract StakingVaultPacingTest is Test {
    function test_topUpsCannotProfitByDeferringAnotherStakersRewards() public {
        uint256 start = 1_700_000_000;
        vm.warp(start);
        LaunchToken token = new LaunchToken();
        StakingVault vault = new StakingVault(address(token), 30 days, 1_000e18);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        token.transfer(alice, 100_000e18);
        token.transfer(bob, 930_000e18);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.stake(100_000e18);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(vault), type(uint256).max);
        vault.stake(900_000e18);
        vm.stopPrank();
        token.approve(address(vault), 1_000_000e18);
        vault.fundRewards(1_000_000e18);

        uint256 snapshot = vm.snapshotState();
        vm.warp(start + 30 days);
        vm.prank(alice);
        vault.exit();
        uint256 baselineAlice = token.balanceOf(alice) - 100_000e18;
        vm.warp(start + 60 days);
        vm.prank(bob);
        vault.exit();
        uint256 baselineBobNet = token.balanceOf(bob) - 930_000e18;
        assertTrue(vm.revertToState(snapshot));

        uint256 spent;
        for (uint256 day = 1; day < 30; ++day) {
            vm.warp(start + day * 1 days);
            vm.prank(bob);
            // Accept a fix that rejects a top-up which would slow the stream.
            (bool accepted,) = address(vault).call(abi.encodeCall(StakingVault.fundRewards, (1_000e18)));
            if (accepted) spent += 1_000e18;
        }
        vm.warp(start + 30 days);
        vm.prank(alice);
        vault.exit();
        uint256 actualAlice = token.balanceOf(alice) - 100_000e18;
        uint256 finalFinish = vault.periodFinish();
        vm.warp(finalFinish > start + 60 days ? finalFinish : start + 60 days);
        vm.prank(bob);
        vault.exit();
        uint256 actualBobNet = token.balanceOf(bob) - 930_000e18;

        emit log_named_uint("baseline Alice reward", baselineAlice);
        emit log_named_uint("actual Alice reward", actualAlice);
        emit log_named_uint("baseline Bob net reward", baselineBobNet);
        emit log_named_uint("actual Bob net reward after funding cost", actualBobNet);
        emit log_named_uint("Bob top-ups", spent);
        emit log_named_uint("final period finish", finalFinish);

        // A microtoken tolerance is much larger than the rounding error in this scenario.
        assertLe(actualBobNet, baselineBobNet + 1e12, "top-ups profit by moving rewards past Alice's exit");
        assertGe(actualAlice + 1e12, baselineAlice, "third-party top-ups reduce Alice's scheduled payout");
    }
}
