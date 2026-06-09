# ERC20 Staking Rewards

> 本 README 描述一个独立的 ERC-20 staking rewards 项目。
> 本项目负责 ERC-20 staking token 的质押、ERC-20 reward token 的奖励累计、领取、暂停和紧急退出。
> 当前交付范围只包含 staking 主体逻辑，不包含交易、做市、预言机、治理投票、手续费分红或复杂代币经济模型。

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 目录

- [项目说明](#项目说明)
- [交付范围](#交付范围)
- [用户流程](#用户流程)
- [合约结构](#合约结构)
- [核心合约](#核心合约)
- [奖励计算](#奖励计算)
- [权限设计](#权限设计)
- [安全要求](#安全要求)
- [测试计划](#测试计划)
- [部署说明](#部署说明)
- [验收标准](#验收标准)
- [开发命令](#开发命令)
- [许可证](#许可证)

---

## 项目说明

`StakingPool` 是本项目的质押奖励主体合约。用户将指定的 ERC-20 `stakingToken` 存入合约后，根据质押数量和质押时间获得 ERC-20 `rewardToken` 奖励。

本项目采用单池 staking 设计：

- `stakingToken` 是用户质押的标准 ERC-20 token。
- `rewardToken` 是用户领取的标准 ERC-20 reward token。
- 奖励资金由 `rewardManager` 注入，本项目负责接收奖励、记录奖励会计和向用户发放奖励。
- 本项目不实现多池权重分配、投票治理、收益聚合或外部协议集成。

本项目的开发重点是：

- 正确保管用户质押本金。
- 正确计算用户随时间累积的奖励。
- 支持用户质押、提款、领取奖励和一键退出。
- 支持 reward manager 配置奖励周期和注入奖励。
- 在暂停状态下禁止新增质押，但不阻止用户提款和领取奖励。
- 支持紧急退出：异常情况下用户可以取回本金，并放弃当前未领取奖励。
- 使用 Foundry 覆盖主要成功路径、失败路径和边界条件。

---

## 交付范围

### 当前交付范围

- ERC-20 `stakingToken` 的存入、提款和余额会计。
- ERC-20 `rewardToken` 的奖励累计、领取和奖励余额检查。
- 普通质押池：用户可随时质押、提款和领取奖励。
- 奖励周期配置：`rewardRate`、`periodFinish`、`rewardsDuration`。
- 基础权限管理：`owner`、`rewardManager` 和 `guardian`。
- 暂停机制：暂停 `stake`，保留 `withdraw` 和 `claimReward`。
- 紧急退出：`emergencyWithdraw` 允许用户取回本金并放弃未领取奖励。
- Foundry 单元测试、集成测试和本地部署脚本。

### 后续扩展范围

- 锁仓质押池：用户选择锁定周期，锁定期内不能普通提款。
- `RewardVault`：奖励资金独立托管，并授权池子拉取奖励。
- 可选的测试网部署和区块浏览器验证。
- 基础 fuzz 测试和 Gas 报告。

### 不在当前交付范围

- 本项目不提供交易、价格预言机、治理投票 等 复杂代币经济模型。

---

## 用户流程

### 用户质押

```text
User
  -> approve stakingToken to StakingPool
  -> stake(amount)
  -> balanceOf(user) 增加
  -> totalSupply 增加
```

### 用户领取奖励

```text
User
  -> earned(user)
  -> claimReward()
  -> rewardToken 转给 user
  -> rewards[user] 清零
```

### 用户提款

```text
User
  -> withdraw(amount)
  -> 先更新用户奖励
  -> balanceOf(user) 减少
  -> totalSupply 减少
  -> stakingToken 转回 user
```

### 用户退出

```text
User
  -> exit()
  -> withdraw(fullBalance)
  -> claimReward()
```

### 用户紧急退出

```text
User
  -> emergencyWithdraw()
  -> balanceOf(user) 清零
  -> totalSupply 减少
  -> stakingToken 转回 user
  -> rewards[user] 清零
  -> 不领取 rewardToken
```

### 奖励配置

```text
Reward Manager
  -> transfer rewardToken to StakingPool
  -> notifyRewardAmount(reward)
  -> rewardRate = reward / rewardsDuration
```

---

## 合约结构

```text
src/
├── staking/
│   ├── StakingPool.sol
│   └── interfaces/
│       └── IStakingPool.sol
├── libraries/
│   └── RewardMath.sol
└── mocks/
    └── MockERC20.sol

test/
├── unit/
│   ├── StakingPool.t.sol
│   └── RewardMath.t.sol
└── integration/
    └── StakingFlow.t.sol

script/
└── Deploy.s.sol
```

---

## 核心合约

### StakingPool.sol

`StakingPool` 负责用户本金托管和奖励分发。

#### 状态变量

| 变量 | 说明 |
|---|---|
| `stakingToken` | 用户质押的 ERC-20 token |
| `rewardToken` | 用户领取的 ERC-20 reward token |
| `totalSupply` | 当前总质押数量 |
| `balanceOf[user]` | 用户当前质押本金 |
| `rewardRate` | 每秒释放的 rewardToken 数量 |
| `rewardsDuration` | 奖励释放周期 |
| `periodFinish` | 当前奖励周期结束时间 |
| `lastUpdateTime` | 最近一次全局奖励更新时间 |
| `rewardPerTokenStored` | 每单位质押本金累计奖励 |
| `userRewardPerTokenPaid[user]` | 用户上次结算时的累计值 |
| `rewards[user]` | 用户已结算但未领取奖励 |
| `rewardManager` | 负责配置奖励周期的地址 |
| `guardian` | 负责紧急暂停和恢复的地址 |
| `paused` | 是否暂停新增质押 |

#### 必要函数

| 函数 | 说明 |
|---|---|
| `stake(uint256 amount)` | 用户质押 `stakingToken` |
| `withdraw(uint256 amount)` | 用户提取部分或全部本金 |
| `claimReward()` | 用户领取已累积奖励 |
| `exit()` | 用户提取全部本金并领取奖励 |
| `emergencyWithdraw()` | 用户紧急提取全部本金并放弃奖励 |
| `earned(address account)` | 查询用户当前可领取奖励 |
| `rewardPerToken()` | 查询当前每单位本金累计奖励 |
| `notifyRewardAmount(uint256 reward)` | 配置新一轮奖励 |
| `setRewardsDuration(uint256 duration)` | 设置奖励周期 |
| `setRewardManager(address manager)` | 设置奖励管理员 |
| `setGuardian(address guardian)` | 设置紧急暂停角色 |
| `pause()` | 暂停新增质押 |
| `unpause()` | 恢复新增质押 |

#### 函数规则

`stake(amount)`：

- `amount` 必须大于 0。
- paused 状态下必须 revert。
- 转入 token 前先更新用户奖励。
- 用户余额和 `totalSupply` 必须正确增加。
- 使用 `SafeERC20.safeTransferFrom`。
- 使用 `nonReentrant`。

`withdraw(amount)`：

- `amount` 必须大于 0。
- `amount` 不能超过用户余额。
- paused 状态下仍然允许提款。
- 转出 token 前先更新用户奖励。
- 用户余额和 `totalSupply` 必须正确减少。
- 使用 `SafeERC20.safeTransfer`。
- 使用 `nonReentrant`。

`claimReward()`：

- 先更新用户奖励。
- 如果奖励为 0，可以直接返回或 revert，具体行为需在测试中固定。
- 成功领取后 `rewards[user]` 清零。
- rewardToken 转账金额必须等于用户已结算奖励。
- 使用 `nonReentrant`。

`exit()`：

- 等价于提取全部本金并领取奖励。
- 用户没有本金时不能错误转账。
- 需要覆盖只有本金、只有奖励、本金和奖励都存在的情况。

`emergencyWithdraw()`：

- 用户只能提取自己的全部本金。
- 不向用户发放 rewardToken。
- 必须清零 `balanceOf[user]` 和 `rewards[user]`。
- 必须减少 `totalSupply`。
- paused 和 unpaused 状态下都可以调用。
- 使用 `SafeERC20.safeTransfer`。
- 使用 `nonReentrant`。

`notifyRewardAmount(reward)`：

- 只能由 owner 或 `rewardManager` 调用。
- `reward` 必须大于 0。
- `rewardsDuration` 必须大于 0。
- 如果上一轮奖励未结束，需要把剩余未释放奖励计入新周期。
- 新的 `rewardRate` 不能超过合约当前 rewardToken 余额可支付的范围。
- 更新 `lastUpdateTime` 和 `periodFinish`。

`pause()` / `unpause()`：

- 只能由 owner 或 `guardian` 调用。
- 不能改变用户本金和奖励会计。
- 必须发出暂停状态变更事件。

---

## 奖励计算

本项目使用常见的 `rewardPerToken` 模型。

```text
lastTimeRewardApplicable =
  min(block.timestamp, periodFinish)

rewardPerToken =
  rewardPerTokenStored
  + (
      lastTimeRewardApplicable - lastUpdateTime
    )
    * rewardRate
    * 1e18
    / totalSupply

earned(user) =
  balanceOf[user]
  * (
      rewardPerToken - userRewardPerTokenPaid[user]
    )
    / 1e18
  + rewards[user]
```

当 `totalSupply == 0` 时，`rewardPerToken()` 返回 `rewardPerTokenStored`，不能除以 0。

### 舍入规则

- 奖励计算向下取整。
- 小额 dust 留在合约中。
- 合约不能因为整数除法多发 rewardToken。
- 测试需要覆盖小额质押、短时间奖励、多用户同时参与和中途退出。

---

## 权限设计

| 角色 | 权限 |
|---|---|
| User | `stake`、`withdraw`、`claimReward`、`exit`、`emergencyWithdraw` |
| Owner | 设置 reward manager、guardian、奖励周期、暂停和恢复 |
| Reward Manager | 调用 `notifyRewardAmount` 配置奖励 |
| Guardian | 只允许暂停和恢复，不允许配置奖励或转移资金 |

权限要求：

- 用户只能操作自己的质押本金和奖励。
- owner 不能直接转走用户的 stakingToken。
- guardian 不能调用 `notifyRewardAmount`。
- `setRewardsDuration` 不应在当前奖励周期未结束时随意修改。
- 所有关键权限操作需要 emit event。

与其他系统的边界：

- 本项目不创建 staking token，只接收已经存在的标准 ERC-20 `stakingToken`。
- 本项目不铸造 reward token，只按已经注入的 `rewardToken` 发放奖励。
- 本项目不实现投票权、boost 或多池权重分配。
- 本项目不负责手续费分红、回购或收益聚合。

---

## 安全要求

### Reentrancy

以下函数必须使用 `nonReentrant`：

- `stake`
- `withdraw`
- `claimReward`
- `exit`
- `emergencyWithdraw`

### ERC-20 兼容性

所有 ERC-20 转账使用 OpenZeppelin `SafeERC20`。

本项目只支持标准 ERC-20，不支持：

- fee-on-transfer token
- rebasing token
- ERC777 callback token
- blacklist / pausable / tax token
- 行为异常的 ERC-20 token

### Pause

paused 状态下：

- `stake` 必须 revert。
- `withdraw` 必须可用。
- `claimReward` 必须可用。
- `exit` 必须可用。
- `emergencyWithdraw` 必须可用。

暂停功能只能限制新增风险，不能阻止用户取回本金和已累积奖励。

### Emergency Withdraw

`emergencyWithdraw` 用于异常情况下快速取回本金。该函数不领取奖励，并清空用户已结算但未领取的奖励。

设计约束：

- 只能提取调用者自己的全部本金。
- 不能指定任意 recipient。
- 不能提取其他用户本金。
- 放弃的奖励留在合约中，可用于后续奖励周期或由后续资金处理流程统一处理。
- 函数必须发出 `EmergencyWithdraw(user, amount, forfeitedReward)` 事件。

### Reward Solvency

`notifyRewardAmount` 必须检查奖励余额是否足够覆盖当前奖励周期。

```text
rewardRate <= rewardToken.balanceOf(address(this)) / rewardsDuration
```

如果上一轮奖励未结束，需要考虑 leftover：

```text
remaining = periodFinish - block.timestamp
leftover = remaining * rewardRate
newRewardRate = (reward + leftover) / rewardsDuration
```

---

## 测试计划

### 单元测试

`StakingPool.t.sol`：

- 部署后 `stakingToken`、`rewardToken`、owner 配置正确。
- `stake` 成功转入 token 并更新用户余额。
- `stake(0)` revert。
- paused 状态下 `stake` revert。
- `withdraw` 成功转出 token 并更新余额。
- `withdraw(0)` revert。
- 提取超过余额时 revert。
- `claimReward` 成功领取奖励。
- 重复领取同一段奖励不能多发。
- `exit` 提取全部本金并领取奖励。
- `emergencyWithdraw` 只提取本金，不发放奖励。
- `emergencyWithdraw` 后用户本金和已结算奖励清零。
- 非授权地址不能调用 `notifyRewardAmount`。
- guardian 可以 pause / unpause，但不能调用 `notifyRewardAmount`。
- `notifyRewardAmount` 正确设置 `rewardRate` 和 `periodFinish`。
- 上一轮未结束时追加奖励，leftover 计算正确。
- rewardToken 余额不足时 `notifyRewardAmount` revert。

`RewardMath.t.sol`：

- `rewardPerToken` 计算正确。
- `earned` 计算正确。
- `totalSupply == 0` 时不除以 0。
- 多用户按质押数量和时间分配奖励。
- 小额奖励向下取整，不多发 token。

### 集成测试

`StakingFlow.t.sol`：

- 用户 A 先质押，用户 B 后质押，奖励分配正确。
- 用户中途提款后，只对剩余本金继续累积奖励。
- 用户先 claim 再 withdraw，资金流正确。
- 用户直接 exit，结果与 withdraw + claimReward 一致。
- paused 后用户不能新增质押，但可以提款和领取奖励。
- paused 后用户可以调用 `emergencyWithdraw` 取回本金。

### 测试覆盖目标

| 模块 | 目标 |
|---|---:|
| StakingPool | >= 90% |
| RewardMath | >= 90% |
| Integration Flow | >= 80% |

---

## 部署说明

### 环境变量

```bash
PRIVATE_KEY=
RPC_URL=
ETHERSCAN_API_KEY=
STAKING_TOKEN=
REWARD_TOKEN=
OWNER=
REWARD_MANAGER=
GUARDIAN=
REWARDS_DURATION=
```

### 部署顺序

1. 确认 `stakingToken` 和 `rewardToken` 地址。
2. 部署 `StakingPool`。
3. 设置 `rewardManager`。
4. 设置 `guardian`。
5. 设置 `rewardsDuration`。
6. 向 `StakingPool` 转入 rewardToken。
7. 调用 `notifyRewardAmount(reward)` 开启奖励周期。
8. 运行基础交互脚本，确认 stake、withdraw、claimReward、emergencyWithdraw 正常。

### 部署命令

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

---

## 验收标准

### 功能验收

- 用户可以质押标准 ERC-20。
- 用户可以提取部分或全部本金。
- 用户可以领取已累积奖励。
- `exit()` 可以一次性完成提款和领奖。
- reward manager 可以配置奖励周期并开启奖励发放。
- paused 状态下不能新增质押，但用户可以退出。
- 用户可以通过 `emergencyWithdraw` 取回本金并放弃奖励。

### 会计验收

- `totalSupply` 等于所有用户本金之和。
- `balanceOf[user]` 与用户实际质押本金一致。
- 用户奖励不会重复领取。
- 用户紧急退出后不能继续领取已放弃奖励。
- 合约不会发出超过余额的 rewardToken。
- 多用户不同时间进入和退出时，奖励分配符合公式。

### 安全验收

- 所有转账使用 `SafeERC20`。
- 移动资产的 external 函数使用 `nonReentrant`。
- 权限函数有访问控制测试。
- guardian 权限不能配置奖励或移动资金。
- zero amount、zero address、余额不足、奖励不足等失败路径有测试。
- 不支持的 token 类型在文档中明确说明。

---

## 开发命令

```bash
forge fmt
forge build
forge test
forge test --match-path "test/unit/*"
forge test --match-path "test/integration/*"
forge coverage --report lcov
forge test --gas-report
```

---

## 许可证

MIT
