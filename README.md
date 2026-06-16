# Pro Staking

> 一个单池 ERC20 StakingRewards 合约项目：用户质押 `stakingToken`，按时间线性领取 `rewardToken`。
> 本项目聚焦 staking 奖励会计、权限控制、暂停恢复、资金偿付和边界测试，不包含 AMM、多池 Gauge、ve 投票、手续费分红、回购或收益聚合。

## 项目定位

Pro Staking 是一个 contracts-only 的 Solidity / Foundry 项目，用来展示一个可上线标准的单池质押奖励模块。

核心目标：

- 用户可以 `stake/deposit`、`withdraw`、`getReward/claimReward`、`exit`。
- 奖励由授权 `rewardManager` 注入，并在固定 `rewardsDuration` 内线性释放。
- 合约清楚区分用户本金、已结算未领取奖励、未来排程奖励、放弃奖励和误转资金。
- 所有高权限变更、暂停恢复、奖励注入和资金处理都有明确事件，方便前端、监控和审计追踪。

明确不做：

- 不做多池权重分配、GaugeController、ve 投票、Boost。
- 不做 AMM、Router、LP 手续费分红、回购、收益聚合。
- 不做自动复投、策略金库、跨池排放调度。

## 合约范围

主合约建议命名为 `ProStaking` 或 `StakingRewards`。

| 合约 | 作用 |
|---|---|
| `ProStaking` | 单池 staking、奖励累计、领取、暂停、权限和资金会计 |
| `MockERC20` | 测试用 staking/reward token |

## 依赖选择

本项目使用 OpenZeppelin 合约库：

| 依赖 | 用途 |
|---|---|
| `Ownable2Step` | owner 权限和两步转移 ownership |
| `ReentrancyGuard` | 防止 `stake/withdraw/getReward/exit/fundAndNotify` 重入 |
| `Pausable` | 暂停新增质押和新增奖励注入 |
| `SafeERC20` | 安全处理 ERC20 转账 |

权限模型不使用 `AccessControl`。原因是本项目只有三个清晰角色：`owner`、`rewardManager`、`guardian`。使用 `Ownable2Step` 加显式地址变量更容易审计，也避免 role admin 层级过度复杂。

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

示例：

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
MIN_REWARDS_DURATION = 1 days
MAX_REWARDS_DURATION = 30 days
default rewardsDuration = 7 days
```

部署脚本必须显式传入 `initialOwner`，生产环境中 `initialOwner` 应为 Governance Timelock 或项目多签，不应让部署者 EOA 长期持有 owner。

### 部署后初始化流程

部署后不需要额外 initializer，构造函数必须一次性写入所有不可变依赖和初始角色。部署脚本仍必须执行以下校验和交接流程：

1. 部署 `ProStaking(initialOwner, stakingToken, rewardToken, rewardManager, guardian, rewardsDuration)`。
2. 校验 `owner() == initialOwner`。
3. 校验 `stakingToken()`、`rewardToken()`、`rewardManager()`、`guardian()`、`rewardsDuration()` 与部署参数一致。
4. 校验 `stakingToken() != rewardToken()`。
5. 校验初始奖励状态为未开启：`periodFinish == 0`、`rewardRate == 0`、`lastUpdateTime == 0`、`rewardPerTokenStored == 0`。
6. 校验资金会计为空：`totalSupply == 0`、`scheduledRewards == 0`、`accruedRewardReserve == 0`、`aggregateClaimableRewards == 0`、`unallocatedRewards == 0`、`accountedRewardBalance == 0`。
7. 如果 `initialOwner` 临时设置为部署者 EOA，部署交易后必须立即调用 `transferOwnership(multisigOrTimelock)`，并由目标地址 `acceptOwnership()`。
8. 部署者 EOA 完成交接后不得保留 owner、rewardManager 或 guardian 权限。
9. `rewardManager` 给 staking 合约授权一笔小额 `rewardToken`，执行一次小额 `fundAndNotify` 验证奖励注入路径。
10. 测试用户执行小额 `stake -> getReward -> exit`，确认本金和奖励路径正常。

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
| `totalSupply()` | `0` |
| `balanceOf(user)` | `0` |
| `earned(user)` | `0` |
| `rewards(user)` | `0` |
| `userRewardPerTokenPaid(user)` | `0` |
| `scheduledRewards()` | `0` |
| `accruedRewardReserve()` | `0` |
| `aggregateClaimableRewards()` | `0` |
| `unallocatedRewards()` | `0` |
| `accountedRewardBalance()` | `0` |
| `pausedModule(STAKE)` | `false` |
| `pausedModule(REWARD_FUNDING)` | `false` |

`lastTimeRewardApplicable()` 在 `periodFinish == 0` 时必须返回 `0`，不能返回当前时间，否则未开启周期时会污染奖励计算。

## 接口规格

### 写函数

| 函数 | 权限 | 前置条件 | 状态变化 | 事件 | 失败错误 |
|---|---|---|---|---|---|
| `stake(uint256 amount)` / `deposit(uint256 amount)` | anyone | `amount > 0`，`STAKE` 未暂停，实际收到 stakingToken 等于 amount | 更新全局和用户奖励；增加 `totalSupply`、`balanceOf[msg.sender]`；转入 stakingToken | `Staked` | `ZeroAmount`、`ModuleIsPaused`、`InvalidReceivedAmount` |
| `withdraw(uint256 amount)` | staker | `amount > 0`，`balanceOf[msg.sender] >= amount` | 更新奖励；减少本金；转出 stakingToken | `Withdrawn` | `ZeroAmount`、`InsufficientStake` |
| `getReward()` / `claimReward()` | anyone for self | 无 | 更新奖励；若 reward > 0，减少 `rewards[user]` 和 `aggregateClaimableRewards`，转出 rewardToken | `RewardPaid` 仅在 amount > 0 时发出 | 无奖励时不失败 |
| `exit()` | staker or no-op user | 无 | 如果有本金则 withdraw 全部；随后 claim | `Withdrawn`、可选 `RewardPaid` | 本金和奖励都为 0 时不失败 |
| `emergencyExit()` | staker or no-op user | 无，且不受 pause 影响 | 必须先更新用户奖励；转出全部本金；清零 `rewards[user]`；将 forfeited reward 计入 `unallocatedRewards` | `EmergencyExit`，若 forfeited > 0 还发 `RewardsForfeited` 或在事件中记录 | 本金和奖励都为 0 时不失败 |
| `fundAndNotify(uint256 amount)` | `rewardManager` | `amount > 0`，`REWARD_FUNDING` 未暂停，实际收到等于 amount，`newRewardRate > 0`，偿付检查通过 | 转入 rewardToken；更新排程奖励、rate、finish、资金会计 | `RewardAdded`，可能 `RewardsForfeited` | `OnlyRewardManager`、`ZeroAmount`、`InvalidReceivedAmount`、`RewardTooSmall`、`InsufficientRewardBalance`、`ModuleIsPaused` |
| `setRewardsDuration(uint256 newDuration)` | owner | 非活跃周期，范围 `[1 days, 30 days]` | 更新 `rewardsDuration` | `RewardsDurationUpdated` | OZ `OwnableUnauthorizedAccount`、`RewardPeriodActive`、`InvalidRewardsDuration` |
| `setRewardManager(address newManager)` | owner | `newManager != address(0)` | 更新 `rewardManager`；不改变已注入奖励周期 | `RewardManagerUpdated` | OZ `OwnableUnauthorizedAccount`、`ZeroAddress` |
| `setGuardian(address newGuardian)` | owner | 允许零地址 | 更新 `guardian` | `GuardianUpdated` | OZ `OwnableUnauthorizedAccount` |
| `pauseModule(bytes32 module, bytes32 reasonHash)` | owner or guardian | module 可暂停；guardian 只能暂停允许模块 | 标记模块暂停，记录暂停操作者类型 | `ModulePaused` | `OnlyGuardianOrOwner`、`InvalidModule`、`GuardianNotAllowed` |
| `unpauseModule(bytes32 module)` | owner or guardian | owner 可恢复；guardian 只能恢复自己暂停且未 owner lockdown 的模块 | 清除模块暂停 | `ModuleUnpaused` | `OnlyGuardianOrOwner`、`GuardianCannotUnpause` |
| `syncUnallocatedRewards()` | anyone | `rewardToken.balanceOf(this) > accountedRewardBalance` | 将未入账余额计入 `unallocatedRewards` 和 `accountedRewardBalance` | `UnallocatedRewardsSynced` | `NoUnaccountedRewards` |
| `sweepUnallocatedRewards(address to, uint256 amount)` | owner | `to` 已允许，`amount > 0`，`amount <= unallocatedRewards` | 更新全局奖励；减少 `unallocatedRewards` 和 `accountedRewardBalance`；转出 rewardToken | `UnallocatedRewardsSwept` | OZ `OwnableUnauthorizedAccount`、`ZeroAmount`、`InvalidSweepRecipient`、`InsufficientUnallocatedRewards` |
| `recoverExcessStakingToken(address to, uint256 amount)` | owner | `amount <= stakingToken.balanceOf(this) - totalSupply` | 转出误转的超额 stakingToken，不改变用户本金会计 | `ExcessStakingTokenRecovered` | OZ `OwnableUnauthorizedAccount`、`ZeroAmount`、`InvalidSweepRecipient`、`InsufficientExcessStakingToken` |
| `recoverERC20(address token, address to, uint256 amount)` | owner | `token != stakingToken && token != rewardToken`，`to` 已允许，`amount > 0` | 转出非核心误转 token | `ERC20Recovered` | OZ `OwnableUnauthorizedAccount`、`CannotRecoverCoreToken`、`ZeroAmount`、`InvalidSweepRecipient` |

`deposit` 和 `claimReward` 可以作为别名存在，但必须与 `stake`、`getReward` 共享同一套会计逻辑和事件语义，不能出现两套实现分叉。

### View 函数

| 函数 | 返回值语义 |
|---|---|
| `lastTimeRewardApplicable()` | `periodFinish == 0 ? 0 : min(block.timestamp, periodFinish)` |
| `rewardPerToken()` | 当前全局累计每单位质押奖励，`totalSupply == 0` 时返回 `rewardPerTokenStored` |
| `earned(address user)` | 用户当前可领取奖励，包含已结算 `rewards[user]` 和实时新增部分 |
| `recoverableUnallocatedRewards()` | 当前可 sweep 的未分配奖励，必须 `<= unallocatedRewards` |
| `unreservedRewardBalance()` | 当前尚未进入内部会计分类的 rewardToken 余额；正常情况下应为 0，误转后可通过 `syncUnallocatedRewards` 归类 |
| `isRewardPeriodActive()` | `block.timestamp < periodFinish` |
| `pausedModule(bytes32 module)` | 指定模块是否暂停 |

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
error InvalidReceivedAmount(uint256 expected, uint256 received);
error InsufficientRewardBalance(uint256 required, uint256 available);
error InsufficientStake(uint256 requested, uint256 available);
error ModuleIsPaused(bytes32 module);
error InvalidModule(bytes32 module);
error GuardianNotAllowed(bytes32 module);
error GuardianCannotUnpause(bytes32 module);
error InvalidSweepRecipient(address to);
error CannotRecoverCoreToken(address token);
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
| `guardian` | 紧急 `pause`，受限 `unpause` | 快速响应事故，不拥有资金权限 |
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
| `setRewardManager(newRewardManager)` | owner | 不允许零地址 | `RewardManagerUpdated(oldManager, newManager)` |
| `setGuardian(newGuardian)` | owner | 允许零地址，用于禁用 guardian | `GuardianUpdated(oldGuardian, newGuardian)` |

`setRewardManager(address(0))` 不允许。若需要停止新增奖励，应暂停 `fundAndNotify` 或将 `rewardManager` 切换到治理控制地址。

`setGuardian(address(0))` 允许，但只能由 owner 执行。设置后 guardian 相关函数全部不可用。

当前奖励周期未结束时允许更换 `rewardManager`，但只影响未来调用权，不改变已经注入的奖励：

- 旧 `rewardManager` 已经通过 `fundAndNotify` 注入的 `scheduledRewards`、`rewardRate`、`periodFinish` 不变。
- 新 `rewardManager` 从事件生效后才可以调用下一次 `fundAndNotify`。
- 旧 `rewardManager` 事件生效后立即失去调用权，不能追加、撤回或修改已注入奖励。
- 更换 `rewardManager` 不会改变 `leftover` 归属。周期中追加时，`leftover` 仍来自合约内已排程奖励，与新旧 manager 身份无关。
- 若需要停止旧 manager 继续注入，应先 `setRewardManager(newManager)` 或暂停 `REWARD_FUNDING`，但不得影响用户 `withdraw/getReward/exit/emergencyExit`。

## Guardian 暂停与恢复设计

Guardian 被允许调用受限 `unpause` 是有意设计，不是权限泄漏。原因是紧急多签可能误暂停，或者风险解除后需要快速恢复用户正常交互；如果只能等待 Timelock，用户体验和资金效率会受到不必要影响。

约束条件：

- Guardian 可以暂停新增风险入口：`stake/deposit` 和 `fundAndNotify`。
- Guardian 不得暂停 `withdraw`、`getReward/claimReward`、`exit`，用户必须始终能退出和领取已结算奖励。
- Guardian 的 `unpause` 只能恢复由 guardian 自己暂停的模块。
- 如果 owner 执行了 owner-level pause 或设置了 `ownerLockdown = true`，guardian 不能 unpause，必须由 owner 恢复。
- Guardian 不能修改 `rewardManager`、`rewardsDuration`、owner、token 地址或任何资金接收地址。
- Guardian 不能调用 `sweepUnallocatedRewards` 或任何资金提取函数。
- 每次 pause/unpause 必须包含事件，事件中记录 `operator`、`module`、`reasonHash` 或等价字段。

推荐暂停模块：

| 模块 | guardian 可暂停 | guardian 可恢复 | 用户退出是否受影响 |
|---|---:|---:|---:|
| `STAKE` | yes | yes，仅限 guardian 自己暂停 | no |
| `REWARD_FUNDING` | yes | yes，仅限 guardian 自己暂停 | no |
| `WITHDRAW` | no | no | no |
| `CLAIM` | no | no | no |

Paused 状态下管理员操作：

- `STAKE` 暂停时，用户 `stake/deposit` 必须 revert，但 `withdraw/getReward/exit/earned` 不受影响。
- `REWARD_FUNDING` 暂停时，`fundAndNotify` 必须 revert，但 `syncUnallocatedRewards` 和 view 函数不受影响。
- paused 状态下 owner 仍可以执行安全修复类管理操作：`setGuardian`、`setRewardManager`、`setRewardsDuration`、`sweepUnallocatedRewards`、`unpauseModule`。
- paused 状态下 owner 不能绕过活跃周期限制修改 `rewardsDuration`，也不能 sweep 超过 `unallocatedRewards` 的资金。
- paused 状态下 guardian 只能执行允许模块的 `unpauseModule`，不能执行资金处理或参数变更。
- 暂停不应改变奖励公式。只要时间流逝，活跃周期内的奖励仍按规则释放；如果 `totalSupply == 0`，对应奖励仍进入 `unallocatedRewards`。

## 核心状态变量

| 变量 | 含义 |
|---|---|
| `stakingToken` | 用户质押资产，immutable |
| `rewardToken` | 奖励资产，immutable |
| `rewardManager` | 可注入奖励的地址 |
| `guardian` | 可紧急暂停/受限恢复的地址 |
| `rewardsDuration` | 奖励释放周期 |
| `periodFinish` | 当前奖励周期结束时间 |
| `rewardRate` | 每秒释放奖励数量 |
| `lastUpdateTime` | 上次全局奖励更新时间 |
| `rewardPerTokenStored` | 全局累计每单位质押奖励 |
| `totalSupply` | 当前总质押本金 |
| `balanceOf[user]` | 用户质押本金 |
| `userRewardPerTokenPaid[user]` | 用户已结算到的全局游标 |
| `rewards[user]` | 用户已结算但未领取奖励 |
| `accruedRewardReserve` | 已释放到全局 `rewardPerToken`、但尚未被用户逐个 checkpoint 到 `rewards[user]` 的奖励储备 |
| `aggregateClaimableRewards` | 所有用户已结算未领取奖励总额 |
| `scheduledRewards` | 当前和未来仍按 `rewardRate` 释放的奖励 |
| `unallocatedRewards` | 误转、空池放弃、舍入 dust 等未分配奖励 |
| `accountedRewardBalance` | 已进入合约奖励会计的 rewardToken 总额 |

`rewardToken.balanceOf(address(this))` 不能直接等于可发奖励，因为它可能包含用户已结算未领取奖励、未来排程奖励、未分配奖励和误转资金。

## 内部奖励资金会计

本项目当前范围不实现独立 `RewardVault` 合约，但主合约必须实现等价的内部奖励资金账本。所有 rewardToken 余额都必须落入以下四类之一：

| 类别 | 状态变量 | 是否可由用户领取 | 是否可 sweep | 说明 |
|---|---|---:|---:|---|
| 已结算未领取奖励 | `aggregateClaimableRewards` 和 `rewards[user]` | yes | no | 用户已经 earned 并 checkpoint 到个人账上 |
| 已释放未逐户结算奖励 | `accruedRewardReserve` | 用户 checkpoint 后可领取 | no | 已进入全局 `rewardPerToken`，但尚未进入用户 `rewards[user]` |
| 未来排程奖励 | `scheduledRewards` | 未来按时间释放 | no | 当前 reward period 剩余可释放奖励 |
| 未分配奖励 | `unallocatedRewards` | no | yes，仅 owner | forfeited、rounding dust、donation、误转 |
| 未入账余额 | `rewardToken.balanceOf(this) - accountedRewardBalance` | no | no，需先 sync | 只能通过 `syncUnallocatedRewards` 进入 `unallocatedRewards` |

核心等式：

```text
accountedRewardBalance
  = aggregateClaimableRewards
  + accruedRewardReserve
  + scheduledRewards
  + unallocatedRewards
```

`accruedRewardReserve` 是已经按时间释放、但尚未被用户逐个 checkpoint 到 `rewards[user]` 的奖励。用户执行 `stake/withdraw/getReward/exit` 时，属于该用户的新增 earned 会从 `accruedRewardReserve` 转入 `aggregateClaimableRewards` 和 `rewards[user]`。

资金流规则：

- `fundAndNotify` 收到 rewardToken 后增加 `accountedRewardBalance`。
- 开启或追加周期时，`scheduledRewards` 设置为新周期 `newRewardRate * rewardsDuration`。
- 时间流逝且有用户质押时，奖励从 `scheduledRewards` 释放到全局 `rewardPerToken`，并先进入 `accruedRewardReserve`；用户交互时再从 `accruedRewardReserve` 转入 `rewards[user]` 和 `aggregateClaimableRewards`。
- 用户 `getReward/claimReward` 成功转账时，减少 `rewards[user]`、`aggregateClaimableRewards` 和 `accountedRewardBalance`。
- 空池期间释放、整除 dust 和误转 sync 的资金进入 `unallocatedRewards`。
- `sweepUnallocatedRewards` 成功转账时，减少 `unallocatedRewards` 和 `accountedRewardBalance`。

任何时候都必须满足：

```text
aggregateClaimableRewards + accruedRewardReserve + scheduledRewards + unallocatedRewards
  <= accountedRewardBalance
  <= rewardToken.balanceOf(address(this))
```

验收时应断言“不多发”和“未分配资金不会被用户领取”。如果实现为了节省 gas 不存储 `accruedRewardReserve`，必须提供等价可验证机制，证明已释放未逐户结算奖励不会被再次排程或 sweep。

## 奖励累计规则

全局公式：

```text
lastTimeRewardApplicable = min(block.timestamp, periodFinish)

if totalSupply == 0:
  rewardPerToken = rewardPerTokenStored
else:
  rewardPerToken = rewardPerTokenStored
    + (lastTimeRewardApplicable - lastUpdateTime) * rewardRate * 1e18 / totalSupply
```

用户公式：

```text
earned(user) =
  balanceOf[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18
  + rewards[user]
```

空池期间：

- 当 `totalSupply == 0` 且奖励周期正在进行时，时间仍然流逝。
- 这段时间对应的奖励视为已经释放但无人获得。
- 空池释放奖励不顺延，不补给第一个后进入用户，也不自动进入下一轮 `leftover`。
- `_updateReward(address(0))` 或等价 checkpoint 必须把空池期间 `elapsed * rewardRate` 从 `scheduledRewards` 移入 `unallocatedRewards`，并发出 `RewardsForfeited(startTime, endTime, amount)`。

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
| `stake/deposit` | 先 `_updateReward(msg.sender)`，再增加本金 |
| `withdraw` | 先 `_updateReward(msg.sender)`，再减少本金 |
| `getReward/claimReward` | 先 `_updateReward(msg.sender)`，再支付奖励 |
| `exit` | 读取本金后，withdraw 和 claim 路径都必须完成奖励更新 |
| `fundAndNotify` | 先 `_updateReward(address(0))`，再计算 `leftover` 和新 `rewardRate` |
| `sweepUnallocatedRewards` | 先 `_updateReward(address(0))`，确保空池放弃奖励已入账 |

`_updateGlobalReward()` 必须做两件事：

- 计算 `elapsed = lastTimeRewardApplicable() - lastUpdateTime`，并从 `scheduledRewards` 中扣减 `released = min(elapsed * rewardRate, scheduledRewards)`。
- 当 `totalSupply > 0` 时，用 `released` 更新 `rewardPerTokenStored`，并将 `released` 加入 `accruedRewardReserve`。
- 当 `totalSupply == 0` 时，不增加 `rewardPerTokenStored`，而是将 `released` 加入 `unallocatedRewards` 并发出 `RewardsForfeited`。
- 将 `lastUpdateTime` 设置为 `lastTimeRewardApplicable()`。

在 `totalSupply == 0` 的时间段，`rewardPerTokenStored` 不增加，但 `lastUpdateTime` 仍必须推进到 `lastTimeRewardApplicable()`，否则第一个后进入用户会错误领取空池期间奖励。

`_updateUserReward(account)` 必须计算用户新增 `delta = newlyEarnedSincePaid(account)`。当 `delta > 0` 时：

- `rewards[account] += delta`
- `aggregateClaimableRewards += delta`
- `accruedRewardReserve -= delta`
- `userRewardPerTokenPaid[account] = rewardPerTokenStored`

如果因为整数舍入导致 `delta == 0`，只更新用户游标，不改变资金会计。

## 奖励注入与偿付检查

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
newScheduledRewards = newRewardRate * rewardsDuration
roundingDust = grossRewards - newScheduledRewards

availableForThisSchedule =
  received
  + leftover

reservedRewards =
  aggregateClaimableRewards
  + accruedRewardReserve
  + unallocatedRewards

postAccountedBalance =
  accountedRewardBalance + received

if (postAccountedBalance < reservedRewards + newScheduledRewards + roundingDust) {
  revert InsufficientRewardBalance(
    reservedRewards + newScheduledRewards + roundingDust,
    postAccountedBalance
  )
}
if (newScheduledRewards > availableForThisSchedule) {
  revert InsufficientRewardBalance(newScheduledRewards, availableForThisSchedule)
}
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

- 追加奖励时检查的是 `newRewardRate * rewardsDuration`，也就是新周期真正会释放的 `newScheduledRewards`。
- `leftover` 只包含当前周期未来尚未释放的奖励，即 `(periodFinish - now) * oldRewardRate`。
- `unreservedRewardBalance` 必须排除用户已结算未领取的 `aggregateClaimableRewards`。
- `unreservedRewardBalance` 必须排除已经释放但尚未逐户结算的 `accruedRewardReserve`。
- `unreservedRewardBalance` 必须排除 `scheduledRewards` 和 `unallocatedRewards`，包括 forfeited、dust、donated token。
- `fundAndNotify` 不得把 `aggregateClaimableRewards`、`accruedRewardReserve`、`unallocatedRewards` 或历史误转余额用作本轮偿付来源。
- 误转或提前转入的 rewardToken 不得自动参与本次奖励注入。
- 如果 `grossRewards` 不能被 `rewardsDuration` 整除，向下取整后的 `roundingDust` 进入 `unallocatedRewards`，不能被用户领取，也不能自动进入下一轮。
- `newRewardRate == 0` 时必须 revert，避免奖励过小导致整笔资金只变成 dust。

不支持公开的“先 transfer，再 notifyRewardAmount(reward)”裸流程。若保留 `notifyRewardAmount(uint256 reward)`，它只能是内部函数或仅由 `fundAndNotify` 调用，否则无法可靠证明本次转入金额与参数一致。

## 未分配奖励处理

`unallocatedRewards` 来源：

- 空池期间已释放但无人获得的奖励。
- `rewardRate` 整除向下取整产生的 dust。
- 外部误转或捐赠进入合约的 rewardToken。

处理规则：

- `unallocatedRewards` 不会自动成为下一轮可发奖励。
- `unallocatedRewards` 不会自动进入下一次 `leftover`。
- 只能由 owner 调用 `sweepUnallocatedRewards(to, amount)` 处理。
- `to` 必须在治理允许列表中，默认只允许 Treasury 或奖励资金管理地址。
- 若要让这笔资金重新成为奖励，必须先 sweep 到奖励资金管理地址，再通过 `fundAndNotify` 重新注入。
- `sweepUnallocatedRewards` 只能减少 `unallocatedRewards`，不得减少 `scheduledRewards`、`aggregateClaimableRewards` 或任何用户的 `rewards[user]`。

偿付边界：

```text
scheduledRewards + accruedRewardReserve + aggregateClaimableRewards + unallocatedRewards
  <= accountedRewardBalance
  <= rewardToken.balanceOf(address(this))
```

如果存在未入账误转余额，可通过 `syncUnallocatedRewards()` 将 `rewardToken.balanceOf(address(this)) - accountedRewardBalance` 计入 `unallocatedRewards`，并发出事件。该函数可以 permissionless，因为它只会增加未分配余额，不会转出资金。

## 误转资产处理策略

误转资产必须按 token 类型区分，不能使用一个无限制 recover 函数处理所有资产。

| 误转资产 | 处理策略 | 原因 |
|---|---|---|
| `stakingToken` | 不提供普通 recover。只有当 `stakingToken.balanceOf(this) > totalSupply` 时，超额部分可由 owner 调用 `recoverExcessStakingToken(to, amount)` 转出，且 `amount <= balance - totalSupply` | `totalSupply` 对应用户本金，不能被管理员挪用 |
| `rewardToken` | 不提供 `recoverRewardToken`。未入账余额先通过 `syncUnallocatedRewards()` 进入 `unallocatedRewards`，再按 `sweepUnallocatedRewards` 治理处理 | rewardToken 可能属于用户已结算奖励、未来排程奖励或未分配奖励 |
| 非 `stakingToken/rewardToken` 的 ERC20 | 可由 owner 调用 `recoverERC20(token, to, amount)` 转出 | 不属于协议核心资金会计 |

`recoverExcessStakingToken` 规则：

- 必须先计算 `excess = stakingToken.balanceOf(address(this)) - totalSupply`。
- 只能转出 `amount <= excess`。
- 不得改变 `totalSupply` 或任何用户 `balanceOf[user]`。
- 必须发出 `ExcessStakingTokenRecovered(operator, to, amount, remainingExcess)`。

`recoverERC20` 规则：

- `token != stakingToken && token != rewardToken`。
- `to != address(0)` 且应在治理允许列表中。
- 转账失败时整个调用 revert，不能留下部分状态更新。
- 必须发出 `ERC20Recovered(operator, token, to, amount)`。

## 用户函数语义

| 函数 | 行为 |
|---|---|
| `stake(amount)` / `deposit(amount)` | `amount > 0`，先更新奖励，再转入本金 |
| `withdraw(amount)` | `amount > 0`，先更新奖励，再转出本金 |
| `getReward()` / `claimReward()` | 领取已结算奖励 |
| `exit()` | 尽力退出全部本金并领取奖励 |
| `emergencyExit()` | 尽力退出全部本金并放弃已结算奖励 |
| `earned(user)` | view 查询用户当前可领奖励 |

零奖励与 `exit()`：

- `getReward/claimReward` 在奖励为 0 时 no-op 成功，不 revert，不转账，不发出 `RewardPaid`。
- 用户没有本金但有已结算奖励时，`exit()` 应领取奖励。
- 用户有本金但没有奖励时，`exit()` 应成功提款，并跳过奖励转账。
- 用户本金和奖励都为 0 时，`exit()` 应 no-op 成功。
- 单独调用 `withdraw(0)` 必须 revert；`exit()` 是组合型便利函数，不应因本金为 0 revert。

推荐 `exit()`：

```solidity
function exit() external nonReentrant {
    uint256 principal = balanceOf[msg.sender];
    if (principal > 0) {
        withdraw(principal);
    }
    getReward();
}
```

### 紧急退出

`emergencyExit()` 是用户在前端、奖励领取或 token 异常时的安全退出入口。它只保证尽快取回全部本金，不保证领取奖励。

调用顺序必须是：

```text
_updateReward(msg.sender)
principal = balanceOf[msg.sender]
forfeitedReward = rewards[msg.sender]
balanceOf[msg.sender] = 0
totalSupply -= principal
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
- `emergencyExit()` 不受 `STAKE`、`REWARD_FUNDING` pause 影响。
- `principal == 0 && forfeitedReward == 0` 时 no-op 成功，可发或不发 `EmergencyExit`；若发事件，amount 均为 0。
- 如果 stakingToken 转账失败，整个调用必须 revert，用户本金、`rewards[user]`、`aggregateClaimableRewards` 和 `unallocatedRewards` 必须全部回滚。

## 奖励周期修改

```solidity
function setRewardsDuration(uint256 newDuration) external onlyOwner
```

规则：

- 活跃奖励周期内禁止修改：`block.timestamp < periodFinish` 时必须 revert。
- 修改只影响下一次 `fundAndNotify` 开启的新周期。
- 不回溯改变已开始周期，不重算历史 `rewardRate`、`periodFinish` 或用户已累积奖励。
- `newDuration` 必须满足 `1 days <= newDuration <= 30 days`。
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
```

暂停事件：

```solidity
event ModulePaused(bytes32 indexed module, address indexed operator, bytes32 reasonHash);
event ModuleUnpaused(bytes32 indexed module, address indexed operator);
```

OZ `Ownable2Step` 会提供 ownership 相关事件。

事件规则：

- 零奖励 `getReward/claimReward` 不发 `RewardPaid`。
- `emergencyExit` 必须发 `EmergencyExit`，并记录准确的 `forfeitedReward`。
- `fundAndNotify` 必须发 `RewardAdded`。
- 空池奖励进入 `unallocatedRewards` 必须发 `RewardsForfeited`。
- 任何角色变更必须发事件。
- 任何 pause/unpause 必须发事件。

## 安全不变量

| 编号 | 不变量 |
|---|---|
| I-1 | `stakingToken != rewardToken` |
| I-2 | `totalSupply == sum(balanceOf[user])`，允许测试中用 handler 聚合 |
| I-3 | 用户可领取总额不超过已注入并完成会计登记的奖励 |
| I-4 | `scheduledRewards + accruedRewardReserve + aggregateClaimableRewards + unallocatedRewards <= accountedRewardBalance` |
| I-5 | `accountedRewardBalance <= rewardToken.balanceOf(address(this))` |
| I-6 | `sweepUnallocatedRewards` 不得减少任何用户本金或已结算奖励 |
| I-7 | 空池期间释放的奖励不得被后续第一个质押用户领取 |
| I-8 | `fundAndNotify` 的参数必须等于本次实际收到的 `rewardToken` 数量 |
| I-9 | `getReward/claimReward` 零奖励 no-op 成功 |
| I-10 | 活跃周期内 `setRewardsDuration` 必须 revert |
| I-11 | Guardian 不能转移资金、不能改角色、不能改参数 |
| I-12 | `emergencyExit` 必须先更新奖励；forfeited reward 从用户已结算奖励转入 `unallocatedRewards`，不得减少 `accountedRewardBalance` |
| I-13 | `stakingToken.balanceOf(this) >= totalSupply`，只有超过 `totalSupply` 的 stakingToken 才能作为误转超额恢复 |
| I-14 | 任意 token 转账失败时，相关函数必须整体 revert，所有本合约状态回滚 |

## 测试清单

权限与初始化：

- 构造函数拒绝零 `initialOwner`、零 token、零 `rewardManager`、相同 `stakingToken/rewardToken`。
- `guardian_ == address(0)` 时 guardian 函数不可用。
- owner 来自构造函数参数，而不是隐式部署者。
- `setRewardManager(address(0))` revert。
- `setGuardian(address(0))` 成功并禁用 guardian。
- owner 可与 rewardManager/guardian 相同，但生产部署脚本应提示风险。
- `Ownable2Step` ownership 转移流程测试通过。
- 活跃奖励周期未结束时 owner 可以更换 `rewardManager`；旧 manager 立即失去调用权，新 manager 可以追加新奖励，已注入的 `rewardRate/periodFinish/scheduledRewards` 不被修改。
- 更换 `rewardManager` 不改变旧周期 leftover 的计算；周期中追加仍按 `received + leftover` 计算。

奖励会计：

- `stake`、`withdraw`、`getReward`、`exit` 都先更新全局和用户奖励。
- `fundAndNotify` 先更新全局 `rewardPerTokenStored` 和 `lastUpdateTime`，再计算 `leftover`。
- 追加奖励时偿付检查使用 `newRewardRate * rewardsDuration <= received + leftover`。
- `unreservedRewardBalance` 排除 `aggregateClaimableRewards`、`accruedRewardReserve`、`scheduledRewards` 和 `unallocatedRewards`。
- `rewardRate` 向下取整产生的 dust 进入 `unallocatedRewards`。
- `newRewardRate == 0` revert。
- 误转 token 只能进入 `unallocatedRewards`，不能被下一次奖励自动使用。
- 用户已结算未领取奖励存在时，`fundAndNotify` 不得把这部分余额计入新周期偿付。
- 已释放但未逐户结算的 `accruedRewardReserve` 存在时，`fundAndNotify` 不得把这部分余额计入新周期偿付。
- 多次 `stake` 必须先结算旧本金产生的奖励，再增加本金；第二次 stake 后的奖励按新本金继续计算。
- 部分 `withdraw` 必须先结算提现前本金产生的奖励，再减少本金；剩余本金继续参与后续奖励。
- `stake -> partial withdraw -> stake again -> getReward` 的累计奖励必须等于分段本金和分段时间计算结果，误差只允许整数 dust。
- `stake A -> stake B -> withdraw C -> withdraw remaining` 后，`totalSupply` 和 `balanceOf[user]` 必须逐步匹配每次本金变化。

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
- sweep 不改变用户 `rewards[user]`、`aggregateClaimableRewards`、`scheduledRewards`。

用户边界：

- `getReward/claimReward` 零奖励 no-op，不发 `RewardPaid`。
- 无本金有奖励时 `exit()` 领取奖励。
- 有本金无奖励时 `exit()` 提款成功。
- 本金和奖励都为 0 时 `exit()` no-op 成功。
- `withdraw(0)` revert。
- `emergencyExit` 必须先更新奖励，再清零 `rewards[user]`；事件 `forfeitedReward` 等于更新后的 `rewards[user]`。
- `emergencyExit` 后用户本金为 0、奖励为 0，`unallocatedRewards` 增加 forfeitedReward，`accountedRewardBalance` 不减少。

误转资产：

- 误转 `stakingToken` 后，只有 `balance - totalSupply` 的超额部分可 recover；recover 后 `stakingToken.balanceOf(this) == totalSupply + remainingExcess`。
- 误转 `rewardToken` 后，不能直接 recover；必须先 `syncUnallocatedRewards`，再按 `sweepUnallocatedRewards` 处理。
- 误转非核心 ERC20 后，owner 可 `recoverERC20`，非 owner revert，`stakingToken/rewardToken` 作为 token 参数时 revert。

异常 token 和转账失败：

- `FeeOnTransferMock` 用作 rewardToken 时，`fundAndNotify(amount)` 因实际到账不足以 `InvalidReceivedAmount` revert，`accountedRewardBalance/rewardRate/periodFinish` 不变。
- `FeeOnTransferMock` 用作 stakingToken 时，`stake(amount)` 必须拒绝实际到账不等于 amount，或通过 balance-delta 检查 revert，`totalSupply/balanceOf` 不变。
- `FalseReturnERC20Mock` 或 `BlacklistMock` 导致 `stake/withdraw/getReward/fundAndNotify/sweepUnallocatedRewards/recoverERC20` 转账失败时，函数整体 revert，所有状态保持调用前值。
- `ERC777HookMock` 重入 `stake/withdraw/getReward/exit/fundAndNotify` 必须因 `ReentrancyGuard` revert。
- `PausableTokenMock` 暂停 token 转账后，相关操作必须 revert 且状态回滚。

暂停与恢复：

- guardian 可暂停 `STAKE` 和 `REWARD_FUNDING`。
- guardian 不能暂停 `WITHDRAW` 和 `CLAIM`。
- guardian 只能恢复自己暂停的模块。
- owner-level lockdown 后 guardian 不能 unpause。
- pause/unpause 都发事件。

奖励周期：

- 活跃周期内 `setRewardsDuration` revert。
- 周期结束后 owner 可设置 `[1 days, 30 days]` 内的新 duration。
- `0`、过小、过大和非 owner 调用都 revert。
- 修改成功发 `RewardsDurationUpdated`，只影响下一次 `fundAndNotify`。
- `setRewardsDuration` 在 paused 状态下仍可由 owner 调用，但必须满足非活跃周期和范围限制。

专项测试：

- `stakingToken == rewardToken` 构造必须以 `SameToken()` revert。
- `stakingToken != rewardToken` 正常部署后，stakingToken 余额变化只等于用户本金净流入，rewardToken 余额变化只来自奖励注入、领取、sweep。
- 所有 custom error 均使用 selector 断言；OZ owner 错误使用 OZ 标准 selector。
- 所有事件参数必须断言，包括 indexed 地址、金额、`periodFinish`、`remainingUnallocated`。

## 验收标准

核心函数验收：

| 函数 | 成功断言 | 失败断言 |
|---|---|---|
| `stake(amount)` | `totalSupply += amount`，`balanceOf[user] += amount`，合约 stakingToken 增加 amount，发 `Staked` | `amount == 0` 用 `ZeroAmount` revert；`STAKE` paused 用 `ModuleIsPaused` revert |
| `withdraw(amount)` | `totalSupply -= amount`，`balanceOf[user] -= amount`，用户 stakingToken 增加 amount，发 `Withdrawn` | `amount == 0` 用 `ZeroAmount` revert；余额不足用 `InsufficientStake` revert |
| `getReward()` | reward > 0 时用户 rewardToken 增加 reward，`aggregateClaimableRewards` 和 `accountedRewardBalance` 同步减少，发 `RewardPaid` | reward == 0 时成功 no-op，不发 `RewardPaid` |
| `exit()` | 有本金时全部提款；有奖励时领奖；二者为 0 时成功 no-op | 不得因零本金或零奖励 revert |
| `emergencyExit()` | 先更新奖励；本金全部返还；`rewards[user] = 0`；`unallocatedRewards += forfeitedReward`；发 `EmergencyExit` | stakingToken 转账失败时整体 revert，所有状态回滚 |
| `fundAndNotify(amount)` | 实际收到等于 amount；`rewardRate = floor((received + leftover) / duration)`；`periodFinish = now + duration`；发 `RewardAdded` | 非 manager、零 amount、实际收到不等、rate 为 0、偿付不足、paused 均按指定 custom error revert |
| `setRewardsDuration(newDuration)` | 非活跃期内更新 duration，发 `RewardsDurationUpdated` | 活跃期、0、过小、过大、非 owner 均 revert |
| `sweepUnallocatedRewards(to, amount)` | 只减少 `unallocatedRewards` 和 `accountedRewardBalance`，用户本金和奖励不变，发 `UnallocatedRewardsSwept` | 非 owner、to 不允许、amount 为 0、amount 超额均 revert |
| `recoverERC20(token, to, amount)` | 只能恢复非 staking/reward token，发 `ERC20Recovered` | token 是核心 token、to 不允许、转账失败均 revert |

奖励会计量化标准：

- 任意测试路径中，用户累计领取奖励总额 `<= sum(all newScheduledRewards)`。
- 奖励误差只允许来自整数除法向下取整，dust 必须进入 `unallocatedRewards`。
- 对单用户、单周期、无中途操作场景，领取值应等于 `floor(amount / duration) * elapsed`，误差不超过 dust。
- 对多用户场景，每个用户奖励按 `stakeWeight * elapsed` 分摊，所有用户累计领取加未领取加未分配不得超过 `accountedRewardBalance`。
- 空池期间释放奖励的用户可领取量必须为 0，对应金额必须进入 `unallocatedRewards`。
- `aggregateClaimableRewards + accruedRewardReserve + scheduledRewards + unallocatedRewards <= accountedRewardBalance <= rewardToken.balanceOf(this)` 始终成立。
- `stakingToken.balanceOf(this) == totalSupply` 始终成立；因为 `stakingToken != rewardToken`，奖励资金不得影响本金断言。
- 如果存在误转 stakingToken，则 `stakingToken.balanceOf(this) - totalSupply` 才是可恢复上限。
- 任意外部 token 转账失败的测试中，所有核心状态变量必须等于调用前快照。

部署验收：

- 构造参数和所有初始 view 返回值与部署报告一致。
- 部署后未开启奖励周期时，`earned(anyUser) == 0`、`rewardPerToken() == 0`、`lastTimeRewardApplicable() == 0`。
- owner 已完成 `Ownable2Step` 交接，部署者 EOA 不再拥有 owner、rewardManager、guardian。
- 小额冒烟流程 `fundAndNotify -> stake -> warp -> getReward -> exit` 通过，资金差额只允许整数 dust。

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
- 部署脚本或 fork 检查必须验证小额 `transfer/transferFrom` 的 balance delta 等于 amount；如果实际到账不同，禁止部署。
- 对支持 blacklist、pause、tax、rebase、hook 的 token，即使当前配置看起来关闭，也不得作为生产 `stakingToken` 或 `rewardToken`。
- `stakingToken != rewardToken`。
- `initialOwner`、`rewardManager`、`guardian` 地址已在部署配置中显式填写。
- 生产环境 `initialOwner` 应为多签或 Timelock；如果临时使用部署者 EOA，必须在同一部署批次中完成 ownership 交接。
- `rewardManager` 非零，并持有或可调拨足够 rewardToken。
- `guardian` 生产环境非零，且不是普通热钱包。
- 初始 `rewardsDuration` 在允许范围内。

部署后校验：

- 查询所有构造参数 view，逐项匹配部署配置。
- 查询初始状态：`periodFinish == 0`、`rewardRate == 0`、`totalSupply == 0`、`accountedRewardBalance == 0`。
- 如果发生 ownership 交接，确认 `owner() == finalOwner` 且部署者 EOA 不再是 owner。
- 确认部署者 EOA 不是 `rewardManager`，也不是 `guardian`，除非部署报告明确说明这是临时测试环境。
- 确认 `rewardManager` 已对 staking 合约完成 rewardToken allowance，或已经准备好通过资金管理合约调用。
- 执行小额 `fundAndNotify`、`stake`、`getReward`、`exit` fork 测试。
- 执行一次 `pauseModule(STAKE)` 和 `unpauseModule(STAKE)` 测试 guardian 权限；生产主网可用 fork 或 testnet 演练，不建议主网随意暂停。

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
