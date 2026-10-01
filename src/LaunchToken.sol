// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice The fixed-supply launch token staked in, and paid out by, the StakingVault.
/// @dev Plain OpenZeppelin ERC-20: 18 decimals, exactly 1,000,000,000 tokens (10^27 minor units)
/// minted once to `msg.sender` in the constructor. The launch factory deploys it and so receives the
/// whole supply, which the launch policy splits. There is no mint, owner, pause, blocklist, fee,
/// upgrade, burn or hook path: transfers move exactly what they are asked to move.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Vault Stake", "VSTK") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
