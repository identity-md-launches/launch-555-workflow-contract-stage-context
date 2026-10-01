// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {ReenteringToken} from "./mocks/ReenteringToken.sol";

contract StakingVaultTest is Test {
    uint256 internal constant DURATION = 30 days;
    uint256 internal constant MIN_FUNDING = 1_000e18;
    uint256 internal constant LOCK = 7 days;

    LaunchToken internal token;
    StakingVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal funder = makeAddr("funder");

    event Staked(address indexed account, uint256 amount, uint256 lockedUntil);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    function setUp() public {
        // Start at a non-zero, deterministic time so lock arithmetic is meaningful.
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        vault = new StakingVault(address(token), DURATION, MIN_FUNDING);

        token.transfer(alice, 1_000_000e18);
        token.transfer(bob, 1_000_000e18);
        token.transfer(funder, 10_000_000e18);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(funder);
        token.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(funder);
        vault.fundRewards(amount);
    }

    /// @dev The vault must always hold every staker's principal plus every reward it still owes.
    function _assertSolvent() internal view {
        assertGe(token.balanceOf(address(vault)), vault.totalStaked() + vault.rewardReserve(), "vault insolvent");
        assertEq(
            token.balanceOf(address(vault)),
            vault.totalStaked() + vault.totalRewardsFunded() - vault.totalRewardsPaid(),
            "balance drifted from accounting"
        );
    }

    // ------------------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------------------

    function test_constructorStoresParameters() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.rewardsDuration(), DURATION);
        assertEq(vault.minimumFunding(), MIN_FUNDING);
        assertEq(vault.LOCK_DURATION(), 7 days);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.rewardRate(), 0);
        assertEq(vault.periodFinish(), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        new StakingVault(address(0), DURATION, MIN_FUNDING);
    }

    function test_constructorRejectsZeroDuration() public {
        vm.expectRevert(StakingVault.ZeroDuration.selector);
        new StakingVault(address(token), 0, MIN_FUNDING);
    }

    function test_constructorAcceptsZeroMinimumFunding() public {
        StakingVault open = new StakingVault(address(token), DURATION, 0);
        assertEq(open.minimumFunding(), 0);
    }

    function test_noOwnerOrAdminSelectors() public {
        string[6] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "setRewardRate(uint256)",
            "recoverERC20(address,uint256)",
            "emergencyWithdraw()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        bytes memory runtime = address(vault).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    // ------------------------------------------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------------------------------------------

    function test_stakeRecordsBalanceAndLock() public {
        uint256 unlock = block.timestamp + LOCK;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Staked(alice, 100e18, unlock);
        _stake(alice, 100e18);

        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.lockedUntil(alice), unlock);
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(token.balanceOf(alice), 1_000_000e18 - 100e18);
        _assertSolvent();
    }

    function test_stakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_stakeWithoutApprovalReverts() public {
        address carol = makeAddr("carol");
        token.transfer(carol, 10e18);
        vm.prank(carol);
        vm.expectRevert();
        vault.stake(10e18);
    }

    function test_stakeBeyondBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.stake(1_000_000e18 + 1);
    }

    function test_restakeResetsLockForWholeBalance() public {
        _stake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        _stake(alice, 1e18);
        assertEq(vault.lockedUntil(alice), block.timestamp + LOCK);

        // The original lock would have expired by now; the top-up re-locked the whole balance.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        uint256 unlock = vault.lockedUntil(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, unlock));
        vault.unstake(1);

        vm.warp(unlock);
        vm.prank(alice);
        vault.unstake(101e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_stakeRefusesTokenThatDeliversLess() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        StakingVault feeVault = new StakingVault(address(fee), DURATION, 0);
        fee.approve(address(feeVault), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(StakingVault.TransferAmountMismatch.selector, 100e18, 99e18));
        feeVault.stake(100e18);

        vm.expectRevert(abi.encodeWithSelector(StakingVault.TransferAmountMismatch.selector, 100e18, 99e18));
        feeVault.fundRewards(100e18);
    }

    // ------------------------------------------------------------------------------------------------------
    // Unstaking and the lock
    // ------------------------------------------------------------------------------------------------------

    function test_unstakeDuringLockReverts() public {
        _stake(alice, 100e18);
        uint256 unlock = vault.lockedUntil(alice);

        vm.warp(unlock - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, unlock));
        vault.unstake(100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, unlock));
        vault.exit();
    }

    function test_unstakeAfterLockReturnsPrincipal() public {
        _stake(alice, 100e18);
        vm.warp(vault.lockedUntil(alice));

        vm.expectEmit(true, true, true, true, address(vault));
        emit Unstaked(alice, 40e18);
        vm.prank(alice);
        vault.unstake(40e18);
        assertEq(vault.balanceOf(alice), 60e18);
        assertEq(vault.totalStaked(), 60e18);

        vm.prank(alice);
        vault.unstake(60e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(alice), 1_000_000e18);
        _assertSolvent();
    }

    function test_unstakeMoreThanStakedReverts() public {
        _stake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 100e18 + 1, 100e18));
        vault.unstake(100e18 + 1);
    }

    function test_unstakeZeroReverts() public {
        _stake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.unstake(0);
    }

    function test_unstakeWithNothingStakedReverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 1, 0));
        vault.unstake(1);

        vm.prank(bob);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.exit();
    }

    function test_unstakeCannotTouchOtherStakers() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 101e18, 100e18));
        vault.unstake(101e18);
    }

    // ------------------------------------------------------------------------------------------------------
    // Funding
    // ------------------------------------------------------------------------------------------------------

    function test_fundStartsPeriod() public {
        uint256 amount = 3_000e18;
        uint256 expectedRate = amount / DURATION;
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsFunded(funder, amount, expectedRate, block.timestamp + DURATION);
        _fund(amount);

        assertEq(vault.rewardRate(), expectedRate);
        assertEq(vault.periodFinish(), block.timestamp + DURATION);
        assertEq(vault.lastUpdateTime(), block.timestamp);
        assertEq(vault.totalRewardsFunded(), amount);
        assertEq(vault.rewardForDuration(), expectedRate * DURATION);
        assertEq(vault.unallocatedRewards(), amount - expectedRate * DURATION);
        assertEq(vault.rewardReserve(), amount);
        _assertSolvent();
    }

    function test_fundByAnyone() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vault.fundRewards(MIN_FUNDING);
        assertEq(vault.totalRewardsFunded(), MIN_FUNDING);
        // Funding is not a stake: alice's principal is unchanged.
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.totalStaked(), 100e18);
    }

    function test_fundZeroReverts() public {
        vm.prank(funder);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.fundRewards(0);
    }

    function test_fundBelowMinimumReverts() public {
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.FundingBelowMinimum.selector, MIN_FUNDING - 1, MIN_FUNDING));
        vault.fundRewards(MIN_FUNDING - 1);
    }

    function test_fundWithoutApprovalReverts() public {
        address carol = makeAddr("carol");
        token.transfer(carol, MIN_FUNDING);
        vm.prank(carol);
        vm.expectRevert();
        vault.fundRewards(MIN_FUNDING);
    }

    function test_fundRateZeroReverts() public {
        StakingVault open = new StakingVault(address(token), DURATION, 0);
        token.approve(address(open), type(uint256).max);
        vm.expectRevert(StakingVault.RewardRateZero.selector);
        open.fundRewards(DURATION - 1);
        open.fundRewards(DURATION);
        assertEq(open.rewardRate(), 1);
    }

    function test_fundDuringPeriodRollsLeftoverIntoNewPeriod() public {
        _stake(alice, 100e18); // somebody is staked, so nothing is parked while time passes
        _fund(3_000e18);
        uint256 rate1 = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 leftover = (vault.periodFinish() - block.timestamp) * rate1;
        uint256 dust = vault.unallocatedRewards();
        uint256 earnedSoFar = vault.earned(alice);

        _fund(6_000e18);
        uint256 total = 6_000e18 + leftover + dust;
        assertEq(vault.rewardRate(), total / DURATION);
        assertEq(vault.periodFinish(), block.timestamp + DURATION);
        assertEq(vault.unallocatedRewards(), total - (total / DURATION) * DURATION);
        assertEq(vault.totalRewardsFunded(), 9_000e18);
        // A refunding never takes back what was already earned.
        assertEq(vault.earned(alice), earnedSoFar);
        _assertSolvent();
    }

    function test_fundAfterPeriodStartsFresh() public {
        _fund(3_000e18);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        // Nobody staked: the whole first period is parked as unallocated.
        _fund(3_000e18);
        uint256 total = 6_000e18;
        assertEq(vault.rewardRate(), total / DURATION);
        assertEq(vault.unallocatedRewards(), total - (total / DURATION) * DURATION);
    }

    function test_topUpCannotLowerRateAndRevertRollsBackCheckpoint() public {
        _stake(alice, 100e18);
        _fund(1_000_000e18);
        uint256 finish = vault.periodFinish();
        uint256 rate = vault.rewardRate();
        uint256 updated = vault.lastUpdateTime();
        uint256 accumulator = vault.rewardPerTokenStored();
        uint256 parked = vault.unallocatedRewards();
        uint256 funderBalance = token.balanceOf(funder);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 earnedBefore = vault.earned(alice);
        uint256 proposed = (MIN_FUNDING + parked + (finish - block.timestamp) * rate) / DURATION;

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardRateDecrease.selector, proposed, rate));
        vault.fundRewards(MIN_FUNDING);

        assertEq(vault.rewardRate(), rate);
        assertEq(vault.periodFinish(), finish);
        assertEq(vault.lastUpdateTime(), updated);
        assertEq(vault.rewardPerTokenStored(), accumulator);
        assertEq(vault.unallocatedRewards(), parked);
        assertEq(vault.earned(alice), earnedBefore);
        assertEq(vault.totalRewardsFunded(), 1_000_000e18);
        assertEq(token.balanceOf(funder), funderBalance);
        _assertSolvent();
    }

    function test_topUpAtRateFloorAcceptedOneWeiLessRejected() public {
        _stake(alice, 100e18);
        _fund(DURATION * 1e18);
        uint256 finish = vault.periodFinish();
        vm.warp(vm.getBlockTimestamp() + 10 days);
        uint256 topUp = 10 days * 1e18;
        uint256 earnedBefore = vault.earned(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardRateDecrease.selector, 1e18 - 1, 1e18));
        vault.fundRewards(topUp - 1);
        vm.prank(bob);
        vault.fundRewards(topUp);
        assertEq(vault.rewardRate(), 1e18);
        assertEq(vault.periodFinish(), block.timestamp + DURATION);
        assertEq(vault.earned(alice), earnedBefore);

        vm.warp(finish);
        assertEq(vault.earned(alice), DURATION * 1e18, "original scheduled rewards were delayed");
        _assertSolvent();
    }

    function test_lowerRateCanStartAtExactPeriodFinish() public {
        _stake(alice, 100e18);
        _fund(DURATION * 1e18);
        uint256 finish = vault.periodFinish();
        vm.warp(finish - 1);
        uint256 proposed = (MIN_FUNDING + 1e18) / DURATION;
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardRateDecrease.selector, proposed, 1e18));
        vault.fundRewards(MIN_FUNDING);

        vm.warp(finish);
        _fund(MIN_FUNDING);
        assertEq(vault.rewardRate(), MIN_FUNDING / DURATION);
        assertEq(vault.earned(alice), DURATION * 1e18);
        assertEq(vault.periodFinish(), finish + DURATION);
        _assertSolvent();
    }

    function testFuzz_activeFundingCannotLowerRate(uint256 delay, uint256 amount) public {
        delay = bound(delay, 1, DURATION - 1);
        amount = bound(amount, MIN_FUNDING, 5_000_000e18);
        _stake(alice, 100e18);
        _fund(DURATION * 1e18);
        uint256 finish = vault.periodFinish();
        vm.warp(vm.getBlockTimestamp() + delay);
        uint256 earnedBefore = vault.earned(alice);
        uint256 proposed = (amount + (DURATION - delay) * 1e18) / DURATION;
        if (proposed < 1e18) {
            vm.prank(funder);
            vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardRateDecrease.selector, proposed, 1e18));
            vault.fundRewards(amount);
            assertEq(vault.periodFinish(), finish);
        } else {
            _fund(amount);
            assertGe(vault.rewardRate(), 1e18);
            assertEq(vault.periodFinish(), block.timestamp + DURATION);
        }
        assertEq(vault.earned(alice), earnedBefore);
        vm.warp(finish);
        // Each of the two global updates loses less than totalStaked / 1e18 = 100 token wei.
        assertGe(vault.earned(alice) + 200, DURATION * 1e18);
        _assertSolvent();
    }

    function test_rewardsStreamedWithNoStakersAreParkedNotLost() public {
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + 10 days);

        _stake(alice, 100e18);
        assertEq(vault.unallocatedRewards(), (3_000e18 - rate * DURATION) + rate * 10 days);
        assertEq(vault.earned(alice), 0);
        _assertSolvent();

        // The parked amount joins the next funding.
        uint256 parked = vault.unallocatedRewards();
        uint256 leftover = (vault.periodFinish() - block.timestamp) * rate;
        _fund(MIN_FUNDING);
        assertEq(vault.rewardRate(), (MIN_FUNDING + parked + leftover) / DURATION);
    }

    // ------------------------------------------------------------------------------------------------------
    // Reward accrual
    // ------------------------------------------------------------------------------------------------------

    function test_singleStakerEarnsWholePeriod() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        assertEq(vault.earned(alice), rate * (DURATION / 2));

        vm.warp(vm.getBlockTimestamp() + DURATION);
        assertEq(vault.earned(alice), rate * DURATION);
        assertApproxEqAbs(vault.earned(alice), 3_000e18, DURATION); // dust < one wei per second
        assertEq(vault.lastTimeRewardApplicable(), vault.periodFinish());
    }

    function test_noRewardsBeforeFundingOrAfterPeriod() public {
        _stake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(vault.earned(alice), 0);

        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + DURATION + 30 days);
        assertEq(vault.earned(alice), rate * DURATION);
        assertEq(vault.aprWad(), 0);
    }

    function test_twoStakersShareProRataByAmount() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _fund(4_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + DURATION);

        uint256 total = rate * DURATION;
        assertApproxEqAbs(vault.earned(alice), total / 4, 1);
        assertApproxEqAbs(vault.earned(bob), total * 3 / 4, 1);
        assertLe(vault.earned(alice) + vault.earned(bob), total);
    }

    function test_lateStakerEarnsOnlyFromEntry() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        _stake(bob, 100e18);
        uint256 aliceFirstHalf = rate * (DURATION / 2);
        assertEq(vault.earned(alice), aliceFirstHalf);
        assertEq(vault.earned(bob), 0);

        vm.warp(vm.getBlockTimestamp() + DURATION / 2);
        uint256 secondHalf = rate * (DURATION / 2);
        assertApproxEqAbs(vault.earned(alice), aliceFirstHalf + secondHalf / 2, 1);
        assertApproxEqAbs(vault.earned(bob), secondHalf / 2, 1);
        assertLe(vault.earned(alice) + vault.earned(bob), rate * DURATION);
    }

    function test_unstakingStopsFurtherAccrualButKeepsEarned() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + LOCK);
        uint256 earnedAtExit = rate * LOCK;

        vm.prank(alice);
        vault.unstake(100e18);
        assertEq(vault.earned(alice), earnedAtExit);
        assertEq(vault.rewards(alice), earnedAtExit);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.earned(alice), earnedAtExit);
        // Nobody is staked now: that day is parked.
        _stake(bob, 1e18);
        assertEq(vault.unallocatedRewards(), (3_000e18 - rate * DURATION) + rate * 1 days);
    }

    function test_aprReflectsRateAndStake() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        assertEq(vault.aprWad(), rate * 365 days * 1e18 / 100e18);
        _stake(bob, 100e18);
        assertEq(vault.aprWad(), rate * 365 days * 1e18 / 200e18);
    }

    function test_aprIsZeroWithoutStakeOrPeriod() public {
        assertEq(vault.aprWad(), 0);
        _fund(3_000e18);
        assertEq(vault.aprWad(), 0);
        _stake(alice, 100e18);
        assertGt(vault.aprWad(), 0);
        vm.warp(vault.periodFinish());
        assertEq(vault.aprWad(), 0);
    }

    // ------------------------------------------------------------------------------------------------------
    // Claiming
    // ------------------------------------------------------------------------------------------------------

    function test_claimPaysRewardsAndKeepsPrincipalLocked() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 expected = rate * 1 days;

        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardPaid(alice, expected);
        vm.prank(alice);
        vault.claim();

        assertEq(token.balanceOf(alice), 1_000_000e18 - 100e18 + expected);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.rewards(alice), 0);
        assertEq(vault.totalRewardsPaid(), expected);
        assertEq(vault.balanceOf(alice), 100e18);
        assertGt(vault.lockedUntil(alice), block.timestamp);
        _assertSolvent();

        // Accrual continues after a claim.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.earned(alice), expected);
    }

    function test_claimWithNothingEarnedReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        vault.claim();

        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_doubleClaimPaysNothingTwice() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        vault.claim();
        uint256 balance = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        vault.claim();
        assertEq(token.balanceOf(alice), balance);
    }

    function test_exitReturnsPrincipalAndRewards() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        uint256 rate = vault.rewardRate();
        vm.warp(vm.getBlockTimestamp() + LOCK);

        vm.prank(alice);
        vault.exit();
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(alice), 1_000_000e18 + rate * LOCK);
        _assertSolvent();
    }

    function test_exitWithZeroRewardsStillWorks() public {
        _stake(alice, 100e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);
        vm.prank(alice);
        vault.exit();
        assertEq(token.balanceOf(alice), 1_000_000e18);
    }

    function test_settledDustIsRecycledAndPaidByLaterFunding() public {
        _stake(alice, 7e18);
        _fund(DURATION * (1e18 + 1));
        vm.warp(vault.periodFinish());
        vm.prank(alice);
        vault.exit();
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.totalCheckpointedRewards(), 0);
        assertEq(vault.rewardReserve(), 3);
        assertEq(vault.unallocatedRewards(), 3, "settled rounding dust must be recyclable");
        _assertSolvent();

        // Donations must not enter the reconciliation; only accounted reward funds may be recycled.
        token.transfer(address(vault), 10e18);
        _stake(alice, 1e18);
        _fund(DURATION * 1e18 - 3);
        assertEq(vault.rewardRate(), 1e18);
        assertEq(vault.unallocatedRewards(), 0);
        vm.warp(vault.periodFinish());
        vm.prank(alice);
        vault.exit();
        assertEq(vault.totalRewardsPaid(), vault.totalRewardsFunded());
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.unallocatedRewards(), 0);
        assertEq(token.balanceOf(address(vault)), 10e18, "donation entered reward accounting");
    }

    function test_dustRecyclingPreservesFormerStakersUnpaidRewards() public {
        _stake(alice, 3e18);
        _stake(bob, 4e18);
        uint256 funding = DURATION * (1e18 + 1);
        _fund(funding);
        vm.warp(vault.periodFinish());
        uint256 aliceOwed = vault.earned(alice);
        uint256 bobOwed = vault.earned(bob);
        vm.prank(alice);
        vault.unstake(3e18); // Alice leaves her entire earned reward unclaimed.
        assertEq(vault.unallocatedRewards(), 0, "must not reconcile while Bob is still staked");
        vm.prank(bob);
        vault.exit();
        uint256 dust = funding - aliceOwed - bobOwed;
        assertGt(dust, 0);
        assertEq(vault.totalCheckpointedRewards(), aliceOwed);
        assertEq(vault.unallocatedRewards(), dust);
        assertEq(vault.rewardReserve(), aliceOwed + dust);

        _stake(bob, 1e18);
        _fund(DURATION * 1e18 - dust);
        assertEq(vault.unallocatedRewards(), 0);
        vm.warp(vault.periodFinish());
        vm.prank(bob);
        vault.exit();
        assertEq(vault.rewardReserve(), aliceOwed);
        assertEq(vault.totalCheckpointedRewards(), aliceOwed);
        assertEq(vault.unallocatedRewards(), 0);
        uint256 aliceBalance = token.balanceOf(alice);
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice) - aliceBalance, aliceOwed);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.totalCheckpointedRewards(), 0);
        _assertSolvent();
    }

    function test_midStreamLastWithdrawalReservesFutureStreamAndUnpaidRewards() public {
        _stake(alice, 7e18);
        _fund(DURATION * (1e18 + 1));
        vm.warp(vm.getBlockTimestamp() + LOCK + 1);
        uint256 aliceOwed = vault.earned(alice);
        uint256 futureStream = (vault.periodFinish() - vm.getBlockTimestamp()) * vault.rewardRate();
        uint256 dust = vault.rewardReserve() - aliceOwed - futureStream;
        vm.prank(alice);
        vault.unstake(7e18);
        assertGt(dust, 0);
        assertEq(vault.unallocatedRewards(), dust);
        assertEq(vault.totalCheckpointedRewards(), aliceOwed);
        assertEq(vault.rewardReserve(), aliceOwed + futureStream + dust);

        vm.prank(alice);
        vault.claim();
        assertEq(vault.totalCheckpointedRewards(), 0);
        assertEq(vault.rewardReserve(), futureStream + dust);
        vm.warp(vault.periodFinish());
        _stake(bob, 1e18); // Checkpoint the empty remainder of the period.
        assertEq(vault.unallocatedRewards(), futureStream + dust);
        assertEq(vault.earned(bob), 0);
        _assertSolvent();
    }

    function test_repeatedAccountCheckpointsBecomeRecyclableDustOnExit() public {
        _stake(alice, 3e18 + 1);
        _stake(bob, 4e18 + 2);
        _fund(DURATION * (1e18 + 1));
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i = 1; i <= 5; ++i) {
            vm.warp(start + i * 1 days + 2 * i);
            vm.prank(alice);
            vault.claim();
            assertEq(vault.totalCheckpointedRewards(), 0);
        }
        vm.warp(vault.periodFinish());
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(vault.totalCheckpointedRewards(), 0);
        assertGt(vault.rewardReserve(), 3, "test must exercise repeated rounding losses");
        assertEq(vault.unallocatedRewards(), vault.rewardReserve());
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------------------------------
    // Principal is untouchable
    // ------------------------------------------------------------------------------------------------------

    function test_rewardsNeverExceedFundingAndPrincipalIsIntact() public {
        _stake(alice, 100e18);
        _stake(bob, 250e18);
        _fund(5_000e18);
        vm.warp(vm.getBlockTimestamp() + 12 days);
        _fund(2_500e18); // Cover the elapsed stream so restarting cannot lower its rate.
        vm.warp(vm.getBlockTimestamp() + 20 days);
        _stake(bob, 50e18);
        vm.warp(vm.getBlockTimestamp() + 40 days);

        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();

        assertLe(vault.totalRewardsPaid(), vault.totalRewardsFunded());
        assertGe(token.balanceOf(alice), 1_000_000e18);
        assertGe(token.balanceOf(bob), 1_000_000e18);
        assertEq(vault.totalStaked(), 0);
        // Whatever is left is reward reserve only, never somebody's principal.
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve());
        _assertSolvent();
    }

    function test_rewardsCannotBeClaimedFromPrincipalWhenUnfunded() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.earned(bob), 0);
        vm.prank(alice);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_directDonationDoesNotBecomeRewardsOrPrincipal() public {
        _stake(alice, 100e18);
        token.transfer(address(vault), 500e18);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.rewardReserve(), 0);
        assertEq(vault.balanceOf(alice), 100e18);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_conservationAcrossRandomSequence(
        uint96 stakeA,
        uint96 stakeB,
        uint96 funding,
        uint32 gap1,
        uint32 gap2,
        uint32 gap3
    ) public {
        stakeA = uint96(bound(stakeA, 1, 1_000_000e18));
        stakeB = uint96(bound(stakeB, 1, 1_000_000e18));
        funding = uint96(bound(funding, MIN_FUNDING, 10_000_000e18));

        _stake(alice, stakeA);
        vm.warp(vm.getBlockTimestamp() + gap1);
        _fund(funding);
        vm.warp(vm.getBlockTimestamp() + gap2);
        _stake(bob, stakeB);
        vm.warp(vm.getBlockTimestamp() + gap3);
        _assertSolvent();

        uint256 earnedA = vault.earned(alice);
        uint256 earnedB = vault.earned(bob);
        uint256 streamed = (vault.lastTimeRewardApplicable() - vault.lastUpdateTime()) * vault.rewardRate();
        assertLe(earnedA + earnedB, vault.rewardReserve(), "earned exceeds reserve");
        assertLe(earnedA + earnedB, streamed + vault.rewardPerTokenStored() * vault.totalStaked() / 1e18 + 2);

        vm.warp(vm.getBlockTimestamp() + LOCK);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();

        assertEq(vault.totalStaked(), 0);
        assertGe(token.balanceOf(alice), 1_000_000e18, "alice lost principal");
        assertGe(token.balanceOf(bob), 1_000_000e18, "bob lost principal");
        assertLe(vault.totalRewardsPaid(), vault.totalRewardsFunded(), "paid more than funded");
        _assertSolvent();
    }

    // ------------------------------------------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------------------------------------------

    function test_reentrantUnstakeIsBlocked() public {
        ReenteringToken hostile = new ReenteringToken();
        StakingVault hostileVault = new StakingVault(address(hostile), DURATION, 0);
        hostile.approve(address(hostileVault), type(uint256).max);
        hostileVault.stake(100e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);

        hostile.arm(address(hostileVault), abi.encodeCall(StakingVault.unstake, (50e18)));
        hostileVault.unstake(50e18);

        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentrant unstake went through");
        assertEq(hostileVault.balanceOf(address(this)), 50e18);
        assertEq(hostileVault.totalStaked(), 50e18);
        assertEq(hostile.balanceOf(address(hostileVault)), 50e18);
    }

    function test_reentrantClaimIsBlocked() public {
        ReenteringToken hostile = new ReenteringToken();
        StakingVault hostileVault = new StakingVault(address(hostile), DURATION, 0);
        hostile.approve(address(hostileVault), type(uint256).max);
        hostileVault.stake(100e18);
        hostileVault.fundRewards(3_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 expected = hostileVault.earned(address(this));

        hostile.arm(address(hostileVault), abi.encodeCall(StakingVault.claim, ()));
        uint256 before = hostile.balanceOf(address(this));
        hostileVault.claim();

        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentrant claim went through");
        assertEq(hostile.balanceOf(address(this)) - before, expected);
        assertEq(hostileVault.totalRewardsPaid(), expected);
    }

    function test_reentrantExitIsBlocked() public {
        ReenteringToken hostile = new ReenteringToken();
        StakingVault hostileVault = new StakingVault(address(hostile), DURATION, 0);
        hostile.approve(address(hostileVault), type(uint256).max);
        hostileVault.stake(100e18);
        hostileVault.fundRewards(3_000e18);
        vm.warp(vm.getBlockTimestamp() + LOCK);

        hostile.arm(address(hostileVault), abi.encodeCall(StakingVault.exit, ()));
        hostileVault.exit();
        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentrant exit went through");
        assertEq(hostileVault.totalStaked(), 0);
        assertLe(hostileVault.totalRewardsPaid(), hostileVault.totalRewardsFunded());
    }

    // ------------------------------------------------------------------------------------------------------
    // Views used by the website
    // ------------------------------------------------------------------------------------------------------

    function test_viewsForFrontend() public {
        _stake(alice, 100e18);
        _fund(3_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.balanceOf(alice), 100e18);
        assertEq(vault.earned(alice), vault.rewardRate() * 1 days);
        assertEq(vault.lockedUntil(alice), block.timestamp - 1 days + LOCK);
        assertGt(vault.aprWad(), 0);
        assertEq(IERC20(address(vault.token())).balanceOf(address(vault)), 100e18 + 3_000e18);
    }
}
