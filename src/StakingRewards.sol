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
 * @notice Allows users to stake one ERC20 token and earn rewards paid in another ERC20 token.
 * @dev Rewards are streamed linearly over a configured duration. The contract keeps separate
 * accounting buckets for scheduled rewards, claimable user rewards, accrued reserves,
 * unallocated rewards, and reward tokens not yet classified by internal accounting.
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

    /// @notice Raised when a required address is zero.
    error ZeroAddress();

    /// @notice Raised when a required amount is zero.
    error ZeroAmount();

    /// @notice Raised when staking token and reward token are the same address.
    error SameToken();

    /// @notice Raised when a caller other than rewardManager calls a reward-manager-only function.
    error OnlyRewardManager();

    /// @notice Raised when a caller is neither guardian nor owner.
    error OnlyGuardianOrOwner();

    /// @notice Raised when rewardsDuration is outside the allowed range.
    error InvalidRewardsDuration();

    /// @notice Raised when trying to change rewardsDuration during an active reward period.
    error RewardPeriodActive();

    /// @notice Raised when funded rewards are too small to produce a non-zero reward rate.
    error RewardTooSmall();

    /// @notice Raised when a reward amount exceeds MAX_REWARDS_AMOUNT.
    error RewardAmountTooLarge(uint256 amount, uint256 maxAmount);

    /// @notice Raised when a computed reward rate exceeds MAX_REWARDS_RATE.
    error RewardRateTooLarge(uint256 rewardRate, uint256 maxRate);

    /// @notice Raised when actual received tokens differ from the requested amount.
    error InvalidReceivedAmount(uint256 expected, uint256 received);

    /// @notice Raised when the contract reward token balance cannot cover internal accounting.
    error InsufficientRewardBalance(uint256 required, uint256 available);

    /// @notice Raised when a user tries to withdraw more than their staked balance.
    error InsufficientStake(uint256 requested, uint256 available);

    /// @notice Raised when a sweep or recovery recipient is not allowlisted.
    error InvalidSweepRecipient(address to);

    /// @notice Raised when attempting to recover the staking token or reward token through recoverERC20.
    error CannotRecoverCoreToken(address token);

    /// @notice Raised when owner tries to renounce ownership.
    error RenounceOwnershipDisabled();

    /// @notice Raised when recovering more staking tokens than the excess balance.
    error InsufficientExcessStakingToken(uint256 requested, uint256 available);

    /// @notice Raised when sweeping more unallocated rewards than available.
    error InsufficientUnallocatedRewards(uint256 requested, uint256 available);

    /// @notice Raised when there are no direct reward-token transfers to sync.
    error NoUnaccountedRewards();

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

    /// @notice Emitted when rewards are released while no stakers exist.
    event RewardsForfeited(uint256 indexed startTime, uint256 indexed endTime, uint256 amount);

    /// @notice Emitted when reward-per-token rounding dust is moved to unallocatedRewards.
    event RewardPerTokenDust(uint256 amount);

    /// @notice Emitted when a user's checkpoint creates whole-token dust for unallocatedRewards.
    event UserCheckpointDust(address indexed user, uint256 amount);

    /// @notice Emitted when unallocated reward tokens are swept to an allowlisted recipient.
    event UnallocatedRewardsSwept(
        address indexed operator, address indexed to, uint256 amount, uint256 remainingUnallocated
    );

    /// @notice Emitted when directly transferred reward tokens are classified as unallocated.
    event UnallocatedRewardsSynced(address indexed operator, uint256 amount, uint256 newUnallocated);

    /// @notice Emitted when excess staking tokens are recovered without touching user principal.
    event ExcessStakingTokenRecovered(
        address indexed operator, address indexed to, uint256 amount, uint256 remainingExcess
    );

    /// @notice Emitted when a non-core ERC20 token is recovered.
    event ERC20Recovered(address indexed operator, address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when the rewardManager address is updated.
    event RewardManagerUpdated(address indexed oldManager, address indexed newManager);

    /// @notice Emitted when the guardian address is updated.
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Emitted when rewardsDuration is updated.
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when a sweep or recovery recipient allowlist entry is updated.
    event SweepRecipientUpdated(address indexed recipient, bool allowed);

    /// @notice Emitted with an off-chain reason hash when the contract is paused.
    event PauseReason(address indexed operator, bytes32 reasonHash);

    /*---------------------------- modifier ----------------------------- */

    /**
     * @dev Checkpoints global reward accounting before executing the function.
     * If account is non-zero, also checkpoints that user's accrued rewards.
     */
    modifier updateReward(address account) {
        _updateGlobalReward();
        if (account != address(0)) {
            _updateUserReward(account);
        }
        _;
    }

    /**
     * @dev Restricts a function to the configured rewardManager.
     */
    modifier onlyRewardManager() {
        if (msg.sender != rewardManager) revert OnlyRewardManager();
        _;
    }

    /*------------------------- constructor ----------------------------- */
    /**
     * @notice Initializes the staking rewards contract.
     * @dev The owner is explicitly provided by `initialOwner` and is not implicitly
     * set to the deployer. The staking token and reward token must be different to
     * keep user principal and reward accounting separate. The reward manager must
     * be non-zero, while the guardian may be address(0) to disable guardian pause.
     * @param initialOwner Initial owner address for Ownable2Step administration.
     * @param stakingToken_ ERC20 token users deposit as principal.
     * @param rewardToken_ ERC20 token distributed as rewards.
     * @param rewardManager_ Address authorized to call fundAndNotify.
     * @param guardian_ Address authorized to pause emergency-sensitive entry points; may be address(0).
     * @param rewardsDuration_ Initial reward distribution duration in seconds.
     */
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
     * unallocatedRewards. This function is not blocked by pause and does not transfer
     * reward tokens to the caller.
     */
    function emergencyExit() public nonReentrant updateReward(msg.sender) {
        uint256 principal = balanceOf[msg.sender];
        uint256 forfeitedReward = rewards[msg.sender];

        balanceOf[msg.sender] = 0;
        totalStaked -= principal;
        rewards[msg.sender] = 0;
        aggregateClaimableRewards -= forfeitedReward;
        unallocatedRewards += forfeitedReward;

        _flushAccruedRewardReserveIfNoStakers();

        if (principal > 0) {
            stakingToken.safeTransfer(msg.sender, principal);
        }
        emit EmergencyExit(msg.sender, principal, forfeitedReward);
    }

    /**
     * @notice Fund a new reward period and start linear reward distribution.
     * @dev Only the rewardManager can fund rewards. If the previous reward period is
     * still active, unreleased scheduled rewards are carried forward as leftover.
     * Historical balances, synced unallocated rewards, forfeited rewards, and claimable
     * user rewards are not used as new funding.
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

        accountedRewardBalance += receivedReward;
        scheduledRewards = newScheduledRewards;
        unallocatedRewards += roundingDust;
        rewardRate = newRewardRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        uint256 actualRewardBalance = rewardToken.balanceOf(address(this));
        if (actualRewardBalance < accountedRewardBalance) {
            revert InsufficientRewardBalance(accountedRewardBalance, actualRewardBalance);
        }

        emit RewardAdded(msg.sender, receivedReward, newRewardRate, periodFinish);
    }

    /**
     * @notice Updates the reward distribution duration.
     * @dev Only callable by the owner. The duration can only be changed when no
     * reward period is active, so an ongoing emission schedule cannot be altered
     * mid-period.
     * @param newDuration New reward duration in seconds.
     */
    function setRewardsDuration(uint256 newDuration) external onlyOwner {
        if (newDuration < MIN_REWARDS_DURATION || newDuration > MAX_REWARDS_DURATION) revert InvalidRewardsDuration();
        if (periodFinish > block.timestamp) revert RewardPeriodActive();

        uint256 oldDuration = rewardsDuration;
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(oldDuration, newDuration);
    }

    /**
     * @notice Updates the address allowed to fund reward periods.
     * @dev Only callable by the owner. Changing the reward manager does not alter
     * any existing reward schedule, leftover accounting, or claimable rewards.
     * @param newManager New reward manager address.
     */
    function setRewardManager(address newManager) external onlyOwner {
        if (newManager == address(0)) revert ZeroAddress();

        address oldManager = rewardManager;
        rewardManager = newManager;
        emit RewardManagerUpdated(oldManager, newManager);
    }

    /**
     * @notice Updates the guardian address.
     * @dev Only callable by the owner. Setting the guardian to address(0) disables
     * guardian-triggered pause while preserving owner pause authority.
     * @param newGuardian New guardian address. May be address(0).
     */
    function setGuardian(address newGuardian) external onlyOwner {
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /**
     * @notice Sets whether an address may receive swept or recovered tokens.
     * @dev Only callable by the owner. This allowlist gates sweepUnallocatedRewards,
     * recoverExcessStakingToken, and recoverERC20 recipients.
     * @param recipient_ Recipient address to update.
     * @param allowed Whether the recipient is allowed.
     */
    function setSweepRecipientAllowed(address recipient_, bool allowed) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        address recipient = recipient_;
        sweepRecipientAllowed[recipient] = allowed;

        emit SweepRecipientUpdated(recipient, allowed);
    }

    /**
     * @notice Disables ownership renunciation.
     * @dev The owner controls safety-critical functions such as reward manager
     * updates, guardian updates, pause recovery, sweep allowlisting, and asset
     * recovery. Renouncing ownership would permanently disable those controls.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    /**
     * @notice Pauses new risk-increasing entry points.
     * @dev Callable by the owner or guardian. Pausing blocks stake and fundAndNotify,
     * but does not block withdraw, getReward, exit, emergencyExit, or owner safety
     * and recovery operations.
     * @param reasonHash Off-chain incident or governance reason identifier.
     */
    function pause(bytes32 reasonHash) public {
        if (msg.sender != guardian && msg.sender != owner()) {
            revert OnlyGuardianOrOwner();
        }
        if (paused()) revert EnforcedPause();

        _pause();

        emit PauseReason(msg.sender, reasonHash);
    }

    /**
     * @notice Restores normal operation after a pause.
     * @dev Only callable by the owner. The guardian can pause quickly in an
     * emergency but cannot unpause.
     */
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
        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        if (accountedRewardBalance >= rewardBalance) revert NoUnaccountedRewards();
        uint256 unaccountedRewardBalance = rewardBalance - accountedRewardBalance;

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

    /**
     * @notice Recover non-core ERC20 tokens accidentally sent to this contract.
     * @dev Only callable by the owner. The staking token and reward token cannot be
     * recovered through this function, and the recipient must be allowlisted.
     * @param token ERC20 token address to recover.
     * @param to Approved recipient address.
     * @param amount Amount of tokens to recover.
     */
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
     * @notice Returns currently stored unallocated rewards.
     * @dev This does not include rewards that would become unallocated after a pending global checkpoint.
     */
    function storedUnallocatedRewards() public view returns (uint256) {
        return unallocatedRewards;
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

    /**
     * @notice Returns reward tokens not yet classified by internal accounting.
     * @dev In normal operation this should be zero. A positive value usually means
     * reward tokens were transferred directly to the contract and can be classified
     * through syncUnallocatedRewards().
     */
    function unreservedRewardBalance() public view returns (uint256) {
        return rewardToken.balanceOf(address(this)) - accountedRewardBalance;
    }

    /**
     * @notice Returns whether the current reward period is still active.
     * @dev A reward period is active only while block.timestamp is strictly before periodFinish.
     */
    function isRewardPeriodActive() public view returns (bool) {
        return periodFinish > block.timestamp;
    }

    // ================================== internal functions ==================================

    /**
     * @dev Updates global reward accounting up to the current applicable timestamp.
     * If no stakers exist, released rewards become unallocated. Otherwise, released
     * rewards increase rewardPerTokenStored and are held in accruedRewardReserve
     * until users checkpoint individually.
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
     * Whole-token rewards are added to rewards[account]; fractional scaled dust is
     * accumulated and eventually moved into unallocatedRewards.
     */
    function _updateUserReward(address account) internal {
        // account is guaranteed non-zero by the updateReward modifier.
        uint256 rptDelta = rewardPerTokenStored - userRewardPerTokenPaid[account];
        uint256 userBalance = balanceOf[account];
        uint256 delta = Math.mulDiv(userBalance, rptDelta, 1e18);
        uint256 userDustScaled = mulmod(userBalance, rptDelta, 1e18);

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

    /**
     * @dev Withdraws staked principal for a user after rewards have been checkpointed.
     * If the withdrawal empties the pool, remaining accrued reserve is flushed into
     * unallocatedRewards before transferring principal back to the user.
     */
    function _withdraw(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[user]) revert InsufficientStake(amount, balanceOf[user]);

        totalStaked -= amount;
        balanceOf[user] -= amount;

        _flushAccruedRewardReserveIfNoStakers();

        stakingToken.safeTransfer(user, amount);
        emit Withdrawn(user, amount);
    }

    /**
     * @dev Transfers a user's checkpointed rewards, if any.
     * Does nothing when the user has no claimable reward.
     */
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

    /**
     * @dev Flushes remaining accrued reserve when the pool has no stakers.
     * Rewards that can no longer be attributed to active users become unallocated,
     * and pending scaled user dust is reset.
     */
    function _flushAccruedRewardReserveIfNoStakers() internal {
        if (totalStaked != 0) return;

        if (accruedRewardReserve > 0) {
            uint256 dust = accruedRewardReserve;
            unallocatedRewards += dust;
            accruedRewardReserve = 0;

            emit RewardPerTokenDust(dust);
        }
        pendingUserDustScaled = 0;
    }
}
