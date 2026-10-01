// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingVault
/// @notice Single-token staking vault for the launch token: stake it, wait out a 7-day lock, earn a share of
/// rewards that anyone can fund, streamed per second pro rata to stake.
///
/// @dev Accounting follows the Synthetix StakingRewards model (a global `rewardPerToken` accumulator scaled by
/// 1e18) with two additions that keep every funded token reachable:
///
/// - Rewards that stream while nothing is staked are not lost: they accumulate in `unallocatedRewards` and are
///   folded into the next funding.
/// - The rounding remainder of `total / rewardsDuration` is likewise kept in `unallocatedRewards` instead of
///   being stranded.
///
/// Principal is untouchable by construction: stake and reward balances are tracked separately, rewards paid
/// are bounded above by rewards funded (`rewardRate * rewardsDuration <= total`), and nothing in the contract
/// can move more than `balanceOf[account]` of principal to anyone but that account.
///
/// There is no owner, no pause, no upgrade path and no privileged beneficiary. Every parameter is fixed in the
/// constructor; the deployer gets no special powers.
contract StakingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------------------
    // Constants and immutables
    // ------------------------------------------------------------------------------------------------------

    /// @notice How long principal stays locked after every stake. Fixed by the brief: 7 days.
    uint256 public constant LOCK_DURATION = 7 days;

    /// @dev Fixed-point scale of `rewardPerTokenStored` and `aprWad`.
    uint256 private constant PRECISION = 1e18;

    /// @notice The token that is staked and the token rewards are paid in. The launch token.
    IERC20 public immutable token;

    /// @notice Length, in seconds, of the reward period that every funding (re)starts.
    uint256 public immutable rewardsDuration;

    /// @notice Smallest amount `fundRewards` accepts, in minor units. Stops dust fundings from repeatedly
    /// stretching the active period (each funding spreads the leftover over a fresh `rewardsDuration`).
    uint256 public immutable minimumFunding;

    // ------------------------------------------------------------------------------------------------------
    // Reward stream state
    // ------------------------------------------------------------------------------------------------------

    /// @notice Sum of every account's staked principal.
    uint256 public totalStaked;

    /// @notice Rewards streamed per second during the active period, in minor units.
    uint256 public rewardRate;

    /// @notice Timestamp at which the active reward period ends. Zero before the first funding.
    uint256 public periodFinish;

    /// @notice Timestamp of the last accumulator update, capped at `periodFinish`.
    uint256 public lastUpdateTime;

    /// @notice Cumulative rewards per staked token, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @notice Rewards that streamed while nothing was staked, plus funding rounding remainders. Folded into the
    /// next funding so they are never stranded.
    uint256 public unallocatedRewards;

    /// @notice Lifetime total of rewards funded through `fundRewards`.
    uint256 public totalRewardsFunded;

    /// @notice Lifetime total of rewards paid out through `claim` and `exit`.
    uint256 public totalRewardsPaid;

    // ------------------------------------------------------------------------------------------------------
    // Per-account state
    // ------------------------------------------------------------------------------------------------------

    /// @notice Staked principal per account.
    mapping(address account => uint256 amount) public balanceOf;

    /// @notice Timestamp from which `account` may unstake. Reset to `now + LOCK_DURATION` by every stake.
    mapping(address account => uint256 timestamp) public lockedUntil;

    /// @notice `rewardPerTokenStored` at the account's last checkpoint.
    mapping(address account => uint256 paid) public userRewardPerTokenPaid;

    /// @notice Rewards checkpointed for the account and not yet claimed.
    mapping(address account => uint256 amount) public rewards;

    // ------------------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 lockedUntil);
    event Unstaked(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error StillLocked(uint256 unlockTime);
    error InsufficientStake(uint256 requested, uint256 available);
    error FundingBelowMinimum(uint256 amount, uint256 minimum);
    error RewardRateZero();
    error NothingToClaim();
    error TransferAmountMismatch(uint256 expected, uint256 received);

    // ------------------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------------------

    /// @param token_ The launch token: staked and paid as rewards. Must not be zero.
    /// @param rewardsDuration_ Reward period length in seconds. Must not be zero.
    /// @param minimumFunding_ Smallest accepted funding in minor units. May be zero (then any positive amount
    /// that yields a non-zero rate is accepted).
    constructor(address token_, uint256 rewardsDuration_, uint256 minimumFunding_) {
        if (token_ == address(0)) revert ZeroAddress();
        if (rewardsDuration_ == 0) revert ZeroDuration();
        token = IERC20(token_);
        rewardsDuration = rewardsDuration_;
        minimumFunding = minimumFunding_;
    }

    // ------------------------------------------------------------------------------------------------------
    // Staking
    // ------------------------------------------------------------------------------------------------------

    /// @notice Stake `amount` tokens. Requires a prior approval. Re-locks the caller's whole stake for
    /// `LOCK_DURATION`. Rewards already earned keep accruing to the caller.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);

        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        uint256 unlockTime = block.timestamp + LOCK_DURATION;
        lockedUntil[msg.sender] = unlockTime;
        emit Staked(msg.sender, amount, unlockTime);

        _pullExactly(amount);
    }

    /// @notice Withdraw `amount` of staked principal once the lock has expired. Rewards stay claimable.
    function unstake(uint256 amount) external nonReentrant {
        _unstake(amount);
    }

    /// @notice Pay out every reward the caller has earned so far. Reverts when there is nothing to pay.
    function claim() external nonReentrant {
        _updateReward(msg.sender);
        if (_payReward() == 0) revert NothingToClaim();
    }

    /// @notice Withdraw the caller's whole stake and claim any rewards in one call. Requires the lock to have
    /// expired; a zero reward is fine here.
    function exit() external nonReentrant {
        _unstake(balanceOf[msg.sender]);
        _payReward();
    }

    // ------------------------------------------------------------------------------------------------------
    // Funding
    // ------------------------------------------------------------------------------------------------------

    /// @notice Add `amount` tokens of rewards. Anyone may call. Requires a prior approval. The amount, whatever
    /// is still unstreamed from the active period and any unallocated remainder are spread evenly over a new
    /// period of `rewardsDuration` seconds starting now.
    function fundRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < minimumFunding) revert FundingBelowMinimum(amount, minimumFunding);
        _updateReward(address(0));

        uint256 total = amount + unallocatedRewards;
        if (block.timestamp < periodFinish) {
            total += (periodFinish - block.timestamp) * rewardRate;
        }
        uint256 rate = total / rewardsDuration;
        if (rate == 0) revert RewardRateZero();

        rewardRate = rate;
        unallocatedRewards = total % rewardsDuration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        totalRewardsFunded += amount;
        emit RewardsFunded(msg.sender, amount, rate, periodFinish);

        _pullExactly(amount);
    }

    // ------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------

    /// @notice The last second at which rewards accrue: now, or the end of the period if that has passed.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Cumulative rewards per staked token as of now, scaled by 1e18.
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return
            rewardPerTokenStored + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION / totalStaked;
    }

    /// @notice Rewards `account` could claim right now.
    function earned(address account) public view returns (uint256) {
        return balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account]) / PRECISION + rewards[account];
    }

    /// @notice Rewards the active period streams in total (`rewardRate * rewardsDuration`).
    function rewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    /// @notice Rewards still inside the vault: funded minus paid. Includes the unstreamed part of the active
    /// period, checkpointed-but-unclaimed rewards and `unallocatedRewards`.
    function rewardReserve() public view returns (uint256) {
        return totalRewardsFunded - totalRewardsPaid;
    }

    /// @notice Annualised reward rate as a fraction of total stake, scaled by 1e18 (1e18 = 100% APR). Zero when
    /// nothing is staked or no period is active. Assumes the current rate and stake persist for a year; it is a
    /// display figure, not a promise.
    function aprWad() external view returns (uint256) {
        if (totalStaked == 0 || block.timestamp >= periodFinish) return 0;
        return rewardRate * 365 days * PRECISION / totalStaked;
    }

    // ------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------

    /// @dev Checkpoints the global accumulator and, when `account` is non-zero, that account's rewards.
    function _updateReward(address account) private {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0) {
            // Nobody to pay: park what streamed so the next funding can hand it out.
            unallocatedRewards += (applicable - lastUpdateTime) * rewardRate;
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdateTime = applicable;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _unstake(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 unlockTime = lockedUntil[msg.sender];
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        uint256 staked = balanceOf[msg.sender];
        if (amount > staked) revert InsufficientStake(amount, staked);
        _updateReward(msg.sender);

        balanceOf[msg.sender] = staked - amount;
        totalStaked -= amount;
        emit Unstaked(msg.sender, amount);

        token.safeTransfer(msg.sender, amount);
    }

    /// @dev Pays the caller's checkpointed rewards. Caller must have run `_updateReward(msg.sender)` first.
    function _payReward() private returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (reward == 0) return 0;
        rewards[msg.sender] = 0;
        totalRewardsPaid += reward;
        emit RewardPaid(msg.sender, reward);
        token.safeTransfer(msg.sender, reward);
    }

    /// @dev Pulls `amount` from the caller and refuses anything but an exact delivery, so a token that charges
    /// a transfer fee or rebases cannot desynchronise the accounting.
    function _pullExactly(uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert TransferAmountMismatch(amount, received);
    }
}
