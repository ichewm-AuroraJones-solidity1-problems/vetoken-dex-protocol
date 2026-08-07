// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StakingRewards} from "../src/StakingRewards.sol";

contract DeployStakingRewardsScript is Script {
    uint256 internal constant DEFAULT_REWARDS_DURATION = 7 days;

    function run() external returns (StakingRewards stakingRewards) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address initialOwner = vm.envAddress("INITIAL_OWNER");
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        address rewardToken = vm.envAddress("REWARD_TOKEN");
        address rewardManager = vm.envAddress("REWARD_MANAGER");
        address guardian = vm.envAddress("GUARDIAN");

        uint256 rewardDuration = vm.envOr("REWARDS_DURATION", DEFAULT_REWARDS_DURATION);

        require(initialOwner != address(0), "INITIAL_OWNER_ZERO");
        require(stakingToken != address(0), "STAKING_TOKEN_ZERO");
        require(rewardToken != address(0), "REWARD_TOKEN_ZERO");
        require(rewardManager != address(0), "REWARD_MANAGER_ZERO");
        require(guardian != address(0), "GUARDIAN_ZERO");

        require(stakingToken != rewardToken, "SAME_TOKEN");
        require(rewardDuration >= 1 days, "DURATION_TOO_SHORT");
        require(rewardDuration <= 365 days, "DURATION_TOO_LONG");

        require(initialOwner != deployer, "OWNER_IS_DEPLOYER");
        require(rewardManager != deployer, "REWARD_MANAGER_IS_DEPLOYER");
        require(guardian != deployer, "GUARDIAN_IS_DEPLOYER");

        require(initialOwner != rewardManager, "OWNER_MANAGER_SAME");
        require(initialOwner != guardian, "OWNER_GUARDIAN_SAME");
        require(rewardManager != guardian, "MANAGER_GUARDIAN_SAME");

        vm.startBroadcast(deployerPrivateKey);

        stakingRewards =
            new StakingRewards(initialOwner, stakingToken, rewardToken, rewardManager, guardian, rewardDuration);

        vm.stopBroadcast();

        _verifyDeployment(
            stakingRewards,
            initialOwner,
            stakingToken,
            rewardToken,
            rewardManager,
            guardian,
            rewardDuration
        );

        console2.log("StakingRewards deployed at :", address(stakingRewards));
        console2.log("Deployer:", deployer);
        console2.log("Initial owner:", initialOwner);
        console2.log("Staking Token:", stakingToken);
        console2.log("Reward Token:", rewardToken);
        console2.log("Reward Manager:", rewardManager);
        console2.log("Guardian:", guardian);
        console2.log("Reward Duration:", rewardDuration);
    }

    function _verifyDeployment(
        StakingRewards stakingRewards,
        address initialOwner,
        address stakingToken,
        address rewardToken,
        address rewardManager,
        address guardian,
        uint256 rewardDuration
    ) internal  view {
        require(stakingRewards.owner() == initialOwner, "OWNER_MISMATCH");
        require(address(stakingRewards.stakingToken()) == stakingToken, "STAKING_TOKEN_MISMATCH");
        require(address(stakingRewards.rewardToken()) == rewardToken, "REWARD_TOKEN_MISMATCH");
        require(stakingRewards.rewardManager() == rewardManager, "REWARD_MANAGER_MISMATCH");
        require(stakingRewards.guardian() == guardian, "GUARDIAN_MISMATCH");
        require(stakingRewards.rewardsDuration() == rewardDuration, "REWARDS_DURATION_MISMATCH");

        require(stakingRewards.periodFinish() == 0, "PERIOD_FINISH_NOT_ZERO");
        require(stakingRewards.rewardRate() == 0, "REWARD_RATE_NOT_ZERO");
        require(stakingRewards.lastUpdateTime() == 0, "LAST_UPDATE_TIME_NOT_ZERO");
        require(stakingRewards.rewardPerTokenStored() == 0, "PRT_NOT_ZERO");
        
        require(stakingRewards.totalStaked() == 0, "TOTAL_STAKED_NOT_ZERO");
        require(stakingRewards.scheduledRewards() == 0, "SCHEDULED_NOT_ZERO");
        require(stakingRewards.accruedRewardReserve() == 0, "RESERVE_NOT_ZERO");
        require(stakingRewards.aggregateClaimableRewards() == 0, "CLAIMABLE_NOT_ZERO");
        require(stakingRewards.unallocatedRewards() == 0, "UNALLOCATED_NOT_ZERO");
        require(stakingRewards.pendingUserDustScaled() == 0, "DUST_NOT_ZERO");
        require(stakingRewards.accountedRewardBalance() == 0, "ACCOUNTED_NOT_ZERO");

        require(stakingRewards.paused() == false, "PAUSED");

    }
}

