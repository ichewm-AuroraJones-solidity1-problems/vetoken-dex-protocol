// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {StakingRewardsHandler} from "../handler/StakingRewardsHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewardsInvariantTest is Test {
    StakingRewards public stakingRewards;
    StakingRewardsHandler public handler;
    MockERC20 public stakingToken;
    MockERC20 public rewardToken;
    address public initialOwner = makeAddr("initialOwner");
    address public rewardManager = makeAddr("rewardManager");
    address public guardian = makeAddr("guardian");
    uint256 public constant REWARD_DURATION = 7 days;

    uint256 public constant MAX_REWARDS_AMOUNT = type(uint128).max;
    uint256 public constant MAX_REWARDS_RATE = type(uint128).max;
    uint256 public constant MIN_REWARDS_DURATION = 1 days;
    uint256 public constant MAX_REWARDS_DURATION = 365 days;
    address public treasury = makeAddr("treasury");
    address public recoveryRecipient = makeAddr("recoveryRecipient");
    address public alice = makeAddr("alice");

    function setUp() public {
        stakingToken = new MockERC20("Staking Token", "STAKING", 18);
        rewardToken = new MockERC20("Reward Token", "REWARD", 18);
        stakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );

        handler = new StakingRewardsHandler(
            stakingRewards, stakingToken, rewardToken, rewardManager, initialOwner, guardian, recoveryRecipient
        );

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = StakingRewardsHandler.stake.selector;
        selectors[1] = StakingRewardsHandler.withdraw.selector;
        selectors[2] = StakingRewardsHandler.getReward.selector;
        selectors[3] = StakingRewardsHandler.exit.selector;
        selectors[4] = StakingRewardsHandler.emergencyExit.selector;
        selectors[5] = StakingRewardsHandler.fundAndNotify.selector;
        selectors[6] = StakingRewardsHandler.warp.selector;
        selectors[7] = StakingRewardsHandler.syncUnallocatedRewards.selector;
        selectors[8] = StakingRewardsHandler.sweepUnallocatedRewards.selector;
        selectors[9] = StakingRewardsHandler.recoverExcessStakingToken.selector;
        selectors[10] = StakingRewardsHandler.recoverERC20.selector;
        selectors[11] = StakingRewardsHandler.setRewardManager.selector;
        selectors[12] = StakingRewardsHandler.setGuardian.selector;
        selectors[13] = StakingRewardsHandler.pause.selector;
        selectors[14] = StakingRewardsHandler.unpause.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        excludeContract(address(stakingRewards));
        excludeContract(address(stakingToken));
        excludeContract(address(rewardToken));
        excludeContract(address(handler.recoverToken()));
    }

    function invariant_RewardAccountingBucketsSumAccountedBalance() public view {
        assertEq(
            stakingRewards.accountedRewardBalance(),
            stakingRewards.aggregateClaimableRewards() + stakingRewards.accruedRewardReserve()
                + stakingRewards.scheduledRewards() + stakingRewards.unallocatedRewards()
        );
    }

    function invariant_AccountedPlusUnreservedEqualsRewardTokenBalance() public view {
        assertEq(
            stakingRewards.accountedRewardBalance() + stakingRewards.unreservedRewardBalance(),
            rewardToken.balanceOf(address(stakingRewards))
        );
    }

    function invariant_AccountedRewardBalanceNeverExceedsRewardTokenBalance() public view {
        assertLe(stakingRewards.accountedRewardBalance(), rewardToken.balanceOf(address(stakingRewards)));
    }

    function invariant_StakingTokenBalanceAlwaysCoversTotalStaked() public view {
        assertGe(stakingToken.balanceOf(address(stakingRewards)), stakingRewards.totalStaked());
    }

    function invariant_TotalStakedEqualsSumUserBalances() public view {
        uint256 sumBalances;

        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            sumBalances += stakingRewards.balanceOf(actor);
        }

        assertEq(stakingRewards.totalStaked(), sumBalances);
    }

    function invariant_AggregateClaimableEqualsSumUserRewards() public view {
        uint256 sumRewards;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address actor = handler.actors(i);
            sumRewards += stakingRewards.rewards(actor);
        }
        assertEq(stakingRewards.aggregateClaimableRewards(), sumRewards);
    }

    function invariant_PendingUserDustScaledLessThanOneE18() public view {
        assertLt(stakingRewards.pendingUserDustScaled(), 1e18);
    }

    function invariant_TotalClaimedNeverExceedsTotalFundedMinusSwept() public view {
        uint256 totalAccountedIn = handler.ghostFunds() + handler.ghostSynced();
        assertLe(handler.ghostSwept(), totalAccountedIn);
        assertLe(handler.ghostClaimed(), totalAccountedIn - handler.ghostSwept());
    }

    function invariant_SweepNeverReducesUserPrincipalOrClaimableRewards() public view {
        assertEq(handler.ghostPrincipalAfterSweep(), handler.ghostPrincipalBeforeSweep());
        assertEq(handler.ghostClaimableAfterSweep(), handler.ghostClaimableBeforeSweep());
    }

    function invariant_StoredUnallocatedNeverExceedsSweepable() public view {
        assertLe(stakingRewards.storedUnallocatedRewards(), stakingRewards.sweepableUnallocatedRewards());
    }

    function invariant_RewardTokenConservation() public view {
        uint256 inflows = handler.ghostFunds() + handler.ghostSynced();

        uint256 outflowsAndBalance =
            handler.ghostClaimed() + handler.ghostSwept() + rewardToken.balanceOf(address(stakingRewards));

        assertEq(inflows, outflowsAndBalance);
    }

    function invariant_RewardPerTokenStoredMonotonic() public view {
        assertTrue(handler.ghostRewardPerTokenStoredMonotonic());
        assertGe(stakingRewards.rewardPerTokenStored(), handler.ghostLastRewardPerTokenStored());
    }

    function invariant_RewardPerTokenStoredStableWhenNoStake() public view {
        assertTrue(handler.ghostRewardPerTokenStableWhenNoStake());
    }
}
