// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @title DeployStakingVault
/// @notice Reviewable deployment for local networks and manual deployments.
/// @dev The production launch goes through the ProjectFactory described by launch.json, which deploys
/// `LaunchToken` and then `StakingVault` with `$token` as the first argument; this script reproduces that
/// order for a developer chain. `run()` reads the environment and hands a config to `deployAll`, which the
/// tests call directly, so no test depends on an environment variable or on the broadcaster.
contract DeployStakingVault is Script {
    /// @notice Constructor parameters of the vault. Mirrors launch.json's constructorArgs after `$token`.
    struct VaultConfig {
        uint256 rewardsDuration;
        uint256 minimumFunding;
    }

    /// @notice Recommended reward period: 30 days.
    uint256 public constant DEFAULT_REWARDS_DURATION = 30 days;

    /// @notice Recommended minimum funding: 1,000 tokens.
    uint256 public constant DEFAULT_MINIMUM_FUNDING = 1_000 * 1e18;

    /// @notice Deploys the token and then the vault bound to it. The caller of this function receives the
    /// token supply, as the factory does in production.
    function deployAll(VaultConfig memory config) public returns (LaunchToken token, StakingVault vault) {
        token = new LaunchToken();
        vault = deployVault(address(token), config);
    }

    /// @notice Deploys a vault for an existing token.
    function deployVault(address token, VaultConfig memory config) public returns (StakingVault vault) {
        vault = new StakingVault(token, config.rewardsDuration, config.minimumFunding);
    }

    /// @notice Entry point for `forge script`. Optional environment: REWARDS_DURATION, MINIMUM_FUNDING and
    /// STAKING_TOKEN (set to reuse an already deployed token instead of deploying a new one).
    function run() external returns (address token, address vault) {
        VaultConfig memory config = VaultConfig({
            rewardsDuration: vm.envOr("REWARDS_DURATION", DEFAULT_REWARDS_DURATION),
            minimumFunding: vm.envOr("MINIMUM_FUNDING", DEFAULT_MINIMUM_FUNDING)
        });
        address existingToken = vm.envOr("STAKING_TOKEN", address(0));

        vm.startBroadcast();
        if (existingToken == address(0)) {
            (LaunchToken deployedToken, StakingVault deployedVault) = deployAll(config);
            token = address(deployedToken);
            vault = address(deployedVault);
        } else {
            token = existingToken;
            vault = address(deployVault(existingToken, config));
        }
        vm.stopBroadcast();
    }
}
