// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Exercises callbacks during transferFrom, before the vault has finished pulling funds.
contract PullCallbackToken is ERC20 {
    address private target;
    bytes private payload;
    bool public attempted;
    bool public succeeded;
    bytes public result;

    constructor() ERC20("Pull callback fixture", "PULL") {
        _mint(msg.sender, 1e27);
    }

    function arm(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
        succeeded = false;
        delete result;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (to == target && !attempted) {
            attempted = true;
            (succeeded, result) = target.call(payload);
        }
    }
}
