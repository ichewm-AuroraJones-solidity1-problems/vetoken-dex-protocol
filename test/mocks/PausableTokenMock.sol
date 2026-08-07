// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PausableTokenMock is ERC20 {
    bool public transfersPaused;

    error TokenPaused();

    constructor (string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to,amount);
    }

    function setTransfersPaused(bool value) external {
        transfersPaused = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (transfersPaused && from != address(0) && to != address(0)) {
            revert TokenPaused();
        }

        super._update(from, to, value);
    }
}