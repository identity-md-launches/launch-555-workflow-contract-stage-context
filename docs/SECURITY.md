# Security notes

Tests passing are not an audit. The vault holds other people's tokens, so the independent adversarial
review that follows this stage is required before release. These notes record the assumptions the design
rests on and how each checklist item from the pinned `eth-security` reference was handled.

## Trust assumptions

- **No privileged party.** The vault has no owner, admin, pauser or upgrader. The deployer (the factory)
  is never read from `msg.sender` and gets nothing. All three constructor values are immutable.
- **The staked token is the launch token.** `LaunchToken` is a plain OpenZeppelin ERC-20 with no hooks,
  fees, rebasing, pausing or blocklist. The vault's accounting assumes exact transfers and enforces it
  (`TransferAmountMismatch`); hostile tokens are only used in tests to show the guards hold.
- **Funders are unprivileged.** Anyone can fund enough to restart a full `rewardsDuration` while
  preserving or increasing an active emission rate. A smaller active-period contribution reverts,
  regardless of who submits it. After a period ends, a new stream may have a lower rate. Accepted
  funding cannot remove earned rewards or principal. Future payouts still depend on how long each
  account remains staked and on the total stake over time.
- **Time.** Lock and streaming use `block.timestamp`. A validator can shift it by seconds; against a
  7-day lock and a 30-day period this changes nothing material.
- **No randomness, no oracles, no swaps.** APR is a display value computed from the current rate and
  stake; it is not a promise and depends on nothing external.

## Threats considered

| Threat | Handling |
| --- | --- |
| Reentrancy via the token | `nonReentrant` on every state-changing function, checks-effects-interactions, `SafeERC20`. Tested with a callback token that re-enters `unstake`, `claim` and `exit`: the inner call fails, outer accounting is intact. |
| Draining principal through rewards | Rewards paid ≤ rewards funded by construction (`rate = total / duration`, remainder parked). Vault balance always equals `totalStaked + rewardReserve()`. Unit, fuzz and invariant tests. |
| Unstaking someone else's stake | Only `balanceOf[msg.sender]` can be withdrawn; tested. |
| Bypassing the lock | Lock checked before any effect; a top-up re-locks the whole balance; tested at `lockedUntil - 1` and at `lockedUntil`. |
| Funding that defers rewards past another staker's departure | Reject an active-period restart when its proposed rate is below the current rate. The 1,000-token minimum alone was not an economic defense: a dominant staker could recover top-up costs and profit from delayed rewards. The supplied departure/profit regression, rate threshold boundaries and fuzz tests cover the revised rule. |
| Stranded rewards when nobody is staked | Parked in `unallocatedRewards`, folded into the next funding. Tested. |
| Direct donations manipulating shares | Not shares-based; donations are ignored by accounting (neither rewards nor principal). Tested. No ERC-4626 inflation surface. |
| Rounding dust | Each global accumulator update loses less than `totalStaked / 1e18` token wei in aggregate; each account checkpoint separately loses less than one token wei. These losses can accumulate. When `totalStaked` becomes zero, every account has checkpointed and the vault recycles only `rewardReserve - totalCheckpointedRewards - remainingStream` into `unallocatedRewards`. Tests cover the reported three wei, repeated checkpoints, unpaid former stakers, an active stream and direct donations. |
| Overflow | Solidity 0.8 checked math. With the 10^27 fixed supply every amount is ≤ 1e27, `rewardPerTokenStored` ≤ 1e45 and `balance * Δ` ≤ 1e72 < 2^256. |
| Escape opcodes | No `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`; tested on the runtime of both contracts. |
| Admin backdoors | Curated selector probe (`owner`, `transferOwnership`, `pause`, `setRewardRate`, `recoverERC20`, `emergencyWithdraw`, `mint`, `upgradeTo`, …) returns failure on both contracts; tested. |

## Known limitations (by design, documented in the README)

- A top-up re-locks the whole balance for 7 days. Per-deposit tranches were not implemented.
- Tokens sent directly to the vault cannot be recovered or distributed except by being ignored; there is
  no sweep function because any sweep is an admin power.
- Rewards accrue only during a funded period; between periods stakers earn nothing until someone funds.
- `aprWad` extrapolates the current second to a year. It is informational.
- A small top-up can be rejected during an active period even if it meets `minimumFunding`; see the
  pacing formula in `DEPLOYMENT.md`. The rate check, not the minimum, prevents slowing the stream.
- Accumulator and account rounding dust is recyclable only once all stake has left. Later accepted
  funding and stakers are needed to distribute it. Individual sub-wei account fractions are not retained;
  settled dust is pooled for future stakers. Unpaid integer rewards remain reserved for their owners.

## Checklist results (eth-security pre-deploy list)

| Item | Result |
| --- | --- |
| Access control | No privileged functions exist. |
| Pausable trade-off | No pause; nothing to flag. |
| Reentrancy | CEI + `nonReentrant`; tested. |
| Token decimals | Single 18-decimal token fixed at construction; no cross-token math. |
| Oracle safety | No oracle. |
| Integer math | Multiply before divide in `rewardPerToken` and `earned`; funding remainder kept; accumulated dust reconciled on the last withdrawal without recycling unpaid user rewards or the active stream. |
| Return values | `SafeERC20` everywhere. |
| Input validation | Zero address, zero duration, zero amount, below-minimum funding, zero rate, decreasing active rate, oversized unstake, lock all rejected and tested. |
| Events | `Staked`, `Unstaked`, `RewardPaid`, `RewardsFunded` on every state change. |
| Incentive design | Funding is permissionless and self-serving for anyone who wants stakers paid. |
| Infinite approvals | The vault approves nothing. Users approve the vault; the website should request exact amounts. |
| Fee-on-transfer | Exact-delivery check, reverts otherwise; tested with a fee token. |
| MEV / swaps | None. |
| Proxies / upgradeability / delegatecall / EIP-712 | None used. |
| Automated analysis | `forge build` (lint on), `forge test` with 512-run fuzz and 64×32 invariant runs. Slither and Mythril are not available in this environment and were not run; recommended for the review step. |
| Explorer verification | Open item for the network's deployer after launch. |
