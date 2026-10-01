# Launch-token staking vault

Contracts for the approved workflow: *a staking vault for the launch token: 7-day lock, rewards anyone can
fund, paid pro rata per second, principal untouchable*, plus the launch token itself.

| Contract | File | Purpose |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | Fixed-supply ERC-20 (name `Vault Stake`, symbol `VSTK`, 18 decimals). Zero-argument constructor mints exactly 10^27 minor units (1,000,000,000 tokens) to `msg.sender`. Nothing else. |
| `StakingVault` | `src/StakingVault.sol` | Stake `LaunchToken`, principal locked 7 days after every stake, rewards in `LaunchToken` funded by anyone and streamed per second pro rata to stake. No owner. |

ABI exports: `docs/abi/LaunchToken.json`, `docs/abi/StakingVault.json`.
Deployment parameters, manifest values and operator duties: `docs/DEPLOYMENT.md`.
Security assumptions and review notes: `docs/SECURITY.md`.

## How the vault works

**Staking.** `stake(amount)` pulls `amount` tokens (prior `approve` required), adds them to the caller's
`balanceOf` and `totalStaked`, and sets `lockedUntil[caller] = now + 7 days`. Every stake re-locks the
caller's *whole* balance for a fresh 7 days, including a tiny top-up: this is the simplest rule that keeps
the brief's lock honest, and the website should show the unlock time before a top-up.

**Unstaking.** `unstake(amount)` returns principal once `now >= lockedUntil[caller]`. It can only move the
caller's own `balanceOf`; nobody, including the deployer, can move anyone else's stake. `exit()` unstakes
everything and claims in one call.

**Rewards.** `fundRewards(amount)` is open to anyone (prior `approve` required). The amount, plus whatever
the active period had not yet streamed, plus any `unallocatedRewards`, is spread evenly over a new period
of `rewardsDuration` seconds starting now, so a top-up never takes back rewards that were already earned.
While a period is active, a top-up must preserve or increase `rewardRate`; otherwise it reverts with
`RewardRateDecrease(proposed, current)` without taking tokens or changing the stream. This pacing decision
retains the full-duration restart for accepted fundings while preventing a funder from pushing existing
emissions past another staker's departure by lowering the rate. Anyone may fund enough to meet this rule,
or wait until the current period ends to start a smaller stream.
Rewards accrue per second to stakers in proportion to their stake (Synthetix `rewardPerToken`
accounting, 1e18 scale). `claim()` pays everything earned so far at any time; rewards are never locked,
only principal is. Nothing accrues before the first funding or after the period ends until someone funds
again.

**Recycling undistributed rewards.** Rewards that stream while nobody is staked, and the rounding remainder of
`total / rewardsDuration`, are parked in `unallocatedRewards` and folded into the next funding instead of
being lost. Accumulator and account checkpoint rounding also leaves dust in the reserve. When the last
stake is withdrawn, all accounts have checkpointed: the vault reserves their unpaid rewards and the
remaining active stream, then assigns the residual funded balance to `unallocatedRewards`. This dust can
join later funding without consuming principal or anyone's unclaimed reward. Dust reconciliation requires
the vault to become empty; distribution requires another accepted funding and stakers. Individual
fractional entitlements are rounded down, with settled dust pooled for future stakers.

**Principal is untouchable.** Stake and reward balances are tracked separately. Rewards paid are bounded
by rewards funded (`rewardRate * rewardsDuration <= total`), the only outgoing transfers are a caller's own
`balanceOf` and a caller's own checkpointed `rewards`, and `rewardReserve()` (funded minus paid) always
equals the vault balance minus `totalStaked`. The invariant suite checks this under random sequences.

**Minimum funding.** `minimumFunding` is an absolute contribution floor and may be zero. It is not an
economic defense against slowing payouts: the separate rate check enforces pacing even with a zero
minimum. During an active period, an amount must cover both this floor and any additional funding needed
to keep the rate unchanged over a fresh full duration. Funders should simulate their transaction near
submission because this additional requirement grows as the active period elapses.

### Views for the website

| View | Meaning |
| --- | --- |
| `totalStaked()` | total staked principal |
| `balanceOf(account)` | the account's stake |
| `earned(account)` | rewards the account can claim now |
| `lockedUntil(account)` | timestamp from which the account may unstake |
| `aprWad()` | `rewardRate * 365 days * 1e18 / totalStaked`; 1e18 = 100 % APR; 0 when nothing is staked or no period is active |
| `rewardRate()`, `periodFinish()`, `rewardForDuration()` | the active stream |
| `rewardReserve()`, `unallocatedRewards()` | rewards still in the vault, and the parked part |
| `totalCheckpointedRewards()` | sum of unpaid account checkpoints; excludes rewards accruing since each account's last checkpoint |

### What the vault does not do

- No owner, pause, upgrade, fee, blocklist, `selfdestruct` or `delegatecall`. Every parameter is an
  immutable set in the constructor; the deployer gets nothing.
- No recovery function: tokens sent directly to the vault (not through `fundRewards`) are not rewards
  and not principal; they stay there. Use `fundRewards`.
- No per-deposit lock tranches: the lock is per account and resets on every stake (see above).
- No support for fee-on-transfer or rebasing tokens: a transfer that delivers anything but the exact
  amount reverts with `TransferAmountMismatch`. The launch token never does this.

## The launch token

`LaunchToken` is the standard launch token: plain OpenZeppelin ERC-20, 18 decimals, 10^27 minor units
minted once to the deployer, no mint, owner, pause, blocklist, fee, burn or upgrade path. The brief does
not ask the token for anything beyond this, so nothing was left out. The factory, not this repository,
splits the supply and seeds the pool; the vault holds only what stakers and funders send it.

## Layout

```
src/                  contracts
script/               forge deployment script for developer chains (simulate first, broadcast deliberately)
test/                 Foundry tests; test/mocks holds the hostile ERC-20s used for failure cases
docs/abi/             ABI exports
docs/DEPLOYMENT.md    parameters, manifest values, operator responsibilities
docs/SECURITY.md      assumptions, threat notes, checklist results
lib/                  vendored dependencies as plain files (no submodules):
                      forge-std 1.16.2, openzeppelin-contracts 5.7.0
```

## Build and test

```
forge build
forge test
forge fmt --check
```

The compiler is pinned to solc 0.8.26 in `foundry.toml` (evm `cancun`, optimizer 200 runs, `bytecode_hash =
"none"`, no ffi, no filesystem permissions). Tests use no environment variables and no network; they pass
in any order and in parallel. The invariant suite runs 64 sequences of 32 calls by default.
