// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {StakingVault} from "src/StakingVault.sol";

/// @dev Closed actor set; no deal/mint/storage edits. Ghost cash flows are recorded from
/// call inputs and observed transfers, independently of the vault's accounting counters.
contract VaultCashflowHandler is Test {
    struct AccountLedger {
        uint256 initialWallet;
        uint256 deposited;
        uint256 withdrawn;
        uint256 funded;
        uint256 paid;
        uint256 donated;
        uint256 unlock;
    }

    LaunchToken public immutable token;
    StakingVault public immutable vault;
    address[4] public actors;
    mapping(address => AccountLedger) private ledger;
    uint256 public funded;
    uint256 public paid;
    uint256 public donated;

    constructor(LaunchToken token_, StakingVault vault_, address[4] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            ledger[actors[i]].initialWallet = token.balanceOf(actors[i]);
        }
    }

    modifier monotonicCheckpoint() {
        uint256 accumulator = vault.rewardPerTokenStored();
        uint256 timestamp = vault.lastUpdateTime();
        _;
        assertGe(vault.rewardPerTokenStored(), accumulator, "reward index decreased");
        assertGe(vault.lastUpdateTime(), timestamp, "checkpoint moved backwards");
    }

    function account(address actor) external view returns (AccountLedger memory) {
        return ledger[actor];
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        if (seed % 4 == 0) return 1;
        if (seed % 4 == 1) return maximum;
        return bound(seed, 1, maximum);
    }

    function stake(uint256 actorSeed, uint256 amountSeed) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        uint256 wallet = token.balanceOf(actor);
        if (wallet == 0) return;
        uint256 amount = _amount(amountSeed, wallet);
        uint256 accrued = vault.earned(actor);
        vm.prank(actor);
        vault.stake(amount);
        ledger[actor].deposited += amount;
        ledger[actor].unlock = block.timestamp + 7 days;
        assertEq(token.balanceOf(actor), wallet - amount, "stake cash flow");
        assertEq(vault.earned(actor), accrued, "top-up changed previously earned rewards");
    }

    function fund(uint256 actorSeed, uint256 amountSeed) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        uint256 wallet = token.balanceOf(actor);
        uint256 minimum = vault.minimumFunding();
        if (wallet < minimum) return;
        uint256 amount = bound(amountSeed, minimum, wallet);
        vm.prank(actor);
        vault.fundRewards(amount);
        ledger[actor].funded += amount;
        funded += amount;
        assertEq(token.balanceOf(actor), wallet - amount, "funding cash flow");
    }

    function claim(uint256 actorSeed) public monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        uint256 expected = vault.earned(actor);
        if (expected == 0) {
            vm.prank(actor);
            vm.expectRevert(StakingVault.NothingToClaim.selector);
            vault.claim();
            return;
        }
        uint256 wallet = token.balanceOf(actor);
        vm.prank(actor);
        vault.claim();
        uint256 received = token.balanceOf(actor) - wallet;
        ledger[actor].paid += received;
        paid += received;
        assertEq(received, expected, "claim did not match quote");
        assertEq(vault.earned(actor), 0, "claim left payable rewards");
        vm.prank(actor);
        vm.expectRevert(StakingVault.NothingToClaim.selector);
        vault.claim();
    }

    function unstake(uint256 actorSeed, uint256 amountSeed) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        AccountLedger storage a = ledger[actor];
        uint256 principal = a.deposited - a.withdrawn;
        if (principal == 0) return;
        uint256 amount = _amount(amountSeed, principal);
        if (block.timestamp < a.unlock) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, a.unlock));
            vault.unstake(amount);
            return;
        }
        uint256 wallet = token.balanceOf(actor);
        uint256 accrued = vault.earned(actor);
        vm.prank(actor);
        vault.unstake(amount);
        a.withdrawn += amount;
        assertEq(token.balanceOf(actor), wallet + amount, "unstake lost principal");
        assertEq(vault.earned(actor), accrued, "unstake forfeited earned rewards");
    }

    function exit(uint256 actorSeed) public monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        AccountLedger storage a = ledger[actor];
        uint256 principal = a.deposited - a.withdrawn;
        if (principal == 0) {
            vm.prank(actor);
            vm.expectRevert(StakingVault.ZeroAmount.selector);
            vault.exit();
            return;
        }
        if (block.timestamp < a.unlock) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, a.unlock));
            vault.exit();
            return;
        }
        uint256 wallet = token.balanceOf(actor);
        uint256 accrued = vault.earned(actor);
        vm.prank(actor);
        vault.exit();
        uint256 received = token.balanceOf(actor) - wallet;
        assertEq(received, principal + accrued, "exit cash flow");
        a.withdrawn += principal;
        a.paid += received - principal;
        paid += received - principal;
        assertEq(vault.balanceOf(actor), 0);
        assertEq(vault.earned(actor), 0);
    }

    function donate(uint256 actorSeed, uint256 amountSeed) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        uint256 wallet = token.balanceOf(actor);
        if (wallet == 0) return;
        uint256 amount = _amount(amountSeed, wallet);
        uint256 accrued = vault.earned(actor);
        vm.prank(actor);
        token.transfer(address(vault), amount);
        ledger[actor].donated += amount;
        donated += amount;
        assertEq(vault.earned(actor), accrued, "donation changed earned rewards");
    }

    function advance(uint256 secondsSeed) external monotonicCheckpoint {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 45 days));
    }

    function advanceToBoundary(uint256 actorSeed, uint256 boundary) external monotonicCheckpoint {
        uint256 timestamp = boundary % 2 == 0 ? ledger[actors[actorSeed % 4]].unlock : vault.periodFinish();
        if (boundary % 3 == 0 && timestamp > 0) --timestamp;
        if (boundary % 3 == 2) ++timestamp;
        if (timestamp > block.timestamp) vm.warp(timestamp);
    }

    function rejectInvalidAmount(uint256 actorSeed, uint8 choice) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        vm.startPrank(actor);
        if (choice % 4 == 0) {
            vm.expectRevert(StakingVault.ZeroAmount.selector);
            vault.stake(0);
        } else if (choice % 4 == 1) {
            vm.expectRevert(StakingVault.ZeroAmount.selector);
            vault.fundRewards(0);
        } else if (choice % 4 == 2) {
            uint256 minimum = vault.minimumFunding();
            vm.expectRevert(abi.encodeWithSelector(StakingVault.FundingBelowMinimum.selector, minimum - 1, minimum));
            vault.fundRewards(minimum - 1);
        } else {
            uint256 principal = ledger[actor].deposited - ledger[actor].withdrawn;
            if (block.timestamp < ledger[actor].unlock) {
                vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, ledger[actor].unlock));
            } else {
                vm.expectRevert(
                    abi.encodeWithSelector(StakingVault.InsufficientStake.selector, principal + 1, principal)
                );
            }
            vault.unstake(principal + 1);
        }
        vm.stopPrank();
    }

    function rejectMissingApproval(uint256 actorSeed, bool funding) external monotonicCheckpoint {
        address actor = actors[actorSeed % 4];
        uint256 amount = funding ? vault.minimumFunding() : 1;
        vm.startPrank(actor);
        token.approve(address(vault), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), 0, amount)
        );
        if (funding) vault.fundRewards(amount);
        else vault.stake(amount);
        token.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StakingVaultStatefulTest is Test {
    LaunchToken private token;
    StakingVault private vault;
    VaultCashflowHandler private handler;
    address[4] private actors;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        vault = new StakingVault(address(token), 30 days, 1_000e18);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("cashflow-actor-", vm.toString(i)));
            token.transfer(actors[i], 1e27 / 4);
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
        handler = new VaultCashflowHandler(token, vault, actors);

        // Seed real stakes and a nonzero payout. All subsequent accounting remains random.
        for (uint256 i; i < 4; ++i) {
            handler.stake(i, 1e18 + 2);
        }
        handler.fund(0, 30 days * 1e18);
        handler.advance(1 days);
        handler.claim(1);
        assertGt(handler.paid(), 0, "seed sequence must exercise a reward payout");

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.unstake.selector;
        selectors[4] = handler.exit.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.advanceToBoundary.selector;
        selectors[8] = handler.rejectInvalidAmount.selector;
        selectors[9] = handler.rejectMissingApproval.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_cashAndPrincipalMatchIndependentLedger() public view {
        uint256 principal;
        uint256 wallets;
        for (uint256 i; i < 4; ++i) {
            address actor = actors[i];
            VaultCashflowHandler.AccountLedger memory a = handler.account(actor);
            assertLe(a.withdrawn, a.deposited, "withdrew more principal than deposited");
            assertEq(vault.balanceOf(actor), a.deposited - a.withdrawn, "per-user principal mismatch");
            assertEq(vault.lockedUntil(actor), a.unlock, "another operation changed the lock");
            assertEq(
                token.balanceOf(actor) + a.deposited + a.funded + a.donated,
                a.initialWallet + a.withdrawn + a.paid,
                "wallet cash flow mismatch"
            );
            principal += a.deposited - a.withdrawn;
            wallets += token.balanceOf(actor);
        }
        assertEq(vault.totalStaked(), principal);
        assertEq(vault.totalRewardsFunded(), handler.funded());
        assertEq(vault.totalRewardsPaid(), handler.paid());
        assertLe(handler.paid(), handler.funded());
        assertEq(token.balanceOf(address(vault)), principal + handler.funded() - handler.paid() + handler.donated());
        assertEq(vault.rewardReserve(), handler.funded() - handler.paid());
        assertEq(wallets + token.balanceOf(address(vault)), 1e27, "token supply escaped closed actor set");
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_allRewardLiabilitiesFitInsideReserveTogether() public view {
        uint256 owed;
        for (uint256 i; i < 4; ++i) {
            owed += vault.earned(actors[i]);
        }
        uint256 future =
            vault.periodFinish() > block.timestamp ? (vault.periodFinish() - block.timestamp) * vault.rewardRate() : 0;
        uint256 idlePending = vault.totalStaked() == 0
            ? (vault.lastTimeRewardApplicable() - vault.lastUpdateTime()) * vault.rewardRate()
            : 0;
        assertLe(owed + future + idlePending + vault.unallocatedRewards(), vault.rewardReserve());
        assertLe(vault.lastUpdateTime(), vault.lastTimeRewardApplicable());
    }

    /// @dev Liveness matters as well as backing: every sequence must actually let everyone leave.
    function afterInvariant() public {
        uint256 finish = block.timestamp;
        if (vault.periodFinish() > finish) finish = vault.periodFinish();
        for (uint256 i; i < 4; ++i) {
            VaultCashflowHandler.AccountLedger memory a = handler.account(actors[i]);
            if (a.unlock > finish) finish = a.unlock;
        }
        vm.warp(finish);
        for (uint256 i; i < 4; ++i) {
            if (vault.balanceOf(actors[i]) > 0) handler.exit(i);
            else if (vault.earned(actors[i]) > 0) handler.claim(i);
            VaultCashflowHandler.AccountLedger memory a = handler.account(actors[i]);
            assertEq(a.deposited, a.withdrawn, "principal could not be recovered");
            assertEq(vault.earned(actors[i]), 0);
        }
        assertEq(vault.totalStaked(), 0);
        invariant_cashAndPrincipalMatchIndependentLedger();
        invariant_allRewardLiabilitiesFitInsideReserveTogether();
    }
}
