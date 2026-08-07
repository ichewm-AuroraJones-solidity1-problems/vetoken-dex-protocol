// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BlacklistMock is ERC20 {
    mapping(address => bool) public blacklisted;

    error Blacklisted(address account);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && blacklisted[from]) revert Blacklisted(from);
        if (to != address(0) && blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
