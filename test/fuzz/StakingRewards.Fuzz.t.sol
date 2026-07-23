// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StakingRewardsFuzzTest is Test {
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

    /// @notice Emitted when a user stakes tokens.
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws staked tokens.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims rewards.
    event RewardPaid(address indexed user, uint256 amount);
    event EmergencyExit(address indexed user, uint256 principal, uint256 forfeitedReward);

    /// @notice Emitted when the reward manager funds a new reward period.
    event RewardAdded(address indexed rewardManager, uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event RewardsForfeited(uint256 indexed startTime, uint256 indexed endTime, uint256 amount);
    event RewardPerTokenDust(uint256 amount);
    event UserCheckpointDust(address indexed user, uint256 amount);
    event UnallocatedRewardsSwept(
        address indexed operator, address indexed to, uint256 amount, uint256 remainingUnallocated
    );
    event UnallocatedRewardsSynced(address indexed operator, uint256 amount, uint256 newUnallocated);
    event ExcessStakingTokenRecovered(
        address indexed operator, address indexed to, uint256 amount, uint256 remainingExcess
    );
    event ERC20Recovered(address indexed operator, address indexed token, address indexed to, uint256 amount);

    event RewardManagerUpdated(address indexed oldManager, address indexed newManager);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event SweepRecipientUpdated(address indexed recipient, bool allowed);

    event PauseReason(address indexed operator, bytes32 reasonHash);

    function setUp() public {
        stakingToken = new MockERC20("Staking Token", "STAKING", 18);
        rewardToken = new MockERC20("Reward Token", "REWARD", 18);
        stakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
    }

    function testFuzz_Stake_IncreasesBalanceAndTotalStaked(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        stakingToken.mint(alice, amount);
        uint256 beforeBalance = stakingToken.balanceOf(alice);
        uint256 beforeTotalStaked = stakingRewards.totalStaked();

        vm.startPrank(alice);
        stakingToken.approve(address(stakingRewards), amount);
        stakingRewards.stake(amount);
        vm.stopPrank();
        uint256 afterBalance = stakingToken.balanceOf(alice);
        uint256 afterTotalStaked = stakingRewards.totalStaked();

        assertEq(beforeBalance, amount);
        assertEq(beforeTotalStaked, 0);
        assertEq(afterBalance, 0);
        assertEq(afterTotalStaked, amount);
    }

    function testFuzz_Withdraw_DecreasesBalanceAndTotalStaked(uint256 stakeAmount, uint256 withdrawAmount) public {
        stakeAmount = bound(stakeAmount, 1, type(uint256).max);
        withdrawAmount = bound(withdrawAmount, 1, stakeAmount);

        _stake(alice, stakeAmount);
        uint256 beforeBalance = stakingToken.balanceOf(alice);
        uint256 beforeTotalStaked = stakingRewards.totalStaked();

        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);
        uint256 afterBalance = stakingToken.balanceOf(alice);
        uint256 afterTotalStaked = stakingRewards.totalStaked();

        assertEq(beforeBalance, 0);
        assertEq(beforeTotalStaked, stakeAmount);
        assertEq(afterBalance, withdrawAmount);
        assertEq(afterTotalStaked, stakeAmount - withdrawAmount);
    }

    function testFuzz_FundAndNotify_ComputesRateScheduledAndDust(uint256 amount) public {
        amount = bound(amount, REWARD_DURATION, stakingRewards.MAX_REWARDS_AMOUNT());

        _fundAndNotify(amount);
        uint256 newRewardRate = amount / REWARD_DURATION;
        uint256 newScheduledRewards = newRewardRate * REWARD_DURATION;
        uint256 roundingDust = amount - newScheduledRewards;

        assertEq(stakingRewards.accountedRewardBalance(), amount);
        assertEq(stakingRewards.scheduledRewards(), newScheduledRewards);
        assertEq(stakingRewards.unallocatedRewards(), roundingDust);
        assertEq(stakingRewards.rewardRate(), newRewardRate);
        assertEq(stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
    }

    function testFuzz_FundAndNotify_RejectsinvalidAmounts(uint256 amount) public {
        uint256 livalidCase = amount % 3;
        uint256 livalidAmount = amount;

        if (livalidCase == 0) {
            livalidAmount = 0;
            rewardToken.mint(rewardManager, livalidAmount);
            vm.startPrank(rewardManager);
            rewardToken.approve(address(stakingRewards), livalidAmount);
            vm.expectRevert(StakingRewards.ZeroAmount.selector);
            stakingRewards.fundAndNotify(livalidAmount);
            vm.stopPrank();
        } else if (livalidCase == 1) {
            livalidAmount = bound(amount, 1, REWARD_DURATION - 1);
            rewardToken.mint(rewardManager, livalidAmount);
            vm.startPrank(rewardManager);
            rewardToken.approve(address(stakingRewards), livalidAmount);
            vm.expectRevert(StakingRewards.RewardTooSmall.selector);
            stakingRewards.fundAndNotify(livalidAmount);
            vm.stopPrank();
        } else if (livalidCase == 2) {
            livalidAmount = bound(amount, MAX_REWARDS_AMOUNT + 1, type(uint256).max);
            rewardToken.mint(rewardManager, livalidAmount);
            vm.startPrank(rewardManager);
            rewardToken.approve(address(stakingRewards), livalidAmount);
            vm.expectRevert(
                abi.encodeWithSelector(StakingRewards.RewardAmountTooLarge.selector, livalidAmount, MAX_REWARDS_AMOUNT)
            );
            stakingRewards.fundAndNotify(livalidAmount);
            vm.stopPrank();
        }

        assertEq(stakingRewards.accountedRewardBalance(), 0);
        assertEq(stakingRewards.scheduledRewards(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.rewardRate(), 0);
        assertEq(stakingRewards.periodFinish(), 0);
    }

    function testFuzz_Earned_NeverExceedsReleasedReward(uint256 stakeAmount, uint256 rewardAmount, uint256 elapsed)
        public
    {
        stakeAmount = bound(stakeAmount, 1, type(uint256).max);
        rewardAmount = bound(rewardAmount, REWARD_DURATION, MAX_REWARDS_AMOUNT);
        elapsed = bound(elapsed, 1, REWARD_DURATION);

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);
        uint256 beforeEarned = stakingRewards.earned(alice);

        vm.warp(block.timestamp + elapsed);
        uint256 afterEarned = stakingRewards.earned(alice);

        assertGe(afterEarned, beforeEarned);
        assertGe(stakingRewards.accountedRewardBalance(), afterEarned);
    }

    function testFuzz_GetReward_PaysAtMostEarned(uint256 stakeAmount, uint256 rewardAmount, uint256 elapsed) public {
        stakeAmount = bound(stakeAmount, 1, type(uint256).max);
        rewardAmount = bound(rewardAmount, REWARD_DURATION, MAX_REWARDS_AMOUNT);
        elapsed = bound(elapsed, 1, REWARD_DURATION);

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 totalEarned = stakingRewards.earned(alice);

        vm.prank(alice);
        stakingRewards.getReward();

        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.earned(alice), 0);
        assertEq(rewardToken.balanceOf(alice), totalEarned);
    }

    function testFuzz_SweepUnallocated_CannotSweepMoreThanSweepable(
        uint256 rewardAmount,
        uint256 elapsed,
        uint256 sweepAmount
    ) public {
        rewardAmount = bound(rewardAmount, REWARD_DURATION, MAX_REWARDS_AMOUNT);
        elapsed = bound(elapsed, 1, REWARD_DURATION);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 sweepable = stakingRewards.sweepableUnallocatedRewards();
        if (sweepable == 0) return;
        sweepAmount = bound(sweepAmount, 1, sweepable);
        uint256 beforeRecipientAmount = rewardToken.balanceOf(recoveryRecipient);
        uint256 beforeAccountedRewardBalance = stakingRewards.accountedRewardBalance();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        stakingRewards.sweepUnallocatedRewards(recoveryRecipient, sweepAmount);
        vm.stopPrank();

        assertEq(stakingRewards.unallocatedRewards(), sweepable - sweepAmount);
        assertEq(stakingRewards.accountedRewardBalance(), beforeAccountedRewardBalance - sweepAmount);
        assertEq(rewardToken.balanceOf(recoveryRecipient), beforeRecipientAmount + sweepAmount);
    }

    function testFuzz_RecoverExcessStakingToken_CannotRecoverPrincipal(
        uint256 stakeAmount,
        uint256 donation,
        uint256 recoverAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1, 1e24);
        donation = bound(donation, 1, 1e24);
        recoverAmount = bound(recoverAmount, 1, donation);

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), donation);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.expectEmit(true, true, false, true);
        emit ExcessStakingTokenRecovered(initialOwner, recoveryRecipient, recoverAmount, donation - recoverAmount);
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, recoverAmount);
        vm.stopPrank();

        assertEq(stakingToken.balanceOf(address(stakingRewards)), stakeAmount + donation - recoverAmount);
        assertEq(stakingToken.balanceOf(alice), 0);
        assertEq(stakingToken.balanceOf(recoveryRecipient), recoverAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
    }

    function testFuzz_SetRewardsDuration_AcceptsOnlyValidRange(uint256 duration) public {
        duration = bound(duration, MIN_REWARDS_DURATION, MAX_REWARDS_DURATION);
        vm.startPrank(initialOwner);
        uint256 beforeDuration = stakingRewards.rewardsDuration();
        vm.expectEmit(false, false, false, true);
        emit RewardsDurationUpdated(beforeDuration, duration);
        stakingRewards.setRewardsDuration(duration);
        vm.stopPrank();
    }

    function testFuzz_FeeOnTransferStake_RevertsWhenReceivedMismatch(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 1, 1e24);
        feeBps = bound(feeBps, 1, 9999);
        FeeOnTransferMock feeToken = new FeeOnTransferMock("Fee Token", "FEETOKEN", feeBps);
        StakingRewards FeeStakingRewards = new StakingRewards(
            initialOwner, address(feeToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        feeToken.mint(alice, amount);

        vm.startPrank(alice);
        feeToken.approve(address(FeeStakingRewards), amount);
        uint256 expectedFee = Math.mulDiv(amount, feeBps, 10000);
        vm.assume(expectedFee > 0);
        uint256 expectedAmount = amount - expectedFee;
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidReceivedAmount.selector, amount, expectedAmount));
        FeeStakingRewards.stake(amount);
        vm.stopPrank();
    }

    function testFuzz_EmergencyExit_ReturnsPrincipalAndForfeitsRewards(
        uint256 stakeAmount,
        uint256 rewardAmount,
        uint256 elapsed
    ) public {
        stakeAmount = bound(stakeAmount, 1, 1e24);
        rewardAmount = bound(rewardAmount, REWARD_DURATION, 100 * REWARD_DURATION);
        elapsed = bound(elapsed, 1, REWARD_DURATION);

        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 beforeUnallocatedRewards = stakingRewards.unallocatedRewards();
        uint256 beforeRewards = stakingRewards.earned(alice);

        vm.expectEmit(true, false, false, true);
        emit EmergencyExit(alice, stakeAmount, beforeRewards);
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);

        assertEq(rewardToken.balanceOf(alice), 0);
        assertEq(stakingRewards.rewards(alice), 0);
        assertApproxEqAbs(stakingRewards.unallocatedRewards(), beforeUnallocatedRewards + beforeRewards, 1e12);
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
