// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @dev Drives the vault with random stakes, unstakes, claims, fundings and time jumps from a small set of actors.
/// Reverts are expected for locked or oversized actions and are swallowed; the invariants check what survives.
contract StakingVaultHandler is Test {
    LaunchToken public token;
    StakingVault public vault;
    address[] public actors;

    uint256 public ghostFunded;
    uint256 public ghostStakedNet;

    constructor(LaunchToken token_, StakingVault vault_, address[] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(who);
        vault.stake(amount);
        ghostStakedNet += amount;
    }

    function unstake(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 staked = vault.balanceOf(who);
        if (staked == 0 || block.timestamp < vault.lockedUntil(who)) return;
        amount = bound(amount, 1, staked);
        vm.prank(who);
        vault.unstake(amount);
        ghostStakedNet -= amount;
    }

    function claim(uint256 seed) external {
        address who = _actor(seed);
        if (vault.earned(who) == 0) return;
        vm.prank(who);
        vault.claim();
    }

    function exit(uint256 seed) external {
        address who = _actor(seed);
        uint256 staked = vault.balanceOf(who);
        if (staked == 0 || block.timestamp < vault.lockedUntil(who)) return;
        vm.prank(who);
        vault.exit();
        ghostStakedNet -= staked;
    }

    function fund(uint256 seed, uint256 amount) external {
        address who = _actor(seed);
        uint256 balance = token.balanceOf(who);
        if (balance < vault.minimumFunding()) return;
        amount = bound(amount, vault.minimumFunding(), balance);
        vm.prank(who);
        vault.fundRewards(amount);
        ghostFunded += amount;
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 40 days);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }
}

contract StakingVaultInvariantTest is Test {
    LaunchToken internal token;
    StakingVault internal vault;
    StakingVaultHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        vault = new StakingVault(address(token), 30 days, 1_000e18);

        for (uint256 i; i < 4; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            token.transfer(actor, 5_000_000e18);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
        }
        handler = new StakingVaultHandler(token, vault, actors);
        targetContract(address(handler));
    }

    /// @dev The vault always holds every staker's principal plus every reward it still owes.
    function invariant_vaultHoldsPrincipalAndReserve() public view {
        assertEq(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve());
        assertGe(token.balanceOf(address(vault)), vault.totalStaked());
    }

    /// @dev Stake accounting matches the actions that were taken.
    function invariant_totalStakedMatchesLedger() public view {
        assertEq(vault.totalStaked(), handler.ghostStakedNet());
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.balanceOf(actors[i]);
        }
        assertEq(sum, vault.totalStaked());
    }

    /// @dev Rewards paid can never exceed rewards funded, and nothing owed can exceed the reserve.
    function invariant_rewardsBoundedByFunding() public view {
        assertEq(vault.totalRewardsFunded(), handler.ghostFunded());
        assertLe(vault.totalRewardsPaid(), vault.totalRewardsFunded());
        uint256 owed;
        uint256 checkpointed;
        for (uint256 i; i < actors.length; ++i) {
            owed += vault.earned(actors[i]);
            checkpointed += vault.rewards(actors[i]);
        }
        assertLe(owed, vault.rewardReserve());
        assertEq(vault.totalCheckpointedRewards(), checkpointed);
        uint256 remaining = vault.periodFinish() > block.timestamp ? vault.periodFinish() - block.timestamp : 0;
        assertLe(owed + remaining * vault.rewardRate() + vault.unallocatedRewards(), vault.rewardReserve());

        if (vault.totalStaked() == 0) {
            // Includes empty-period emissions not yet checkpointed into unallocatedRewards.
            uint256 uncheckpointedStream = (vault.periodFinish() - vault.lastUpdateTime()) * vault.rewardRate();
            assertEq(checkpointed + uncheckpointedStream + vault.unallocatedRewards(), vault.rewardReserve());
        }
    }

    /// @dev The active period never promises more than the vault has set aside for it.
    function invariant_periodCoveredByReserve() public view {
        uint256 remaining = vault.periodFinish() > block.timestamp ? vault.periodFinish() - block.timestamp : 0;
        assertLe(remaining * vault.rewardRate() + vault.unallocatedRewards(), vault.rewardReserve());
    }

    /// @dev Settle every account after each random sequence. No unpaid entitlement may be recycled, and all
    /// residual funded rewards must become recyclable once the final principal balance is withdrawn.
    function afterInvariant() public {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 end = vault.periodFinish() > now_ ? vault.periodFinish() : now_;
        vm.warp(end + vault.LOCK_DURATION());
        for (uint256 i; i < actors.length; ++i) {
            if (vault.balanceOf(actors[i]) != 0) {
                vm.prank(actors[i]);
                vault.exit();
            } else if (vault.earned(actors[i]) != 0) {
                vm.prank(actors[i]);
                vault.claim();
            }
        }
        // If there were no stakers, checkpoint any empty-period emissions as well.
        token.approve(address(vault), 1);
        vault.stake(1);
        vm.warp(vm.getBlockTimestamp() + vault.LOCK_DURATION());
        vault.exit();
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.totalCheckpointedRewards(), 0);
        assertEq(vault.rewardReserve(), vault.unallocatedRewards());
        assertEq(token.balanceOf(address(vault)), vault.unallocatedRewards());
    }
}
