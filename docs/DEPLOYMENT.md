# Deployment

This stage delivers source and tests only. It does not deploy, broadcast, hold keys or write
`launch.json`; the manifest assignment and the network's services do that after review.

## Contracts in dependency order

1. `LaunchToken` — no constructor arguments. The factory deploys it and receives the whole supply.
2. `StakingVault(address token_, uint256 rewardsDuration_, uint256 minimumFunding_)`.

Supported manifest references: `token_` is `$token`. The other two are plain `uint256` values. The vault
has no owner parameter, so `$owner` is not used anywhere. Identifier suggestion for the manifest:
`StakingVault` (12 ASCII characters).

### Recommended constructor values

| Parameter | Recommended | Meaning |
| --- | --- | --- |
| `token_` | `$token` | the launch token; the vault stakes it and pays rewards in it |
| `rewardsDuration_` | `2592000` (30 days) | every funding (re)starts a period of this many seconds |
| `minimumFunding_` | `1000000000000000000000` (1,000 tokens) | smallest accepted funding, guards against dust fundings stretching the period |

`LOCK_DURATION` is a compile-time constant of 7 days, as the brief requires, and is not a parameter.

These two numbers are deployment choices, not derived from the brief. The brief fixes the lock at 7 days
and says rewards are paid per second but does not say how long a funding should stream for. 30 days was
chosen so that a single funding gives a stable APR figure for a month; the lower bound that still makes
sense is the 7-day lock itself, and anything from 7 to 90 days works with the same code. 1,000 tokens is
one millionth of the supply; raise it if dust fundings turn out to be a nuisance, lower it (even to zero)
if small community top-ups are wanted. Both must be fixed before the manifest is written and cannot be
changed afterwards.

## Constructor behaviour under the factory

- The constructor is nonpayable, takes only `address`/`uint256` arguments, makes no external calls and
  reads nothing from `msg.sender`. The factory's address plays no role; there is no owner.
- The vault starts empty: `totalStaked = 0`, `rewardRate = 0`, `periodFinish = 0`. It receives no share of
  the supply. The factory keeps the whole supply for the policy split (`SupplyMismatch` otherwise).
- Runtime is about 7.9 KB, well under EIP-170, with no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## After deployment (operational responsibilities)

| Who | What |
| --- | --- |
| Anyone who wants stakers paid | `approve(vault, amount)` then `fundRewards(amount)` with at least `minimumFunding`. The vault pays nothing until it is funded. The requester's wallet, which receives the non-pool part of the supply from the policy split, is the natural first funder. |
| Whoever runs the website | Read `aprWad`, `totalStaked`, `balanceOf`, `earned`, `lockedUntil`, `periodFinish` from `docs/abi/StakingVault.json`; wire `approve` + `stake`, `unstake`, `claim`, `exit`. Show the unlock time before a top-up, because a top-up re-locks the whole balance. |
| Stakers | Approve, stake, wait 7 days to unstake; claim any time. |
| Nobody | There is no admin. No parameter can be changed, nothing can be paused, no token can be recovered from the vault. |

When a period ends and nobody funds again, rewards stop; whatever streamed while nobody was staked waits
in `unallocatedRewards` and is handed out by the next funding of at least `minimumFunding`.

## Local or manual deployment with the script

`script/DeployStakingVault.s.sol` reproduces the factory's order (token, then vault) for a developer chain.
`run()` reads optional `REWARDS_DURATION`, `MINIMUM_FUNDING` and `STAKING_TOKEN` from the environment and
hands them to `deployAll` / `deployVault`, which the tests call directly with explicit values.

```
forge script script/DeployStakingVault.s.sol --rpc-url <url> --sender <addr>            # simulate
forge script script/DeployStakingVault.s.sol --rpc-url <url> --broadcast --account <name>  # deploy
```

Simulate first. On a manual deployment the broadcaster receives the whole token supply, which is what the
factory receives in the launch; nothing in the script allocates anything to the vault.

## Explorer verification

After the network's deployer has published the contracts, `forge verify-contract` with the pinned settings
(solc 0.8.26, evm `cancun`, optimizer 200 runs, `bytecode_hash = "none"`) verifies both contracts. This
is an open item for the deployer, not something this stage can do.
