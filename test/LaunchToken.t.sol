// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer;
    address internal alice = makeAddr("alice");

    function setUp() public {
        deployer = address(this);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Vault Stake");
        assertEq(token.symbol(), "VSTK");
        assertEq(token.decimals(), 18);
    }

    function test_fixedSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.TOTAL_SUPPLY(), 10 ** 27);
        assertEq(token.balanceOf(deployer), 10 ** 27);
    }

    function test_supplyGoesToWhoeverDeploys() public {
        address factory = makeAddr("factory");
        vm.prank(factory);
        LaunchToken other = new LaunchToken();
        assertEq(other.balanceOf(factory), 10 ** 27);
        assertEq(other.balanceOf(deployer), 0);
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), 10 ** 27 - amount);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(alice, 10e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, alice, 10e18));
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.allowance(deployer, alice), 0);

        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferBeyondBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminSelectors() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
