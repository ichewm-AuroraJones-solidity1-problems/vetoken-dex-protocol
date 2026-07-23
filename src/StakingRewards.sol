// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title StakingRewards
 * @notice Allows uesrs to stake one ERC20 token and earn rewards paid in another ERC20 toekn.
 * @dev Rewards are streamed linearly over a configured duration. The contract keeps separate
 *       accounting buckets for scheduled rewards, claimable user rewards, unallocated rewards,
 *       accrued reserve, and unallocated token balances.
 */
contract StakingRewards is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    /// @notice Token deposited by users for staking.
    IERC20 public immutable stakingToken;

    /// @notice Token distributed to stakers as rewards.
    IERC20 public immutable rewardToken;

    /// @notice Address authorized to fund and notify new reward distributions.
    address public rewardManager;

    /// @notice Address authorized to pause high-risk operations in emergencies.
    address public guardian;

    /// @notice Duration over which newly funded rewards are distributed.
    uint256 public rewardsDuration;

    /// @notice Timestamp when the current reward distribution period ends.
    uint256 public periodFinish;

    /// @notice Reward tokens distributed per second.
    uint256 public rewardRate;

    /// @notice Timestamp of the last global reward accounting update.
    uint256 public lastUpdateTime;

    /// @notice Total amount of staking tokens currently deposited by all users.
    uint256 public totalStaked;

    /// @notice Reward token released by the schedule but not yet assigned to individual users.
    /// @dev This bucket is reduced when users checkpoint their rewards.
    uint256 public accruedRewardReserve;

    /// @notice Accumulated per-user reward dust, scaled by 1e18 and always less than 1e18.
    uint256 public pendingUserDustScaled;

    /// @notice sum of all users' claimable rewards already checkpoint into 'rewards[user]'.
    uint256 public aggregateClaimableRewards;

    /// @notice Reward amount still reserved for future linear distribution.
    uint256 public scheduledRewards;

    /// @notice Reward tokens owned by the contract but not owed to active users.
    /// @dev Includes rounding dust, rewards released while no stakers exist, and synced direct transfers.
    uint256 public unallocatedRewards;

    /// @notice Reward token balance already tracked by contract but not owed to active users.
    /// @dev This includes scheduled, claimable, accrued reserve, and unallocated rewards.
    uint256 public accountedRewardBalance;

    /// @notice Accumulated reward amount per staked token, scaled by 1e18.
    uint256 public rewardPerTokenStored;

    /// @notice Minimum duration for a reward campaign.
    uint256 public constant MIN_REWARDS_DURATION = 1 days;

    /// @notice Maximum duration for a reward campaign.
    uint256 public constant MAX_REWARDS_DURATION = 365 days;

    /// @notice Maximum reward rate allowed to reduce misconfiguration risk.
    uint256 public constant MAX_REWARDS_RATE = type(uint128).max;

    /// @notice Maximum reward amount allowed to reduce misconfiguration risk.
    uint256 public constant MAX_REWARDS_AMOUNT = type(uint128).max;

    /// @notice Mapping of user addresses to their staked balances.
    mapping(address => uint256) public balanceOf;

    /// @notice Reward-per-token value already accounted for each user.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Rewards accrued by each user but not yet claimed.
    mapping(address => uint256) public rewards;

    /// @notice Mapping of sweep recipients to their allowance status.
    mapping(address => bool) public sweepRecipientAllowed;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------
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

    /// @notice Raised when a user tries to withdraw more than their staked balance.
    error InsufficientStake(uint256 requested, uint256 available);
    error InvalidSweepRecipient(address to);
    error CannotRecoverCoreToken(address token);
    error RenounceOwnershipDisabled();
    error InsufficientExcessStakingToken(uint256 requested, uint256 available);
    error InsufficientUnallocatedRewards(uint256 requested, uint256 available);
    error NoUnaccountedRewards();
    error OnlyOwner();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    /// @notice Emitted when a user stakes tokens.
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws staked tokens.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims rewards.
    event RewardPaid(address indexed user, uint256 amount);

    /// @notice Emitted when a user exits immediately and forfeits unclaimed rewards.
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

    /*---------------------------- modifier ----------------------------- */

    modifier updateReward(address account) {
        _updateGlobalReward();
        if (account != address(0)) {
            _updateUserReward(account);
        }
        _;
    }

    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) revert OnlyRewardManager();
        _;
    }

    /*------------------------- constructor ----------------------------- */
    constructor(
        address initialOwner,
        address stakingToken_,
        address rewardToken_,
        address rewardManager_,
        address guardian_,
        uint256 rewardsDuration_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || rewardToken_ == address(0) || stakingToken_ == address(0)
                || rewardManager_ == address(0)
        ) revert ZeroAddress();
        if (rewardToken_ == stakingToken_) revert SameToken();
        if (rewardsDuration_ < MIN_REWARDS_DURATION || rewardsDuration_ > MAX_REWARDS_DURATION) {
            revert InvalidRewardsDuration();
        }

        rewardToken = IERC20(rewardToken_);
        stakingToken = IERC20(stakingToken_);
        rewardManager = rewardManager_;
        guardian = guardian_;
        rewardsDuration = rewardsDuration_;
    }

    /// @notice Stake tokens to start earning rewards.
    /// @dev Updates accrued rewards before changing the user's staking balance.
    /// @param amount The amount of staking tokens to deposit.
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        uint256 beforeStakingBalance = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterStakingBalance = stakingToken.balanceOf(address(this));
        uint256 actualStaked = afterStakingBalance - beforeStakingBalance;
        if (actualStaked != amount) revert InvalidReceivedAmount(amount, actualStaked);

        totalStaked += amount;
        balanceOf[msg.sender] += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraw staked tokens.
     * @dev Checkpoints the caller's rewards before reducing principal, so the user
     *      still receives rewards earned up to this withdrawal.
     * @param amount Amount of staking tokens to withdraw.
     */
    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        _withdraw(msg.sender, amount);
    }

    /**
     * @notice Claim all currently accrued rewards.
     * @dev Rewards are checkpointed first, then transferred to the caller.
     */
    function getReward() external nonReentrant updateReward(msg.sender) {
        _getReward(msg.sender);
    }

    /**
     * @notice Withdraw all principal and claim all accrued rewards.
     * @dev This is a convenience function combining full withdraw and getReward.
     */
    function exit() public nonReentrant updateReward(msg.sender) {
        uint256 principal = balanceOf[msg.sender];
        if (principal > 0) {
            _withdraw(msg.sender, principal);
        }
        _getReward(msg.sender);
    }

    /**
     * @notice Exit staking immediately and forfeit all unclaimed rewards.
     * @dev Principal is returned to the user, while forfeited rewards are moved into
     *      'unallocatedRewards' so they can later be swept by the owner.
     */
    function emergencyExit() public nonReentrant updateReward(msg.sender) {
        uint256 principal = balanceOf[msg.sender];
        uint256 forfeitedReward = rewards[msg.sender];

        balanceOf[msg.sender] = 0;
        totalStaked -= principal;
        rewards[msg.sender] = 0;
        aggregateClaimableRewards -= forfeitedReward;
        unallocatedRewards += forfeitedReward;

        if (totalStaked == 0) {
            _flushAccruedRewardReserveIfNoStakers();
        }

        if (principal > 0) {
            stakingToken.safeTransfer(msg.sender, principal);
        }
        emit EmergencyExit(msg.sender, principal, forfeitedReward);
    }

    /**
     * @notice Fund a new reward period and start linear reward distribution.
     * @dev If an old reward period is still active, the undistributed leftover is rolled
     *      into the new schedule. Rounding dust is moved to 'unallocatedRewards' .
     * @param amount Amount of reward tokens transferred in by the reward manager.
     */
    function fundAndNotify(uint256 amount) external onlyRewardManager nonReentrant updateReward(address(0)) {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_REWARDS_AMOUNT) revert RewardAmountTooLarge(amount, MAX_REWARDS_AMOUNT);
        if (paused()) revert EnforcedPause();
        if (rewardsDuration == 0) revert InvalidRewardsDuration();

        uint256 beforeRewardBalance = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterRewardBalance = rewardToken.balanceOf(address(this));
        uint256 receivedReward = afterRewardBalance - beforeRewardBalance;
        if (receivedReward != amount) revert InvalidReceivedAmount(amount, receivedReward);

        uint256 oldRewardRate = rewardRate;

        // Carry forward rewards that were scheduled but not yet released.
        uint256 leftover = block.timestamp < periodFinish ? (periodFinish - block.timestamp) * oldRewardRate : 0;

        // The new reward schedule is based on newly received rewards plus leftover rewards.
        uint256 grossRewards = receivedReward + leftover;

        uint256 newRewardRate = grossRewards / rewardsDuration;
        if (newRewardRate == 0) revert RewardTooSmall();
        if (newRewardRate > MAX_REWARDS_RATE) revert RewardRateTooLarge(newRewardRate, MAX_REWARDS_RATE);
        uint256 newScheduledRewards = newRewardRate * rewardsDuration;

        // Integer division may leave dust; dust is not distributed and becomes unallocated.
        uint256 roundingDust = grossRewards - newScheduledRewards;

        uint256 availableForThisSchedule = receivedReward + leftover;
        uint256 reservedRewards = aggregateClaimableRewards + accruedRewardReserve + unallocatedRewards;

        uint256 postAccountedBalance = accountedRewardBalance + receivedReward;
        if (postAccountedBalance < reservedRewards + newScheduledRewards + roundingDust) {
            revert InsufficientRewardBalance(reservedRewards + newScheduledRewards + roundingDust, postAccountedBalance);
        }

        if (newScheduledRewards > availableForThisSchedule) {
            revert InsufficientRewardBalance(newScheduledRewards, availableForThisSchedule);
        }

        accountedRewardBalance += receivedReward;
        scheduledRewards = newScheduledRewards;
        unallocatedRewards += roundingDust;
        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(msg.sender, receivedReward, newRewardRate, periodFinish);
    }

    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        if (newDuration < MIN_REWARDS_DURATION || newDuration > MAX_REWARDS_DURATION) revert InvalidRewardsDuration();
        if (periodFinish > block.timestamp) revert RewardPeriodActive();

        uint256 oldDuration = rewardsDuration;
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(oldDuration, newDuration);
    }

    function setRewardManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();

        address oldManager = rewardManager;
        rewardManager = newManager;
        emit RewardManagerUpdated(oldManager, newManager);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    function setSweepRecipientAllowed(address recipient_, bool allowed) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        address recipient = recipient_;
        sweepRecipientAllowed[recipient] = allowed;

        emit SweepRecipientUpdated(recipient, allowed);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function pause(bytes32 reasonHash) public {
        if (msg.sender != guardian && msg.sender != owner()) {
            revert OnlyGuardianOrOwner();
        }
        if (paused()) revert EnforcedPause();

        _pause();

        emit PauseReason(msg.sender, reasonHash);
    }

    function unpause() public onlyOwner {
        if (!paused()) revert ExpectedPause();

        _unpause();
    }

    /**
     * @notice Sync reward tokens that were sent directly to this contract.
     * @dev Direct token transfers bypass 'fundAndNotify', so this function accounts
     *      for the excess balance and moves it into 'unallocatedRewards'.
     */
    function syncUnallocatedRewards() external {
        if (accountedRewardBalance >= rewardToken.balanceOf(address(this))) revert NoUnaccountedRewards();
        uint256 unaccountedRewardBalance = rewardToken.balanceOf(address(this)) - accountedRewardBalance;

        unallocatedRewards += unaccountedRewardBalance;
        accountedRewardBalance += unaccountedRewardBalance;

        emit UnallocatedRewardsSynced(msg.sender, unaccountedRewardBalance, unallocatedRewards);
    }

    /**
     * @notice Sweep unallocated reward tokens to an approved recipient.
     * @dev Only the owner can sweep, and the recipient must be allowlisted.
     *      Active user principal and claimable rewards must not be affected.
     */
    function sweepUnallocatedRewards(address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
        updateReward(address(0))
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to != address(0) && sweepRecipientAllowed[to] == false) revert InvalidSweepRecipient(to);
        if (amount > unallocatedRewards) revert InsufficientUnallocatedRewards(amount, unallocatedRewards);

        unallocatedRewards -= amount;
        accountedRewardBalance -= amount;
        rewardToken.safeTransfer(to, amount);

        emit UnallocatedRewardsSwept(msg.sender, to, amount, unallocatedRewards);
    }

    /**
     * @notice Recover staking tokens accidentally sent to this contract.
     * @dev Only tokens above 'totalStaked' are recoverable, so user principal remain protected.
     */
    function recoverExcessStakingToken(address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (to != address(0) && sweepRecipientAllowed[to] == false) revert InvalidSweepRecipient(to);

        uint256 excess = stakingToken.balanceOf(address(this)) - totalStaked;
        if (amount > excess) revert InsufficientExcessStakingToken(amount, excess);
        uint256 remainingExcess = excess - amount;

        stakingToken.safeTransfer(to, amount);
        emit ExcessStakingTokenRecovered(msg.sender, to, amount, remainingExcess);
    }

    function recoverERC20(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0) || token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (token == address(stakingToken) || token == address(rewardToken)) revert CannotRecoverCoreToken(token);
        if (sweepRecipientAllowed[to] == false) revert InvalidSweepRecipient(to);

        IERC20 recoverToken = IERC20(token);
        recoverToken.safeTransfer(to, amount);
        emit ERC20Recovered(msg.sender, token, to, amount);
    }

    // ===================================== view functions===============================
    /**
     * @notice Returns the timestamp up to which rewards should be accrued.
     * @dev Caps reward accrual at `periodFinish` so rewards do not continue
     *      accumulating after the current reward period ends. Returns zero before
     *      the first reward period is initialized.
     * @return The applicable reward accounting timestamp.
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return periodFinish == 0 ? 0 : Math.min(block.timestamp, periodFinish);
    }

    /**
     * @notice Returns the current accumulated reward per staked token.
     * @dev This is a view-only simulation of the global reward checkpoint. It includes
     *      rewards released since `lastUpdateTime`, but does not update contract state.
     *      The returned value is scaled by 1e18.
     * @return rewardPerToken_ The accumulated reward per staked token, scaled by 1e18.
     */
    function rewardPerToken() public view returns (uint256 rewardPerToken_) {
        if (totalStaked == 0) {
            rewardPerToken_ = rewardPerTokenStored;
        } else {
            uint256 pendingReleased =
                Math.min((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate, scheduledRewards);
            rewardPerToken_ = rewardPerTokenStored + Math.mulDiv(pendingReleased, 1e18, totalStaked);
        }

        return rewardPerToken_;
    }

    /**
     * @notice Returns the total rewards currently earned by a user.
     * @dev Includes both rewards already checkpointed to `rewards[user]` and rewards
     *      accrued since the user's last reward-per-token checkpoint.
     * @param user The account to query.
     * @return earned_ The user's earned reward amount in reward token units.
     */
    function earned(address user) public view returns (uint256 earned_) {
        if (user == address(0)) return 0;
        earned_ = Math.mulDiv(balanceOf[user], rewardPerToken() - userRewardPerTokenPaid[user], 1e18) + rewards[user];
        return earned_;
    }

    /**
     * @notice Rerurn currently stored unallocated rewards.
     * @dev This does not include rewards that would become unallocated after a pending global checkpoint.
     */
    function storedUnallocatedRewards() public view returns (uint256) {
        uint256 storedUnallocatedRewards_ = unallocatedRewards;
        return storedUnallocatedRewards_;
    }

    /**
     * @notice Returns the amount of unallocated rewards currently sweepable.
     * @dev If there are no stakers, rewards released since the last checkpoint are also sweepable
     *      because they cannot be assigned to any user.
     */
    function sweepableUnallocatedRewards() public view returns (uint256) {
        uint256 sweepable;
        uint256 pendingReleased = Math.min((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate, scheduledRewards);

        if (totalStaked == 0) {
            sweepable = unallocatedRewards + pendingReleased;
        } else {
            sweepable = unallocatedRewards;
        }

        return sweepable;
    }

    function unreservedRewardBalance() public view returns (uint256) {
        uint256 unreservedRewardBalance_ = rewardToken.balanceOf(address(this)) - accountedRewardBalance;
        return unreservedRewardBalance_;
    }

    function isRewardPeriodActive() public view returns (bool) {
        return periodFinish > block.timestamp;
    }

    // ================================== internal functions ==================================

    /**
     * @dev Updates global reward accounting up to the current applicable timestamp.
     *      If no stakers exist, released rewards become unallocated. Otherwise, released
     *      rewards increase 'rewardPerTokenStored' and are held in 'accruedRewardReserve'
     */
    function _updateGlobalReward() internal {
        if (lastTimeRewardApplicable() <= lastUpdateTime) return;

        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        uint256 released = Math.min(elapsed * rewardRate, scheduledRewards);
        scheduledRewards -= released;

        if (totalStaked == 0) {
            if (released > 0) {
                unallocatedRewards += released;
                emit RewardsForfeited(lastUpdateTime, lastTimeRewardApplicable(), released);
            }
        } else {
            uint256 rewardPerTokenIncrement = Math.mulDiv(released, 1e18, totalStaked);
            rewardPerTokenStored = rewardPerTokenStored + rewardPerTokenIncrement;
            accruedRewardReserve += released;
        }

        lastUpdateTime = lastTimeRewardApplicable();
    }

    /**
     * @dev Checkpoints one user's rewards based on the latest global reward-per-token value.
     *      Whole-token rewards are added to 'rewards[amount]'; fractional dust is accumulated
     *      and eventually moved into 'unallocatedRewards'.
     */
    function _updateUserReward(address account) internal {
        if (account == address(0)) revert ZeroAddress();
        uint256 rptDelta = rewardPerTokenStored - userRewardPerTokenPaid[account];
        uint256 raw = balanceOf[account] * rptDelta;
        uint256 delta = raw / 1e18;
        uint256 userDustScaled = raw % 1e18;

        pendingUserDustScaled += userDustScaled;
        uint256 userCheckpointDust = pendingUserDustScaled / 1e18;
        pendingUserDustScaled = pendingUserDustScaled % 1e18;

        if (delta > 0) {
            rewards[account] += delta;
            aggregateClaimableRewards += delta;
            accruedRewardReserve -= delta;
        }
        if (userCheckpointDust > 0) {
            accruedRewardReserve -= userCheckpointDust;
            unallocatedRewards += userCheckpointDust;
            emit UserCheckpointDust(account, userCheckpointDust);
        }

        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }

    function _withdraw(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[user]) revert InsufficientStake(amount, balanceOf[user]);

        totalStaked -= amount;
        balanceOf[user] -= amount;
        if (totalStaked == 0) {
            _flushAccruedRewardReserveIfNoStakers();
        }

        stakingToken.safeTransfer(user, amount);
        emit Withdrawn(user, amount);
    }

    function _getReward(address user) internal {
        uint256 reward = rewards[user];

        if (reward == 0) {
            return;
        }
        rewards[user] = 0;
        aggregateClaimableRewards -= reward;
        accountedRewardBalance -= reward;

        rewardToken.safeTransfer(user, reward);

        emit RewardPaid(user, reward);
    }

    function _flushAccruedRewardReserveIfNoStakers() internal {
        if (totalStaked == 0) {
            if (accruedRewardReserve > 0) {
                uint256 dust = accruedRewardReserve;
                unallocatedRewards += dust;
                accruedRewardReserve = 0;

                emit RewardPerTokenDust(dust);
            }
            pendingUserDustScaled = 0;
        } else {
            return;
        }
    }
}
