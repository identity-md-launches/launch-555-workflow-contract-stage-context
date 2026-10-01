// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployStakingVault} from "../script/DeployStakingVault.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

contract DeployStakingVaultTest is Test {
    DeployStakingVault internal deployer;

    function setUp() public {
        deployer = new DeployStakingVault();
    }

    function test_deployAllWiresVaultToToken() public {
        DeployStakingVault.VaultConfig memory config =
            DeployStakingVault.VaultConfig({rewardsDuration: 30 days, minimumFunding: 1_000e18});
        (LaunchToken token, StakingVault vault) = deployer.deployAll(config);

        assertEq(address(vault.token()), address(token));
        assertEq(vault.rewardsDuration(), 30 days);
        assertEq(vault.minimumFunding(), 1_000e18);
        // The script contract made the `new` call, so it holds the supply, as the factory would.
        assertEq(token.balanceOf(address(deployer)), 10 ** 27);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_deployVaultForExistingToken() public {
        LaunchToken token = new LaunchToken();
        DeployStakingVault.VaultConfig memory config = DeployStakingVault.VaultConfig({
            rewardsDuration: deployer.DEFAULT_REWARDS_DURATION(), minimumFunding: deployer.DEFAULT_MINIMUM_FUNDING()
        });
        StakingVault vault = deployer.deployVault(address(token), config);
        assertEq(address(vault.token()), address(token));
        assertEq(vault.rewardsDuration(), 30 days);
        assertEq(vault.minimumFunding(), 1_000e18);
    }

    function test_deployVaultRejectsBadConfig() public {
        DeployStakingVault.VaultConfig memory config =
            DeployStakingVault.VaultConfig({rewardsDuration: 0, minimumFunding: 0});
        vm.expectRevert(StakingVault.ZeroDuration.selector);
        deployer.deployVault(address(new LaunchToken()), config);
    }
}
