// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract StakingRewards is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public rewardToken;
    IERC20 public stakingToken;

    uint256 public constant MIN_REWARDS_DURATION = 1 days;
    uint256 public constant MAX_REWARDS_DURATION = 365 days;
    uint256 public constant MAX_REWARDS_RATE = type(uint128).max;
    uint256 public constant MAX_REWARDS_AMOUNT = type(uint128).max;

    mapping(address => bool) public sweepRecipientAllowed;


    error ZeroAddress();
    error ZeroAmount();
    error SameToken();
    error OnlyRewardManager();
    error OnlyGuardianOrOwner();
    error InvalidRewardsDuration();
    error RewardPeriodActive();
    error RewardTooSmall();
    error RewardAmountTooLarge(uint256 amount, uint256 maxAmount);
    error RewardRateTooLarge(uint256 rewardRate, uint256 maxRate);
    error InvalidReceivedAmount(uint256 expected, uint256 received);
    error InsufficientRewardBalance(uint256 required, uint256 available);
    error InsufficientStake(uint256 requested, uint256 available);
    error InvalidSweepRecipient(address to);
    error CannotRecoverCoreToken(address token);
    error RenounceOwnershipDisabled();
    error InsufficientExcessStakingToken(uint256 requested, uint256 available);
    error InsufficientUnallocatedRewards(uint256 requested, uint256 available);
    error NoUnaccountedRewards();

    function stake(uint256 amount) external {



    }

    function setSweepRecipientAllowed(address recipient, bool allowed) external onlyOwner{
        if(recipient == address(0)) revert ZeroAddress();

    }

    
}
