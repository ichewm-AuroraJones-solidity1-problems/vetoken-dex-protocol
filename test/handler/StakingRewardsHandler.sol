// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewardsHandler is Test {
    StakingRewards stakingRewards;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;

    address public rewardManager;
    address public owner;
    address public recoveryRecipient;

    address[] public actors;

    uint256 public ghostStakes;
    uint256 public ghostWithdraws;
    uint256 public ghostFunds;
    uint256 public ghostClaimed;
    uint256 public ghostSwept;

    uint256 public ghostSynced;
    uint256 public ghostPrincipalBeforeSweep;
    uint256 public ghostPrincipalAfterSweep;
    uint256 public ghostClaimableBeforeSweep;
    uint256 public ghostClaimableAfterSweep;

    uint256 public ghostLastRewardPerTokenStored;
    bool public ghostRewardPerTokenStoredMonotonic = true;
    bool public ghostRewardPerTokenStableWhenNoStake = true;

    modifier trackRewardPerTokenStored() {
        uint256 beforeRpt = stakingRewards.rewardPerTokenStored();
        uint256 beforeTotalStaked = stakingRewards.totalStaked();

        if (beforeRpt < ghostLastRewardPerTokenStored) {
            ghostRewardPerTokenStoredMonotonic = false;
        }

        _;

        uint256 afterRpt = stakingRewards.rewardPerTokenStored();

        if (afterRpt < beforeRpt || afterRpt < ghostLastRewardPerTokenStored) {
            ghostRewardPerTokenStoredMonotonic = false;
        }

        if (beforeTotalStaked == 0 && afterRpt != beforeRpt) {
            ghostRewardPerTokenStableWhenNoStake = false;
        }

        if (afterRpt > ghostLastRewardPerTokenStored) {
            ghostLastRewardPerTokenStored = afterRpt;
        }
    }

    constructor(
        StakingRewards _stakingRewards,
        MockERC20 _stakingToken,
        MockERC20 _rewardToken,
        address _rewardManager,
        address _owner,
        address _recoveryRecipient
    ) {
        stakingRewards = _stakingRewards;
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        rewardManager = _rewardManager;
        owner = _owner;
        recoveryRecipient = _recoveryRecipient;

        actors.push(makeAddr("Alice"));
        actors.push(makeAddr("Bob"));
        actors.push(makeAddr("Charlie"));

        ghostLastRewardPerTokenStored = stakingRewards.rewardPerTokenStored();
    }

    function _actor(uint256 actorSeed) internal view returns (address) {
        return actors[actorSeed % actors.length];
    }

    function stake(uint256 actorSeed, uint256 amount) external trackRewardPerTokenStored {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 1e24);
        stakingToken.mint(actor, amount);

        vm.startPrank(actor);
        stakingToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();

        ghostStakes += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external trackRewardPerTokenStored {
        address actor = _actor(actorSeed);

        uint256 balance = stakingRewards.balanceOf(actor);
        if (balance == 0) return;

        amount = bound(amount, 1, balance);
        vm.prank(actor);
        stakingRewards.withdraw(amount);

        ghostWithdraws += amount;
    }

    function getReward(uint256 actorSeed) external trackRewardPerTokenStored {
        address actor = _actor(actorSeed);

        uint256 beforeReward = rewardToken.balanceOf(actor);

        vm.prank(actor);
        stakingRewards.getReward();

        uint256 claimed = rewardToken.balanceOf(actor) - beforeReward;
        ghostClaimed += claimed;
    }

    function exit(uint256 actorSeed) external trackRewardPerTokenStored {
        address actor = _actor(actorSeed);

        uint256 balance = stakingRewards.balanceOf(actor);
        uint256 beforeReward = rewardToken.balanceOf(actor);

        vm.prank(actor);
        stakingRewards.exit();

        uint256 claimBalance = rewardToken.balanceOf(actor) - beforeReward;

        ghostWithdraws += balance;
        ghostClaimed += claimBalance;
    }

    function emergencyExit(uint256 actorSeed) external trackRewardPerTokenStored {
        address actor = _actor(actorSeed);

        uint256 balance = stakingRewards.balanceOf(actor);

        vm.prank(actor);
        stakingRewards.emergencyExit();

        ghostWithdraws += balance;
    }

    function fundAndNotify(uint256 amount) external trackRewardPerTokenStored {
        amount = bound(amount, stakingRewards.rewardsDuration(), 1e24);
        rewardToken.mint(rewardManager, amount);

        vm.startPrank(rewardManager);
        rewardToken.approve(address(stakingRewards), amount);
        stakingRewards.fundAndNotify(amount);
        vm.stopPrank();

        ghostFunds += amount;
    }

    function warp(uint256 secondsForward) external trackRewardPerTokenStored {
        secondsForward = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + secondsForward);
    }

    function syncUnallocatedRewards(uint256 amount) external trackRewardPerTokenStored {
        amount = bound(amount, 1, 1e24);
        rewardToken.mint(address(stakingRewards), amount);

        stakingRewards.syncUnallocatedRewards();
        ghostSynced += amount;
    }

    function sweepUnallocatedRewards(uint256 amount) external trackRewardPerTokenStored {
        uint256 sweepable = stakingRewards.sweepableUnallocatedRewards();
        if (sweepable == 0) return;

        ghostPrincipalBeforeSweep = _sumUserPrincipal();
        ghostClaimableBeforeSweep = _sumUserClaimable();

        amount = bound(amount, 1, sweepable);
        vm.startPrank(owner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        stakingRewards.sweepUnallocatedRewards(recoveryRecipient, amount);
        vm.stopPrank();

        ghostPrincipalAfterSweep = _sumUserPrincipal();
        ghostClaimableAfterSweep = _sumUserClaimable();
        ghostSwept += amount;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 index) external view returns (address) {
        return actors[index];
    }

    function _sumUserPrincipal() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += stakingRewards.balanceOf(actors[i]);
        }
    }

    function _sumUserClaimable() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += stakingRewards.rewards(actors[i]);
        }
    }
}
