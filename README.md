# StakingRewards

> 一个单池 ERC20 `StakingRewards` 合约项目：用户质押 `stakingToken`，按时间线性领取 `rewardToken`。
> 本项目聚焦 staking 奖励会计、权限控制、暂停恢复、资金偿付和边界测试，不包含 AMM、多池 Gauge、ve 投票、手续费分红、回购或收益聚合。

## 项目定位

`StakingRewards` 是一个 contracts-only 的 Solidity / Foundry 项目，用来展示一个可上线标准的单池质押奖励模块。

核心目标：

- 用户可以 `stake`、`withdraw`、`getReward`、`exit`。
- 奖励由授权 `rewardManager` 注入，并在固定 `rewardsDuration` 内线性释放。
- 合约清楚区分用户本金、已结算未领取奖励、未来排程奖励、放弃奖励和误转资金。
- 所有高权限变更、暂停恢复、奖励注入和资金处理都有明确事件，方便前端、监控和审计追踪。

明确不做：

- 不做多池权重分配、GaugeController、ve 投票、Boost。
- 不做 AMM、Router、LP 手续费分红、回购、收益聚合。
- 不做自动复投、策略金库、跨池排放调度。

## 合约范围

主合约命名为 `StakingRewards`。

| 合约 | 作用 |
|---|---|
| `StakingRewards` | 单池 staking、奖励累计、领取、暂停、权限和资金会计 |
| `MockERC20` | 测试用 staking/reward token |
| `FeeOnTransferMock` | 测试专用，验证实际到账不等于 amount 时必须 revert |
| `RebasingMock` | 测试专用，验证 rebasing token 不属于支持范围 |
| `ERC777HookMock` | 测试专用，验证带 hook token 的重入路径 |
| `BlacklistMock` / `PausableTokenMock` / `FalseReturnERC20Mock` | 测试专用，验证转账失败和异常返回值时状态回滚 |

## 依赖选择

本项目使用 OpenZeppelin 合约库：

| 依赖 | 用途 |
|---|---|
| `Ownable2Step` | owner 权限和两步转移 ownership |
| `Pausable` | 全局风险暂停开关，只限制新增风险入口，不阻断用户退出 |
| `ReentrancyGuard` | 防止 `stake/withdraw/getReward/exit/emergencyExit/fundAndNotify/sweepUnallocatedRewards/recoverExcessStakingToken/recoverERC20` 重入 |
| `SafeERC20` | 安全处理 ERC20 转账 |

权限模型不使用 `AccessControl`。原因是本项目只有三个清晰角色：`owner`、`rewardManager`、`guardian`。使用 `Ownable2Step` 加显式地址变量更容易审计，也避免 role admin 层级过度复杂。

暂停模型使用 OpenZeppelin `Pausable` 作为全局风险开关，但 paused 状态只限制新增风险入口，不锁定用户资金。

暂停权限：

- `owner` 和 `guardian` 都可以调用 `pause(bytes32 reasonHash)`，用于快速阻断新增风险。
- 只有 `owner` 可以调用 `unpause()`。恢复协议正常运行应由 owner、多签或 timelock 明确确认，guardian 不拥有恢复权限。
- `pause(reasonHash)` 必须触发 OZ `Paused(operator)`，并额外发出 `PauseReason(operator, reasonHash)` 方便监控和事故追踪。
- `unpause()` 使用 OZ `Unpaused(operator)`。
- 权限检查优先于 paused 状态检查。`pause(reasonHash)` 必须先检查 `OnlyGuardianOrOwner`，再调用 OZ `_pause()`；`unpause()` 必须先执行 OZ `onlyOwner`，再调用 OZ `_unpause()`。
- 如果权限错误和 paused 状态错误同时成立，必须优先返回权限错误：非 owner/guardian 在已 paused 时调用 `pause(reasonHash)` 仍 revert `OnlyGuardianOrOwner()`；非 owner 在未 paused 时调用 `unpause()` 仍 revert OZ owner error。

paused 状态下禁止：

- `stake`
- `fundAndNotify`

paused 状态下仍允许：

- `withdraw`
- `getReward`
- `exit`
- `emergencyExit`
- `syncUnallocatedRewards`
- owner 安全修复和治理资金处理函数，例如 `setGuardian`、`setRewardManager`、`setRewardsDuration`、`sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20`

这个模型的安全目标是：暂停用于阻止新增风险，不用于冻结用户退出和领奖路径。

### 资金接收 Allowlist

所有会把资产转出到治理地址的函数必须使用接收地址 allowlist，避免 owner 误把资金扫到错误地址。

状态变量：

```solidity
mapping(address => bool) public sweepRecipientAllowed;
```

初始化：

- 构造函数不强制设置 allowlist。
- 部署后 owner 必须显式添加 Treasury 和奖励资金管理地址。
- `address(0)` 永远不能被 allowlist。

接口：

```solidity
function setSweepRecipientAllowed(address recipient, bool allowed) external onlyOwner
```

规则：

- 只有 owner 可以添加或移除地址。
- `recipient == address(0)` 必须 revert `ZeroAddress()`。
- `sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20` 的 `to` 必须满足 `sweepRecipientAllowed[to] == true`，否则 revert `InvalidSweepRecipient(to)`。
- 对这些资金转出函数，`to == address(0)` 必须先 revert `ZeroAddress()`；`to != address(0)` 但未在 allowlist 中时 revert `InvalidSweepRecipient(to)`。
- 变更必须发出 `SweepRecipientUpdated(recipient, allowed)`。
- 重复设置为当前值必须成功并发出事件。例如 `setSweepRecipientAllowed(addr, true)` 在已经为 `true` 时仍成功、状态保持 `true`，并发出新的 `SweepRecipientUpdated(addr, true)`，方便配置审计和索引器追踪治理操作。

## Token 标准与精度

`stakingToken` 和 `rewardToken` 可以不是 18 decimals。合约不得假设 token decimals 为 18，也不得把 token decimals 用于奖励数学。

精度规则：

- `1e18` 只表示内部 `rewardPerToken` 累计精度，不表示 token decimals。
- 所有 token 数量均使用对应 ERC20 的最小单位。例如 USDC 的 `1_000000` 表示 1 USDC，WETH 的 `1 ether` 表示 1 WETH。
- `rewardRate` 的单位是 `rewardToken` 最小单位 / 秒。
- `rewardPerTokenStored` 的单位是 `rewardToken最小单位 * 1e18 / stakingToken最小单位`。
- `earned(user)` 返回 `rewardToken` 最小单位。
- `stake/withdraw` 的 amount 使用 `stakingToken` 最小单位。
- 测试必须覆盖非 18 decimals 组合，例如 `stakingToken.decimals() == 6` 且 `rewardToken.decimals() == 18`，以及反向组合。

口径说明：

```text
stakingToken = USDC-like 6 decimals
rewardToken = WETH-like 18 decimals
user stakes 1_000000 staking units
rewardPerToken 仍使用 1e18 内部精度
earned(user) 以 rewardToken 最小单位返回
```

支持的 token 类型：

- 标准 ERC20，`transfer/transferFrom` 成功时余额变化等于 amount。
- 返回 bool 或不返回值的 ERC20 均通过 `SafeERC20` 兼容。

不支持的 token 类型：

- fee-on-transfer / tax token。
- rebasing / elastic supply token。
- ERC777 callback 或带外部转账 hook 的 token。
- blacklist、pausable、可冻结、管理员可阻断转账的 token。
- 任何 `transferFrom(amount)` 后实际到账不等于 amount 的 token。

开发和测试必须使用 mock token 验证这些排除项：

| Mock | 行为 | 预期 |
|---|---|---|
| `FeeOnTransferMock` | 转账扣税，实际到账少于 amount | `fundAndNotify` 以 `InvalidReceivedAmount` revert；`stake` 也必须拒绝或因本金到账不等而 revert |
| `RebasingMock` | 余额随时间或操作变化 | 不作为支持 token；部署或测试配置必须标记 unsupported |
| `ERC777HookMock` | 转账触发回调重入 | 关键函数受 `nonReentrant` 保护，重入尝试 revert |
| `BlacklistMock` | 对指定地址转账失败 | 对应操作整体 revert，状态完全回滚 |
| `PausableTokenMock` | token 暂停后转账失败 | 对应操作整体 revert，状态完全回滚 |
| `FalseReturnERC20Mock` | `transfer/transferFrom` 返回 false | `SafeERC20` revert，状态完全回滚 |

## 构造函数与初始化

推荐构造函数：

```solidity
constructor(
    address initialOwner,
    address stakingToken_,
    address rewardToken_,
    address rewardManager_,
    address guardian_,
    uint256 rewardsDuration_
) Ownable(initialOwner)
```

初始化规则：

| 参数 | 规则 |
|---|---|
| `initialOwner` | 必须非零。owner 来自构造函数参数，不默认等于部署者 |
| `stakingToken_` | 必须非零 |
| `rewardToken_` | 必须非零 |
| `stakingToken_ != rewardToken_` | 必须成立，避免本金和奖励余额混淆 |
| `rewardManager_` | 必须非零 |
| `guardian_` | 可以为零地址，表示禁用 guardian；生产部署建议非零 |
| `rewardsDuration_` | 必须满足 `MIN_REWARDS_DURATION <= rewardsDuration_ <= MAX_REWARDS_DURATION` |

默认参数：

```text
合约常量：
MIN_REWARDS_DURATION = 1 days
MAX_REWARDS_DURATION = 365 days
MAX_REWARDS_AMOUNT = type(uint128).max
MAX_REWARDS_RATE = type(uint128).max

部署脚本建议默认值：
rewardsDuration = 7 days
```

部署脚本必须显式传入 `initialOwner`，生产环境中 `initialOwner` 应为 Governance Timelock 或项目多签，不应让部署者 EOA 长期持有 owner。

设计说明：
- `MAX_REWARDS_DURATION = 365 days` 用于支持长期激励计划，奖励只能由授权 `rewardManager` 注入。
- `setRewardsDuration` 只能在非活跃奖励周期调用；活跃周期内不能修改 duration，避免中途随意改变排放节奏。


### 部署后初始化流程

部署后不需要额外 initializer，构造函数必须一次性写入所有不可变依赖和初始角色。部署脚本仍必须执行以下校验和交接流程：

1. 部署 `StakingRewards(initialOwner, stakingToken, rewardToken, rewardManager, guardian, rewardsDuration)`。
2. 校验 `owner() == initialOwner`。
3. 校验 `stakingToken()`、`rewardToken()`、`rewardManager()`、`guardian()`、`rewardsDuration()` 与部署参数一致。
4. 校验 `stakingToken() != rewardToken()`。
5. 校验初始奖励状态为未开启：`periodFinish == 0`、`rewardRate == 0`、`lastUpdateTime == 0`、`rewardPerTokenStored == 0`。
6. 校验资金会计为空：`totalStaked == 0`、`scheduledRewards == 0`、`accruedRewardReserve == 0`、`aggregateClaimableRewards == 0`、`unallocatedRewards == 0`、`pendingUserDustScaled == 0`、`accountedRewardBalance == 0`。
7. 校验 `paused() == false`。
8. owner 必须调用 `setSweepRecipientAllowed(treasury, true)`、`setSweepRecipientAllowed(rewardManager, true)` 和 `setSweepRecipientAllowed(recoveryRecipient, true)`，除非其中某个地址明确不承担资金接收职责。
9. 校验 `sweepRecipientAllowed(treasury) == true`、`sweepRecipientAllowed(rewardManager) == true`、`sweepRecipientAllowed(recoveryRecipient) == true`；未被 allowlist 的地址不得作为 `sweepUnallocatedRewards/recoverExcessStakingToken/recoverERC20` 的 `to`。
10. 如果 `initialOwner` 临时设置为部署者 EOA，部署交易后必须立即调用 `transferOwnership(multisigOrTimelock)`，并由目标地址 `acceptOwnership()`。
11. 部署者 EOA 完成交接后不得保留 owner、rewardManager 或 guardian 权限。
12. `rewardManager` 给 staking 合约授权预设额度的 `rewardToken`，或确认奖励资金管理合约已具备调用 `fundAndNotify` 的资金和 allowance。
13. 生产部署后不得为了“ping”而直接执行 `fundAndNotify`，因为它会开启奖励周期并改变 `rewardRate/periodFinish/scheduledRewards`。
14. `fundAndNotify -> stake -> warp -> getReward -> exit` 的连通性检查必须在 fork、testnet 或部署前 dry-run 中完成；如果生产首轮奖励确实要立即开启，必须作为正式奖励启动步骤写入部署计划和公告。

部署后校验必须记录到部署报告中，至少包含合约地址、构造参数、角色地址、初始状态查询结果和 ownership 交接交易哈希。

### 初始状态和 view 返回值

合约刚部署且尚未开启奖励周期时，所有 view 必须返回确定值：

| view | 初始返回值 |
|---|---|
| `owner()` | `initialOwner` |
| `stakingToken()` | 构造参数 `stakingToken_` |
| `rewardToken()` | 构造参数 `rewardToken_` |
| `rewardManager()` | 构造参数 `rewardManager_` |
| `guardian()` | 构造参数 `guardian_`，可为零 |
| `rewardsDuration()` | 构造参数 `rewardsDuration_` |
| `periodFinish()` | `0` |
| `rewardRate()` | `0` |
| `lastUpdateTime()` | `0` |
| `lastTimeRewardApplicable()` | `0` |
| `rewardPerToken()` | `0` |
| `rewardPerTokenStored()` | `0` |
| `totalStaked()` | `0` |
| `balanceOf(user)` | `0` |
| `earned(user)` | `0` |
| `rewards(user)` | `0` |
| `userRewardPerTokenPaid(user)` | `0` |
| `scheduledRewards()` | `0` |
| `accruedRewardReserve()` | `0` |
| `aggregateClaimableRewards()` | `0` |
| `unallocatedRewards()` | `0` |
| `pendingUserDustScaled()` | `0` |
| `accountedRewardBalance()` | `0` |
| `paused()` | `false` |

`lastTimeRewardApplicable()` 在 `periodFinish == 0` 时必须返回 `0`，不能返回当前时间，否则未开启周期时会污染奖励计算。

## 接口规格

### 写函数

| 函数                                                        | 权限                 | 前置条件                                                                                                                                                               | 状态变化                                                                                              | 事件                                                                                                             | 失败错误                                                                                                                                                                    |
| ----------------------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stake(uint256 amount)`                                     | anyone               | `amount > 0`，`paused() == false`，实际收到 stakingToken 等于 amount                                                                                                   | 更新全局和用户奖励；增加 `totalStaked`、`balanceOf[msg.sender]`；转入 stakingToken                    | `Staked`，checkpoint 可能发 `RewardsForfeited`、`UserCheckpointDust`                                             | `ZeroAmount`、OZ `EnforcedPause`、`InvalidReceivedAmount`                                                                                                                   |
| `withdraw(uint256 amount)`                                  | staker               | `amount > 0`，`balanceOf[msg.sender] >= amount`                                                                                                                        | 更新奖励；减少本金；转出 stakingToken                                                                 | `Withdrawn`，checkpoint 可能发 `RewardPerTokenDust`、`UserCheckpointDust`                                        | `ZeroAmount`、`InsufficientStake`                                                                                                                                           |
| `getReward()`                                               | anyone for self      | 无                                                                                                                                                                     | 更新奖励；若 reward > 0，减少 `rewards[user]` 和 `aggregateClaimableRewards`，转出 rewardToken        | `RewardPaid` 仅在 amount > 0 时发出；checkpoint 可能发 `RewardsForfeited`、`UserCheckpointDust`                  | 无奖励时不失败                                                                                                                                                              |
| `exit()`                                                    | staker or no-op user | 无                                                                                                                                                                     | 如果有本金则 withdraw 全部；随后 claim                                                                | `Withdrawn`、可选 `RewardPaid`；checkpoint 可能发 `RewardsForfeited`、`RewardPerTokenDust`、`UserCheckpointDust` | 本金和奖励都为 0 时不失败                                                                                                                                                   |
| `emergencyExit()`                                           | staker or no-op user | 无，且不受 pause 影响                                                                                                                                                  | 必须先更新用户奖励；转出全部本金；清零 `rewards[user]`；将 forfeited reward 计入 `unallocatedRewards` | `EmergencyExit`；checkpoint 可能发 `RewardsForfeited`、`RewardPerTokenDust`、`UserCheckpointDust`                | 本金和奖励都为 0 时不失败                                                                                                                                                   |
| `fundAndNotify(uint256 amount)`                             | `rewardManager`      | `amount > 0`，`amount <= MAX_REWARDS_AMOUNT`，`paused() == false`，实际收到等于 amount，`0 < newRewardRate <= MAX_REWARDS_RATE`，最终 rewardToken 余额必须覆盖 accountedRewardBalance | 转入 rewardToken；更新排程奖励、rate、finish、资金会计                                                | `RewardAdded`，checkpoint 可能发 `RewardsForfeited`                                                              | `OnlyRewardManager`、`ZeroAmount`、`RewardAmountTooLarge`、`InvalidReceivedAmount`、`RewardTooSmall`、`RewardRateTooLarge`、`InsufficientRewardBalance`、OZ `EnforcedPause` |
| `setRewardsDuration(uint256 newDuration)`                   | owner                | 非活跃周期，范围 `[MIN_REWARDS_DURATION, MAX_REWARDS_DURATION]`                                                                                                        | 更新 `rewardsDuration`                                                                                | `RewardsDurationUpdated`                                                                                         | OZ `OwnableUnauthorizedAccount`、`RewardPeriodActive`、`InvalidRewardsDuration`                                                                                             |
| `setRewardManager(address newManager)`                      | owner                | `newManager != address(0)`                                                                                                                                             | 更新 `rewardManager`；不改变已注入奖励周期                                                            | `RewardManagerUpdated`                                                                                           | OZ `OwnableUnauthorizedAccount`、`ZeroAddress`                                                                                                                              |
| `setGuardian(address newGuardian)`                          | owner                | 允许零地址                                                                                                                                                             | 更新 `guardian`                                                                                       | `GuardianUpdated`                                                                                                | OZ `OwnableUnauthorizedAccount`                                                                                                                                             |
| `setSweepRecipientAllowed(address recipient, bool allowed)` | owner                | `recipient != address(0)`                                                                                                                                              | 设置 `sweepRecipientAllowed[recipient] = allowed`；重复设置当前值也成功                               | `SweepRecipientUpdated`                                                                                          | OZ `OwnableUnauthorizedAccount`、`ZeroAddress`                                                                                                                              |
| `pause(bytes32 reasonHash)`                                 | owner or guardian    | 当前未 paused                                                                                                                                                          | 进入全局 paused 状态                                                                                  | OZ `Paused`、`PauseReason`                                                                                       | `OnlyGuardianOrOwner`、OZ `EnforcedPause`                                                                                                                                   |
| `unpause()`                                                 | owner                | 当前 paused                                                                                                                                                            | 退出全局 paused 状态                                                                                  | OZ `Unpaused`                                                                                                    | OZ `OwnableUnauthorizedAccount`、OZ `ExpectedPause`                                                                                                                         |
| `syncUnallocatedRewards()`                                  | anyone               | `rewardToken.balanceOf(this) > accountedRewardBalance`                                                                                                                 | 将未入账余额计入 `unallocatedRewards` 和 `accountedRewardBalance`                                     | `UnallocatedRewardsSynced`                                                                                       | `NoUnaccountedRewards`                                                                                                                                                      |
| `sweepUnallocatedRewards(address to, uint256 amount)`       | owner                | `to != address(0)` 且已允许，`amount > 0`，`amount <= sweepableUnallocatedRewards()`                                                                                   | 先 checkpoint 全局奖励；减少 `unallocatedRewards` 和 `accountedRewardBalance`；转出 rewardToken       | `UnallocatedRewardsSwept`，checkpoint 可能发 `RewardsForfeited`                                                  | OZ `OwnableUnauthorizedAccount`、`ZeroAddress`、`ZeroAmount`、`InvalidSweepRecipient`、`InsufficientUnallocatedRewards`                                                     |
| `recoverExcessStakingToken(address to, uint256 amount)`     | owner                | `to != address(0)` 且已允许，`amount > 0`，`amount <= stakingToken.balanceOf(this) - totalStaked`                                                                      | 转出误转的超额 stakingToken，不改变用户本金会计                                                       | `ExcessStakingTokenRecovered`                                                                                    | OZ `OwnableUnauthorizedAccount`、`ZeroAddress`、`ZeroAmount`、`InvalidSweepRecipient`、`InsufficientExcessStakingToken`                                                     |
| `recoverERC20(address token, address to, uint256 amount)`   | owner                | `token != stakingToken && token != rewardToken`，`to != address(0)` 且已允许，`amount > 0`                                                                             | 转出非核心误转 token                                                                                  | `ERC20Recovered`                                                                                                 | OZ `OwnableUnauthorizedAccount`、`CannotRecoverCoreToken`、`ZeroAddress`、`ZeroAmount`、`InvalidSweepRecipient`                                                             |


### View 函数

| 函数 | 返回值语义 |
|---|---|
| `lastTimeRewardApplicable()` | `periodFinish == 0 ? 0 : min(block.timestamp, periodFinish)` |
| `rewardPerToken()` | 当前全局累计每单位质押奖励，`totalStaked == 0` 时返回 `rewardPerTokenStored` |
| `earned(address user)` | 用户当前可领取奖励，包含已结算 `rewards[user]` 和实时新增部分；当 `user == address(0)` 时返回 `0`，不 revert |
| `storedUnallocatedRewards()` | 当前存储中的 `unallocatedRewards`，不模拟 checkpoint，必须等于状态变量 `unallocatedRewards` |
| `sweepableUnallocatedRewards()` | 如果现在调用 `sweepUnallocatedRewards`，理论上可 sweep 的金额；必须模拟 checkpoint 会新增的 pending unallocated reward |
| `unreservedRewardBalance()` | 当前尚未进入内部会计分类的 rewardToken 余额；正常情况下应为 0，误转后可通过 `syncUnallocatedRewards` 归类 |
| `isRewardPeriodActive()` | `block.timestamp < periodFinish` |
| `paused()` | OZ `Pausable` 全局风险开关状态 |

### 错误策略

项目统一使用 Solidity custom error，不使用 `require("string")`。OpenZeppelin 继承合约产生的错误沿用 OZ v5 标准错误，例如 `OwnableUnauthorizedAccount(address)` 和 `OwnableInvalidOwner(address)`。

业务 custom errors：

```solidity
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
```

所有“必须 revert”的地方都应映射到上表 custom error 或 OZ 标准错误；测试必须用 `expectRevert(selector)` 断言 selector，而不是断言字符串。

## 角色与权限

| 角色 | 权限 | 说明 |
|---|---|---|
| `owner` | 参数变更、角色变更、治理资金处理、owner pause/unpause | 使用 OZ `Ownable2Step` |
| `rewardManager` | `fundAndNotify(amount)` | 只能注入奖励，不能提取用户资金或改参数 |
| `guardian` | 紧急 `pause` | 快速响应事故，不拥有资金权限，也不能恢复 paused 状态 |
| 用户 | `stake/withdraw/getReward/exit` | 管理自己的本金和奖励 |

角色关系：

- `owner` 可以同时是 `rewardManager` 或 `guardian`，合约层面允许；生产部署不推荐，建议三者分离。
- `rewardManager` 可以是多签、Timelock、奖励资金合约或运营合约。
- `guardian` 可以是安全多签。
- Keeper 如果存在，只能触发公开函数，不应持有 `owner`、`rewardManager` 或 `guardian`。

角色变更规则：

| 函数 | 权限 | 零地址规则 | 事件 |
|---|---|---|---|
| `transferOwnership(newOwner)` | current owner | `newOwner != address(0)`，由 OZ 处理 | OZ `OwnershipTransferStarted` |
| `acceptOwnership()` | pending owner | - | OZ `OwnershipTransferred` |
| `renounceOwnership()` | owner | 禁止使用，必须 override 并 revert | `RenounceOwnershipDisabled()` |
| `setRewardManager(newRewardManager)` | owner | 不允许零地址 | `RewardManagerUpdated(oldManager, newManager)` |
| `setGuardian(newGuardian)` | owner | 允许零地址，用于禁用 guardian | `GuardianUpdated(oldGuardian, newGuardian)` |

`setRewardManager(address(0))` 不允许。若需要停止新增奖励，应调用 `pause(reasonHash)` 暂停新增风险入口，或将 `rewardManager` 切换到治理控制地址。

`setGuardian(address(0))` 允许，但只能由 owner 执行。设置后 guardian 相关函数全部不可用。

本项目必须禁用 `renounceOwnership()`。`Ownable2Step` 仍继承自 `Ownable`，默认带有 renounce 能力；但本项目 owner 负责更换 `rewardManager/guardian`、修改 `rewardsDuration`、pause/unpause、sweep 未分配奖励、recover 误转资产等关键治理入口。一旦 owner 被 renounce，这些入口会永久不可用。因此实现必须 override：

```solidity
function renounceOwnership() public override onlyOwner {
    revert RenounceOwnershipDisabled();
}
```

当前奖励周期未结束时允许更换 `rewardManager`，但只影响未来调用权，不改变已经注入的奖励：

- 旧 `rewardManager` 已经通过 `fundAndNotify` 注入的 `scheduledRewards`、`rewardRate`、`periodFinish` 不变。
- 新 `rewardManager` 从事件生效后才可以调用下一次 `fundAndNotify`。
- 旧 `rewardManager` 事件生效后立即失去调用权，不能追加、撤回或修改已注入奖励。
- 更换 `rewardManager` 不会改变 `leftover` 归属。周期中追加时，`leftover` 仍来自合约内已排程奖励，与新旧 manager 身份无关。
- 若需要停止旧 manager 继续注入，应先 `setRewardManager(newManager)` 或调用 `pause(reasonHash)` 暂停新增风险入口，但不得影响用户 `withdraw/getReward/exit/emergencyExit`。

## Guardian 暂停与恢复设计

Guardian 只负责紧急暂停，不负责恢复协议。`pause` 是快速止血操作，可以交给 guardian；`unpause` 是恢复协议正常运行，应由 owner、多签或 timelock 确认后执行。

约束条件：

- Guardian 和 owner 都可以调用 `pause(reasonHash)`。
- 只有 owner 可以调用 `unpause()`。
- paused 状态只阻止 `stake` 和 `fundAndNotify`。
- paused 状态不阻止 `withdraw`、`getReward`、`exit`、`emergencyExit`，用户必须始终能退出和领取已结算奖励。
- Guardian 不能修改 `rewardManager`、`rewardsDuration`、owner、token 地址或任何资金接收地址。
- Guardian 不能调用 `sweepUnallocatedRewards` 或任何资金提取函数。
- 每次 `pause(reasonHash)` 必须发出 OZ `Paused(operator)` 和 `PauseReason(operator, reasonHash)`。
- 每次 `unpause()` 必须发出 OZ `Unpaused(operator)`。

Paused 状态下管理员操作：

- paused 状态下，用户 `stake` 必须 revert，但 `withdraw/getReward/exit/earned/emergencyExit` 不受影响。
- paused 状态下，`fundAndNotify` 必须 revert，但 `syncUnallocatedRewards` 和 view 函数不受影响。
- paused 状态下 owner 仍可以执行安全修复类管理操作：`setGuardian`、`setRewardManager`、`setRewardsDuration`、`sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20`、`unpause`。
- paused 状态下 owner 不能绕过活跃周期限制修改 `rewardsDuration`，也不能 sweep 超过 `unallocatedRewards` 的资金。
- paused 状态下 guardian 不能执行 `unpause`、资金处理或参数变更。
- 暂停不应改变奖励公式。只要时间流逝，活跃周期内的奖励仍按规则释放；如果 `totalStaked == 0`，对应奖励仍进入 `unallocatedRewards`。

## 核心状态变量

| 变量 | 含义 |
|---|---|
| `stakingToken` | 用户质押资产，immutable |
| `rewardToken` | 奖励资产，immutable |
| `rewardManager` | 可注入奖励的地址 |
| `guardian` | 可紧急暂停新增风险入口的地址 |
| `rewardsDuration` | 奖励释放周期 |
| `periodFinish` | 当前奖励周期结束时间 |
| `rewardRate` | 每秒释放奖励数量 |
| `lastUpdateTime` | 上次全局奖励更新时间 |
| `rewardPerTokenStored` | 全局累计每单位质押奖励 |
| `totalStaked` | 当前总质押本金 |
| `balanceOf[user]` | 用户质押本金 |
| `userRewardPerTokenPaid[user]` | 用户已结算到的全局游标 |
| `rewards[user]` | 用户已结算但未领取奖励 |
| `accruedRewardReserve` | 已释放到全局 `rewardPerToken`、但尚未被用户逐个 checkpoint 到 `rewards[user]` 或按逐用户 dust 规则转入 `unallocatedRewards` 的奖励储备 |
| `pendingUserDustScaled` | 逐用户 checkpoint 余数累加器，单位为 `rewardToken最小单位 * 1e18` 的余数刻度，必须始终 `< 1e18` |
| `aggregateClaimableRewards` | 所有用户已结算未领取奖励总额 |
| `scheduledRewards` | 当前和未来仍按 `rewardRate` 释放的奖励 |
| `unallocatedRewards` | 误转、空池放弃、舍入 dust 等未分配奖励 |
| `accountedRewardBalance` | 已进入合约奖励会计的 rewardToken 总额 |

`rewardToken.balanceOf(address(this))` 不能直接等于可发奖励，因为它可能包含用户已结算未领取奖励、未来排程奖励、未分配奖励和误转资金。

## 内部奖励资金会计

本项目当前范围不实现独立 `RewardVault` 合约，但主合约必须实现等价的内部奖励资金账本。已经进入 `accountedRewardBalance` 的 rewardToken 必须精确落入四类内部会计之一；尚未进入会计的余额单独由 `unreservedRewardBalance` 表示，不属于这四类内部资金。

| 类别 | 状态变量 | 是否可由用户领取 | 是否可 sweep | 说明 |
|---|---|---:|---:|---|
| 已结算未领取奖励 | `aggregateClaimableRewards` 和 `rewards[user]` | yes | no | 用户已经 earned 并 checkpoint 到个人账上 |
| 已释放未逐户结算奖励 | `accruedRewardReserve` | 用户 checkpoint 后可领取，或按逐用户 dust 规则转入未分配 | no | 已进入全局 `rewardPerToken`，但尚未进入用户 `rewards[user]` 或 `unallocatedRewards` |
| 未来排程奖励 | `scheduledRewards` | 未来按时间释放 | no | 当前 reward period 剩余可释放奖励 |
| 未分配奖励 | `unallocatedRewards` | no | yes，仅 owner | forfeited、rounding dust、donation、sync 后的误转 |
| 未入账余额 | `rewardToken.balanceOf(this) - accountedRewardBalance` | no | no，需先 sync | 只能通过 `syncUnallocatedRewards` 进入 `unallocatedRewards` |

核心等式：

```text
accountedRewardBalance
  = aggregateClaimableRewards
  + accruedRewardReserve
  + scheduledRewards
  + unallocatedRewards
```

`accruedRewardReserve` 是已经按时间释放、但尚未被用户逐个 checkpoint 到 `rewards[user]` 的奖励。用户执行 `stake/withdraw/getReward/exit/emergencyExit` 时，属于该用户的新增 whole-token earned 会从 `accruedRewardReserve` 转入 `aggregateClaimableRewards` 和 `rewards[user]`；逐用户整数除法残差按 `pendingUserDustScaled` 规则累计，凑成 whole token 后从 `accruedRewardReserve` 转入 `unallocatedRewards`。

资金流规则：

- `fundAndNotify` 收到 rewardToken 后增加 `accountedRewardBalance`。
- 开启或追加周期时，`scheduledRewards` 设置为新周期 `newRewardRate * rewardsDuration`。
- 时间流逝且有用户质押时，奖励从 `scheduledRewards` 释放到全局 `rewardPerToken`；`released` 全额进入 `accruedRewardReserve`。全局 `rewardPerToken` 的整数除法精度残余不单独保存、不跨 `totalStaked` 变化结转，也不能被 sweep；它保守留在 `accruedRewardReserve`，直到无质押承接时按残余规则归入 `unallocatedRewards`。用户交互时，whole-token `delta` 从 `accruedRewardReserve` 转入 `rewards[user]` 和 `aggregateClaimableRewards`，逐用户 checkpoint dust 聚合成 whole token 后从 `accruedRewardReserve` 转入 `unallocatedRewards`。
- 用户 `getReward` 成功转账时，减少 `rewards[user]`、`aggregateClaimableRewards` 和 `accountedRewardBalance`。
- 空池期间释放、`rewardRate` dust、逐用户 checkpoint dust、无质押后残余精度 dust 和误转 sync 的资金进入 `unallocatedRewards`。
- `sweepUnallocatedRewards` 会先执行 checkpoint；checkpoint 可能把已释放奖励从 `scheduledRewards` 扣到 `unallocatedRewards/accruedRewardReserve`。随后 sweep 转账本身只能减少 `unallocatedRewards` 和 `accountedRewardBalance`。

任何时候都必须满足：

```text
aggregateClaimableRewards + accruedRewardReserve + scheduledRewards + unallocatedRewards
  == accountedRewardBalance

accountedRewardBalance
  <= rewardToken.balanceOf(address(this))

unreservedRewardBalance
  == rewardToken.balanceOf(address(this)) - accountedRewardBalance
```

验收时应断言“不多发”和“未分配资金不会被用户领取”。已经进入 `accountedRewardBalance` 的资金必须精确属于四类内部会计之一，不能存在“已入账但未分类”的第五类资金。未入账误转只允许体现为 `unreservedRewardBalance`，并应通过 `syncUnallocatedRewards()` 归入 `unallocatedRewards`。如果实现为了节省 gas 不存储 `accruedRewardReserve`，必须提供等价可验证机制，证明已释放未逐户结算奖励不会被再次排程或 sweep，逐用户 checkpoint dust 也必须有等价的聚合和归类路径。

## 奖励累计规则

全局公式：

```text
lastTimeRewardApplicable = min(block.timestamp, periodFinish)

if totalStaked == 0:
  rewardPerToken = rewardPerTokenStored
else:
  pendingReleased =
    min((lastTimeRewardApplicable - lastUpdateTime) * rewardRate, scheduledRewards)

  rewardPerToken = rewardPerTokenStored
    + pendingReleased * 1e18 / totalStaked
```

`rewardPerToken()` 作为 view 函数只能模拟上述结果。真实状态更新必须在 `_updateGlobalReward()` 中同时推进 `rewardPerTokenStored` 和 `lastUpdateTime`。

用户公式：

```text
earned(user) =
  balanceOf[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18
  + rewards[user]
```

空池期间：

- 当 `totalStaked == 0` 且奖励周期正在进行时，时间仍然流逝。
- 这段时间对应的奖励视为已经释放但无人获得。
- 空池释放奖励不顺延，不补给第一个后进入用户，也不自动进入下一轮 `leftover`。
- `_updateReward(address(0))` 或等价 checkpoint 必须把空池期间 `released = min(elapsed * rewardRate, scheduledRewards)` 从 `scheduledRewards` 移入 `unallocatedRewards`，并发出 `RewardsForfeited(startTime, endTime, amount)`。

## 会计更新顺序

所有会改变奖励会计或用户本金的函数，必须先更新奖励。

通用 modifier：

```solidity
modifier updateReward(address account) {
    _updateGlobalReward();
    if (account != address(0)) {
        _updateUserReward(account);
    }
    _;
}
```

必须先更新全局和用户的函数：

| 函数 | 更新要求 |
|---|---|
| `stake` | 先 `_updateReward(msg.sender)`，再增加本金 |
| `withdraw` | 先 `_updateReward(msg.sender)`，再减少本金 |
| `getReward` | 先 `_updateReward(msg.sender)`，再支付奖励 |
| `exit` | 读取本金后，withdraw 和 claim 路径都必须完成奖励更新 |
| `emergencyExit` | 先 `_updateReward(msg.sender)`，再读取 forfeited reward、清零奖励和转出本金 |
| `fundAndNotify` | 先 `_updateReward(address(0))`，再计算 `leftover` 和新 `rewardRate` |
| `sweepUnallocatedRewards` | 先 `_updateReward(address(0))`，确保 pending 空池 forfeited reward 已入账；有质押时只推进全局累计和 `accruedRewardReserve`，不产生可 sweep 的全局舍入残余 |

`_updateGlobalReward()` 必须做这些事：

- 计算 `elapsed = lastTimeRewardApplicable() - lastUpdateTime`，并从 `scheduledRewards` 中扣减 `released = min(elapsed * rewardRate, scheduledRewards)`。
- 当 `totalStaked > 0` 时，不能按单次 checkpoint 计算“本次看起来可分配的 whole-token 金额”，更不能把差额立即归入 `unallocatedRewards`。用户领取基于跨多次 checkpoint 累加后的 `rewardPerTokenStored - userRewardPerTokenPaid[user]`，所以本次 `released` 必须完整保留在已释放储备中。

正确计算方式：

```text
rewardPerTokenIncrement = released * 1e18 / totalStaked
```

- 用 `rewardPerTokenIncrement` 更新 `rewardPerTokenStored`。
- 将完整 `released` 加入 `accruedRewardReserve`。这笔资金仍然属于已释放奖励储备，后续可能因为累计 `rewardPerToken` 增长而被用户领取，不能在单次 checkpoint 时提前归入 `unallocatedRewards`。
- 不保存全局 `rewardPerToken` 余数，也不把旧 `totalStaked` 分母下产生的余数带到新 `totalStaked` 下继续使用。`stake/withdraw/emergencyExit` 虽然必须先 checkpoint 再改变本金，但这只切分时间段，不授权跨分母复用精度余数。
- 正常有质押的全局 checkpoint 不发 `RewardPerTokenDust`。全局整数除法残余保守留在 `accruedRewardReserve`；只有当它在后续状态转换中被明确判定为不可再被任何用户领取，并且 whole-token 金额从 `accruedRewardReserve` 转入 `unallocatedRewards` 时，才发 `RewardPerTokenDust(amount)`。
- 当 `totalStaked == 0` 时，不增加 `rewardPerTokenStored`，而是将 `released` 加入 `unallocatedRewards`；若 `released > 0`，发出 `RewardsForfeited(lastUpdateTime, lastTimeRewardApplicable(), released)`。
- 将 `lastUpdateTime` 设置为 `lastTimeRewardApplicable()`。

在 `totalStaked == 0` 的时间段，`rewardPerTokenStored` 不增加，但 `lastUpdateTime` 仍必须推进到 `lastTimeRewardApplicable()`，否则第一个后进入用户会错误领取空池期间奖励。

逐用户 checkpoint 不能只做 `delta = balance * rptDelta / 1e18` 后丢弃余数。因为多个用户余数相加可能形成 whole-token dust；如果不处理，这部分会长期留在 `accruedRewardReserve`，但所有用户游标已经推进，未来无法再通过 `earned()` 领取。

实现必须增加一个 scaled 小数累加器：

```solidity
uint256 public pendingUserDustScaled; // always < 1e18 after checkpoint
```

`pendingUserDustScaled` 的单位是 `rewardToken最小单位 * 1e18` 的余数刻度，不是 rewardToken 余额，不属于 `accountedRewardBalance` 四类内部资金之一。

`_updateUserReward(account)` 必须按以下规则处理：

```text
rptDelta = rewardPerTokenStored - userRewardPerTokenPaid[account]
raw = balanceOf[account] * rptDelta
delta = raw / 1e18
userDustScaled = raw % 1e18

pendingUserDustScaled += userDustScaled
userCheckpointDust = pendingUserDustScaled / 1e18
pendingUserDustScaled = pendingUserDustScaled % 1e18
```

当 `delta > 0` 时：

- `rewards[account] += delta`
- `aggregateClaimableRewards += delta`
- `accruedRewardReserve -= delta`

当 `userCheckpointDust > 0` 时：

- `accruedRewardReserve -= userCheckpointDust`
- `unallocatedRewards += userCheckpointDust`
- 发出 `UserCheckpointDust(account, userCheckpointDust)`

最后更新 `userRewardPerTokenPaid[account] = rewardPerTokenStored`。

如果因为整数舍入导致 `delta == 0`，仍必须累计 `userDustScaled` 并更新用户游标。只有 `userDustScaled == 0` 且 `delta == 0` 时，资金会计不变。

当 `withdraw/exit/emergencyExit` 完成用户奖励更新并使 `totalStaked == 0` 时，合约中已不存在可继续累积 `rewardPerToken` 的质押本金。此时：

- `aggregateClaimableRewards` 和各用户 `rewards[user]` 不受影响，仍由用户领取或 emergency forfeiture 处理。
- 如果 `accruedRewardReserve > 0`，这部分已经无法通过未来 `earned()` 分配给任何当前 staker，必须转入 `unallocatedRewards`，并发出 `RewardPerTokenDust(accruedRewardReserve)`。
- 转入后设置 `accruedRewardReserve = 0`。
- 设置 `pendingUserDustScaled = 0`，因为逐用户 scaled dust 不代表 whole-token rewardToken 余额。

## 奖励注入与排程计算

推荐只暴露一个原子入口：

```solidity
function fundAndNotify(uint256 amount) external onlyRewardManager nonReentrant updateReward(address(0))
```

流程：

```text
beforeBalance = rewardToken.balanceOf(address(this))
rewardToken.safeTransferFrom(msg.sender, address(this), amount)
afterBalance = rewardToken.balanceOf(address(this))
received = afterBalance - beforeBalance
if (received != amount) revert InvalidReceivedAmount(amount, received)

leftover = block.timestamp < periodFinish
  ? (periodFinish - block.timestamp) * rewardRate
  : 0

grossRewards = received + leftover
newRewardRate = grossRewards / rewardsDuration
if (newRewardRate == 0) revert RewardTooSmall()
newScheduledRewards = newRewardRate * rewardsDuration
roundingDust = grossRewards - newScheduledRewards

accountedRewardBalance += received
scheduledRewards = newScheduledRewards
unallocatedRewards += roundingDust
rewardRate = newRewardRate
lastUpdateTime = block.timestamp
periodFinish = block.timestamp + rewardsDuration

actualRewardBalance = rewardToken.balanceOf(address(this))
if actualRewardBalance < accountedRewardBalance:
  revert InsufficientRewardBalance(accountedRewardBalance, actualRewardBalance)

```

`unreservedRewardBalance()` 的定义：

```text
unreservedRewardBalance =
  rewardToken.balanceOf(address(this))
  - aggregateClaimableRewards
  - accruedRewardReserve
  - scheduledRewards
  - unallocatedRewards
```

它只能用于 view 展示和辅助审计。`fundAndNotify` 的本轮排程仍必须以 `received + leftover` 为上限，不能因为 `unreservedRewardBalance` 或历史裸余额充足就放大 `newScheduledRewards`。

状态更新：

```text
accountedRewardBalance += received
scheduledRewards = newScheduledRewards
unallocatedRewards += roundingDust
rewardRate = newRewardRate
lastUpdateTime = block.timestamp
periodFinish = block.timestamp + rewardsDuration
```

完整语义：

- 追加奖励时，新周期排程由 received + leftover 计算得到。
- `leftover` 只包含当前周期未来尚未释放的奖励，即 `(periodFinish - now) * oldRewardRate`。
- `unreservedRewardBalance` 必须排除用户已结算未领取的 `aggregateClaimableRewards`。
- `unreservedRewardBalance` 必须排除已经释放但尚未逐户结算的 `accruedRewardReserve`。
- `unreservedRewardBalance` 必须排除 `scheduledRewards` 和 `unallocatedRewards`，包括 forfeited、dust、donated token。
- `fundAndNotify` 不得把 `aggregateClaimableRewards`、`accruedRewardReserve`、`unallocatedRewards` 或历史误转余额用作本轮偿付来源。
- 误转或提前转入的 rewardToken 不得自动参与本次奖励注入。
- 如果 `grossRewards` 不能被 `rewardsDuration` 整除，向下取整后的 `roundingDust` 进入 `unallocatedRewards`，不能被用户领取，也不能自动进入下一轮。
- `newRewardRate == 0` 时必须 revert `RewardTooSmall()`，避免奖励过小导致整笔资金只变成 dust。当前设计不单独定义 `MIN_REWARD_AMOUNT`，金额过小的硬边界由 `grossRewards / rewardsDuration == 0` 决定。
- `amount > MAX_REWARDS_AMOUNT` 必须以 `RewardAmountTooLarge` revert。
- `newRewardRate > MAX_REWARDS_RATE` 必须以 `RewardRateTooLarge` revert。
- Solidity 0.8 算术 overflow revert 是预期失败路径，但实现应优先用显式上限和 custom error 捕获极端大数。若仍因 `received + leftover`、`remaining * rewardRate` 或 `newRewardRate * rewardsDuration` 触发 Solidity panic，测试应将其作为预期失败，而不是成功路径。

不支持公开的“先 transfer，再 notifyRewardAmount(reward)”裸流程。若保留 `notifyRewardAmount(uint256 reward)`，它只能是内部函数或仅由 `fundAndNotify` 调用，否则无法可靠证明本次转入金额与参数一致。

## 未分配奖励处理

`unallocatedRewards` 来源：

- 空池期间已释放但无人获得的奖励。
- `rewardRate` 整除向下取整产生的 dust。
- 有质押期间保守留在 `accruedRewardReserve`、并在无质押承接时被 flush 的全局舍入残余。
- 逐用户 checkpoint 时 `balanceOf[user] * rptDelta / 1e18` 向下取整产生、并通过 `pendingUserDustScaled` 聚合成 whole token 的 dust。
- 外部误转或捐赠进入合约的 rewardToken。

处理规则：

- `unallocatedRewards` 不会自动成为下一轮可发奖励。
- `unallocatedRewards` 不会自动进入下一次 `leftover`。
- 只能由 owner 调用 `sweepUnallocatedRewards(to, amount)` 处理。
- `to == address(0)` 必须 revert `ZeroAddress()`。
- `to != address(0)` 但 `sweepRecipientAllowed[to] == false` 时必须 revert `InvalidSweepRecipient(to)`。
- `sweepUnallocatedRewards` 必须使用 `nonReentrant`。
- 若要让这笔资金重新成为奖励，必须先 sweep 到奖励资金管理地址，再通过 `fundAndNotify` 重新注入。
- `sweepUnallocatedRewards` 的前置 checkpoint 可以按 `_updateGlobalReward()` 规则减少 `scheduledRewards`；checkpoint 完成后的 sweep 转账只能减少 `unallocatedRewards` 和 `accountedRewardBalance`，不得额外减少 `scheduledRewards`、`aggregateClaimableRewards` 或任何用户的 `rewards[user]`。

偿付边界：

```text
scheduledRewards + accruedRewardReserve + aggregateClaimableRewards + unallocatedRewards
  == accountedRewardBalance

accountedRewardBalance
  <= rewardToken.balanceOf(address(this))
```

如果存在未入账误转余额，可通过 `syncUnallocatedRewards()` 将 `rewardToken.balanceOf(address(this)) - accountedRewardBalance` 计入 `unallocatedRewards`，并发出事件。该函数可以 permissionless，因为它只会增加未分配余额，不会转出资金。

### 未分配奖励 view 口径

`storedUnallocatedRewards()` 和 `sweepableUnallocatedRewards()` 必须区分：

```text
storedUnallocatedRewards = unallocatedRewards
```

`storedUnallocatedRewards()` 只返回当前存储值，不模拟任何 checkpoint。

```text
pendingReleased =
  min((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate, scheduledRewards)

pendingCheckpointUnallocated =
  totalStaked == 0
  ? pendingReleased
  : 0

sweepableUnallocatedRewards =
  unallocatedRewards + pendingCheckpointUnallocated
```

`sweepableUnallocatedRewards()` 是 view 层模拟值，用来回答“如果现在调用 `sweepUnallocatedRewards`，最多能 sweep 多少”。它可以大于当前存储的 `unallocatedRewards`，因为 `sweepUnallocatedRewards` 执行时会先 `_updateReward(address(0))`：空池时 pending released 全部进入 `unallocatedRewards`；有质押时 pending released 进入 `accruedRewardReserve`，不会在本次 sweep 中变成可 sweep 的全局舍入残余。

`sweepableUnallocatedRewards()` 不模拟未来某个用户执行 `_updateUserReward(account)` 时可能产生的 `UserCheckpointDust`，因为 `sweepUnallocatedRewards` 只做全局 checkpoint，不会推进任何用户游标。

约束：

- view 命名必须区分存储值和模拟值，避免把“当前存储的未分配奖励”和“立即 checkpoint 后可 sweep 上限”混在一起。
- `storedUnallocatedRewards() <= sweepableUnallocatedRewards()` 必须成立。
- 当 `totalStaked > 0` 时，`sweepableUnallocatedRewards() == storedUnallocatedRewards()`，因为有质押时 pending released 不是未分配奖励。
- `sweepUnallocatedRewards(to, amount)` 的 `amount` 上限使用 checkpoint 后的 `unallocatedRewards`，等价于调用前 view 的 `sweepableUnallocatedRewards()`。

## 误转资产处理策略

误转资产必须按 token 类型区分，不能使用一个无限制 recover 函数处理所有资产。

| 误转资产 | 处理策略 | 原因 |
|---|---|---|
| `stakingToken` | 不提供普通 recover。只有当 `stakingToken.balanceOf(this) > totalStaked` 时，超额部分可由 owner 调用 `recoverExcessStakingToken(to, amount)` 转出，且 `amount <= balance - totalStaked` | `totalStaked` 对应用户本金，不能被管理员挪用 |
| `rewardToken` | 不提供 `recoverRewardToken`。未入账余额先通过 `syncUnallocatedRewards()` 进入 `unallocatedRewards`，再按 `sweepUnallocatedRewards` 治理处理 | rewardToken 可能属于用户已结算奖励、未来排程奖励或未分配奖励 |
| 非 `stakingToken/rewardToken` 的 ERC20 | 可由 owner 调用 `recoverERC20(token, to, amount)` 转出 | 不属于协议核心资金会计 |

`recoverExcessStakingToken` 规则：

- 必须先计算 `excess = stakingToken.balanceOf(address(this)) - totalStaked`。
- 只能转出 `amount <= excess`。
- `to == address(0)` 必须 revert `ZeroAddress()`。
- `to != address(0)` 但 `sweepRecipientAllowed[to] == false` 时必须 revert `InvalidSweepRecipient(to)`。
- 不允许把误转的 stakingToken 转回任意用户地址，除非该地址已被 owner 显式加入 `sweepRecipientAllowed`。
- 不得改变 `totalStaked` 或任何用户 `balanceOf[user]`。
- 必须使用 `nonReentrant`。
- 必须发出 `ExcessStakingTokenRecovered(operator, to, amount, remainingExcess)`。

`recoverERC20` 规则：

- `token != stakingToken && token != rewardToken`。
- `to == address(0)` 必须 revert `ZeroAddress()`。
- `to != address(0)` 但 `sweepRecipientAllowed[to] == false` 时必须 revert `InvalidSweepRecipient(to)`。
- 转账失败时整个调用 revert，不能留下部分状态更新。
- 必须使用 `nonReentrant`，并用带 hook 的恶意 token 覆盖重入测试。
- 必须发出 `ERC20Recovered(operator, token, to, amount)`。

## 用户函数语义

| 函数 | 行为 |
|---|---|
| `stake(amount)` | `amount > 0`，先更新奖励，再转入本金 |
| `withdraw(amount)` | `amount > 0`，先更新奖励，再转出本金 |
| `getReward()` | 领取已结算奖励 |
| `exit()` | 尽力退出全部本金并领取奖励 |
| `emergencyExit()` | 尽力退出全部本金并放弃已结算奖励 |
| `earned(user)` | view 查询用户当前可领奖励 |

零奖励与 `exit()`：

- `getReward` 在奖励为 0 时 no-op 成功，不 revert，不转账，不发出 `RewardPaid`。
- 用户没有本金但有已结算奖励时，`exit()` 应领取奖励。
- 用户有本金但没有奖励时，`exit()` 应成功提款，并跳过奖励转账。
- 用户本金和奖励都为 0 时，`exit()` 应 no-op 成功。
- 单独调用 `withdraw(0)` 必须 revert；`exit()` 是组合型便利函数，不应因本金为 0 revert。

推荐 `exit()`：

```solidity
function exit() external nonReentrant {
    uint256 principal = balanceOf[msg.sender];
    if (principal > 0) {
        _withdraw(msg.sender, principal);
    }
    _getReward(msg.sender);
}
```

`exit()` 不得直接调用 `withdraw(principal)` 和 `getReward()` 这两个 external `nonReentrant` 函数，否则会触发嵌套 `nonReentrant` 并导致 `exit()` 自己 revert。推荐结构是：

```solidity
function withdraw(uint256 amount) external nonReentrant {
    _withdraw(msg.sender, amount);
}

function getReward() public nonReentrant {
    _getReward(msg.sender);
}

function exit() external nonReentrant {
    uint256 principal = balanceOf[msg.sender];
    if (principal > 0) _withdraw(msg.sender, principal);
    _getReward(msg.sender);
}
```

`_withdraw` 和 `_getReward` 是 internal helper，不带 `nonReentrant` modifier，但内部仍必须遵守 CEI：先更新奖励和状态，再执行 token transfer。

所有 external 资金转出函数都必须使用 `nonReentrant`，包括：

- 用户资金路径：`withdraw`、`getReward`、`exit`、`emergencyExit`。
- 奖励和治理资金路径：`sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20`。

`recoverERC20(token, to, amount)` 的 `token` 参数可以是任意非核心 ERC20，误转 token 可能带 hook 或恶意回调；因此它的重入风险高于只处理受生产约束的核心 token 的 recover 路径，必须纳入 `ReentrancyGuard` 和恶意 token 测试。

### 紧急退出

`emergencyExit()` 是用户在前端、奖励领取或 token 异常时的安全退出入口。它只保证尽快取回全部本金，不保证领取奖励。

调用顺序必须是：

```text
_updateReward(msg.sender)
principal = balanceOf[msg.sender]
forfeitedReward = rewards[msg.sender]
balanceOf[msg.sender] = 0
totalStaked -= principal
rewards[msg.sender] = 0
aggregateClaimableRewards -= forfeitedReward
unallocatedRewards += forfeitedReward
transfer stakingToken principal to msg.sender
emit EmergencyExit(msg.sender, principal, forfeitedReward)
```

规则：

- 必须先执行全局和用户奖励更新，再读取 `forfeitedReward`。否则用户在上次 checkpoint 后新增的应计奖励会被错误遗漏。
- `forfeitedReward` 不转给用户，进入 `unallocatedRewards`，后续只能由治理按未分配奖励规则处理。
- `emergencyExit()` 不得减少 `accountedRewardBalance`，因为 rewardToken 仍留在合约内，只是从用户已结算奖励变成未分配奖励。
- `emergencyExit()` 不受 OZ `paused()` 影响。
- `principal == 0 && forfeitedReward == 0` 时 no-op 成功，但仍必须发出 `EmergencyExit(msg.sender, 0, 0)`，保证事件规则和验收标准一致。
- 如果 stakingToken 转账失败，整个调用必须 revert，用户本金、`rewards[user]`、`aggregateClaimableRewards` 和 `unallocatedRewards` 必须全部回滚。

## 奖励周期修改

```solidity
function setRewardsDuration(uint256 newDuration) external onlyOwner
```

规则：

- 活跃奖励周期内禁止修改：`block.timestamp < periodFinish` 时必须 revert。
- 修改只影响下一次 `fundAndNotify` 开启的新周期。
- 不回溯改变已开始周期，不重算历史 `rewardRate`、`periodFinish` 或用户已累积奖励。
- `newDuration` 必须满足 `MIN_REWARDS_DURATION <= newDuration <= MAX_REWARDS_DURATION`。
- `newDuration == 0` 必须在 `setRewardsDuration` 本身 revert，不能等到 `fundAndNotify` 再失败。
- 成功时发出 `RewardsDurationUpdated(oldDuration, newDuration)`。
- `fundAndNotify` 仍应防御性检查 `rewardsDuration > 0`。

## 核心事件

业务事件：

```solidity
event Staked(address indexed user, uint256 amount);
event Withdrawn(address indexed user, uint256 amount);
event RewardPaid(address indexed user, uint256 amount);
event EmergencyExit(address indexed user, uint256 principal, uint256 forfeitedReward);
event RewardAdded(address indexed rewardManager, uint256 amount, uint256 rewardRate, uint256 periodFinish);
event RewardsForfeited(uint256 indexed startTime, uint256 indexed endTime, uint256 amount);
event RewardPerTokenDust(uint256 amount);
event UserCheckpointDust(address indexed user, uint256 amount);
event UnallocatedRewardsSwept(address indexed operator, address indexed to, uint256 amount, uint256 remainingUnallocated);
event UnallocatedRewardsSynced(address indexed operator, uint256 amount, uint256 newUnallocated);
event ExcessStakingTokenRecovered(address indexed operator, address indexed to, uint256 amount, uint256 remainingExcess);
event ERC20Recovered(address indexed operator, address indexed token, address indexed to, uint256 amount);
```

权限和参数事件：

```solidity
event RewardManagerUpdated(address indexed oldManager, address indexed newManager);
event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);
event SweepRecipientUpdated(address indexed recipient, bool allowed);
```

暂停事件：

```solidity
event PauseReason(address indexed operator, bytes32 reasonHash);
```

OZ `Ownable2Step` 会提供 ownership 相关事件，OZ `Pausable` 会提供 `Paused(address account)` 和 `Unpaused(address account)`。

事件规则：

- 零奖励 `getReward` 不发 `RewardPaid`。
- `emergencyExit` 必须发 `EmergencyExit`，并记录准确的 `forfeitedReward`；本金和奖励都为 0 的 no-op 也必须发 `EmergencyExit(user, 0, 0)`。
- `fundAndNotify` 必须发 `RewardAdded`。
- `RewardAdded(rewardManager, amount, rewardRate, periodFinish)` 中的 `amount` 必须等于本次实际收到的 `received`，不是函数参数的盲目信任值，也不是 `received + leftover`。`leftover` 只影响新 `rewardRate`，不作为本次新增 amount 记录。
- 空池奖励进入 `unallocatedRewards` 必须发 `RewardsForfeited`。
- 正常有质押的全局 checkpoint 不发 `RewardPerTokenDust`。当无质押承接时，`accruedRewardReserve` 中无法再被用户领取的 whole-token 残余被转入 `unallocatedRewards`，必须发 `RewardPerTokenDust(amount)`；`amount == 0` 时不发。
- 逐用户 checkpoint dust 聚合成 `userCheckpointDust > 0` 时必须发 `UserCheckpointDust(user, userCheckpointDust)`；`userCheckpointDust == 0` 时不发。事件中的 `user` 是触发本次聚合跨过 whole-token 边界的 checkpoint 用户，不表示全部 dust 都来自该用户。
- `RewardsForfeited(startTime, endTime, amount)` 只用于描述某段空池 checkpoint 窗口内释放但无人获得的奖励。用户 `emergencyExit()` 放弃奖励没有 `startTime/endTime` 语义，不得复用 `RewardsForfeited`，必须只通过 `EmergencyExit(user, principal, forfeitedReward)` 表达。
- `RewardsForfeited` 的 `startTime` 必须取本次 `_updateGlobalReward()` 执行前的 `lastUpdateTime`，`endTime` 必须取本次的 `lastTimeRewardApplicable()`，`amount` 必须取实际从 `scheduledRewards` 移入 `unallocatedRewards` 的 `released = min((endTime - startTime) * rewardRate, scheduledRewards)`。
- 当 `endTime <= startTime` 或 `released == 0` 时不得发 `RewardsForfeited`。如果因为 `scheduledRewards` 上限导致 `amount < (endTime - startTime) * rewardRate`，事件消费者必须以 `amount` 为准，不能用时间差和 `rewardRate` 反推金额。
- 任何角色变更必须发事件。
- 任何 pause/unpause 必须发事件；`pause(reasonHash)` 必须发 OZ `Paused(operator)` 和 `PauseReason(operator, reasonHash)`，`unpause()` 必须发 OZ `Unpaused(operator)`。

## 安全不变量

| 编号 | 不变量 |
|---|---|
| I-1 | `stakingToken != rewardToken` |
| I-2 | `totalStaked == sum(balanceOf[user])`，允许测试中用 handler 聚合 |
| I-3 | `aggregateClaimableRewards == sum(rewards[user])`，允许测试中用 handler 聚合 |
| I-4 | 用户可领取总额不超过已注入并完成会计登记的奖励 |
| I-5 | `scheduledRewards + accruedRewardReserve + aggregateClaimableRewards + unallocatedRewards == accountedRewardBalance` |
| I-6 | `accountedRewardBalance <= rewardToken.balanceOf(address(this))` |
| I-7 | `sweepUnallocatedRewards` 不得减少任何用户本金或已结算奖励 |
| I-8 | 空池期间释放的奖励不得被后续第一个质押用户领取 |
| I-9 | `fundAndNotify` 的参数必须等于本次实际收到的 `rewardToken` 数量 |
| I-10 | `getReward` 零奖励 no-op 成功 |
| I-11 | 活跃周期内 `setRewardsDuration` 必须 revert |
| I-12 | Guardian 不能转移资金、不能改角色、不能改参数 |
| I-13 | `emergencyExit` 必须先更新奖励；forfeited reward 从用户已结算奖励转入 `unallocatedRewards`，不得减少 `accountedRewardBalance` |
| I-14 | `stakingToken.balanceOf(this) >= totalStaked`，只有超过 `totalStaked` 的 stakingToken 才能作为误转超额恢复 |
| I-15 | 任意 token 转账失败时，相关函数必须整体 revert，所有本合约状态回滚 |
| I-16 | 有质押时 `released` 必须完整进入 `accruedRewardReserve`，不得按单次 checkpoint 的临时可分配结果提前把任何差额转入 `unallocatedRewards` |
| I-17 | 合约不得存储或跨 checkpoint 结转全局 `rewardPerToken` 余数；`pendingUserDustScaled < 1e18` 始终成立，且不计入 `accountedRewardBalance` |
| I-18 | 逐用户 checkpoint 产生的 whole-token dust，以及无质押承接时 flush 的 whole-token 残余，必须从 `accruedRewardReserve` 转入 `unallocatedRewards` |

## 测试清单

权限与初始化：

- 构造函数拒绝零 `initialOwner`、零 token、零 `rewardManager`、相同 `stakingToken/rewardToken`。
- `guardian_ == address(0)` 时 guardian 函数不可用。
- owner 来自构造函数参数，而不是隐式部署者。
- `setRewardManager(address(0))` revert。
- `setGuardian(address(0))` 成功并禁用 guardian。
- `setSweepRecipientAllowed(recipient, allowed)` 只能由 owner 调用，零地址 revert，事件包含 recipient 和 allowed。
- 重复 `setSweepRecipientAllowed(recipient, currentValue)` 必须成功并再次发 `SweepRecipientUpdated`，状态保持不变。
- owner 可与 rewardManager/guardian 相同，但生产部署脚本应提示风险。
- `Ownable2Step` ownership 转移流程测试通过。
- 活跃奖励周期未结束时 owner 可以更换 `rewardManager`；旧 manager 立即失去调用权，新 manager 可以追加新奖励，已注入的 `rewardRate/periodFinish/scheduledRewards` 不被修改。
- 更换 `rewardManager` 不改变旧周期 leftover 的计算；周期中追加仍按 `received + leftover` 计算。

奖励会计：

- `stake`、`withdraw`、`getReward`、`exit`、`emergencyExit` 都先更新全局和用户奖励。
- `fundAndNotify` 先更新全局 `rewardPerTokenStored` 和 `lastUpdateTime`，再计算 `leftover`。
- 追加奖励时，`newScheduledRewards <= receiced + leftover` 是向下取整后的公式结果，不再作为单独偿付检查。
- `unreservedRewardBalance` 排除 `aggregateClaimableRewards`、`accruedRewardReserve`、`scheduledRewards` 和 `unallocatedRewards`。
- `rewardRate` 向下取整产生的 dust 进入 `unallocatedRewards`。
- 有质押时，全局 checkpoint 必须把完整 `released` 加入 `accruedRewardReserve`；不得保存跨 `totalStaked` 变化复用的全局余数，也不得按单次 checkpoint 的临时可分配结果提前把任何差额归入 `unallocatedRewards`。
- 必须覆盖多次小额 checkpoint 累加后用户获得 whole-token reward 的场景，证明 `accruedRewardReserve` 有足够资金支付累计后的 `earned()`。
- 必须覆盖 `totalStaked` 变化场景：某次 checkpoint 的 `released * 1e18` 不能整除当时 `totalStaked` 后，用户部分 withdraw 使 `totalStaked` 下降但仍大于 0，或新用户 stake 使 `totalStaked` 上升；后续 checkpoint 不得复用旧分母下的余数，用户奖励只能来自已存储的 `rewardPerTokenStored`、新的 `released * 1e18 / currentTotalStaked` 和个人 `rptDelta`。
- 逐用户 checkpoint 场景必须覆盖多个用户的 `sum(floor(balance_i * rptDelta_i / 1e18))` 小于累计已释放储备中可归属用户部分的情况；聚合后的 `userCheckpointDust` 必须从 `accruedRewardReserve` 转入 `unallocatedRewards`，并发 `UserCheckpointDust`。
- `pendingUserDustScaled` 每次用户 checkpoint 后必须 `< 1e18`，且不得进入 `accountedRewardBalance`。
- `aggregateClaimableRewards == sum(rewards[user])` 必须在 stake、withdraw、getReward、exit、emergencyExit、多用户交错 checkpoint 后始终成立。
- `newRewardRate == 0` 必须以 `RewardTooSmall()` revert。
- `amount > MAX_REWARDS_AMOUNT` 以 `RewardAmountTooLarge` revert。
- `newRewardRate > MAX_REWARDS_RATE` 以 `RewardRateTooLarge` revert。
- 极端大数导致 Solidity 0.8 arithmetic panic 时，测试必须明确 `expectRevert(stdError.arithmeticError)` 或对应 panic selector。
- 误转 token 只能进入 `unallocatedRewards`，不能被下一次奖励自动使用。
- 用户已结算未领取奖励存在时，`fundAndNotify` 不得把这部分余额计入新周期偿付。
- 已释放但未逐户结算的 `accruedRewardReserve` 存在时，`fundAndNotify` 不得把这部分余额计入新周期偿付。
- 多次 `stake` 必须先结算旧本金产生的奖励，再增加本金；第二次 stake 后的奖励按新本金继续计算。
- 部分 `withdraw` 必须先结算提现前本金产生的奖励，再减少本金；剩余本金继续参与后续奖励。
- `stake -> partial withdraw -> stake again -> getReward` 的累计奖励必须等于分段本金和分段时间计算结果，误差只允许整数 dust。
- `stake A -> stake B -> withdraw C -> withdraw remaining` 后，`totalStaked` 和 `balanceOf[user]` 必须逐步匹配每次本金变化。

奖励周期矩阵：

| 场景 | 预期 |
|---|---|
| 周期未开始时首次 `fundAndNotify(A)` | `rewardRate = floor(A / duration)`，`periodFinish = now + duration`，dust 进入 `unallocatedRewards` |
| 周期中追加 `fundAndNotify(B)` | 先 checkpoint；`leftover = remaining * oldRewardRate`；新周期金额只来自 `B + leftover` |
| 周期刚好结束时追加 | `leftover == 0`，新周期只使用本次 `received` |
| 周期结束很久后追加 | 历史余额不参与排程，除非通过本次 `fundAndNotify` 实际转入 |
| 周期中追加但本次实际转入少于参数 | `InvalidReceivedAmount(expected, received)` |
| 周期中追加且存在用户未领取奖励 | 新周期偿付不得占用 `aggregateClaimableRewards` |
| 周期中追加且存在误转余额 | 误转余额不参与 `received + leftover` |
| 多轮连续追加 | 每轮总可领取奖励之和不得超过各轮 `newScheduledRewards` 之和，误差只允许整数除法 dust |

空池和未分配奖励：

- 奖励周期开始后长期无质押，后续第一个用户不能领取空池期间奖励。
- 空池释放金额进入 `unallocatedRewards` 并发出 `RewardsForfeited`。
- 空池前半段无质押、后半段有质押时，用户只能领取后半段按其质押时间和份额产生的奖励。
- 空池跨完整 reward period 后再质押，`earned(firstUser) == 0`，直到下一次有效奖励释放。
- `sweepUnallocatedRewards` 只能由 owner 调用，只能转出 `unallocatedRewards`。
- 空池奖励周期进行中且尚未 checkpoint 时，`storedUnallocatedRewards()` 只返回存储值，`sweepableUnallocatedRewards()` 必须包含 pending empty-pool forfeited reward。
- 有质押且奖励周期进行中但尚未 checkpoint 时，`sweepableUnallocatedRewards() == storedUnallocatedRewards()`；pending released 必须进入 `accruedRewardReserve`，不能作为可 sweep 的全局舍入残余。
- `sweepUnallocatedRewards(to, amount)` 在 amount 等于调用前 `sweepableUnallocatedRewards()` 时应成功；执行后 pending unallocated reward 已进入事件和状态会计。
- `sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20` 的接收地址必须在 `sweepRecipientAllowed` 中，否则 `InvalidSweepRecipient` revert。
- sweep 转账本身不改变用户 `rewards[user]`、`aggregateClaimableRewards` 或 checkpoint 后的 `scheduledRewards`；但调用开始时的强制 checkpoint 可能先按时间释放规则减少 `scheduledRewards`。

用户边界：

- `getReward` 零奖励 no-op，不发 `RewardPaid`。
- 无本金有奖励时 `exit()` 领取奖励。
- 有本金无奖励时 `exit()` 提款成功。
- 本金和奖励都为 0 时 `exit()` no-op 成功。
- `withdraw(0)` revert。
- `exit()` 必须通过 internal `_withdraw/_getReward` helper 实现；测试应覆盖 `exit()` 不会因为嵌套 `nonReentrant` 自己 revert。
- `emergencyExit` 必须先更新奖励，再清零 `rewards[user]`；事件 `forfeitedReward` 等于更新后的 `rewards[user]`。
- `emergencyExit` 后用户本金为 0、奖励为 0，`unallocatedRewards` 增加 forfeitedReward，`accountedRewardBalance` 不减少。
- 本金和奖励都为 0 时 `emergencyExit()` no-op 成功，并必须发 `EmergencyExit(user, 0, 0)`。

误转资产：

- 误转 `stakingToken` 后，只有 `balance - totalStaked` 的超额部分可 recover；recover 后 `stakingToken.balanceOf(this) == totalStaked + remainingExcess`。
- 误转 `rewardToken` 后，不能直接 recover；必须先 `syncUnallocatedRewards`，再按 `sweepUnallocatedRewards` 处理。
- 误转非核心 ERC20 后，owner 可 `recoverERC20`，非 owner revert，`stakingToken/rewardToken` 作为 token 参数时 revert。

异常 token 和转账失败：

- `FeeOnTransferMock` 用作 rewardToken 时，`fundAndNotify(amount)` 因实际到账不足以 `InvalidReceivedAmount` revert，`accountedRewardBalance/rewardRate/periodFinish` 不变。
- `FeeOnTransferMock` 用作 stakingToken 时，`stake(amount)` 必须拒绝实际到账不等于 amount，或通过 balance-delta 检查 revert，`totalStaked/balanceOf` 不变。
- `FalseReturnERC20Mock` 或 `BlacklistMock` 导致 `stake/withdraw/getReward/fundAndNotify/sweepUnallocatedRewards/recoverExcessStakingToken/recoverERC20` 转账失败时，函数整体 revert，所有状态保持调用前值。
- `ERC777HookMock` 重入 `stake/withdraw/getReward/exit/emergencyExit/fundAndNotify/sweepUnallocatedRewards/recoverExcessStakingToken/recoverERC20` 必须因 `ReentrancyGuard` revert。
- `recoverERC20` 必须使用恶意 hook token 单独测试，因为它接收任意非核心 token 地址，不受生产核心 token 类型限制。
- `PausableTokenMock` 暂停 token 转账后，相关操作必须 revert 且状态回滚。

暂停与恢复：

- guardian 和 owner 都可以调用 `pause(reasonHash)`。
- 非 owner / 非 guardian 调用 `pause(reasonHash)` 必须 revert `OnlyGuardianOrOwner()`。
- 只有 owner 可以调用 `unpause()`；guardian 调用 `unpause()` 必须以 OZ owner error revert。
- 已 paused 时再次 `pause(reasonHash)` 必须按 OZ `Pausable` 标准错误 revert。
- 未 paused 时调用 `unpause()` 必须按 OZ `Pausable` 标准错误 revert。
- 当权限错误和 paused 状态错误同时成立时，必须先鉴权、后检查状态：非 owner/guardian 在已 paused 时调用 `pause(reasonHash)` 断言 `OnlyGuardianOrOwner()`；非 owner 在未 paused 时调用 `unpause()` 断言 OZ owner error。
- paused 后 `stake` 必须 revert。
- paused 后 `fundAndNotify` 必须 revert。
- paused 后 `withdraw/getReward/exit/emergencyExit` 必须仍可执行。
- `pause(reasonHash)` 必须发 OZ `Paused` 和 `PauseReason`；`unpause()` 必须发 OZ `Unpaused`。
- 暂停测试必须使用 OZ `paused()` view，不再引入模块级暂停接口或模块常量。

奖励周期：

- 活跃周期内 `setRewardsDuration` revert。
- 周期结束后 owner 可设置 `[MIN_REWARDS_DURATION, MAX_REWARDS_DURATION]` 内的新 duration。
- `0`、过小、过大和非 owner 调用都 revert。
- 修改成功发 `RewardsDurationUpdated`，只影响下一次 `fundAndNotify`。
- `setRewardsDuration` 在 paused 状态下仍可由 owner 调用，但必须满足非活跃周期和范围限制。

专项测试：

- `stakingToken == rewardToken` 构造必须以 `SameToken()` revert。
- `stakingToken != rewardToken` 正常用户路径下，stakingToken 余额变化只等于用户本金净流入；若存在误转 stakingToken，额外余额只能体现在 `stakingToken.balanceOf(this) - totalStaked`，不得影响任何用户本金。
- 所有 custom error 均使用 selector 断言；OZ owner 错误使用 OZ 标准 selector。
- 所有事件参数必须断言，包括 indexed 地址、金额、`periodFinish`、`remainingUnallocated`、`RewardPerTokenDust.amount` 和 `UserCheckpointDust.amount`。

## 验收标准

核心函数验收：

| 函数 | 成功断言 | 失败断言 |
|---|---|---|
| `stake(amount)` | `totalStaked += amount`，`balanceOf[user] += amount`，合约 stakingToken 增加 amount，发 `Staked`；前置 checkpoint 产生空池 forfeited 或用户 dust 时，分别断言 `RewardsForfeited`、`UserCheckpointDust` | `amount == 0` 用 `ZeroAmount` revert；paused 时用 OZ `EnforcedPause` revert |
| `withdraw(amount)` | `totalStaked -= amount`，`balanceOf[user] -= amount`，用户 stakingToken 增加 amount，发 `Withdrawn`；用户 dust 发 `UserCheckpointDust`；提现后 `totalStaked == 0` 且 flush 残余时发 `RewardPerTokenDust` | `amount == 0` 用 `ZeroAmount` revert；余额不足用 `InsufficientStake` revert |
| `getReward()` | reward > 0 时用户 rewardToken 增加 reward，`aggregateClaimableRewards` 和 `accountedRewardBalance` 同步减少，发 `RewardPaid`；空池 forfeited 和用户 dust 分别发 `RewardsForfeited`、`UserCheckpointDust` | reward == 0 时成功 no-op，不发 `RewardPaid` |
| `exit()` | 有本金时全部提款；有奖励时领奖；二者为 0 时成功 no-op；内部 withdraw/claim 路径产生的 `RewardsForfeited`、`UserCheckpointDust`、`RewardPerTokenDust` 必须按事件规则断言 | 不得因零本金或零奖励 revert |
| `emergencyExit()` | 先更新奖励；本金全部返还；`rewards[user] = 0`；`unallocatedRewards += forfeitedReward`；总是发 `EmergencyExit`，即使本金和奖励都为 0；`RewardsForfeited`、用户 dust 和 flush 残余事件必须按规则断言 | stakingToken 转账失败时整体 revert，所有状态回滚 |
| `fundAndNotify(amount)` | 实际收到等于 amount；`rewardRate = floor((received + leftover) / duration)`；`periodFinish = now + duration`；发 `RewardAdded`；前置 checkpoint 产生空池 forfeited 时发 `RewardsForfeited`；有质押的前置 checkpoint 不得发 `RewardPerTokenDust` | 非 manager、零 amount、amount 超上限、实际收到不等、`newRewardRate == 0` 用 `RewardTooSmall`、rate 超上限、偿付不足、paused、算术 overflow 均按指定错误或 panic revert |
| `setRewardsDuration(newDuration)` | 非活跃期内更新 duration，且 `MIN_REWARDS_DURATION <= newDuration <= MAX_REWARDS_DURATION`，发 `RewardsDurationUpdated` | 活跃期、0、小于 `MIN_REWARDS_DURATION`、大于 `MAX_REWARDS_DURATION`、非 owner 均 revert |
| `setRewardManager(newManager)` | `rewardManager` 更新为 newManager，发 `RewardManagerUpdated(old,new)`，不改变当前奖励周期 | 非 owner 用 OZ owner error；零地址用 `ZeroAddress` |
| `setGuardian(newGuardian)` | `guardian` 更新为 newGuardian，零地址表示禁用，发 `GuardianUpdated(old,new)` | 非 owner 用 OZ owner error |
| `setSweepRecipientAllowed(recipient, allowed)` | `sweepRecipientAllowed[recipient] == allowed`，发 `SweepRecipientUpdated`；重复设置当前值也成功并发事件 | 非 owner用 OZ owner error；零地址用 `ZeroAddress` |
| `pause(reasonHash)` | 全局 `paused() == true`；发 OZ `Paused` 和 `PauseReason` | 非 owner/guardian 用 `OnlyGuardianOrOwner`；已 paused 时授权 caller 用 OZ `EnforcedPause`；非 owner/guardian 且已 paused 时优先 `OnlyGuardianOrOwner` |
| `unpause()` | 全局 `paused() == false`；发 OZ `Unpaused` | 非 owner 用 OZ owner error；未 paused 时 owner 用 OZ `ExpectedPause`；非 owner 且未 paused 时优先 OZ owner error |
| `syncUnallocatedRewards()` | 将 `rewardToken.balanceOf(this) - accountedRewardBalance` 加入 `unallocatedRewards` 和 `accountedRewardBalance`，发 `UnallocatedRewardsSynced` | 无未入账余额时 `NoUnaccountedRewards` revert |
| `sweepUnallocatedRewards(to, amount)` | 先 checkpoint；允许 amount 最大为调用前 `sweepableUnallocatedRewards()`；只减少 checkpoint 后的 `unallocatedRewards` 和 `accountedRewardBalance`，用户本金和奖励不变，发 `UnallocatedRewardsSwept`；前置 checkpoint 产生空池 forfeited 时发 `RewardsForfeited`；有质押的前置 checkpoint 不得发 `RewardPerTokenDust` | 非 owner、to 不允许、amount 为 0、amount 超过 checkpoint 后 `unallocatedRewards` 均 revert |
| `recoverExcessStakingToken(to, amount)` | 只转出 `stakingToken.balanceOf(this) - totalStaked` 范围内的超额 stakingToken，发 `ExcessStakingTokenRecovered` | 非 owner、零地址、recipient 未允许、amount 为 0、amount 超额均 revert |
| `recoverERC20(token, to, amount)` | 只能恢复非 staking/reward token，发 `ERC20Recovered` | 非 owner、token 是核心 token、to 为零地址、to 未允许、amount 为 0、转账失败均 revert |

奖励会计量化标准：

- 任意测试路径中，用户累计领取奖励总额 `<= sum(all newScheduledRewards)`。
- 奖励误差只允许来自整数除法向下取整；有质押期间的全局舍入残余必须保守留在 `accruedRewardReserve`，不能立即作为 whole-token dust sweep，也不能跨 `totalStaked` 变化作为余数结转。
- 逐用户 checkpoint 的 scaled dust 必须通过 `pendingUserDustScaled` 聚合；每形成 1 个 rewardToken 最小单位，就从 `accruedRewardReserve` 转入 `unallocatedRewards`。
- 对单用户、单周期、无中途操作场景，领取值应等于 `floor(amount / duration) * elapsed`，误差不超过 dust。
- 对多用户场景，每个用户奖励按 `stakeWeight * elapsed` 分摊，所有用户累计领取加未领取加未分配不得超过 `accountedRewardBalance`。
- 空池期间释放奖励的用户可领取量必须为 0，对应金额必须进入 `unallocatedRewards`。
- `aggregateClaimableRewards + accruedRewardReserve + scheduledRewards + unallocatedRewards == accountedRewardBalance` 始终成立。
- `accountedRewardBalance + unreservedRewardBalance == rewardToken.balanceOf(this)` 始终成立。
- `stakingToken.balanceOf(this) >= totalStaked` 始终成立；因为 `stakingToken != rewardToken`，奖励资金不得影响本金断言。
- 没有误转 stakingToken 的普通路径中，`stakingToken.balanceOf(this) == totalStaked` 应成立。
- 如果存在误转 stakingToken，`stakingToken.balanceOf(this) - totalStaked` 才是可恢复上限；recover 前允许余额大于 `totalStaked`，recover 后应满足 `stakingToken.balanceOf(this) == totalStaked + remainingExcess`。
- 任意外部 token 转账失败的测试中，所有核心状态变量必须等于调用前快照。
- `exit()` 成功路径不得触发嵌套 `nonReentrant`；`emergencyExit()` 必须和 `withdraw()` 同等级受重入保护。
- `sweepUnallocatedRewards`、`recoverExcessStakingToken`、`recoverERC20` 必须受 `nonReentrant` 保护；`recoverERC20` 必须覆盖恶意 hook token 重入测试。
- 暂停验收必须证明全局 `paused()` 只限制新增风险入口：`stake` 和 `fundAndNotify` paused 时 revert，`withdraw/getReward/exit/emergencyExit` paused 时仍可执行。

部署验收：

- 构造参数和所有初始 view 返回值与部署报告一致。
- 部署后未开启奖励周期时，`earned(anyUser) == 0`、`rewardPerToken() == 0`、`lastTimeRewardApplicable() == 0`、`paused() == false`。
- owner 已完成 `Ownable2Step` 交接，部署者 EOA 不再拥有 owner、rewardManager、guardian。
- fork、testnet 或 dry-run 基础连通性检查 `fundAndNotify -> stake -> warp -> getReward -> exit` 通过，资金差额只允许整数 dust；生产部署后除非正式开启首轮奖励，不得执行该流程。

## 开发命令

```bash
forge build
forge test
forge test -vvv
forge coverage
```

## 部署检查

部署前：

- `stakingToken` 和 `rewardToken` 已确认非特殊 ERC20；v1 不支持 rebasing、fee-on-transfer、ERC777 callback token。
- 部署脚本或 fork 检查必须验证最小验证额度的 `transfer/transferFrom` balance delta 等于 amount；如果实际到账不同，禁止部署。
- 对支持 blacklist、pause、tax、rebase、hook 的 token，即使当前配置看起来关闭，也不得作为生产 `stakingToken` 或 `rewardToken`。
- `stakingToken != rewardToken`。
- `initialOwner`、`rewardManager`、`guardian` 地址已在部署配置中显式填写。
- 生产环境 `initialOwner` 应为多签或 Timelock；如果临时使用部署者 EOA，必须在同一部署批次中完成 ownership 交接。
- `rewardManager` 非零，并持有或可调拨足够 rewardToken。
- `guardian` 生产环境非零，且不是普通热钱包。
- 初始 `rewardsDuration` 在允许范围内。

部署后校验：

- 查询所有构造参数 view，逐项匹配部署配置。
- 查询初始状态：`periodFinish == 0`、`rewardRate == 0`、`totalStaked == 0`、`pendingUserDustScaled() == 0`、`accountedRewardBalance == 0`、`paused() == false`。
- 如果发生 ownership 交接，确认 `owner() == finalOwner` 且部署者 EOA 不再是 owner。
- 确认部署者 EOA 不是 `rewardManager`，也不是 `guardian`，除非部署报告明确说明这是临时测试环境。
- 确认 Treasury、rewardManager 和 recovery recipient 已按部署配置调用 `setSweepRecipientAllowed(..., true)`；如果某个地址不承担资金接收职责，部署报告必须明确记录跳过原因。
- 查询 `sweepRecipientAllowed(treasury)`、`sweepRecipientAllowed(rewardManager)`、`sweepRecipientAllowed(recoveryRecipient)`，必须与部署配置一致。
- 确认 `rewardManager` 已对 staking 合约完成 rewardToken allowance，或已经准备好通过资金管理合约调用。
- 执行基础连通性 fork/testnet/dry-run 测试，覆盖 `fundAndNotify`、`stake`、`getReward`、`exit`；生产部署后不得把 `fundAndNotify` 当作无副作用 ping。
- 执行一次 `pause(reasonHash)` 和 `unpause()` 测试暂停权限；生产主网可用 fork 或 testnet 演练，不建议主网随意暂停。

角色安全交接：

1. 部署者完成合约部署和参数校验。
2. 部署者调用 `transferOwnership(finalOwner)`。
3. `finalOwner` 调用 `acceptOwnership()`。
4. owner 调用 `setRewardManager(finalRewardManager)`，如果构造时已正确设置则跳过。
5. owner 调用 `setGuardian(finalGuardian)`，如果构造时已正确设置则跳过。
6. 部署报告记录 `owner`、`rewardManager`、`guardian` 三个最终地址。
7. 验证部署者 EOA 对合约无 owner 权限、无 rewardManager 权限、无 guardian 权限。
8. 验证 Keeper 或自动化地址没有 owner、rewardManager、guardian 中任何一个权限。

## 许可证

MIT
