// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract DeployStakingRewardsScript is Script {
    uint256 internal constant DEFAULT_REWARDS_DURATION = 7 days;
   
    function run() external returns (StakingRewards stakingRewards){
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerPrivateKey);

        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        address rewardManager = vm.envOr("REWARD_MANAGER", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);

        uint256 rewardDuration = vm.envOr(
            "REWARDS_DURATION",
            DEFAULT_REWARDS_DURATION
        );

        require(initialOwner != address(0), "INITIAL_OWNER_ZERO");
        require(stakingToken != address(0), "STAKING_TOKEN_ZERO");
        require(rewardToken != address(0), "REWARD_TOKEN_ZERO");
        require(rewardManager != address(0), "REWARD_MANAGER_ZERO");
        require(rewardToken != stakingToken, "SAME_TOKEN");
        require(rewardDuration >= 1 days, "DURATION_TOO_SHORT");
        require(rewardDuration <= 365 days, "DURATION_TOO_LONG");


        vm.startBroadcast(deployerPrivateKey);

        stakingRewards = new StakingRewards(
            initialOwner,
            stakingToken,
            rewardToken,
            rewardManager,
            guardian,
            rewardDuration
        );

        vm.stopBroadcast();

        console2.log("StakingRewards deployed at :", address(stakingRewards));
        console2.log("Initial owner:", initialOwner);
        console2.log("Staking Token:", stakingToken);
        console2.log("Reward Token:", rewardToken);
        console2.log("Reward Manager:", rewardManager);
        console2.log("Guardian:", guardian);
        console2.log("Reward Duration:", rewardDuration);
        console2.log("Deployer:", deployer);
    }
}


