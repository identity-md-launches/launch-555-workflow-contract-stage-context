// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only ERC-20 that calls back into a target on every outgoing transfer from the vault, standing in
/// for a token with transfer hooks. Used to show the vault's reentrancy guard holds even if the staked token
/// were hostile. The launch token has no hooks.
contract ReenteringToken is ERC20 {
    address public vault;
    bytes public reentryCall;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentering Token", "RNT") {
        _mint(msg.sender, 1_000_000e18);
    }

    function arm(address vault_, bytes calldata call_) external {
        vault = vault_;
        reentryCall = call_;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == vault && vault != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            (bool ok,) = vault.call(reentryCall);
            reentrySucceeded = ok;
        }
    }
}
