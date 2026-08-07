// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FalseReturnERC20Mock} from "../mocks/FalseReturnERC20Mock.sol";
import {ERC777HookMock} from "../mocks/ERC777HookMock.sol";
import {BlacklistMock} from "../mocks/BlacklistMock.sol";
import {PausableTokenMock} from "../mocks/PausableTokenMock.sol";
import {FeeOnTransferMock} from "../mocks/FeeOnTransferMock.sol";

contract StakingRewardsSecurityTest is Test {
    address initialOwner = makeAddr("initialOwner");
    address rewardManager = makeAddr("rewardManager");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");
    address recoveryRecipient = makeAddr("recoveryRecipient");

    uint256 constant REWARD_DURATION = 7 days;

    MockERC20 stakingToken;
    MockERC20 rewardToken;
    StakingRewards stakingRewards;


    function setUp() public {
        stakingToken = new MockERC20("StakingToken", "STK", 18);
        rewardToken = new MockERC20("RewardToken", "RWD", 18);
        stakingRewards = new StakingRewards(
            initialOwner,
            address(stakingToken),
            address(rewardToken),
            rewardManager,
            guardian,
            REWARD_DURATION
        );
    }

    // -----------------------------------------------------------------
    // ReentrancyGuard Tests
    // -----------------------------------------------------------------

    function test_ReentrancyGuard_BlocksStakeHook() public {
        uint256 stakeAmount = 1000;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner,
            address(hookToken),
            address(rewardToken),
            rewardManager,
            guardian,
            REWARD_DURATION
        );
        hookToken.mint(alice, stakeAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.Stake,
            1,
            address(0),
            address(0)
        );
        hookToken.setEnabled(true);

        vm.startPrank(alice);
        hookToken.approve(address(hookStakingRewards), stakeAmount);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        assertEq (hookStakingRewards.totalStaked(), 0);
        assertEq (hookStakingRewards.balanceOf(alice), 0);
        assertEq (hookToken.balanceOf(alice), stakeAmount);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), 0);
    }

    function test_ReentrancyGuard_BlockWithdrawHook() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 700;
        uint256 elapsed = 100;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner,
            address(hookToken),
            address(rewardToken),
            rewardManager,
            guardian,
            REWARD_DURATION
        );
        hookToken.mint(alice, stakeAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.Withdraw,
            1,
            address(0),
            address(0)
        );
        hookToken.setEnabled(false);

        vm.startPrank(alice);
        hookToken.approve(address(hookStakingRewards), stakeAmount);
        hookStakingRewards.stake(stakeAmount);

        vm.warp(block.timestamp + elapsed);
        hookToken.setEnabled(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq (hookStakingRewards.totalStaked(), stakeAmount);
        assertEq (hookStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (hookToken.balanceOf(alice), 0);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), stakeAmount);
    }

    function test_ReentrancyGuard_BlockGetRewardHook() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(hookToken), address(hookToken), guardian, REWARD_DURATION
        );
       
       stakingToken.mint(alice, stakeAmount);
       vm.startPrank(alice);
       hookToken.setEnabled(false);
       stakingToken.approve(address(hookStakingRewards), stakeAmount);
       hookStakingRewards.stake(stakeAmount);
       vm.stopPrank();

       hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.GetReward,
            1,
            address(0),
            address(0)
        );

        hookToken.mint(address(hookToken), rewardAmount);
        vm.startPrank(address(hookToken));
        hookToken.approve(address(hookStakingRewards), rewardAmount);
        hookToken.setEnabled(false);
        hookStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        hookToken.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.getReward();
        
        assertEq (hookStakingRewards.totalStaked(), stakeAmount);
        assertEq (hookStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (hookStakingRewards.earned(alice), elapsed);
        assertEq (hookStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (hookStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (hookToken.balanceOf(alice), 0);
    }

    function test_ReentrancyGuard_BlockExitHook() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner,
            address(hookToken),
            address(rewardToken),
            rewardManager,
            guardian,
            REWARD_DURATION
        );
        
        rewardToken.mint(rewardManager, rewardAmount);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(hookStakingRewards), rewardAmount);
        hookStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        hookToken.mint(alice, stakeAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.Exit,
            1,
            address(0),
            address(0)
        );

        hookToken.setEnabled(false);
        vm.startPrank(alice);
        hookToken.approve(address(hookStakingRewards), stakeAmount);
        hookStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        hookToken.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.exit();
        
        assertEq (hookStakingRewards.totalStaked(), stakeAmount);
        assertEq (hookStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (hookToken.balanceOf(alice), 0);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), stakeAmount);

        assertEq (rewardToken.balanceOf(alice), 0);
        assertEq (hookStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (hookStakingRewards.accountedRewardBalance(), rewardAmount);
    }

    function test_ReentrancyGuard_BlockEmergencyExitHook() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner,
            address(hookToken),
            address(rewardToken),
            rewardManager,
            guardian,
            REWARD_DURATION
        );
        
        rewardToken.mint(rewardManager, rewardAmount);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(hookStakingRewards), rewardAmount);
        hookStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        hookToken.mint(alice, stakeAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.EmergencyExit,
            1,
            address(0),
            address(0)
        );

        hookToken.setEnabled(false);
        vm.startPrank(alice);
        hookToken.approve(address(hookStakingRewards), stakeAmount);
        hookStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        hookToken.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.emergencyExit();

        assertEq (hookStakingRewards.totalStaked(), stakeAmount);
        assertEq (hookStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (hookStakingRewards.earned(alice), elapsed);
        assertEq (hookStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (hookStakingRewards.unallocatedRewards(), 0);
        assertEq (hookToken.balanceOf(alice), 0);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), stakeAmount);
    }

    function test_ReentrancyGuard_BlockFundAndNotifyHook() public {
        uint256 rewardAmount = REWARD_DURATION;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(hookToken), address(hookToken), guardian, REWARD_DURATION
        );
       hookToken.mint(rewardManager, rewardAmount);
       hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.FundAndNotify,
            1,
            address(0),
            address(0)
        );

        vm.startPrank(address(hookToken));
        hookToken.approve(address(hookStakingRewards), rewardAmount);
        hookToken.setEnabled(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        assertEq (hookStakingRewards.accountedRewardBalance(), 0);
        assertEq (hookStakingRewards.scheduledRewards(), 0);
        assertEq (hookStakingRewards.unallocatedRewards(), 0);
        assertEq (hookStakingRewards.rewardRate(), 0);
        assertEq (hookToken.balanceOf(rewardManager), rewardAmount);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), 0);
    }

    function test_ReentrancyGuard_BlocksSweepUnallocatedRewardsHook() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 amount = 70;
        uint256 elapsed = 100;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(hookToken), address(hookToken), guardian, REWARD_DURATION
        );

        hookToken.mint(address(hookToken), rewardAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.SweepUnallocatedRewards,
            amount,
            treasury,
            address(0)
        );
        vm.startPrank(address(hookToken));
        hookToken.approve(address(hookStakingRewards), rewardAmount);
        hookToken.setEnabled(false);
        hookStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        vm.startPrank(initialOwner);
        hookStakingRewards.setSweepRecipientAllowed(treasury, true);
        hookToken.setEnabled(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.sweepUnallocatedRewards(treasury, amount);
        vm.stopPrank();

        assertEq (hookStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (hookStakingRewards.unallocatedRewards(), 0);
        assertEq (hookToken.balanceOf(treasury), 0);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), rewardAmount);
    }

    function test_ReentrancyGuard_BlocksRecoverExcessStakingTokenHook() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 700;
        ERC777HookMock hookToken = new ERC777HookMock("HookToken", "HOOK");
        StakingRewards hookStakingRewards = new StakingRewards(
            initialOwner, address(hookToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        hookToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        hookToken.setEnabled(false);
        hookToken.approve(address(hookStakingRewards), stakeAmount);
        hookStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        hookToken.mint(address(hookStakingRewards), excessAmount);
        hookToken.configure(
            hookStakingRewards,
            ERC777HookMock.ReenterCall.RecoverExcessStakingToken,
            excessAmount,
            recoveryRecipient,
            address(0)
        );
        vm.startPrank(initialOwner);
        hookToken.setEnabled(true);
        hookStakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hookStakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();

        assertEq (hookStakingRewards.totalStaked(), stakeAmount);
        assertEq (hookToken.balanceOf(address(hookStakingRewards)), stakeAmount + excessAmount);
        assertEq (hookToken.balanceOf(recoveryRecipient), 0);
    }

    function test_ReentrancyGuard_BlocksRecoverERC20Hook() public {
        uint256 amount = 1000;
        ERC777HookMock recoverToken = new ERC777HookMock("RecoverToken", "REC");
        recoverToken.mint(address(stakingRewards), amount);
        recoverToken.configure(
            stakingRewards,
            ERC777HookMock.ReenterCall.RecoverERC20,
            amount,
            recoveryRecipient,
            address(recoverToken)
        );

        vm.startPrank(initialOwner);
        recoverToken.approve(address(stakingRewards), amount);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        recoverToken.setEnabled(true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();

        assertEq (recoverToken.balanceOf(recoveryRecipient), 0);
        assertEq (recoverToken.balanceOf(address(stakingRewards)), amount);
    }

    // -----------------------------------------------------------------
    // Blacklist Tests
    // -----------------------------------------------------------------

    function test_BlacklistMock_StakeTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(blacklistToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        blacklistToken.mint(alice, stakeAmount);
        blacklistToken.setBlacklisted(alice, true);

        vm.startPrank(alice);
        blacklistToken.approve(address(blacklistStakingRewards), stakeAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                alice
            )
        );
        blacklistStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        assertEq (blacklistStakingRewards.totalStaked(), 0);
        assertEq (blacklistStakingRewards.balanceOf(alice), 0);
        assertEq (blacklistToken.balanceOf(alice), stakeAmount);
        assertEq (blacklistToken.balanceOf(address(blacklistStakingRewards)), 0);
    }

    function test_BlacklistMock_WithdrawTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 700;
        uint256 elapsed = 100;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(blacklistToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        blacklistToken.mint(alice, stakeAmount);
        blacklistToken.setBlacklisted(alice, false);

        vm.startPrank(alice);
        blacklistToken.approve(address(blacklistStakingRewards), stakeAmount);
        blacklistStakingRewards.stake(stakeAmount);

        vm.warp(block.timestamp + elapsed);
        blacklistToken.setBlacklisted(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                alice
            )
        );
        blacklistStakingRewards.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq (blacklistStakingRewards.totalStaked(), stakeAmount);
        assertEq (blacklistStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (blacklistToken.balanceOf(alice), 0);
        assertEq (blacklistToken.balanceOf(address(blacklistStakingRewards)), stakeAmount);
    }

    function test_BlacklistMock_GetRewardTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(blacklistToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        stakingToken.mint(alice, stakeAmount);
        stakingToken.approve(address(blacklistStakingRewards), stakeAmount);
        blacklistStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(rewardManager);
        blacklistToken.setBlacklisted(rewardManager, false);
        blacklistToken.mint(rewardManager, rewardAmount);
        blacklistToken.approve(address(blacklistStakingRewards), rewardAmount);
        blacklistStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        vm.startPrank(alice);
        blacklistToken.setBlacklisted(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                alice
            )
        );
        blacklistStakingRewards.getReward();
        vm.stopPrank();

        assertEq (blacklistStakingRewards.totalStaked(), stakeAmount);
        assertEq (blacklistStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (stakingToken.balanceOf(alice), 0);

        assertEq (blacklistStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (blacklistStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (blacklistStakingRewards.earned(alice), elapsed);
        assertEq (blacklistToken.balanceOf(alice), 0);
    }

    function test_BlacklistMock_EmergencyExitTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(blacklistToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        blacklistToken.mint(alice, stakeAmount);
        blacklistToken.setBlacklisted(alice, false);
        blacklistToken.approve(address(blacklistStakingRewards), stakeAmount);
        blacklistStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, rewardAmount);
        rewardToken.approve(address(blacklistStakingRewards), rewardAmount);
        blacklistStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        vm.startPrank(alice);
        blacklistToken.setBlacklisted(alice, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                alice
            )
        );
        blacklistStakingRewards.emergencyExit();
        vm.stopPrank();

        assertEq (blacklistStakingRewards.totalStaked(), stakeAmount);
        assertEq (blacklistStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (blacklistToken.balanceOf(alice), 0);
        
        assertEq (blacklistStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (blacklistStakingRewards.unallocatedRewards(), 0);
        assertEq (blacklistStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (blacklistStakingRewards.earned(alice), elapsed);
        assertEq (rewardToken.balanceOf(alice), 0);
    }

    function test_BlacklistMock_FundAndNotifyTransferFailureRollsBack() public {
        uint256 rewardAmount = REWARD_DURATION;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(blacklistToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(rewardManager);
        blacklistToken.mint(rewardManager, rewardAmount);
        blacklistToken.approve(address(blacklistStakingRewards), rewardAmount);
        blacklistToken.setBlacklisted(rewardManager, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                rewardManager
            )
        );
        blacklistStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();
        
        assertEq (blacklistStakingRewards.accountedRewardBalance(), 0);
        assertEq (blacklistStakingRewards.scheduledRewards(), 0);
        assertEq (blacklistStakingRewards.unallocatedRewards(), 0);
        assertEq (blacklistStakingRewards.rewardRate(), 0);
        assertEq (blacklistToken.balanceOf(rewardManager), rewardAmount);
    }

    function test_BlacklistMock_SweepUnallocatedRewardsTransferFailureRollsBack() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 amount = 70;
        uint256 elapsed = 100;
        BlacklistMock blacklistToken = new BlacklistMock("BlacklistToken", "BLK");
        StakingRewards blacklistStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(blacklistToken), rewardManager, guardian, REWARD_DURATION
        );
        blacklistToken.mint(rewardManager, rewardAmount);
        blacklistToken.setBlacklisted(rewardManager, false);
        vm.startPrank(rewardManager);
        blacklistToken.approve(address(blacklistStakingRewards), rewardAmount);
        blacklistStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        blacklistToken.setBlacklisted(treasury, true);
        vm.startPrank(initialOwner);
        blacklistStakingRewards.setSweepRecipientAllowed(treasury, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                treasury
            )
        );
        blacklistStakingRewards.sweepUnallocatedRewards(treasury, amount);
        vm.stopPrank();

        assertEq (blacklistStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (blacklistStakingRewards.unallocatedRewards(), 0);
        assertEq (blacklistToken.balanceOf(treasury), 0);
        assertEq (blacklistToken.balanceOf(address(blacklistStakingRewards)), rewardAmount);
    }

    function test_BlacklistMock_RecoverExcessStakingTokenTransferFailureRollsBack() public {

    }

    function test_BlacklistMock_RecoverERC20TransferFailureRollsBack() public {
        uint256 amount = 1000;
        BlacklistMock recoverToken = new BlacklistMock("BlacklistToken", "BLK");
        recoverToken.mint(address(stakingRewards), amount);

        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        recoverToken.setBlacklisted(recoveryRecipient, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                BlacklistMock.Blacklisted.selector, 
                recoveryRecipient
            )
        );
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();

        assertEq(recoverToken.balanceOf(address(stakingRewards)), amount);
        assertEq (recoverToken.balanceOf(recoveryRecipient), 0);
    }

    // -------------------------------------------------------------------------------------
    // ReturnFalseERC20 Tests
    //-------------------------------------------------------------------------------------

    function test_ReturnFalseERC20_StakeTransferFromFailureRollBack() public {
        uint256 stakeAmount = 1000;
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(badToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        badToken.mint(alice, stakeAmount);
        badToken.setFailTransferFrom(true);

        vm.startPrank(alice);
        badToken.approve(address(badStakingRewards), stakeAmount);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, badToken));
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        assertEq (badStakingRewards.totalStaked(), 0);
        assertEq (badStakingRewards.balanceOf(alice), 0);
        assertEq (badToken.balanceOf(alice), stakeAmount);
        assertEq (badToken.balanceOf(address(badStakingRewards)), 0);
    }

    function test_ReturnFalseERC20_WithdrawTransferFailureRollsBack() public {
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(badToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        uint256 stakeAmount = 1000;
        badToken.mint(alice, stakeAmount);
        badToken.setFailTransferFrom(false);
        vm.startPrank(alice);
        badToken.approve(address(badStakingRewards), stakeAmount);
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        badToken.setFailTransfer(true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken)));
        badStakingRewards.withdraw(stakeAmount);
        vm.stopPrank();

        assertEq (badStakingRewards.totalStaked(), stakeAmount);
        assertEq (badStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (badToken.balanceOf(alice), 0);
        assertEq (badToken.balanceOf(address(badStakingRewards)), stakeAmount);
    }

    function test_ReturnFalseERC20_FundAndNotifyTransferFromFailureRollsBack() public {
        uint256 rewardAmount = 2000;
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(badToken), rewardManager, guardian, REWARD_DURATION
        );
        badToken.mint(rewardManager, rewardAmount);
        badToken.setFailTransferFrom(true);
        vm.startPrank(rewardManager);
        badToken.approve(address(badStakingRewards), rewardAmount);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken)));
        badStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        assertEq (badStakingRewards.accountedRewardBalance(), 0);
        assertEq (badStakingRewards.scheduledRewards(), 0);
        assertEq (badStakingRewards.unallocatedRewards(), 0);
        assertEq (badStakingRewards.rewardRate(), 0);
        assertEq (badToken.balanceOf(rewardManager), rewardAmount);
    }

    function test_ReturnFalseERC20_GetRewardTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(badToken), rewardManager, guardian, REWARD_DURATION
        );
        badToken.mint(rewardManager, rewardAmount);
        badToken.setFailTransferFrom(false);
        vm.startPrank(rewardManager);
        badToken.approve(address(badStakingRewards), rewardAmount);
        badStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        stakingToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        stakingToken.approve(address(badStakingRewards), stakeAmount);
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        badToken.setFailTransfer(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken)));
        badStakingRewards.getReward();

        assertEq (badStakingRewards.totalStaked(), stakeAmount);
        assertEq (badStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (stakingToken.balanceOf(alice), 0);

        assertEq (badStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (badStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (badStakingRewards.earned(alice), elapsed);
        assertEq (badToken.balanceOf(alice), 0);
    }

    function test_ReturnFalseERC20_ExitTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, 
            address(badToken), 
            address(rewardToken), 
            rewardManager, 
            guardian, 
            REWARD_DURATION
        );
        badToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        badToken.approve(address(badStakingRewards), stakeAmount);
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        rewardToken.mint(rewardManager, rewardAmount);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(badStakingRewards), rewardAmount);
        badStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        badToken.setFailTransfer(true);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeERC20.SafeERC20FailedOperation.selector, 
                address(badToken)
            )
        );
        badStakingRewards.exit();

        assertEq (badStakingRewards.totalStaked(), stakeAmount);
        assertEq (badStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (badToken.balanceOf(alice), 0);

        assertEq (badStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (badStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (badStakingRewards.earned(alice), elapsed);
        assertEq (badToken.balanceOf(alice), 0);
    }

    function test_ReturnFalseERC20_EmergencyExitTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;

        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, 
            address(badToken), 
            address(rewardToken), 
            rewardManager, 
            guardian, 
            REWARD_DURATION
        );
        badToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        badToken.approve(address(badStakingRewards), stakeAmount);
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        rewardToken.mint(rewardManager, rewardAmount);
        vm.startPrank(rewardManager);
        rewardToken.approve(address(badStakingRewards), rewardAmount);
        badStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        badToken.setFailTransfer(true);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeERC20.SafeERC20FailedOperation.selector, 
                address(badToken)
            )
        );
        badStakingRewards.emergencyExit();

        assertEq (badStakingRewards.totalStaked(), stakeAmount);
        assertEq (badStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (badToken.balanceOf(alice), 0);
        
        assertEq (badStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (badStakingRewards.unallocatedRewards(), 0);
        assertEq (badStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (badStakingRewards.earned(alice), elapsed);
        assertEq (rewardToken.balanceOf(alice), 0);
    }

    function test_ReturnFalseERC20_SweepUnallocatedRewardsTransferFailureRollsBack() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 amount = 70;
        uint256 elapsed = 100;
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(badToken), rewardManager, guardian, REWARD_DURATION
        );
        badToken.mint(rewardManager, rewardAmount);
        badToken.setFailTransferFrom(false);
        vm.startPrank(rewardManager);
        badToken.approve(address(badStakingRewards), rewardAmount);
        badStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        vm.startPrank(initialOwner);
        badToken.setFailTransfer(true);
        badStakingRewards.setSweepRecipientAllowed(treasury, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeERC20.SafeERC20FailedOperation.selector, 
                address(badToken)
            )
        );
        badStakingRewards.sweepUnallocatedRewards(treasury, amount);
        vm.stopPrank();

        assertEq (badStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (badStakingRewards.unallocatedRewards(), 0);
        assertEq (badToken.balanceOf(treasury), 0);
        assertEq (badToken.balanceOf(address(badStakingRewards)), rewardAmount);
    }

    function test_ReturnFalseERC20_RecoverERC20TransferFailureRollsBack() public {
        FalseReturnERC20Mock recoverToken = new FalseReturnERC20Mock("RecoverToken", "RECOVER", 18);
        uint256 amount = 1000;
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        recoverToken.setFailTransfer(true);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(recoverToken)));
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();

        assertEq(recoverToken.balanceOf(address(stakingRewards)), amount);
        assertEq (recoverToken.balanceOf(recoveryRecipient), 0);
    }

    function test_ReturnFalseERC20_RecoverExcessStakingTokenTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 700;
        FalseReturnERC20Mock badToken = new FalseReturnERC20Mock("BadToken", "badToken", 18);
        StakingRewards badStakingRewards = new StakingRewards(
            initialOwner, address(badToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );

        badToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        badToken.approve(address(badStakingRewards), stakeAmount);
        badToken.setFailTransfer(false);
        badStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        badToken.mint(address(badStakingRewards), excessAmount);
        vm.startPrank(initialOwner);
        badStakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        badToken.setFailTransfer(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken)));
        badStakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();

        assertEq (badStakingRewards.totalStaked(), stakeAmount);
        assertEq (badToken.balanceOf(address(badStakingRewards)), stakeAmount + excessAmount);
        assertEq (badToken.balanceOf(recoveryRecipient), 0);
    }

    // -------------------------------------------------------------------------------------
    // PausableToken Tests
    // -------------------------------------------------------------------------------------

    function test_PausableTokenMock_StakeTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(pausableToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        pausableToken.mint(alice, stakeAmount);

        vm.prank(alice);
        pausableToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableToken.setTransfersPaused(true);

        vm.prank(alice);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.stake(stakeAmount);

        assertEq (pausableStakingRewards.totalStaked(), 0);
        assertEq (pausableStakingRewards.balanceOf(alice), 0);
        assertEq (pausableToken.balanceOf(alice), stakeAmount);
        assertEq (pausableToken.balanceOf(address(pausableStakingRewards)), 0);
    }

    function test_PausableTokenMock_WithdrawTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 withdrawAmount = 700;
        uint256 elapsed = 100;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(pausableToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        pausableToken.mint(alice, stakeAmount);
        pausableToken.setTransfersPaused(false);
        vm.startPrank(alice);
        pausableToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        pausableToken.setTransfersPaused(true);
        vm.prank(alice);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.withdraw(withdrawAmount);

        assertEq (pausableStakingRewards.totalStaked(), stakeAmount);
        assertEq (pausableStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (pausableToken.balanceOf(alice), 0);
        assertEq (pausableToken.balanceOf(address(pausableStakingRewards)), stakeAmount);
    }

    function test_PausableTokenMock_GetRewardTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(pausableToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        stakingToken.mint(alice, stakeAmount);
        stakingToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableStakingRewards.stake(stakeAmount);
        vm.stopPrank();    

        vm.startPrank(rewardManager);
        pausableToken.mint(rewardManager, rewardAmount);
        pausableToken.setTransfersPaused(false);
        pausableToken.approve(address(pausableStakingRewards), rewardAmount);
        pausableStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        pausableToken.setTransfersPaused(true);
        vm.prank(alice);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.getReward();

        assertEq (pausableStakingRewards.totalStaked(), stakeAmount);
        assertEq (pausableStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (stakingToken.balanceOf(alice), 0);

        assertEq (pausableStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (pausableStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (pausableStakingRewards.earned(alice), elapsed);
        assertEq (pausableToken.balanceOf(alice), 0);
    }

    function test_PausableTokenMock_ExitTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(pausableToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        stakingToken.mint(alice, stakeAmount);
        stakingToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableStakingRewards.stake(stakeAmount);
        vm.stopPrank();    

        vm.startPrank(rewardManager);
        pausableToken.mint(rewardManager, rewardAmount);
        pausableToken.setTransfersPaused(false);
        pausableToken.approve(address(pausableStakingRewards), rewardAmount);
        pausableStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        pausableToken.setTransfersPaused(true);
        vm.prank(alice);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.exit();

        assertEq (pausableStakingRewards.totalStaked(), stakeAmount);
        assertEq (pausableStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (stakingToken.balanceOf(alice), 0);
        assertEq (stakingToken.balanceOf(address(pausableStakingRewards)), stakeAmount);

        assertEq (pausableStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (pausableStakingRewards.aggregateClaimableRewards(), 0);
        assertEq (pausableStakingRewards.earned(alice), elapsed);
        assertEq (pausableToken.balanceOf(alice), 0);
    }

    function test_PausableTokenMock_EmergencyExitTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 rewardAmount = REWARD_DURATION;
        uint256 elapsed = 100;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(pausableToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );

        vm.startPrank(alice);
        pausableToken.mint(alice, stakeAmount);
        pausableToken.setTransfersPaused(false);
        pausableToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableStakingRewards.stake(stakeAmount);
        vm.stopPrank();    

        vm.startPrank(rewardManager);
        rewardToken.mint(rewardManager, rewardAmount);
        rewardToken.approve(address(pausableStakingRewards), rewardAmount);
        pausableStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        pausableToken.setTransfersPaused(true);
        vm.prank(alice);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.emergencyExit();

        assertEq (pausableStakingRewards.totalStaked(), stakeAmount);
        assertEq (pausableStakingRewards.balanceOf(alice), stakeAmount);
        assertEq (pausableToken.balanceOf(alice), 0);

        assertEq (pausableStakingRewards.earned(alice), elapsed);
        assertEq (pausableStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (pausableStakingRewards.unallocatedRewards(), 0);
        assertEq (rewardToken.balanceOf(alice), 0);
        assertEq (rewardToken.balanceOf(address(pausableStakingRewards)), rewardAmount);
    }

    function test_PausableTokenMock_FundAndNotifyTransferFailureRollsBack() public {
        uint256 rewardAmount = REWARD_DURATION;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(pausableToken), rewardManager, guardian, REWARD_DURATION
        );

        pausableToken.mint(rewardManager, rewardAmount);
        pausableToken.setTransfersPaused(true);
        vm.startPrank(rewardManager);
        pausableToken.approve(address(pausableStakingRewards), rewardAmount);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        assertEq (pausableStakingRewards.accountedRewardBalance(), 0);
        assertEq (pausableStakingRewards.scheduledRewards(), 0);
        assertEq (pausableStakingRewards.unallocatedRewards(), 0);
        assertEq (pausableStakingRewards.rewardRate(), 0);
        assertEq (pausableToken.balanceOf(address(pausableStakingRewards)), 0);
        assertEq (pausableToken.balanceOf(rewardManager), rewardAmount);
    }

    function test_PausableTokenMock_SweepUnallocatedRewardsTransferFailureRollsBack() public {
        uint256 rewardAmount = REWARD_DURATION;
        uint256 amount = 70;
        uint256 elapsed = 100;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(stakingToken), address(pausableToken), rewardManager, guardian, REWARD_DURATION
        );
        
        vm.startPrank(rewardManager);
        pausableToken.mint(rewardManager, rewardAmount);
        pausableToken.setTransfersPaused(false);
        pausableToken.approve(address(pausableStakingRewards), rewardAmount);
        pausableStakingRewards.fundAndNotify(rewardAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);
        pausableToken.setTransfersPaused(true);
        vm.startPrank(initialOwner);
        pausableStakingRewards.setSweepRecipientAllowed(treasury, true);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.sweepUnallocatedRewards(treasury, amount);
        vm.stopPrank();

        assertEq (pausableStakingRewards.accountedRewardBalance(), rewardAmount);
        assertEq (pausableStakingRewards.unallocatedRewards(), 0);
        assertEq (pausableToken.balanceOf(treasury), 0);
    }

    function test_PausableTokenMock_RecoverExcessStakingTokenTransferFailureRollsBack() public {
        uint256 stakeAmount = 1000;
        uint256 excessAmount = 300;
        PausableTokenMock pausableToken = new PausableTokenMock("PausableToken", "PAT");
        StakingRewards pausableStakingRewards = new StakingRewards(
            initialOwner, address(pausableToken), address(rewardToken), rewardManager, guardian, REWARD_DURATION
        );
        pausableToken.mint(alice, stakeAmount);

        vm.startPrank(alice);
        pausableToken.approve(address(pausableStakingRewards), stakeAmount);
        pausableToken.setTransfersPaused(false);
        pausableStakingRewards.stake(stakeAmount);
        vm.stopPrank();

        pausableToken.mint(address(pausableStakingRewards), excessAmount);
        vm.startPrank(initialOwner);
        pausableStakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        pausableToken.setTransfersPaused(true);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        pausableStakingRewards.recoverExcessStakingToken(recoveryRecipient, excessAmount);
        vm.stopPrank();

        assertEq (pausableStakingRewards.totalStaked(), stakeAmount);
        assertEq (pausableToken.balanceOf(address(pausableStakingRewards)), stakeAmount + excessAmount);
        assertEq (pausableToken.balanceOf(recoveryRecipient), 0);
    }

    function test_PausableTokenMock_RecoverERC20TransferFailureRollsBack() public {
        uint256 amount = 1000;
        PausableTokenMock recoverToken = new PausableTokenMock("RecoverToken", "RECOVER");
        recoverToken.mint(address(stakingRewards), amount);
        vm.startPrank(initialOwner);
        stakingRewards.setSweepRecipientAllowed(recoveryRecipient, true);
        recoverToken.setTransfersPaused(true);
        vm.expectRevert(PausableTokenMock.TokenPaused.selector);
        stakingRewards.recoverERC20(address(recoverToken), recoveryRecipient, amount);
        vm.stopPrank();

        assertEq (recoverToken.balanceOf(address(stakingRewards)), amount);
        assertEq (recoverToken.balanceOf(recoveryRecipient), 0);
    }

    // --------------------------------------------------------------------------------------
    // FeeOnTransferMock Tests
    // --------------------------------------------------------------------------------------

    function test_FeeOnTransferMock_StakeRevertsWhenReceivedAmountMismatch() public {
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

    function test_FeeOnTransferMock_FundAndNotifyRevertsWhenReceivedAmountMismatch() public {
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

}
