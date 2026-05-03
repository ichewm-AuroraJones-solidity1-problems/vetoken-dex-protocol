# VeBoostVault — veToken + Boost 多池质押系统

> 基于 Uniswap V2 AMM + Curve veToken 经济模型的完整 DeFi 协议

---

## 1. 项目背景与设计动机

### 1.1 行业问题

2020 年 DeFi Summer 期间，流动性挖矿（Liquidity Mining）成为协议冷启动的标准策略：协议发放治理代币吸引流动性提供者。然而这种模式暴露出一个核心矛盾——高 APY 吸引的资金绝大多数是"挖提卖"（Farm & Dump）的短期逐利资本。矿工领到代币后立即抛售，导致代币持续承压、价格螺旋下跌，协议无法留住真正关心长期发展的参与者。

根本原因在于：**传统流动性挖矿对所有参与者一视同仁，没有在机制层面区分长期持有者与短期投机者。**

### 1.2 现有解决方案

Curve Finance 于 2020 年 8 月率先提出 Vote-Escrowed Token（veToken）模型，核心思路是：

- 用户必须将治理代币**锁定**一段时间（最长 4 年）才能获得投票权（veCRV）
- 锁定时间越长，获得的 veToken 越多，投票权重和收益加速倍率越高
- veToken 余额随时间线性衰减，到期归零——迫使用户持续续锁以维持权重

这一设计首次在协议层面建立了**时间承诺与权益回报之间的正相关关系**。此后 Balancer (veBAL)、Frax (veFXS)、Velodrome (veVELO) 等主流协议纷纷采用类似架构，veToken 已成为 DeFi 治理经济学的主流范式。

与此同时，Uniswap V2 的恒定乘积自动做市商（x·y=k AMM）凭借其极简而优雅的设计，至今仍是 DEX 领域部署量最大的合约架构，也是理解 DeFi 底层流动性机制的最佳起点。

### 1.3 本项目定位

VeBoostVault 将上述两大经典模型进行整合：

| 层级 | 参考协议 | 本项目实现 |
|------|----------|------------|
| AMM 交易层 | Uniswap V2 | 自建恒定乘积做市商（PairFactory / Pair / Router） |
| 锁仓治理层 | Curve veToken | 时间加权投票锁仓（VotingEscrow） |
| 排放投票层 | Curve Gauge Voting | 多池排放权重投票（GaugeController） |
| 收益加速层 | Curve Boost | 基于 veToken 的 1x~2.5x 挖矿加速（LiquidityGauge） |
| 分红层 | Curve Fee Distribution | 协议手续费按 veToken 份额分配（FeeDistributor） |

项目目标并非部署到生产环境，而是通过从零实现完整的 DeFi 协议经济循环，系统性训练以下能力：

1. **智能合约工程**：多合约交互架构设计、状态机建模、精度安全的数学运算
2. **DeFi 机制理解**：AMM 定价原理、veToken 博弈论、Boost 数学推导
3. **安全意识**：重入防护、整数溢出、会计不变量验证、边界条件测试
4. **工程规范**：Foundry 测试驱动开发、部署脚本编写、文档规范

---

## 2. 项目概述

### 系统模块

| 层级 | 模块 | 合约 | 职责 |
|------|------|------|------|
| AMM 层 | 交易对工厂 | `PairFactory` | 创建并管理交易对，控制协议手续费开关 |
| AMM 层 | 交易对 | `Pair` | 恒定乘积做市（x·y=k），铸造/销毁 LP Token |
| AMM 层 | 路由器 | `Router` | 用户友好的交易与流动性管理入口 |
| 治理层 | 治理代币 | `GovToken` | ERC-20 治理代币，可锁定换取 veToken |
| 治理层 | 投票锁仓 | `VotingEscrow` | 锁定 GOV 获得 veGOV，余额随时间线性衰减 |
| 治理层 | 排放投票 | `GaugeController` | veGOV 持有者投票决定各池奖励排放比例 |
| 激励层 | 流动性挖矿 | `LiquidityGauge` | 质押 LP Token 赚取 GOV 奖励，Boost 倍率 1x ~ 2.5x |
| 激励层 | 协议分红 | `FeeDistributor` | 协议手续费按 veGOV 份额分配给锁仓者 |

---

## 3. 经济循环
用户通过 Router 提供流动性 (GOV/WETH) → Pair 铸造 LP Token
↓
LP Token 质押到 LiquidityGauge → 赚取 GOV 排放奖励（Boost 1x ~ 2.5x）
↓
GOV 锁入 VotingEscrow → 获得 veGOV（线性衰减）
↓
veGOV 用于 GaugeController 投票 → 决定各池 GOV 排放权重
↓
Pair 中每笔 swap 收取 0.3% 手续费：
├── 0.25% → 留在 Pair 中（增厚 LP 持有者的底层资产价值）
└── 0.05% → 进入 FeeDistributor → 按 veGOV 比例分配给锁仓者
**正向飞轮效应：** 更多流动性 → 更多交易量 → 更多手续费 → 更高锁仓收益 → 更多人锁仓 → GOV 流通量减少 → 价值提升。

---

## 4. 用户角色与故事

| 角色 | 行为 | 收益来源 |
|------|------|----------|
| 流动性提供者 | 通过 Router 向交易对注入双边资产，获得 LP Token | swap 手续费自动复利 |
| LP 矿工 | 将 LP Token 质押到 Gauge | GOV 排放奖励（受 Boost 影响） |
| 锁仓治理者 | 将 GOV 锁定 1 周 ~ 4 年，获得 veGOV | 协议手续费分红 + Boost 加速 + 投票权 |
| 投票者 | 用 veGOV 为 Gauge 分配排放权重 | 影响哪个池获得更多 GOV 排放 |
| 交易者 | 通过 Router 进行代币兑换 | 获得目标代币（支付 0.3% 手续费） |

---

## 5. 核心数学公式

### 5.1 AMM 恒定乘积
x · y = k

amountInWithFee = amountIn × 997
amountOut = (amountInWithFee × reserveOut) / (reserveIn × 1000 + amountInWithFee)
- 总手续费率：0.3%
- 协议费：总手续费的 1/6（约 0.05%），通过铸造额外 LP Token 给 FeeDistributor 实现

### 5.2 LP Token 铸造与销毁
首次添加流动性：
liquidity = sqrt(amount0 × amount1) - MINIMUM_LIQUIDITY

后续添加流动性：
liquidity = min(amount0 × totalSupply / reserve0, amount1 × totalSupply / reserve1)

移除流动性：
amount0 = liquidity × reserve0 / totalSupply
amount1 = liquidity × reserve1 / totalSupply
- `MINIMUM_LIQUIDITY = 1000`（首次铸造时永久锁定至零地址，防止除零攻击）

### 5.3 veToken 余额（线性衰减模型）
veBalance(t) = lockedAmount × (lockEnd - t) / MAX_LOCK_TIME
- `MAX_LOCK_TIME = 4 年`
- 当 `t ≥ lockEnd` 时，`veBalance = 0`

**示例：** 用户锁定 100 GOV 持续 4 年，初始 veBalance ≈ 100；2 年后衰减至 ≈ 50；到期时归零。

### 5.4 Boost 公式（Curve 式）
workingBalance = min(balance,0.4 × balance + 0.6 × totalLiquidity × (veBalance / veTotalSupply))
| 变量 | 含义 |
|------|------|
| `balance` | 用户在 Gauge 中质押的 LP 数量 |
| `totalLiquidity` | 该 Gauge 中所有用户质押的 LP 总量 |
| `veBalance` | 用户当前的 veGOV 余额 |
| `veTotalSupply` | veGOV 全局总供应量 |

**Boost 倍率** = `workingBalance / (0.4 × balance)`，取值范围 **[1.0, 2.5]**：

- 无 veGOV → `workingBalance = 0.4 × balance` → **1.0x**（基础收益）
- veGOV 占比 ≥ LP 占比 → `workingBalance = balance` → **2.5x**（满额加速）

### 5.5 奖励分配（Synthetix 累计模型）
rewardPerToken += rewardRate × Δt / workingSupply
earned(user) = user.workingBalance × (rewardPerToken - user.rewardDebt)
- `workingSupply` = 所有用户 `workingBalance` 之和（非原始 totalSupply）
- 当 `workingSupply = 0` 时，`rewardPerToken` 不更新（避免除零）

### 5.6 Gauge 相对权重
gaugeWeight[i] = Σ (voter.veBalance × voter.allocation[i] / 10000)
relativeWeight[i] = gaugeWeight[i] / Σ(gaugeWeight[j]) 对所有 j
- `allocation` 以基点（Basis Points）表示，10000 = 100%

### 5.7 手续费分红
claimable(user, epoch) = epochFees × (user.veBalance / epoch.veTotalSupply)
- 按周（epoch = 7 天）结算
- 仅可领取已结束的 epoch 的分红

---

## 6. 状态机

### 6.1 Pair 状态机
[空池] ──mint(首次)──→ [活跃池] ──swap()──→ [活跃池]（储备量变化）
│
├── mint() ──→ [活跃池]（流动性增加）
├── burn() ──→ [活跃池]（流动性减少）
└── burn(全部) ──→ [空池]（仅保留 MINIMUM_LIQUIDITY）
**规则：**

- R-AMM1：首次 mint 永久锁定 MINIMUM_LIQUIDITY（1000 wei）到零地址
- R-AMM2：swap 输出数量必须 > 0
- R-AMM3：swap 后 k 值不得减少（`reserve0_new × reserve1_new ≥ k_old`）
- R-AMM4：禁止向 Pair 合约自身地址转入 LP Token
- R-AMM5：mint / burn / swap 均加 reentrancy lock
- R-AMM6：协议费开启时，手续费的 1/6 铸造给 feeTo 地址

### 6.2 VotingEscrow 状态机
[无锁定] ──createLock()──→ [锁定中] ──(时间到期)──→ [已到期]
│ │
├── increaseAmount() ──→ [锁定中]（数量增加）
├── extendLock() ──→ [锁定中]（时间延长）
│ │
│ withdraw()
│ ↓
└─────────────────────→ [无锁定]
**规则：**

- R1：每个地址仅允许一个活跃锁定（禁止重复 createLock）
- R2：锁定时长约束：`MIN_LOCK_TIME (1周) ≤ duration ≤ MAX_LOCK_TIME (4年)`
- R3：lockEnd 向下取整到周边界：`lockEnd = (block.timestamp + duration) / WEEK * WEEK`
- R4：increaseAmount 仅在锁定未过期时可调用
- R5：extendLock 新到期必须晚于当前到期，且不超过从当前时间起 4 年
- R6：withdraw 仅在锁定过期后可调用
- R7：veToken 不可转让（合约不实现 transfer / transferFrom）

### 6.3 LiquidityGauge 状态机
[未质押] ──stake()──→ [已质押] ──unstake()──→ [未质押]
│
├── getReward() ──→ [已质押]（发放奖励，继续质押）
├── kick(user) ──→ [已质押]（强制更新 workingBalance）
└── exit() ──→ [未质押]（全部取出 + 领取奖励）
**规则：**

- R8：stake 数量必须 > 0
- R9：unstake 数量不得超过用户已质押余额
- R10：每次 stake / unstake / getReward 必须重新计算 workingBalance
- R11：kick 仅当目标用户 workingBalance 会降低时才成功执行
- R12：notifyRewardAmount 由外部排放管理器调用，注入新一轮奖励

### 6.4 GaugeController 状态机
[管理员] ── addGauge() ──→ 新增 Gauge（活跃状态）
[管理员] ── deactivateGauge() ──→ Gauge 停用（不再接受投票）

[投票者] ── voteForGauges() ──→ 分配投票权重至各 Gauge
[投票者] ── resetVotes() ──→ 清除该用户所有投票
**规则：**

- R13：仅 owner 可添加/停用 Gauge
- R14：投票要求 veBalance > 0
- R15：单个用户的投票分配总和 ≤ 10000（100%）
- R16：投票冷却期为 10 天（同一用户两次投票间隔不得少于 10 天）
- R17：投票时先清除旧权重，再写入新权重（原子操作）
- R18：已停用的 Gauge 不接受新投票

### 6.5 FeeDistributor 状态机
[Pair / 任何人] ── depositFees() ──→ 当前 epoch 累积手续费
[任何人] ── claimProtocolFee(pair) ──→ 从 Pair 提取协议费并存入当前 epoch
[veGOV 持有者] ── claim() ──→ 领取已完成 epoch 的分红
**规则：**

- R19：depositFees 数量必须 > 0
- R20：仅可领取已结束 epoch 的分红（当前 epoch 不可 claim）
- R21：同一 epoch 不可重复 claim（通过 lastClaimedEpoch 追踪）
- R22：若某 epoch 中用户 veBalance = 0 或全局 veTotalSupply = 0，则该 epoch 分红为 0

---

## 7. 合约接口

### 7.1 PairFactory

```solidity
contract PairFactory is Ownable {
    address public feeTo;
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address _feeTo) external onlyOwner;
    function allPairsLength() external view returns (uint256);
}
```
### 7.2 Pair

```solidity
contract Pair is ERC20("VeBoost LP", "vbLP") {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32  private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external;
    function sync() external;

    function getReserves() external view returns (uint112, uint112, uint32);
}
```
### 7.3 Router

```
contract Router {
    address public immutable factory;
    address public immutable WETH;

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut, uint256 amountInMax,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory amounts);

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256);
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256);
}
```

### 7.4 GovToken

```
contract GovToken is ERC20, Ownable {
    constructor(address initialHolder, uint256 initialSupply);
    function mint(address to, uint256 amount) external onlyOwner;
}
```

### 7.5 VotingEscrow

```
contract VotingEscrow {
    uint256 public constant MAX_LOCK_TIME = 4 * 365 days;
    uint256 public constant MIN_LOCK_TIME = 7 days;
    uint256 public constant WEEK = 7 days;

    function createLock(uint256 amount, uint256 duration) external;
    function increaseAmount(uint256 addedAmount) external;
    function extendLock(uint256 newDuration) external;
    function withdraw() external;

    function balanceOf(address user) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function getLock(address user) external view returns (uint256 amount, uint256 end);
}
```

### 7.6 GaugeController

```
contract GaugeController is Ownable {
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant VOTE_COOLDOWN = 10 days;

    function addGauge(address gauge) external onlyOwner returns (uint256 id);
    function deactivateGauge(uint256 id) external onlyOwner;

    function voteForGauges(uint256[] calldata gaugeIds, uint256[] calldata allocations) external;
    function resetVotes() external;

    function getGaugeRelativeWeight(uint256 gaugeId) external view returns (uint256);
    function getGaugeCount() external view returns (uint256);
}
```

### 7.7 LiquidityGauge

```
contract LiquidityGauge {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function getReward() external;
    function exit() external;

    function kick(address user) external;
    function notifyRewardAmount(uint256 amount, uint256 duration) external;

    function earned(address user) external view returns (uint256);
    function getBoostMultiplier(address user) external view returns (uint256);
    function workingBalanceOf(address user) external view returns (uint256);
    function workingSupply() external view returns (uint256);
}
```

### 7.8 FeeDistributor

```
contract FeeDistributor {
    function depositFees(uint256 amount) external;
    function claimProtocolFee(address pair) external;
    function claim() external returns (uint256 totalClaimed);

    function claimable(address user) external view returns (uint256);
    function currentEpoch() external view returns (uint256);
}
```

## 8. 安全考量

本项目在测试阶段将重点关注以下安全方向：

AMM 层：
- 确保 swap 后 k 值不被非法减少
- MINIMUM_LIQUIDITY 防止首存攻击与除零
- 所有核心操作添加重入防护（ReentrancyGuard）
- Router 的 deadline 过期必须 revert

VotingEscrow 层：
- 锁定期内不可提取（withdraw 必须 revert）
- 同一地址不可重复创建锁定
- 零值输入（amount = 0）必须拒绝
- veToken 不可转让

奖励层：
- workingBalance 不超过用户实际质押量（防 Boost 溢出）
- workingBalance 至少为 0.4 × 质押量（防奖励意外归零）
- 奖励池代币余额始终 ≥ 所有用户未领取奖励之和
- 同一 epoch 不可重复 claim

全局：
- 所有外部调用使用 ReentrancyGuard
- 关键状态变更前做权限与前置条件校验
- 使用 SafeERC20 处理代币转账

## 9. 具体的安全不变量断言与攻击场景测试用例将在合约实现与测试编写过程中逐步细化，并补充至本文档。

## 10.部署参数

|参数 |	默认值 | 说明 |
|----|----|----|
|GOV 初始供应|	100,000,000 × 10¹⁸	| 1 亿 GOV|
|MAX_LOCK_TIME|	4 × 365 days | 最长锁定 4 年|
|MIN_LOCK_TIME|	7 days | 最短锁定 1 周|
|WEEK|	7 days | epoch 长度与时间取整单位|
|VOTE_COOLDOWN|	10 days | 两次投票最短间隔|
|Boost 基础比例|	40%（0.4） | 无 veToken 时的有效质押占比|
|Boost 加速比例|	60%（0.6） | veToken 可贡献的最大额外占比|
|Swap 手续费率|	0.3%（3/1000） | 每笔交易的总手续费|
|协议费比例|	总手续费的 1/6 ≈ 0.05% | 流入 FeeDistributor|
|MINIMUM_LIQUIDITY|	1000 wei | 首次铸造永久锁定量|

## 11. 参考协议

|协议       | 核心参考内容|
|-----------|-----------|
|Uniswap V2| AMM 恒定乘积公式、LP Token 铸造/销毁、协议费机制|
|Curve Finance| veToken 线性衰减模型、Boost 公式、Gauge 投票|
|Synthetix  | StakingRewards  |
|Synthetix	StakingRewards | 累计奖励分配模型|
|Convex Finance	| Boost 代理思路（简化为直接持有 veToken）|

