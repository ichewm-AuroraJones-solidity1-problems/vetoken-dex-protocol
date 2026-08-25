// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

contract DryRunStakingRewardsScript is Script {
    function run() external {
        require(block.chainid == 31337, "LOCAL_ONLY");

        uint256 rewardManagerPrivateKey = vm.envUint("REWARD_MANAGER_PRIVATE_KEY");
        uint256 userPrivateKey = vm.envUint("USER_PRIVATE_KEY");

        address rewardManager = vm.addr(rewardManagerPrivateKey);
        address user = vm.addr(userPrivateKey);

        StakingRewards stakingRewards = StakingRewards(vm.envAddress("STAKING_REWARDS"));
        MockERC20 stakingToken = MockERC20(address(stakingRewards.stakingToken()));
        MockERC20 rewardToken = MockERC20(address(stakingRewards.rewardToken()));

        uint256 stakeAmount = vm.envOr("DRY_RUN_STAKE_AMOUNT", uint256(100 ether));
        uint256 rewardAmount = vm.envOr("DRY_RUN_REWARD_AMOUNT", stakingRewards.rewardsDuration());

        require(address(stakingRewards) != address(0), "STAKING_REWARDS_ZERO");
        require(stakingRewards.rewardManager() == rewardManager, "CALLER_NOT_REWARD_MANAGER");
        require(!stakingRewards.paused(), "STAKING_REWARDS_PAUSED");

        vm.startBroadcast(rewardManagerPrivateKey);
        rewardToken.mint(rewardManager, rewardAmount);
        rewardToken.approve(address(stakingRewards), rewardAmount);
        stakingRewards.fundAndNotify(rewardAmount);
        vm.stopBroadcast();

        vm.startBroadcast(userPrivateKey);
        stakingToken.mint(user, stakeAmount);
        stakingToken.approve(address(stakingRewards), stakeAmount);
        stakingRewards.stake(stakeAmount);
        vm.stopBroadcast();

        vm.warp(block.timestamp + 1 days);

        uint256 earnedBeforeClaim = stakingRewards.earned(user);
        require(earnedBeforeClaim > 0, "NO_REWARDS_EARNED");

        vm.startBroadcast(userPrivateKey);
        stakingRewards.getReward();
        stakingRewards.exit();
        vm.stopBroadcast();

        require(stakingRewards.balanceOf(user) == 0, "USER_STAKED_NOT_EXITED");
        require(rewardToken.balanceOf(user) > 0, "USER_REWARDS_NOT_RECEIVED");
    }
}
