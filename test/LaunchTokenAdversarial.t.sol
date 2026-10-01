// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenAdversarialTest is Test {
    uint256 private constant SUPPLY = 1e27;
    LaunchToken private token;
    address private alice = makeAddr("token-alice");
    address private bob = makeAddr("token-bob");
    address private spender = makeAddr("token-spender");

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new LaunchToken();
        token.transfer(alice, SUPPLY);
    }

    function test_fullSupplyRoundTrip() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), SUPPLY);
        vm.prank(bob);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyWalletEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(bob, alice, 0);
        vm.prank(bob);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAddressesAreRejectedWithoutBurningOrSpendingAllowance() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        token.approve(spender, 1);
        vm.stopPrank();

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1);
        assertEq(token.allowance(alice, spender), 1);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumTransferFailsWithoutChangingBalances() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, SUPPLY, type(uint256).max)
        );
        token.transfer(bob, type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_revokeAllowancePreventsPreviouslyAuthorizedSpender() public {
        vm.startPrank(alice);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), 0);
    }

    function testFuzz_selfTransferPreservesBalancesButSpendsFiniteAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.startPrank(alice);
        token.transfer(alice, amount);
        token.approve(spender, amount);
        vm.stopPrank();
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, amount));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_finiteAllowanceIsConsumedExactlyOnce(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 1, SUPPLY);
        amount = bound(amount, 0, allowance);
        vm.prank(alice);
        token.approve(spender, allowance);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        uint256 remaining = allowance - amount;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, remaining, remaining + 1)
        );
        token.transferFrom(alice, bob, remaining + 1);
        vm.stopPrank();
        assertEq(token.allowance(alice, spender), remaining);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_infiniteApprovalSurvivesTransfers(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientBalanceRollsBackAllowanceSpend(uint256 balance) public {
        balance = bound(balance, 0, SUPPLY - 1);
        vm.startPrank(alice);
        token.transfer(bob, SUPPLY - balance);
        token.approve(spender, balance + 1);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, balance + 1)
        );
        token.transferFrom(alice, bob, balance + 1);
        assertEq(token.allowance(alice, spender), balance + 1);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(bob), SUPPLY - balance);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
