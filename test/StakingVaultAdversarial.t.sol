// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakingVault} from "src/StakingVault.sol";
import {PullCallbackToken} from "./mocks/PullCallbackToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract StakingVaultAdversarialTest is Test {
    uint256 private constant START = 1_700_000_000;
    uint256 private constant DURATION = 30 days;
    uint256 private constant MINIMUM = 1_000e18;
    address private alice = makeAddr("vault-alice");
    address private bob = makeAddr("vault-bob");
    LaunchToken private token;
    StakingVault private vault;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        vault = new StakingVault(address(token), DURATION, MINIMUM);
        token.transfer(alice, 100e18);
        token.transfer(bob, 100e18);
        token.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
    }

    // Captures global reward checkpoints as well as the account and actual token ledger.
    function _state(address actor) private view returns (bytes32) {
        bytes32 stream = keccak256(
            abi.encode(
                vault.totalStaked(),
                vault.rewardRate(),
                vault.periodFinish(),
                vault.lastUpdateTime(),
                vault.rewardPerTokenStored(),
                vault.unallocatedRewards(),
                vault.totalRewardsFunded(),
                vault.totalRewardsPaid()
            )
        );
        return keccak256(
            abi.encode(
                stream,
                vault.balanceOf(actor),
                vault.lockedUntil(actor),
                vault.rewards(actor),
                vault.userRewardPerTokenPaid(actor),
                vault.earned(actor),
                token.balanceOf(actor),
                token.balanceOf(address(vault)),
                token.allowance(actor, address(vault))
            )
        );
    }

    function _stake(address actor, uint256 amount) private {
        vm.prank(actor);
        vault.stake(amount);
    }

    function test_failedTopUpRollsBackRewardCheckpointAndLock() public {
        _stake(alice, 10e18);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 6 days);
        vm.prank(alice);
        token.approve(address(vault), 0);
        bytes32 beforeState = _state(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, 1));
        vault.stake(1);
        assertEq(_state(alice), beforeState);
        assertEq(vault.lockedUntil(alice), START + 7 days);

        // The failed top-up cannot postpone recovery of the original principal.
        vm.warp(START + 7 days);
        vm.prank(alice);
        vault.unstake(10e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_failedFundingRollsBackIdleRewardsAndPeriod() public {
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 10 days);
        token.approve(address(vault), 0);
        bytes32 beforeState = _state(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, MINIMUM)
        );
        vault.fundRewards(MINIMUM);
        assertEq(_state(address(this)), beforeState);

        token.approve(address(vault), MINIMUM);
        vault.fundRewards(MINIMUM);
        assertEq(vault.totalRewardsFunded(), DURATION * 1e18 + MINIMUM);
        assertEq(vault.periodFinish(), START + 40 days);
        assertEq(vault.rewardForDuration() + vault.unallocatedRewards(), vault.totalRewardsFunded());
    }

    function test_failedClaimTransferLeavesRewardsClaimable() public {
        _stake(alice, 10e18);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 1 days);
        uint256 earned = vault.earned(alice);
        bytes32 beforeState = _state(alice);
        vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (alice, earned)), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.claim();
        assertEq(_state(alice), beforeState);

        vm.clearMockedCalls();
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice), 90e18 + earned);
        assertEq(vault.totalRewardsPaid(), earned);
        assertEq(vault.earned(alice), 0);
    }

    function test_exitIsAtomicWhenSecondTransferFails() public {
        _stake(alice, 10e18);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 7 days);
        uint256 earned = vault.earned(alice);
        bytes32 beforeState = _state(alice);
        // Principal transfer succeeds, but reward transfer returns false.
        vm.mockCall(address(token), abi.encodeCall(IERC20.transfer, (alice, earned)), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.exit();
        assertEq(_state(alice), beforeState);

        vm.clearMockedCalls();
        vm.prank(alice);
        vault.exit();
        assertEq(token.balanceOf(alice), 100e18 + earned);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.earned(alice), 0);
    }

    function test_partialUnstakeDoesNotRelockAndCanStillClaimAfterFullWithdrawal() public {
        _stake(alice, 10e18);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 7 days);
        vm.startPrank(alice);
        vault.unstake(4e18);
        assertEq(vault.lockedUntil(alice), START + 7 days);
        vault.unstake(6e18);
        vm.stopPrank();
        uint256 earned = vault.earned(alice);
        vm.warp(START + 60 days);
        assertEq(vault.earned(alice), earned);
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice), 100e18 + earned);
        assertEq(vault.totalStaked(), 0);
    }

    function test_oneWeiStakeCanRecoverAllPrincipal() public {
        _stake(alice, 1);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + 7 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + 7 days));
        vault.unstake(1);
        vm.warp(START + 7 days);
        vm.prank(alice);
        vault.exit();
        assertEq(token.balanceOf(alice), 100e18 + 7 days * 1e18);
        assertEq(vault.totalStaked(), 0);
    }

    function test_fullSupplyStakeHasNoRewardClaimOnItsPrincipal() public {
        LaunchToken fullToken = new LaunchToken();
        StakingVault fullVault = new StakingVault(address(fullToken), DURATION, MINIMUM);
        fullToken.approve(address(fullVault), type(uint256).max);
        fullVault.stake(1e27);
        vm.warp(START + 7 days);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        fullVault.claim();
        fullVault.exit();
        assertEq(fullToken.balanceOf(address(this)), 1e27);
        assertEq(fullToken.balanceOf(address(fullVault)), 0);
        assertEq(fullVault.totalStaked(), 0);
    }

    function test_oneSecondPeriodPaysAlmostFullSupplyWithoutOverflow() public {
        LaunchToken edgeToken = new LaunchToken();
        StakingVault edgeVault = new StakingVault(address(edgeToken), 1, 0);
        edgeToken.approve(address(edgeVault), type(uint256).max);
        edgeVault.stake(1);
        edgeVault.fundRewards(1e27 - 1);
        vm.warp(START + 1);
        assertEq(edgeVault.earned(address(this)), 1e27 - 1);
        edgeVault.claim();
        assertEq(edgeToken.balanceOf(address(this)), 1e27 - 1);
        assertEq(edgeToken.balanceOf(address(edgeVault)), 1);
        assertEq(edgeVault.rewardReserve(), 0);
        vm.warp(START + 7 days);
        edgeVault.exit();
        assertEq(edgeToken.balanceOf(address(this)), 1e27);
        assertEq(edgeVault.totalStaked(), 0);
    }

    function test_maximumUnstakeRevertsWithExactAvailableStake() public {
        _stake(alice, 1);
        vm.warp(START + 7 days);
        bytes32 beforeState = _state(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, type(uint256).max, 1));
        vault.unstake(type(uint256).max);
        assertEq(_state(alice), beforeState);
    }

    function test_fundingAtFinishCannotRetroactivelyPayAnEmptyInterval() public {
        _stake(alice, 1e18);
        vault.fundRewards(DURATION * 1e18);
        vm.warp(START + DURATION);
        vm.prank(alice);
        vault.exit();
        vm.warp(START + DURATION + 3 days);
        _stake(bob, 1e18);
        assertEq(vault.earned(bob), 0);
        vault.fundRewards(DURATION * 2e18);
        assertEq(vault.earned(bob), 0);
        vm.warp(START + DURATION + 3 days + 1);
        assertEq(vault.earned(bob), 2e18);
        assertEq(vault.earned(alice), 0);
    }

    // Direct interval integration: one staker, then a 1:2 split, then a 1:1 split.
    // Amounts divide the stream exactly, so this oracle needs no rounding tolerance.
    function testFuzz_rewardsFollowStakeChangesPerSecond(uint256 middle, uint256 last) public {
        middle = bound(middle, 1, 3 days);
        last = bound(last, 1, 3 days);
        _stake(alice, 2e18);
        vault.fundRewards(DURATION * 12e18);
        vm.warp(START + 7 days);
        _stake(bob, 2e18);
        vm.prank(alice);
        vault.unstake(1e18);
        vm.warp(START + 7 days + middle);
        _stake(alice, 1e18);
        vm.warp(START + 7 days + middle + last);
        uint256 aliceReward = 7 days * 12e18 + middle * 4e18 + last * 6e18;
        uint256 bobReward = middle * 8e18 + last * 6e18;
        assertEq(vault.earned(alice), aliceReward);
        assertEq(vault.earned(bob), bobReward);
        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();
        assertEq(token.balanceOf(alice), 98e18 + aliceReward);
        assertEq(token.balanceOf(bob), 98e18 + bobReward);
        assertEq(vault.totalRewardsPaid(), (7 days + middle + last) * 12e18);
    }

    function testFuzz_splitClaimsEqualSingleClaimWhenRewardsAreIntegral(uint256 checkpoint) public {
        checkpoint = bound(checkpoint, 1, DURATION - 1);
        _stake(alice, 1e18);
        _stake(bob, 1e18);
        vault.fundRewards(DURATION * 2e18);
        vm.warp(START + checkpoint);
        vm.prank(alice);
        vault.claim();
        vm.warp(START + DURATION);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(token.balanceOf(alice), 100e18 + DURATION * 1e18);
        assertEq(token.balanceOf(alice), token.balanceOf(bob));
        assertEq(vault.rewardReserve(), 0);
    }

    function test_callbacksOnBothPullPathsRejectEveryMutatingEntryPoint() public {
        PullCallbackToken hostile = new PullCallbackToken();
        StakingVault guarded = new StakingVault(address(hostile), DURATION, 0);
        hostile.approve(address(guarded), type(uint256).max);
        bytes[5] memory calls = [
            abi.encodeCall(StakingVault.stake, (1)),
            abi.encodeCall(StakingVault.fundRewards, (DURATION)),
            abi.encodeCall(StakingVault.unstake, (1)),
            abi.encodeCall(StakingVault.claim, ()),
            abi.encodeCall(StakingVault.exit, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            hostile.arm(address(guarded), calls[i]);
            guarded.stake(1e18);
            _assertGuardRejection(hostile);
            hostile.arm(address(guarded), calls[i]);
            guarded.fundRewards(DURATION * 1e18);
            _assertGuardRejection(hostile);
        }
        assertEq(guarded.totalStaked(), 5e18);
        assertEq(guarded.totalRewardsFunded(), 5 * DURATION * 1e18);
        assertEq(hostile.balanceOf(address(guarded)), 5e18 + 5 * DURATION * 1e18);
    }

    function _assertGuardRejection(PullCallbackToken hostile) private view {
        assertTrue(hostile.attempted());
        assertFalse(hostile.succeeded());
        assertEq(hostile.result(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
