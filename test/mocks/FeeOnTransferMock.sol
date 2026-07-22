// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FeeOnTransferMock is ERC20 {
    uint256 public feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    /// 
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override{
        if (from == address(0) || to == address(0) || feeBps  == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value * feeBps / 10000;
        uint256 received = value - fee;

        super._update(from, to, received);
        super._update(from, address(0), fee);
    }

        
}