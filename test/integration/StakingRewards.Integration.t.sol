// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract StakingRewardsIntegrationTest is Test {
    StakingRewards public stakingRewards;
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
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    function setUp() public {
        stakingToken = new MockERC20("StakingToken", "STAKING", 18);
        rewardToken = new MockERC20("Reward Token", "REWARD", 18);
        stakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
    }

    function test_Integration_SingleUser_FundStakeWaiteClaimExit() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + REWARD_DURATION);
        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(rewardToken.balanceOf(alice), REWARD_DURATION);
    }

    function test_Integration_MultipleUsers_StaggeredStakeWithdrawClaim() public {
        uint256 stakeAmountAlice = 3000;
        uint256 stakeAmountBob = 1500;
        uint256 stakeAmountCarol = 500;
        uint256 withdrawAmountAlice = 1000;
        uint256 withdrawAmountBob = 1000;
        uint256 rewardAmount = REWARD_DURATION;

        _stake(alice, stakeAmountAlice);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + 1 days);
        _stake(bob, stakeAmountBob);
        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmountAlice);

        vm.warp(block.timestamp + 2 days);
        _stake(carol, stakeAmountCarol);
        vm.prank(bob);
        stakingRewards.withdraw(withdrawAmountBob);

        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        stakingRewards.exit();
        vm.prank(bob);
        stakingRewards.exit();
        vm.prank(carol);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmountAlice);
        assertEq(stakingToken.balanceOf(bob), stakeAmountBob);
        assertEq(stakingToken.balanceOf(carol), stakeAmountCarol);

        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.balanceOf(bob), 0);
        assertEq(stakingRewards.balanceOf(carol), 0);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.rewards(bob), 0);
        assertEq(stakingRewards.rewards(carol), 0);

        assertGt(rewardToken.balanceOf(alice), 0);
        assertGt(rewardToken.balanceOf(bob), 0);
        assertGt(rewardToken.balanceOf(carol), 0);
    }

    function test_Integration_StakeWithdrawStakeAgain_EarnsSegmentedRewards() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.withdraw(stakeAmount);
        assertEq (stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.earned(alice), elapsed);

        vm.warp(block.timestamp + elapsed);
        _stake(alice, stakeAmount);
        assertEq (stakingRewards.earned(alice), elapsed);

        vm.warp(block.timestamp + elapsed);
        assertEq(stakingRewards.earned(alice), elapsed * 2);
    }

    function test_Integration_StakeWithdrawSequence_TracksTotalStakedAndBalance() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 1000;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);
        assertEq(stakingRewards.totalStaked(), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingToken.balanceOf(alice), 0);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), stakeAmount);

        vm.warp(block.timestamp + elapsed);
        _stake(alice, stakeAmount);
        assertEq(stakingRewards.totalStaked(), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingToken.balanceOf(alice), 1000);
    }

    function test_Integration_MidPeriodTopUp_UsesLeftoverAndContinuesRewards() public {
        uint256 rewardAmount = 2 * REWARD_DURATION;
        uint256 elapsed = REWARD_DURATION / 2;
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 beforeAccountedRewardBalance = stakingRewards.accountedRewardBalance();

        _fundAndNotify(rewardAmount);
        uint256 grossRewards = 3 * REWARD_DURATION;
        uint256 expectedRewardRate = grossRewards / REWARD_DURATION;
        uint256 expectedAccountedRewardBalance = beforeAccountedRewardBalance + rewardAmount;
        uint256 expectedScheduledRewards = stakingRewards.rewardRate() * REWARD_DURATION;
        uint256 expectedUnallocatedRewards = rewardAmount / 2;

        assertEq(stakingRewards.accountedRewardBalance(), expectedAccountedRewardBalance);
        assertEq(stakingRewards.scheduledRewards(), expectedScheduledRewards);
        assertEq(stakingRewards.unallocatedRewards(), expectedUnallocatedRewards);
        assertEq(stakingRewards.rewardRate(), expectedRewardRate);
        assertEq(stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
    }

    function test_Integration_EmptyPoolThenStake_DoesNotReceivePastRewards() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        _stake(alice, stakeAmount);

        assertEq(stakingRewards.earned(alice), 0);
    }

    function test_Integration_EmptyPoolHalfThenStake_UserOnlyEarnsStakedHalf() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = REWARD_DURATION / 2;

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        _stake(alice, stakeAmount);
        vm.warp(block.timestamp + elapsed);

        assertEq(stakingRewards.earned(alice), rewardAmount * elapsed / REWARD_DURATION);
    }

    function test_Integration_PauseUsersCanStillWithdrawClaimExitEmergencyExit() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 1000;
        uint256 rewardAmount = 3 * REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);
        _stake(bob, stakeAmount);
        _stake(carol, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("guardian pause"));

        vm.startPrank(alice);
        stakingRewards.getReward();
        stakingRewards.withdraw(withdrawAmount);
        vm.stopPrank();
        assertEq(stakingRewards.totalStaked(), 2 * stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(alice), withdrawAmount);
        assertEq(rewardToken.balanceOf(alice), elapsed);

        vm.prank(bob);
        stakingRewards.exit();
        assertEq(stakingRewards.totalStaked(), stakeAmount);
        assertEq(stakingRewards.balanceOf(bob), 0);
        assertEq(stakingToken.balanceOf(bob), stakeAmount);
        assertEq(rewardToken.balanceOf(bob), elapsed);

        vm.prank(carol);
        stakingRewards.emergencyExit();
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(carol), 0);
        assertEq(stakingToken.balanceOf(carol), stakeAmount);
        assertEq(rewardToken.balanceOf(carol), 0);
    }

    function test_Integration_EmergencyExitForfeitsThenOwnerSweeps() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 forfeitedReward = elapsed;
        vm.prank(alice);
        stakingRewards.emergencyExit();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        stakingRewards.sweepUnallocatedRewards(treasury, forfeitedReward);
        vm.stopPrank();
        assertEq(rewardToken.balanceOf(treasury), forfeitedReward);
    }

    function test_Integration_DonatedRewardToken_SyncThenSweeps() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 donation = 500;

        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        rewardToken.mint(address(stakingRewards), donation);
        stakingRewards.syncUnallocatedRewards();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        stakingRewards.sweepUnallocatedRewards(treasury, donation);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(treasury), donation);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
    }

    function test_Integration_ExcessStakingToken_RecoverDoesNotAffectUserPrincipal() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 100;
        _stake(alice, stakeAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        stakingToken.mint(address(stakingRewards), excessAmount);
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();

        assertEq(stakingToken.balanceOf(recoveryRecipient), excessAmount);
        assertEq(stakingToken.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
    }

    function test_Integration_SetRewardManagerDuringActivePeriod_OldLosesNewCanFund() public {
        uint256 rewardAmount = 2 * REWARD_DURATION;
        uint256 elapsed = REWARD_DURATION / 2;
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        address newManager = makeAddr("newManager");
        address oldManager = stakingRewards.rewardManager();
        vm.prank(initialOwner);
        stakingRewards.setRewardManager(newManager);
        assertEq(stakingRewards.rewardManager(), newManager);

        rewardToken.mint(oldManager, rewardAmount);
        vm.startPrank(oldManager);
        rewardToken.approve(address(stakingRewards), rewardAmount);
        vm.expectRevert(StakingRewards.OnlyRewardManager.selector);
        stakingRewards.fundAndNotify(rewardAmount);

        rewardToken.mint(newManager, rewardAmount);
        vm.startPrank(newManager);
        rewardToken.approve(address(stakingRewards), rewardAmount);
        stakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();
    }

    function test_Integration_LongAfterPeriodFinish_NewFundingDoesNotUseHistoricalBalance() public {
        uint256 firstRewardAmount = REWARD_DURATION;
        uint256 donation = 1234;
        uint256 secondRewardAmount = 3 * REWARD_DURATION;

        _fundAndNotify(firstRewardAmount);
        uint256 firstFinish = stakingRewards.periodFinish();
        vm.warp(firstFinish + 30 days);
        rewardToken.mint(address(stakingRewards), donation);
        stakingRewards.syncUnallocatedRewards();
        
        assertEq (stakingRewards.accountedRewardBalance(), firstRewardAmount + donation);
        assertEq (stakingRewards.unallocatedRewards(), donation);
        assertEq (stakingRewards.scheduledRewards(), firstRewardAmount);

        _fundAndNotify(secondRewardAmount);
        uint256 expectedSecondRate = secondRewardAmount / REWARD_DURATION;
        uint256 expectedSecondScheduled = expectedSecondRate * REWARD_DURATION;
        uint256 expectedSecondDust = secondRewardAmount - expectedSecondScheduled;

        assertEq (stakingRewards.rewardRate(), expectedSecondRate);
        assertEq (stakingRewards.scheduledRewards(), expectedSecondScheduled);
        assertEq (stakingRewards.unallocatedRewards(), firstRewardAmount + donation + expectedSecondDust);
        assertEq (stakingRewards.accountedRewardBalance(), firstRewardAmount + donation + secondRewardAmount);
        assertEq (stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
        assertEq (rewardToken.balanceOf(address(stakingRewards)), firstRewardAmount + donation + secondRewardAmount);
    }

    function test_Integration_WhenPaused_OwnerCanRunSafetyOperations() public {
        uint256 newDuration = 14 days;
        address newManager = makeAddr("newManager");
        address newGuardian = makeAddr("newGuardian");
        uint256 rewardDonation = 500;
        uint256 excessStakeToken = 300;
        uint256 recoveryAmount = 200;
        MockERC20 otherToken = new MockERC20("OtherToken", "OTK", 18);

        vm.prank(guardian);
        stakingRewards.pause(bytes32("guardian pause"));

        assertTrue (stakingRewards.paused());

        stakingToken.mint(alice, 1);
        vm.startPrank(alice);
        stakingToken.approve(address(stakingRewards), 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.stake(1);
        vm.stopPrank();

        rewardToken.mint(rewardManager, REWARD_DURATION);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(stakingRewards), REWARD_DURATION);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.fundAndNotify(REWARD_DURATION);
        vm.stopPrank();

        vm.startPrank(initialOwner);
        stakingRewards.setRewardsDuration(newDuration);
        stakingRewards.setRewardManager(newManager);
        stakingRewards.setGuardian(newGuardian);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.stopPrank();

        assertEq (stakingRewards.rewardsDuration(), newDuration);
        assertEq (stakingRewards.rewardManager(), newManager);
        assertEq (stakingRewards.guardian(), newGuardian);
        assertTrue (stakingRewards.sweepRecipientAllowed(treasury));
        assertTrue (stakingRewards.sweepRecipientAllowed(recoveryRecipient));
        assertTrue (stakingRewards.paused());

        rewardToken.mint(address(stakingRewards), rewardDonation);
        stakingRewards.syncUnallocatedRewards();

        vm.prank(initialOwner);
        stakingRewards.sweepUnallocatedRewards(treasury, rewardDonation);
        assertEq (rewardToken.balanceOf(treasury), rewardDonation);

        stakingToken.mint(address(stakingRewards), excessStakeToken);
        vm.prank(initialOwner);
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessStakeToken);
        assertEq (stakingToken.balanceOf(recoveryRecipient), excessStakeToken);

        otherToken.mint(address(stakingRewards), recoveryAmount);
        vm.prank(initialOwner);
        stakingRewards.recoverERC20(address(otherToken), recoveryRecipient, recoveryAmount);
        assertEq (otherToken.balanceOf(recoveryRecipient), recoveryAmount);
        
        vm.prank(initialOwner);
        stakingRewards.unpause();
        assertFalse (stakingRewards.paused());
    }

    function test_Integration_multipleTopUpAcrossPeriods_UsesLeftoverCorrectly() public {
    uint256 stakeAmount = 1000;
    uint256 firstRewardAmount = 10 * REWARD_DURATION;
    uint256 secondRewardAmount = 5 * REWARD_DURATION;
    uint256 thirdRewardAmount = 2 * REWARD_DURATION;
    uint256 expectedUnallocatedRewards;

    _stake(alice, stakeAmount);
    _fundAndNotify(firstRewardAmount);

    {
        uint256 firstRate = stakingRewards.rewardRate();
        uint256 firstFinish = stakingRewards.periodFinish();

        vm.warp(block.timestamp + 1 days);

        uint256 leftoverBeforeSecond = (firstFinish - block.timestamp) * firstRate;
        uint256 grossSecondRewards = secondRewardAmount + leftoverBeforeSecond;
        uint256 expectedSecondRate = grossSecondRewards / REWARD_DURATION;
        uint256 expectedSecondScheduled = expectedSecondRate * REWARD_DURATION;
        uint256 expectedSecondDust = grossSecondRewards - expectedSecondScheduled;

        expectedUnallocatedRewards = stakingRewards.unallocatedRewards() + expectedSecondDust;

        _fundAndNotify(secondRewardAmount);

        assertEq(stakingRewards.rewardRate(), expectedSecondRate);
        assertEq(stakingRewards.scheduledRewards(), expectedSecondScheduled);
        assertEq(stakingRewards.unallocatedRewards(), expectedUnallocatedRewards);
        assertEq(stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
    }

    vm.warp(stakingRewards.periodFinish() + 3 days);

    _fundAndNotify(thirdRewardAmount);

    {
        uint256 expectedThirdRate = thirdRewardAmount / REWARD_DURATION;
        uint256 expectedThirdScheduled = expectedThirdRate * REWARD_DURATION;
        uint256 expectedThirdDust = thirdRewardAmount - expectedThirdScheduled;

        expectedUnallocatedRewards += expectedThirdDust;

        assertEq(stakingRewards.rewardRate(), expectedThirdRate);
        assertEq(stakingRewards.scheduledRewards(), expectedThirdScheduled);
        assertEq(stakingRewards.unallocatedRewards(), expectedUnallocatedRewards);
    }

    assertEq(stakingRewards.accountedRewardBalance(), firstRewardAmount + secondRewardAmount + thirdRewardAmount);
    assertEq(stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
}

    function test_Integration_DonationSyncSweep_DoesNotAffectUserClaimableRewards() public {
        uint256 stakeAmount = 1000;
        uint256 donation = 500;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        rewardToken.mint(address(stakingRewards), donation);
        stakingRewards.syncUnallocatedRewards();
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        stakingRewards.sweepUnallocatedRewards(treasury, donation);
        vm.stopPrank();

        vm.prank(alice);
        stakingRewards.getReward();
        assertEq(rewardToken.balanceOf(alice), elapsed);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount - elapsed);
    }

    // =====================================internal functions ==========================

    function _stake(address user, uint256 amount) internal {
        stakingToken.mint(user, amount);
        vm.startPrank(user);
        stakingToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();
    }

    function _fundAndNotify(uint256 amount) internal {
        rewardToken.mint(rewardManager, amount);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(stakingRewards), amount);
        stakingRewards.fundAndNotify(amount);
        vm.stopPrank();
    }
}
