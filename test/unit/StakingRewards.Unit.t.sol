// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";
import {ReturnFalseERC20} from "../mocks/ReturnFalseERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StakingRewardsUnitTest is Test {
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

    // ---------------------------------------------------------------------
    // test constructor
    // -----------------------------------------------------------------------
    function test_Constructor_InitializesExpectedState() public view {
        assertEq(stakingRewards.owner(), initialOwner);
        assertEq(address(stakingRewards.stakingToken()), address(stakingToken));
        assertEq(address(stakingRewards.rewardToken()), address(rewardToken));
        assertEq(stakingRewards.rewardManager(), rewardManager);
        assertEq(stakingRewards.guardian(), guardian);
        assertEq(stakingRewards.rewardsDuration(), REWARD_DURATION);
        assertNotEq(address(stakingRewards.stakingToken()), address(stakingRewards.rewardToken()));

        assertEq(stakingRewards.periodFinish(), 0);
        assertEq(stakingRewards.rewardRate(), 0);
        assertEq(stakingRewards.lastUpdateTime(), 0);
        assertEq(stakingRewards.rewardPerTokenStored(), 0);

        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.scheduledRewards(), 0);
        assertEq(stakingRewards.accruedRewardReserve(), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.pendingUserDustScaled(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), 0);

        assertEq(stakingRewards.paused(), false);
    }

    function test_Constructor_RevertWhenOwnerZero() public {
        vm.startPrank(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new StakingRewards(
            address(0), address(stakingToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        vm.stopPrank();
    }

    function test_Constructor_RevertWhenZeroStakingToken() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(initialOwner, address(0), address(rewardToken), rewardManager, guardian, REWARD_DURATION);
        vm.stopPrank();
    }

    function test_Constructor_RevertWhenZeroRewardToken() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(initialOwner, address(stakingToken), address(0), rewardManager, guardian, REWARD_DURATION);
        vm.stopPrank();
    }

    function test_Constructor_RevertWhenZeroRewardManager() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), address(0), guardian, REWARD_DURATION
        );
        vm.stopPrank();
    }

    function test_Constructor_RevertWhenInvaildRewardDuration() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.InvalidRewardsDuration.selector);
        new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, guardian, MIN_REWARDS_DURATION - 1
        );

        vm.expectRevert(StakingRewards.InvalidRewardsDuration.selector);
        new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, guardian, MAX_REWARDS_DURATION + 1
        );
        vm.stopPrank();
    }

    function test_Constructor_RevertWhenSameToken() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.SameToken.selector);
        new StakingRewards(
            initialOwner, address(stakingToken), address(stakingToken), rewardManager, guardian, REWARD_DURATION
        );
        vm.stopPrank();
    }

    function test_Constructor_AllowsZeroGuardian() public {
        vm.startPrank(initialOwner);
        stakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(rewardToken), rewardManager, address(0), REWARD_DURATION
        );
        assertEq(stakingRewards.guardian(), address(0));
        assertEq(stakingRewards.rewardManager(), rewardManager);
        vm.stopPrank();
    }

    function test_GuardianZero_CannotPause() public {
        vm.startPrank(stakingRewards.owner());
        stakingRewards.setGuardian(address(0));
        assertEq(stakingRewards.guardian(), address(0));
        assertTrue(!stakingRewards.paused());

        vm.stopPrank();
    }

    function test_RenounceOwnership_Reverts() public {
        vm.prank(initialOwner);
        vm.expectRevert(StakingRewards.RenounceOwnershipDisabled.selector);
        stakingRewards.renounceOwnership();
    }

    function test_Ownable2Step_TransferAndAcceptOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(initialOwner);
        stakingRewards.transferOwnership(newOwner);
        assertEq(stakingRewards.owner(), initialOwner);

        vm.prank(newOwner);
        stakingRewards.acceptOwnership();
        assertEq(stakingRewards.owner(), newOwner);
    }

    // roles
    function test_SetRewardManager_Success() public {
        vm.startPrank(initialOwner);

        vm.expectEmit(true, true, false, false);
        emit RewardManagerUpdated(rewardManager, rewardManager);
        stakingRewards.setRewardManager(rewardManager);
        assertEq(stakingRewards.rewardManager(), rewardManager);
        vm.stopPrank();
    }

    function test_SetRewardManager_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.setRewardManager(rewardManager);
    }

    function test_SetRewardManager_RevertWhenZeroAddress() public {
        vm.startPrank(initialOwner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        stakingRewards.setRewardManager(address(0));

        vm.stopPrank();
    }

    function test_SetGuardian_Success() public {
        vm.startPrank(initialOwner);
        vm.expectEmit(true, true, false, false);
        emit GuardianUpdated(guardian, guardian);
        stakingRewards.setGuardian(guardian);

        assertEq(stakingRewards.guardian(), guardian);
        vm.stopPrank();
    }

    function test_SetGuardian_AllowsZeroAddress() public {
        vm.startPrank(initialOwner);
        vm.expectEmit(true, true, false, false);
        emit GuardianUpdated(guardian, address(0));
        stakingRewards.setGuardian(address(0));
        assertEq(stakingRewards.guardian(), address(0));
        vm.stopPrank();
    }

    function test_SetGuardian_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.setGuardian(guardian);
    }

    // Sweep Allowlist test
    function test_SetSweepRecipientAllowed_SetsEmitsAndAllowsRepeatedValue() public {
        vm.startPrank(initialOwner);

        vm.expectEmit(true, false, false, true);
        emit SweepRecipientUpdated(treasury, true);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        assertTrue(stakingRewards.sweepRecipientAllowed(treasury));

        vm.expectEmit(true, false, false, true);
        emit SweepRecipientUpdated(rewardManager, true);
        stakingRewards.setSweepRecipientAllowed(rewardManager, true);
        assertTrue(stakingRewards.sweepRecipientAllowed(rewardManager));

        vm.expectEmit(true, false, false, true);
        emit SweepRecipientUpdated(recoveryRecipient, true);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        assertTrue(stakingRewards.sweepRecipientAllowed(recoveryRecipient));

        vm.expectEmit(true, false, false, true);
        emit SweepRecipientUpdated(treasury, true);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        assertTrue(stakingRewards.sweepRecipientAllowed(treasury));

        vm.stopPrank();
    }

    function test_SetSeepRecipientAllowed_RevertWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.setSweepRecipientAllowed(treasury, true);
    }

    function test_SetSweepRecipientAllowed_RevertWhenZeroAddress() public {
        vm.prank(initialOwner);
        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        stakingRewards.setSweepRecipientAllowed(address(0), true);
    }

    // --------------------------------------------------------------------------
    // stake and withdraw test
    // --------------------------------------------------------------------------
    function test_Stake_Success() public {
        uint256 stakeAmount = 1000;
        vm.startPrank(alice);
        stakingToken.mint(alice, stakeAmount);
        stakingToken.approve(address(stakingRewards), stakeAmount);

        vm.expectEmit(true, false, false, true);
        emit Staked(alice, stakeAmount);
        stakingRewards.stake(stakeAmount);
        assertEq(stakingToken.balanceOf(alice), 0);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), stakeAmount);

        vm.stopPrank();
    }

    function test_Withdraw_Success() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 400;
        _stake(alice, stakeAmount);

        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, withdrawAmount);
        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingToken.balanceOf(alice), withdrawAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount - withdrawAmount);
        assertEq(stakingRewards.totalStaked(), stakeAmount - withdrawAmount);
    }

    function test_Withdraw_LastStakerFlushesAccruedRewardReserve() public {
        uint256 stakeAmount = 3;
        uint256 rewardAmount = REWARD_DURATION;
        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardPerTokenDust(1);
        vm.prank(alice);
        stakingRewards.withdraw(stakeAmount);

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.accruedRewardReserve(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 1);
        assertEq(stakingRewards.pendingUserDustScaled(), 0);
    }

    function test_Stake_RevertWhenAmountZero() public {
        vm.startPrank(alice);
        stakingToken.mint(alice, 1000);
        stakingToken.approve(address(stakingRewards), 1000);

        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.stake(0);

        vm.stopPrank();
    }

    function test_Stake_RevertWhenPaused() public {
        stakingToken.mint(alice, 1000);
        vm.prank(initialOwner);
        stakingRewards.pause(bytes32("pause"));

        vm.startPrank(alice);
        stakingToken.approve(address(stakingRewards), 1000);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.stake(1000);

        vm.stopPrank();
    }

    function test_Stake_RevertWhenTokenReturnsFalse() public {
        uint256 stakeAmount = 1000;
        ReturnFalseERC20 BadToken = new ReturnFalseERC20("BadToken", "badToken", 18);
        StakingRewards BadStakingRewards = new StakingRewards(
            initialOwner, address(BadToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        BadToken.mint(alice, stakeAmount);
        BadToken.setFailTransferFrom(true);

        vm.startPrank(alice);
        BadToken.approve(address(BadStakingRewards), stakeAmount);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, BadToken));
        BadStakingRewards.stake(stakeAmount);

        assertEq(BadStakingRewards.balanceOf(alice), 0);
        assertEq(BadStakingRewards.totalStaked(), 0);

        vm.stopPrank();
    }

    function test_Stake_RevertWhenReceivedAmountMismatch() public {
        FeeOnTransferMock FeeToken = new FeeOnTransferMock("FeeToken", "feeToken", 18);
        StakingRewards FeeStakingRewards = new StakingRewards(
            initialOwner, address(FeeToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        FeeToken.mint(alice, 1000);
        FeeToken.approve(address(FeeStakingRewards), 600);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidReceivedAmount.selector, 600, 599));
        FeeStakingRewards.stake(600);

        vm.stopPrank();
    }

    function test_Withdraw_RevertWhenAmountZero() public {
        uint256 stakeAmount = 1000;
        _stake(alice, stakeAmount);

        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        vm.prank(alice);
        stakingRewards.withdraw(0);
    }

    function test_Withdraw_RevertWhenTokenReturnsFalse() public {
        ReturnFalseERC20 BadToken = new ReturnFalseERC20("BadToken", "badToken", 18);
        StakingRewards BadStakingRewards = new StakingRewards(
            initialOwner, address(BadToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        uint256 stakeAmount = 1000;
        BadToken.mint(alice, stakeAmount);
        BadToken.setFailTransferFrom(false);
        vm.startPrank(alice);
        BadToken.approve(address(BadStakingRewards), stakeAmount);
        BadStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        BadToken.setFailTransfer(true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(BadToken)));
        BadStakingRewards.withdraw(stakeAmount);

        assertEq(BadStakingRewards.balanceOf(alice), stakeAmount);
        assertEq(BadStakingRewards.totalStaked(), stakeAmount);
        assertEq(BadToken.balanceOf(alice), 0);

        vm.stopPrank();
    }

    function test_Withdraw_RevertWhenExcessStakeAmount() public {
        uint256 stakeAmount = 1000;
        _stake(alice, stakeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(StakingRewards.InsufficientStake.selector, stakeAmount + 100, stakeAmount)
        );
        vm.prank(alice);
        stakingRewards.withdraw(stakeAmount + 100);
    }

    function test_Stake_CheckpointsRewardBeforeIncreasingPrincipal() public {
        uint256 initialStake = 1000;
        uint256 additionalStake = 500;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        vm.startPrank(alice);
        stakingToken.mint(alice, initialStake + additionalStake);
        stakingToken.approve(address(stakingRewards), initialStake + additionalStake);
        stakingRewards.stake(initialStake);
        vm.stopPrank();

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.stake(additionalStake);

        assertEq(stakingRewards.balanceOf(alice), initialStake + additionalStake);
        assertEq(stakingRewards.totalStaked(), initialStake + additionalStake);
        assertEq(stakingRewards.rewards(alice), elapsed);
        assertEq(stakingRewards.aggregateClaimableRewards(), elapsed);
        assertEq(stakingRewards.accruedRewardReserve(), 0);
        assertEq(stakingRewards.userRewardPerTokenPaid(alice), stakingRewards.rewardPerTokenStored());
    }

    function test_Withdraw_CheckpointsRewardBeforeDecreasingPrincipal() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 500;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.balanceOf(alice), stakeAmount - withdrawAmount);
        assertEq(stakingRewards.totalStaked(), stakeAmount - withdrawAmount);

        assertEq(stakingRewards.rewards(alice), elapsed);
        assertEq(stakingRewards.aggregateClaimableRewards(), elapsed);

        assertEq(stakingRewards.accruedRewardReserve(), 0);
        assertEq(stakingRewards.userRewardPerTokenPaid(alice), stakingRewards.rewardPerTokenStored());
    }

    // ------------------------------------------------------------------
    // Reward into fundAndNotify test
    // ------------------------------------------------------------------

    function test_FundAndNotify_Success() public {
        uint256 expectRewardRate = 10;
        uint256 expectPeriodFinish = block.timestamp + REWARD_DURATION;
        uint256 expectScheduledRewards = 10 * REWARD_DURATION;
        uint256 expectAccountedRewardBalance = 10 * REWARD_DURATION;

        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, 10 * REWARD_DURATION);
        rewardToken.approve(address(stakingRewards), 10 * REWARD_DURATION);
        vm.warp(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit RewardAdded(rewardManager, 10 * REWARD_DURATION, expectRewardRate, expectPeriodFinish);
        stakingRewards.fundAndNotify(10 * REWARD_DURATION);

        assertEq(expectRewardRate, stakingRewards.rewardRate());
        assertEq(block.timestamp, stakingRewards.lastUpdateTime());
        assertEq(expectPeriodFinish, stakingRewards.periodFinish());
        assertEq(expectScheduledRewards, stakingRewards.scheduledRewards());
        assertEq(expectAccountedRewardBalance, stakingRewards.accountedRewardBalance());

        vm.stopPrank();
    }

    function test_FundAndNotify_RevertWhenCallerNotRewardManager() public {
        rewardToken.mint(rewardManager, 2000);
        rewardToken.approve(address(stakingRewards), 2000);

        vm.startPrank(alice);
        vm.expectRevert(StakingRewards.OnlyRewardManager.selector);
        stakingRewards.fundAndNotify(2000);
        vm.stopPrank();
    }

    function test_FundAndNotify_RevertWhenAmountZero() public {
        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, 2000);
        rewardToken.approve(address(stakingRewards), 2000);

        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.fundAndNotify(0);
        vm.stopPrank();
    }

    function test_FundAndNotify_RevertWhenPaused() public {
        uint256 rewardAmount = REWARD_DURATION;
        rewardToken.mint(rewardManager, rewardAmount);

        vm.prank(rewardManager);
        rewardToken.approve(address(stakingRewards), rewardAmount);

        vm.prank(guardian);
        stakingRewards.pause(bytes32("rewardManager paused"));

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(rewardManager);
        stakingRewards.fundAndNotify(rewardAmount);
    }

    function test_FundAndNotify_RevertWhenTransferFromReturnFalse() public {
        uint256 rewardAmount = 2000;
        ReturnFalseERC20 BadToken = new ReturnFalseERC20("BadToken", "badToken", 18);
        StakingRewards BadStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(BadToken), rewardManager, guardian, REWARD_DURATION
        );
        BadToken.mint(rewardManager, rewardAmount);
        BadToken.setFailTransferFrom(true);
        vm.startPrank(rewardManager);
        BadToken.approve(address(BadStakingRewards), rewardAmount);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(BadToken)));
        BadStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        assertEq(BadStakingRewards.accountedRewardBalance(), 0);
        assertEq(BadStakingRewards.unallocatedRewards(), 0);
        assertEq(BadToken.balanceOf(rewardManager), rewardAmount);
    }

    function test_FundAndNotify_RevertWhenRewardTooSmall() public {
        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, 2000);
        rewardToken.approve(address(stakingRewards), 2000);

        vm.expectRevert(StakingRewards.RewardTooSmall.selector);
        stakingRewards.fundAndNotify(5);

        vm.stopPrank();
    }

    function test_FundAndnotify_RevertWhenRewardAmountTooLarge() public {
        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, MAX_REWARDS_AMOUNT + 2);
        rewardToken.approve(address(stakingRewards), MAX_REWARDS_AMOUNT + 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                StakingRewards.RewardAmountTooLarge.selector, MAX_REWARDS_AMOUNT + 1, MAX_REWARDS_AMOUNT
            )
        );
        stakingRewards.fundAndNotify(MAX_REWARDS_AMOUNT + 1);

        vm.stopPrank();
    }

    function test_FundAndNotify_RevertWhenReceivedAmountMismatch() public {
        FeeOnTransferMock FeeToken = new FeeOnTransferMock("FeeToken", "feeToken", 100);
        StakingRewards FeeStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(FeeToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(rewardManager);
        FeeToken.mint(rewardManager, 2000);
        FeeToken.approve(address(FeeStakingRewards), 2000);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidReceivedAmount.selector, 2000, 1980));
        FeeStakingRewards.fundAndNotify(2000);

        vm.stopPrank();
    }

    function test_FundAndNotify_RoundingDustGoesToUnallocatedRewards() public {
        uint256 rewardAmount = REWARD_DURATION + 1;

        _fundAndNotify(rewardAmount);

        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq(stakingRewards.scheduledRewards(), REWARD_DURATION);
        assertEq(stakingRewards.unallocatedRewards(), 1);
        assertEq(stakingRewards.rewardRate(), 1);
        assertEq(stakingRewards.periodFinish(), block.timestamp + REWARD_DURATION);
    }

    // ----------------------------------------------------------------------
    // earned and get Reward test
    // ----------------------------------------------------------------------

    function test_Earned_IsZeroBeforeFunding() public {
        uint256 stakeAmount = 1000;
        uint256 elapsed = 10;
        _stake(alice, stakeAmount);

        vm.warp(block.timestamp + elapsed);
        assertEq(stakingRewards.earned(alice), 0);
    }

    function test_Earned_IncreasesAfterTimePass() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        assertEq(stakingRewards.earned(alice), elapsed);
    }

    function test_GetReward_Success() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);

        assertEq(stakingRewards.earned(alice), elapsed);
        vm.expectEmit(true, false, false, true);
        emit RewardPaid(alice, elapsed);
        vm.prank(alice);
        stakingRewards.getReward();

        assertEq(rewardToken.balanceOf(alice), elapsed);
        assertEq(stakingRewards.rewards(alice), 0);
    }

    function test_GetReward_WhenZeroReward_NoOpAndNoRewardPaidEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        stakingRewards.getReward();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(entries.length, 0);
        assertEq(rewardToken.balanceOf(alice), 0);
        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), 0);
    }

    function test_GetReward_RevertWhenRewardTransferFails() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        ReturnFalseERC20 BadToken = new ReturnFalseERC20("BadToken", "badToken", 18);
        StakingRewards BadStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(BadToken), rewardManager, guardian, REWARD_DURATION
        );
        BadToken.mint(rewardManager, rewardAmount);
        BadToken.setFailTransferFrom(false);
        vm.startPrank(rewardManager);
        BadToken.approve(address(BadStakingRewards), rewardAmount);
        BadStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        stakingToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        stakingToken.approve(address(BadStakingRewards), stakeAmount);
        BadStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        BadToken.setFailTransfer(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(BadToken)));
        vm.prank(alice);
        BadStakingRewards.getReward();
    }

    function test_GetReward_DecreasesRewardsAggregateAndAccountedBalance() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 beforeAccounted = stakingRewards.accountedRewardBalance();
        uint256 claimable = stakingRewards.earned(alice);
        vm.prank(alice);
        stakingRewards.getReward();

        assertEq(stakingRewards.accountedRewardBalance(), beforeAccounted - elapsed);
        assertEq(stakingRewards.aggregateClaimableRewards(), claimable - elapsed);
        assertEq(rewardToken.balanceOf(alice), elapsed);
        assertEq(stakingRewards.rewards(alice), 0);
    }

    function test_Earned_SingleUserFullPeriodMatchesRateTimesElapsed() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 rewardRate = rewardAmount / REWARD_DURATION;
        uint256 expectedEarn = rewardRate * elapsed;

        assertEq(stakingRewards.earned(alice), expectedEarn);
    }

    function test_Earned_MultipleUsersProrataByStakeAndTime() public {
        uint256 stakeAmountAlice = 1000;
        uint256 stakeAmountBob = 1000;
        uint256 rewardAmount = 2 * REWARD_DURATION;
        uint256 elapsed = 100;

        _stake(alice, stakeAmountAlice);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        _stake(bob, stakeAmountBob);

        vm.warp(block.timestamp + elapsed);
        uint256 rewardRate = rewardAmount / REWARD_DURATION;
        uint256 expectedEarnAlice =
            (2 * elapsed) + Math.mulDiv(rewardRate * elapsed, stakeAmountAlice, stakeAmountAlice + stakeAmountBob);
        uint256 expectedEarnBob = Math.mulDiv(rewardRate * elapsed, stakeAmountBob, stakeAmountAlice + stakeAmountBob);

        assertEq(stakingRewards.earned(alice), expectedEarnAlice);
        assertEq(stakingRewards.earned(bob), expectedEarnBob);
    }

    function test_Non18Decimals_Staking6Reward18() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        MockERC20 stToken = new MockERC20("St Token", "ST", 6);
        StakingRewards stRewards = new StakingRewards(
            initialOwner, address(stToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        stToken.mint(alice, stakeAmount);
        rewardToken.mint(rewardManager, rewardAmount);
        vm.startPrank(alice);
        stToken.approve(address(stRewards), stakeAmount);
        stRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(rewardManager);
        rewardToken.approve(address(stRewards), rewardAmount);
        stRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);

        assertEq(stRewards.totalStaked(), stakeAmount);
        assertEq(stRewards.balanceOf(alice), stakeAmount);

        assertEq(stRewards.earned(alice), 100);
    }

    function test_Non18Decimals_Staking18Reward6() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        MockERC20 reToken = new MockERC20("Re Token", "RE", 6);
        StakingRewards reRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(reToken), rewardManager, guardian, REWARD_DURATION
        );
        stakingToken.mint(alice, stakeAmount);
        reToken.mint(rewardManager, rewardAmount);
        vm.startPrank(alice);
        stakingToken.approve(address(reRewards), stakeAmount);
        reRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(rewardManager);
        reToken.approve(address(reRewards), rewardAmount);
        reRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);

        assertEq(reRewards.totalStaked(), stakeAmount);
        assertEq(reRewards.balanceOf(alice), stakeAmount);

        assertEq(reRewards.earned(alice), 100);
    }

    // ------------------------------------------------------------------
    // accounting test
    // ------------------------------------------------------------------

    function test_UserCheckpointDust_AggregatesScaledDustIntoUnallocatedRewards() public {
        uint256 stakeAmount = 3;
        uint256 withdrawAmount = 3;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);

        assertEq(stakingRewards.unallocatedRewards(), 0);

        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.unallocatedRewards(), 1);
    }

    function test_GlobalRoundingDust_StaysInAccruedReserveWhileStakersExist() public {
        uint256 stakeAmount = 3;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 1;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);
        assertEq(stakingRewards.unallocatedRewards(), 0);

        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, rewardAmount);
        rewardToken.approve(address(stakingRewards), rewardAmount);
        stakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        uint256 released = elapsed;

        assertEq(stakingRewards.accruedRewardReserve(), released);
        assertEq(stakingRewards.rewardPerTokenStored(), Math.mulDiv(released, 1e18, stakeAmount));
    }

    // ---------------------------------------------------------------------------
    // emergency and exit test
    // ---------------------------------------------------------------------------

    function test_Exit_WithPrincipalButNoReward_succeeds() public {
        uint256 stakeAmount = 1000;
        _stake(alice, stakeAmount);

        vm.warp(block.timestamp + REWARD_DURATION);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, stakeAmount);
        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), 0);
    }

    function test_Exit_WithNothing_succeeds() public {
        uint256 stakeAmount = 1000;
        _stake(alice, stakeAmount);

        vm.warp(block.timestamp + REWARD_DURATION);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, stakeAmount);
        vm.prank(alice);
        stakingRewards.withdraw(stakeAmount);

        uint256 beforeBalance = stakingRewards.balanceOf(alice);
        uint256 beforeTotalStake = stakingRewards.totalStaked();

        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), beforeTotalStake);
        assertEq(stakingRewards.balanceOf(alice), beforeBalance);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), 0);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_Exit_WithRewardButNoPrincipal_ClaimsReward() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.withdraw(stakeAmount);

        uint256 beforeBalance = stakingRewards.balanceOf(alice);
        uint256 beforeTotalStake = stakingRewards.totalStaked();

        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), beforeTotalStake);
        assertEq(stakingRewards.balanceOf(alice), beforeBalance);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount - elapsed);
        assertEq(rewardToken.balanceOf(alice), elapsed);
    }

    function test_Exit_DoesNotTriggerNestedNonReentrant() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(alice, stakeAmount);
        vm.expectEmit(true, false, false, true);
        emit RewardPaid(alice, elapsed);
        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount - elapsed);
        assertEq(rewardToken.balanceOf(alice), elapsed);
    }

    function test_EmergencyExit_WithdrawsPrincipal() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.expectEmit(true, false, false, true);
        emit EmergencyExit(alice, stakeAmount, elapsed);
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
        assertEq(stakingRewards.unallocatedRewards(), elapsed);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_EmergencyExit_ForfeitsRewardToUnallocatedRewards() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 10;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.unallocatedRewards(), elapsed);
    }

    function test_EmergencyExit_LastStakerFlushesAccruedRewardReserve() public {
        uint256 stakeAmount = 3;
        uint256 rewardAmount = REWARD_DURATION;

        _stake(alice, stakeAmount);

        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + 1);
        vm.expectEmit(false, false, false, true);
        emit RewardPerTokenDust(1);
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq(stakingRewards.unallocatedRewards(), 1);
        assertEq(stakingRewards.pendingUserDustScaled(), 0);
        assertEq(stakingToken.balanceOf(alice), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
    }

    function test_EmergencyExit_WithNothing_EmitsZeroEvent() public {
        vm.expectEmit(true, false, false, true);
        emit EmergencyExit(alice, 0, 0);
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
    }

    function test_EmergencyExit_DoesNotDecreaseAccountedRewardBalance() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("guardian pause"));
        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq(stakingRewards.unallocatedRewards(), 100);
        assertEq(stakingRewards.aggregateClaimableRewards(), 0);
    }

    // ---------------------------------------------------------------------------
    // sync and sweep and recover test
    // ----------------------------------------------------------------------------

    function test_SweepableUnallocatedRewards_WhenNoStakersIncludesPendingReleased() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 sweepable = stakingRewards.sweepableUnallocatedRewards();
        assertEq(sweepable, 100);
    }

    function test_SweepableUnallocatedRewards_WhenStakedEqualsStoredUnallocated() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);

        uint256 sweepable = stakingRewards.sweepableUnallocatedRewards();
        uint256 storedUnallocatedRewards_ = stakingRewards.storedUnallocatedRewards();
        assertEq(sweepable, storedUnallocatedRewards_);
    }

    function test_SyncUnallocatedRewards_Success() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 donation = 1000;
        _fundAndNotify(rewardAmount);

        rewardToken.mint(address(stakingRewards), donation);
        assertEq(rewardToken.balanceOf(address(stakingRewards)), rewardAmount + donation);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq(stakingRewards.unallocatedRewards(), 0);

        vm.expectEmit(true, false, false, true);
        emit UnallocatedRewardsSynced(address(this), donation, donation);
        stakingRewards.syncUnallocatedRewards();

        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount + donation);
        assertEq(stakingRewards.unallocatedRewards(), donation);
    }

    function test_SyncUnallocatedRewards_RevertWhenNoUnaccountedRewards() public {
        vm.expectRevert(StakingRewards.NoUnaccountedRewards.selector);
        stakingRewards.syncUnallocatedRewards();
    }

    function test_SweepUnallocatedRewards_Success() public {
        uint256 amount = 1000;
        rewardToken.mint(address(stakingRewards), amount);
        stakingRewards.syncUnallocatedRewards();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);

        vm.expectEmit(true, true, false, true);
        emit UnallocatedRewardsSwept(initialOwner, treasury, amount, 0);
        stakingRewards.sweepUnallocatedRewards(treasury, amount);

        assertEq(rewardToken.balanceOf(treasury), amount);
        assertEq(stakingRewards.accountedRewardBalance(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(rewardToken.balanceOf(address(stakingRewards)), 0);

        vm.stopPrank();
    }

    function test_SweepUnallocatedRewards_RevertWhenRecipientNotAllowed() public {
        uint256 amount = 1000;
        rewardToken.mint(address(stakingRewards), amount);
        stakingRewards.syncUnallocatedRewards();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, false);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidSweepRecipient.selector, treasury));
        stakingRewards.sweepUnallocatedRewards(treasury, amount);

        vm.stopPrank();
    }

    function test_SweepUnallocatedRewards_RevertWhenNotOwner() public {
        uint256 amount = 1000;
        rewardToken.mint(address(stakingRewards), amount);
        stakingRewards.syncUnallocatedRewards();

        vm.prank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.sweepUnallocatedRewards(treasury, amount);
    }

    function test_SweepUnallocatedRewards_RevertWhenZeroAmount() public {
        uint256 amount = 1000;
        rewardToken.mint(address(stakingRewards), amount);
        stakingRewards.syncUnallocatedRewards();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.sweepUnallocatedRewards(treasury, 0);

        vm.stopPrank();
    }

    function test_SweepUnallocatedRewards_RevertWhenAmountExceedsSweepable() public {
        uint256 amount = 1000;
        rewardToken.mint(address(stakingRewards), amount);
        stakingRewards.syncUnallocatedRewards();

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(treasury, true);
        vm.expectRevert(
            abi.encodeWithSelector(StakingRewards.InsufficientUnallocatedRewards.selector, amount + 1, amount)
        );
        stakingRewards.sweepUnallocatedRewards(treasury, amount + 1);
    }

    function test_RecoverExcessStakingToken_Success() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.expectEmit(true, true, false, true);
        emit ExcessStakingTokenRecovered(initialOwner, recoveryRecipient, excessAmount, 0);
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();

        assertEq(stakingRewards.totalStaked(), stakeAmount);
        assertEq(stakingRewards.balanceOf(alice), stakeAmount);
        assertEq(stakingToken.balanceOf(alice), 0);
    }

    function test_RecoverExcessStakingToken_RevertWhenAmountExceedsExcess() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                StakingRewards.InsufficientExcessStakingToken.selector, excessAmount + 1, excessAmount
            )
        );
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount + 1);

        vm.stopPrank();
    }

    function test_RecoverExcessStakingToken_RevertWhenNotOwner() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);
        vm.prank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();
    }

    function test_RecoverExcessStakingToken_RevertWhenTransferFails() public {
        uint256 excessAmount = 500;
        ReturnFalseERC20 BadToken = new ReturnFalseERC20("BadToken", "badToken", 18);
        StakingRewards BadStakingRewards = new StakingRewards(
            initialOwner, address(BadToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        BadToken.mint(address(BadStakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        BadStakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        BadToken.setFailTransfer(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(BadToken)));
        BadStakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();
    }

    function test_RecoverExcessStakingToken_RevertWhenZeroAddress() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        stakingRewards.recoverExcessStakingToken(address(0), excessAmount);
        vm.stopPrank();
    }

    function test_RecoverExcessStakingToken_RevertWhenZeroAmount() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, 0);
        vm.stopPrank();
    }

    function test_RecoverExcessStakingToken_RevertWhenRecipientNotAllowed() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 500;

        _stake(alice, stakeAmount);

        stakingToken.mint(address(stakingRewards), excessAmount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, false);
        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidSweepRecipient.selector, recoveryRecipient));
        stakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();
    }

    function test_RecoverERC20_SuccessForNonCoreToken() public {
        MockERC20 recoverToken = new MockERC20("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.expectEmit(true, true, true, false);
        emit ERC20Recovered(initialOwner, address(recoverToken), recoveryRecipient, amount);
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();

        assertEq(recoverToken.balanceOf(recoveryRecipient), amount);
        assertEq(recoverToken.balanceOf(address(stakingRewards)), 0);
    }

    function test_RecoverERC20_RevertWhenTokenIsStakingToken() public {
        uint256 amount = 1000;
        MockERC20 recoverToken = stakingToken;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CannotRecoverCoreToken.selector, address(recoverToken)));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();
    }

    function test_RecoverERC20_RevertWhenTokenIsRewardToken() public {
        uint256 amount = 1000;
        MockERC20 recoverToken = rewardToken;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.CannotRecoverCoreToken.selector, address(recoverToken)));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();
    }

    function test_RecoverERC20_RevertWhenNotOwner() public {
        MockERC20 recoverToken = new MockERC20("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.prank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();
    }

    function test_RecoverERC20_RevertWhenTransferFails() public {
        ReturnFalseERC20 recoverToken = new ReturnFalseERC20("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        recoverToken.setFailTransfer(true);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(recoverToken)));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();
    }

    function test_RecoverERC20_RevertWhenZeroAddressOrZeroAmount() public {
        MockERC20 recoverToken = new MockERC20("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);

        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        stakingRewards.recoverERC20(address(0), recoveryRecipient, amount);

        vm.expectRevert(StakingRewards.ZeroAddress.selector);
        stakingRewards.recoverERC20(address(recoverToken), address(0), amount);

        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, 0);

        vm.stopPrank();
    }

    function test_RecoverERC20_RevertWhenRecipientNotAllowed() public {
        MockERC20 recoverToken = new MockERC20("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, false);

        vm.expectRevert(abi.encodeWithSelector(StakingRewards.InvalidSweepRecipient.selector, recoveryRecipient));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();
    }

    // --------------------------------------------------------------
    // pause and unpause test
    // ---------------------------------------------------------------

    function test_Pause_ByOwner() public {
        vm.startPrank(initialOwner);
        vm.expectEmit(true, false, false, true);
        emit PauseReason(initialOwner, bytes32("Owner Pause"));
        stakingRewards.pause(bytes32("Owner Pause"));
        vm.stopPrank();
    }

    function test_Pause_ByGuardian() public {
        vm.startPrank(guardian);
        vm.expectEmit(true, false, false, true);
        emit PauseReason(guardian, bytes32("Guardian Pause"));
        stakingRewards.pause(bytes32("Guardian Pause"));
        vm.stopPrank();
    }

    function test_Pause_RevertWhenRandomCaller() public {
        vm.startPrank(alice);
        vm.expectRevert(StakingRewards.OnlyGuardianOrOwner.selector);
        stakingRewards.pause(bytes32("alice Pause"));
        vm.stopPrank();
    }

    function test_Pause_RevertWhenAlreadyPaused() public {
        vm.startPrank(initialOwner);
        stakingRewards.pause(bytes32("Owner Pause"));

        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.pause(bytes32("Owner Pause again"));
        vm.stopPrank();
    }

    function test_Pause_WhenPausedAndUnauthorized_PrioritizesOnlyGuardianOrOwner() public {
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.expectRevert(StakingRewards.OnlyGuardianOrOwner.selector);
        vm.prank(alice);
        stakingRewards.pause(bytes32("alice Pause again"));
    }

    function test_Unpause_ByOwner() public {
        vm.startPrank(initialOwner);
        stakingRewards.pause(bytes32("Owner Pause"));
        vm.warp(block.timestamp + 10);
        stakingRewards.unpause();
        vm.stopPrank();
    }

    function test_Unpause_RevertWhenGuardian() public {
        vm.startPrank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));
        vm.warp(block.timestamp + 10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        stakingRewards.unpause();
        vm.stopPrank();
    }

    function test_Unpause_RevertWhenNotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(initialOwner);
        stakingRewards.unpause();
    }

    function test_Unpause_WhenNotPausedAndUnauthorized_PrioritizesOwnerError() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        stakingRewards.unpause();
    }

    function test_WhenPaused_StakeReverts() public {
        uint256 stakeAmount = 1000;
        vm.prank(initialOwner);
        stakingRewards.pause(bytes32("Owner Pause"));

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.stake(stakeAmount);
        vm.stopPrank();
    }

    function test_WhenPaused_WithdrawStillWorks() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 1000;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingToken.balanceOf(alice), withdrawAmount);
    }

    function test_WhenPaused_GetRewardStillWorks() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.prank(alice);
        stakingRewards.getReward();

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(rewardToken.balanceOf(alice), elapsed);
    }

    function test_WhenPaused_FundAndNotifyReverts() public {
        uint256 rewardAmount = 1000;
        vm.prank(initialOwner);
        stakingRewards.pause(bytes32("Owner Pause"));

        vm.startPrank(rewardManager);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        stakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();
    }

    function test_WhenPaused_ExitStillWorks() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.prank(alice);
        stakingRewards.exit();

        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingToken.balanceOf(alice), stakeAmount);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(rewardToken.balanceOf(alice), elapsed);
    }

    function test_WhenPaused_EmergencyExitStillWorks() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        uint256 forfeitedReward = stakingRewards.earned(alice);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.prank(alice);
        stakingRewards.emergencyExit();

        assertEq(stakingRewards.balanceOf(alice), 0);
        assertEq(stakingRewards.totalStaked(), 0);
        assertEq(stakingToken.balanceOf(alice), stakeAmount);

        assertEq(stakingRewards.rewards(alice), 0);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq(stakingRewards.unallocatedRewards(), forfeitedReward);
    }

    // --------------------------------------------------------------
    // rewards duration test
    // --------------------------------------------------------------

    function test_SetRewardsDuration_SuccessAfterPeriodEnds() public {
        uint256 newDuration = 14 days;
        vm.startPrank(initialOwner);
        vm.warp(stakingRewards.periodFinish() + 1);

        vm.expectEmit(false, false, false, true);
        emit RewardsDurationUpdated(REWARD_DURATION, newDuration);
        stakingRewards.setRewardsDuration(newDuration);
        vm.stopPrank();
    }

    function test_SetRewardsDuration_RevertWhenActivePeriod() public {
        uint256 newDuration = 14 days;
        uint256 rewardAmount = REWARD_DURATION;
        _fundAndNotify(rewardAmount);

        vm.startPrank(initialOwner);
        vm.warp(stakingRewards.periodFinish() - 1 days);

        vm.expectRevert(StakingRewards.RewardPeriodActive.selector);
        stakingRewards.setRewardsDuration(newDuration);
        vm.stopPrank();
    }

    function test_SetRewardsDuration_RevertWhenTooSmallOrTooLarge() public {
        vm.startPrank(initialOwner);
        vm.warp(stakingRewards.periodFinish() + 1);

        vm.expectRevert(StakingRewards.InvalidRewardsDuration.selector);
        stakingRewards.setRewardsDuration(MIN_REWARDS_DURATION - 1);

        vm.expectRevert(StakingRewards.InvalidRewardsDuration.selector);
        stakingRewards.setRewardsDuration(MAX_REWARDS_DURATION + 1);

        vm.stopPrank();
    }

    function test_SetRewardsDuration_RevertWhenNotOwner() public {
        uint256 newDuration = 14 days;
        vm.warp(stakingRewards.periodFinish() + 1);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        stakingRewards.setRewardsDuration(newDuration);
        vm.stopPrank();
    }

    function test_SetRewardsDuration_WhenPausedStillAllowedIfPeriodInactive() public {
        uint256 newDuration = 14 days;
        vm.warp(stakingRewards.periodFinish() + 1);
        vm.prank(guardian);
        stakingRewards.pause(bytes32("Guardian Pause"));

        vm.prank(initialOwner);
        stakingRewards.setRewardsDuration(newDuration);

        assertEq(stakingRewards.rewardsDuration(), newDuration);
    }

    // ------------------------------------------------------------------------------
    // view functions test
    // ------------------------------------------------------------------------------

    function test_LastTimeRewardApplicable_ReturnsZeroBeforeFirstReward() public view {
        assertEq(stakingRewards.lastTimeRewardApplicable(), 0);
    }

    function test_LastTimeRewardApplicable_CapsAtPeriodFinish() public {
        vm.warp(stakingRewards.periodFinish() + 1 days);
        uint256 lastTime = stakingRewards.lastTimeRewardApplicable();

        assertEq(stakingRewards.periodFinish(), lastTime);
    }

    function test_RewardPerToken_ReturnsStoredWhenNoStakers() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);
        uint256 rewardStored = stakingRewards.rewardPerTokenStored();
        assertEq(stakingRewards.rewardPerToken(), rewardStored);
    }

    function test_UnreservedRewardBalance_ExcludesAccountedBuckets() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 300;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 donation = 500;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);

        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        stakingRewards.withdraw(withdrawAmount);

        assertEq(stakingRewards.unreservedRewardBalance(), 0);

        rewardToken.mint(address(stakingRewards), donation);
        assertEq(stakingRewards.unreservedRewardBalance(), donation);

        stakingRewards.syncUnallocatedRewards();
        assertEq(stakingRewards.unallocatedRewards(), donation);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount + donation);
    }

    function test_IsRewardPeriodActive_ReturnsExpectedValue() public view {
        if (stakingRewards.periodFinish() > block.timestamp) {
            assertEq(stakingRewards.isRewardPeriodActive(), true);
        } else {
            assertEq(stakingRewards.isRewardPeriodActive(), false);
        }
    }

    function test_StoredUnallocatedRewards_WhenNoStakeersIncludesReleasedRewards() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);
        assertEq(stakingRewards.unallocatedRewards(), 0);

        vm.prank(alice);
        stakingRewards.getReward();

        assertEq(stakingRewards.storedUnallocatedRewards(), elapsed);
        assertEq(stakingRewards.unallocatedRewards(), elapsed);
    }

    function test_StoredUnallocatedRewards_WhenStakersExistDoesNotCountActiveAccrual() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);

        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.storedUnallocatedRewards(), 0);
        assertEq(stakingRewards.unallocatedRewards(), 0);
        assertEq(stakingRewards.sweepableUnallocatedRewards(), 0);
        assertEq(stakingRewards.earned(alice), elapsed);
    }

    function test_SyncUnallocatedRewards_WhenStakersExistOnlySyncsTrueExcess() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 donation = 500;
        uint256 elapsed = 100;
        _stake(alice, stakeAmount);
        _fundAndNotify(rewardAmount);
        vm.warp(block.timestamp + elapsed);
        rewardToken.mint(address(stakingRewards), donation);

        stakingRewards.syncUnallocatedRewards();

        assertEq(stakingRewards.unallocatedRewards(), donation);
        assertEq(stakingRewards.accountedRewardBalance(), rewardAmount + donation);
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
