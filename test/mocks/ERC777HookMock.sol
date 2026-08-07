// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";

contract ERC777HookMock is ERC20 {
    enum ReenterCall {
        Stake,
        Withdraw,
        GetReward,
        Exit,
        EmergencyExit,
        FundAndNotify,
        SweepUnallocatedRewards,
        RecoverExcessStakingToken,
        RecoverERC20
    }

    StakingRewards public target;
    ReenterCall public reenterCall;
    address public recipient;
    address public recoverToken;
    uint256 public reenterAmount;
    bool public enabled;
    bool private entered;

    constructor(string memory name_, string memory symbol_) ERC20(name_,symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to,amount);
    }

    function approveSpender(address spender, uint256 amount) external {
        _approve(address(this), spender, amount);
    }

    function configure(
        StakingRewards target_,
        ReenterCall reenterCall_,
        uint256 reenterAmount_,
        address recipient_,
        address recoverToken_
    ) external {
        target = target_;
        reenterCall = reenterCall_;
        reenterAmount = reenterAmount_;
        recipient = recipient_;
        recoverToken = recoverToken_;
    }

    function setEnabled(bool enabled_) external {
        enabled = enabled_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (enabled && !entered && from != address(0) && to != address(0)) {
            entered = true;
            _reenter();
        }

        super._update(from, to, value);
    }

    function _reenter() internal {
        if (reenterCall == ReenterCall.Stake) {
            target.stake(reenterAmount);
    
        } else if (reenterCall == ReenterCall.Withdraw) {
            target.withdraw(reenterAmount);

        } else if (reenterCall == ReenterCall.GetReward) {
            target.getReward();

        } else if (reenterCall == ReenterCall.Exit) {
            target.exit();

        } else if (reenterCall == ReenterCall.EmergencyExit) {
            target.emergencyExit();

        } else if (reenterCall == ReenterCall.FundAndNotify) {
            target.fundAndNotify(reenterAmount);

        } else if (reenterCall == ReenterCall.SweepUnallocatedRewards) {
            target.sweepUnallocatedRewards(recipient, reenterAmount);

        } else if (reenterCall == ReenterCall.RecoverExcessStakingToken) {
            target.recoverExcessStakingToken(recipient, reenterAmount);
            
        } else if (reenterCall == ReenterCall.RecoverERC20) {
            target.recoverERC20(recoverToken, recipient, reenterAmount);
        }
    }
}

