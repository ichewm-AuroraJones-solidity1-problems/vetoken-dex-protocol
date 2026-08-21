// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RebasingMock is ERC20 {
    uint8 private immutable _customDecimals;

    event Rebased(address indexed account, uint256 oldBalance, uint256 newBalance);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBalance(address account, uint256 newBalance) external {
        uint256 oldBalance = balanceOf(account);

        if (newBalance > oldBalance) {
            _mint(account, newBalance - oldBalance);
        } else if (newBalance < oldBalance) {
            _burn(account, oldBalance - newBalance);
        }

        emit Rebased(account, oldBalance, newBalance);
    }
}
