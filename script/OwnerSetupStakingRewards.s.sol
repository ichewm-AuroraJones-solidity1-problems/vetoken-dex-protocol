// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract OwnerSetupStakingRewardsScript is Script {
    function run() external {
        uint256 ownerPrivateKey = vm.envUint("OWNER_PRIVATE_KEY");

        StakingRewards stakingRewards = StakingRewards(vm.envAddress("STAKING_REWARDS"));
        address treasury = vm.envAddress("TREASURY");
        address rewardManager = vm.envAddress("REWARD_MANAGER");
        address recoveryRecipient = vm.envAddress("RECOVERY_RECIPIENT");

        require(address(stakingRewards) != address(0), "STAKING_REWARDS_ZERO");
        require(treasury != address(0), "TREASURY_ZERO");
        require(rewardManager != address(0), "REWARD_MANAGER_ZERO");
        require(recoveryRecipient != address(0), "RECOVERY_RECIPIENT_ZERO");

        address owner = vm.addr(ownerPrivateKey);
        require(stakingRewards.owner() == vm.addr(ownerPrivateKey), "CALLER_NOT_OWNER");

        vm.startBroadcast(ownerPrivateKey);

        stakingRewards.setSweepRecipientAllowed(treasury, true);
        stakingRewards.setSweepRecipientAllowed(rewardManager, true);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.stopBroadcast();

        require(stakingRewards.sweepRecipientAllowed(treasury), "TREASURY_NOT_ALLOWED");
        require(stakingRewards.sweepRecipientAllowed(rewardManager), "MANAGER_NOT_ALLOWED");
        require(stakingRewards.sweepRecipientAllowed(recoveryRecipient), "RECOVERY_NOT_ALLOWED");
    }
}
