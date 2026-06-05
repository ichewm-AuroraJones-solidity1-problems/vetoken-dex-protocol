# VeToken DEX Protocol

> 基于 ve(3,3) 机制的链上智能合约协议，集成 AMM、Router 滑点保护、TWAP 预言机、ve 治理与 Gauge 激励机制。
> 本仓库仅交付 Solidity / Foundry 合约、部署脚本、测试与链上运维脚本，不交付前端、Subgraph、索引器或监控平台。

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

---

## 目录

- [项目概述](#项目概述)
- [目标用户与交互流程](#目标用户与交互流程)
- [术语表](#术语表)
- [范围声明](#范围声明)
- [链上合约架构](#链上合约架构)
- [合约结构](#合约结构)
- [核心模块](#核心模块)
- [资产与权限流总图](#资产与权限流总图)
- [角色与权限定义](#角色与权限定义)
- [安全模型](#安全模型)
- [依赖策略](#依赖策略)
- [快速开始](#快速开始)
- [部署指南](#部署指南)
- [升级与迁移策略](#升级与迁移策略)
- [参数配置](#参数配置)
- [参数治理策略](#参数治理策略)
- [测试](#测试)
- [验收标准](#验收标准)
- [主网上线闸门](#主网上线闸门)
- [Gas 基准](#gas-基准)
- [数值精度与舍入策略](#数值精度与舍入策略)
- [链上运维手册](#链上运维手册)
- [贡献指南](#贡献指南)
- [许可证](#许可证)

---

## 项目概述

VeToken DEX 是一个 contracts-only 的 DeFi 协议项目，目标是在链上实现从交易、流动性、治理到激励分发的闭环，并以生产级智能合约工程标准组织设计、测试、部署、权限和运维边界。

| 组件 | 描述 | 本仓库交付 |
|---|---|:---:|
| AMM | Uniswap V2 风格恒定乘积做市商，默认 0.3% 交易手续费 | yes |
| Router | 交换、添加/移除流动性、多跳路由；仅 Router 入口提供 deadline 与金额边界保护 | yes |
| TWAP Oracle | 固定窗口 TWAP 预言机，基于累计价格机制 | yes |
| GovToken | ERC-20 治理代币，带供应上限与受控铸造 | yes |
| VotingEscrow | GOV 锁仓生成 veGOV，投票权随时间线性衰减 | yes |
| Gauge | LP 质押、Boost 奖励、按权重接收 GOV 排放 | yes |
| FeeDistributor | 将指定 rewardToken 按 ve 快照分配给 veGOV 持有人 | yes |

### 设计理念

```text
用户提供流动性 -> 获得 LP Token
LP Token 质押到 Gauge -> 获得 GOV 排放奖励
GOV 锁定到 VotingEscrow -> 获得 veGOV 投票权
veGOV 持有人投票决定 Gauge 权重 -> 引导排放方向
协议手续费经 FeeCollector 转换为 rewardToken -> FeeDistributor 分配给 veGOV 持有人
锁定时间越长 = 投票权越大 -> 对齐长期利益
```

---

## 目标用户与交互流程

### 目标用户

| 用户类型 | 目标 | 主要交互合约 |
|---|---|---|
| Trader | 使用 AMM 完成 token swap | Router、Pair |
| LP Provider | 提供流动性，获得交易手续费和 LP Token | Router、Pair |
| Gauge Staker | 质押 LP Token，获得 GOV 排放 | LiquidityGauge |
| GOV Holder | 锁定 GOV，获得 veGOV 投票权 | GovToken、VotingEscrow |
| veGOV Voter | 投票决定 Gauge 权重，引导排放方向 | GaugeController |
| Fee Claimer | 按 ve 快照领取协议手续费分红 | FeeDistributor |
| Keeper Operator | 触发周期性链上维护任务 | TwapOracle、GaugeController、Minter、EmissionManager、FeeCollector |
| Governance Operator | 通过 Timelock 执行参数和权限变更 | Governance Timelock |

### 用户交互流程

```text
Trader:
  approve tokenIn
  -> Router.swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline)
  -> Pair.swap

LP Provider:
  approve tokenA/tokenB
  -> Router.addLiquidity(...)
  -> receive LP Token

Gauge Staker:
  approve LP Token
  -> LiquidityGauge.deposit(amount)
  -> earned(user) accumulates GOV
  -> getReward() / withdraw() / exit()

GOV Holder:
  approve GOV
  -> VotingEscrow.createLock(amount, weekAlignedUnlockTime)
  -> receive non-transferable veGOV voting power

veGOV Voter:
  GaugeController.voteMany(gauges, weightsBps)
  -> votes affect nextEpoch weights
  -> EmissionManager distributes GOV by checkpointed weights

Fee Claimer:
  FeeDistributor.claim(user)
  -> receives rewardToken by historical ve snapshot
```

### 经济闭环

```text
Swap fees:
  Trader pays 0.30%
  -> LPs receive fee through reserve growth
  -> if feeTo is on, protocol receives LP Token share
  -> FeeCollector converts LP Token to rewardToken
  -> FeeDistributor pays veGOV holders by weekly snapshot

GOV emissions:
  Minter computes weeklyEmission
  -> GovToken.mint(EmissionVault)
  -> EmissionManager distributes to Gauges by GaugeController weights
  -> LP stakers receive GOV by working balance
  -> users may lock GOV into VotingEscrow for veGOV
```

风险边界：

- Trader 的滑点参数只限制最差成交，不阻止三明治交易发生。
- LP Provider 承担无常损失、低流动性价格操纵和不支持特殊 token 的风险。
- Gauge Staker 的 Boost 是存储会计值，可能被 `kick` 刷新。
- veGOV Voter 的投票只影响未来 epoch，不回溯改变已开始排放。

---

## 术语表

| 术语 | 统一含义 |
|---|---|
| GOV | 协议治理 ERC-20 代币，由 GovToken 合约发行 |
| GovToken | GOV 的 ERC-20 合约，包含 cap 和受控 mint |
| VotingEscrow | GOV 锁仓合约，产生不可转让的 veGOV 投票权 |
| veGOV | 锁仓 GOV 后得到的 account-based voting power，不是 ERC-20 或 ERC-721 |
| veToken | 泛指 ve 模型时使用；本文具体实现统一称为 veGOV |
| LP Token | Pair 铸造的 ERC-20 流动性份额 |
| Pair | 恒定乘积 AMM 池子合约 |
| Router | 用户推荐入口，提供 deadline、amount bounds 和路径校验 |
| TWAP Oracle | 固定窗口累计价格预言机，合约名为 TwapOracle |
| Gauge | LiquidityGauge，LP Token 质押和 GOV 奖励分发合约 |
| GaugeController | Gauge 权重投票和 epoch 权重 checkpoint 合约 |
| Minter | 每周计算并 mint GOV 到 EmissionVault 的合约 |
| EmissionVault | GOV 排放资金保管合约 |
| EmissionManager | 按 Gauge 权重调度 GOV 分发的合约 |
| FeeCollector | 收集协议费 LP、退出并兑换为 rewardToken 的合约 |
| FeeDistributor | 按 veGOV 历史快照分发 rewardToken 的合约 |
| rewardToken | FeeDistributor 分红资产，单一 ERC-20 |
| epoch | 周期单位，v1 固定为 1 周 |
| weekTs | 某个 epoch 的周起点时间戳 |
| bps | basis points，10000 bps = 100% |

本文不使用 `OracleSimple` 或 `ExampleOracleSimple` 作为合约名；预言机统一称为 TwapOracle。

---

## 范围声明

### In Scope（本仓库交付）

- Solidity 合约：AMM、Router、Oracle、Governance、Incentives、Fee collection。
- Foundry 工程：编译、测试、部署、验证脚本。
- 链上运维脚本：oracle update、gauge checkpoint、fee checkpoint、emission distribution。
- 合约安全模型、不变量、权限边界与参数配置。

### Out of Scope（本仓库不交付）

- 任何非智能合约系统，包括前端、Subgraph、索引器、监控平台和后端服务。
- 做市运营执行、市场运营活动和外部安全服务落地。

### 边界说明

本 README 只描述智能合约协议、测试、部署和链上运维脚本；不编写前端、Subgraph、索引器或监控系统 PRD。

---

## 链上合约架构

```text
                       +-------------+
                       |   Router    | <- deadline / amount bounds
                       +------+------+ 
                              |
           +------------------+------------------+
           |                  |                  |
    +------v-------+   +------v-------+   +------v-------+
    |  Pair (A/B)  |   |  Pair (B/C)  |   |  Pair (A/C)  |
    +------+-------+   +--------------+   +--------------+
           |
    +------v-------+
    | TwapOracle   | <- TWAP price feed
    +--------------+

    +--------------+      +----------------+      +-----------------+
    |   GovToken   +----->|  VotingEscrow  +----->| GaugeController |
    +--------------+      |    (veGOV)     |      +--------+--------+
                          +-------+--------+               |
                                  |                        |
                          +-------v--------+        +------v---------+
                          | FeeDistributor |        | LiquidityGauge |
                          +-------^--------+        |  per LP pair   |
                                  |                 +------^---------+
                                  |                        |
                          +-------+--------+               |
                          | FeeCollector   |               |
                          +-------^--------+               |
                                  |                        |
    PairFactory feeTo ------------+                        |
                                                           |
                     reads ve balance for boost <----------+

    Minter -> EmissionVault -> EmissionManager -> LiquidityGauge
```

本图只描述链上合约关系，不包含前端、索引器或监控平台设计。

---

## 合约结构

```text
src/
├── amm/
│   ├── Pair.sol
│   ├── PairFactory.sol
│   ├── Router.sol
│   └── interfaces/
│       ├── IPair.sol
│       ├── IPairFactory.sol
│       └── IRouter.sol
├── oracle/
│   ├── TwapOracle.sol
│   └── interfaces/
│       └── ITwapOracle.sol
├── governance/
│   ├── GovToken.sol
│   ├── VotingEscrow.sol
│   └── interfaces/
│       ├── IGovToken.sol
│       └── IVotingEscrow.sol
├── incentives/
│   ├── GaugeController.sol
│   ├── LiquidityGauge.sol
│   ├── Minter.sol
│   ├── EmissionVault.sol
│   ├── EmissionManager.sol
│   ├── FeeCollector.sol
│   ├── FeeDistributor.sol
│   └── interfaces/
│       ├── IGaugeController.sol
│       ├── ILiquidityGauge.sol
│       ├── IEmissionManager.sol
│       ├── IFeeCollector.sol
│       └── IFeeDistributor.sol
└── libraries/
    ├── UQ112x112.sol
    ├── Math.sol
    └── SafeCast.sol
script/
├── Deploy.s.sol
├── DeployTestnet.s.sol
├── helpers/
│   └── DeployConfig.sol
└── keeper/
    ├── UpdateOracle.s.sol
    ├── CheckpointGauge.s.sol
    ├── DistributeEmission.s.sol
    └── CheckpointFees.s.sol
test/
├── unit/
├── integration/
└── invariant/
```

---

## 核心模块

### 1. AMM 模块

#### Pair.sol

恒定乘积自动化做市商，核心公式为 `x * y = k`。

| 函数 | 描述 |
|---|---|
| `mint(to)` | 存入 token0 / token1，铸造 LP Token |
| `burn(to)` | 销毁 LP Token，取回 token0 / token1 |
| `swap(amount0Out, amount1Out, to)` | 执行交换，包含手续费与 k 值校验 |
| `skim(to)` | 将余额中超过储备量的部分转出 |
| `sync()` | 将储备量同步为当前余额 |

swap k 值校验：

```text
reserve0Before, reserve1Before = swap 前记录的储备
balance0After, balance1After = token 转入/转出后的实际余额
amount0In, amount1In = 根据 balanceAfter 与 reserveBefore 反推的输入量

balance0Adjusted = balance0After * 1000 - amount0In * 3
balance1Adjusted = balance1After * 1000 - amount1In * 3

要求:
balance0Adjusted * balance1Adjusted
  >= reserve0Before * reserve1Before * 1000^2
```

这里的 k 校验不是“新 reserve 乘积 >= 旧 reserve 乘积”的朴素比较，而是用扣除 0.30% 手续费后的 adjusted balance 与 swap 前 reserve 乘积比较。`sync()`、`skim()`、`mint()`、`burn()` 有各自的 reserve 更新语义，不使用该 swap k 校验表达式。

AMM 兼容边界：

| 项目 | 规则 |
|---|---|
| token 排序 | `token0 < token1`，按地址升序排序 |
| Pair 地址 | PairFactory 使用 CREATE2，`pair = address(hash(factory, salt(token0, token1), initCodeHash))` |
| 重复交易对 | 同一 `token0/token1` 只能创建一个 Pair |
| LP Token 名称 | `VeToken DEX LP`，symbol 固定为 `vLP`，decimals 固定为 18 |
| 原生 ETH | v1 不支持 native ETH 用户入口；用户必须自行将 ETH wrap 为 WETH 后按 ERC-20 使用 |
| fee-on-transfer token | v1 不支持。Pair/Router 假设转入数量等于用户指定数量 |
| rebasing token | v1 不支持。余额自动变化会破坏 reserve 与价格累计语义 |
| ERC777 / callback token | v1 不支持；生产 allowlist 不接入带 token callback 的资产 |
| 非标准 ERC-20 | 只兼容返回值缺失但行为标准的 ERC-20；不兼容恶意 token |
| token allowlist | v1 生产部署启用 PairFactory token allowlist，只有 Timelock 白名单 token 可创建 Pair |
| 小数位 | 不要求固定 18 decimals，所有计算按 token 原始最小单位执行 |

特殊 token 拒绝规则：

- PairFactory 必须在生产部署中启用 token allowlist。
- 只有 Governance Timelock 白名单中的 ERC-20 才能创建 Pair。
- `mapping(address => bool) public tokenAllowed` 记录 token 白名单状态。
- `setTokenAllowed(token, allowed)` 只能由 Governance Timelock 调用，并发出 `TokenAllowedUpdated(token, allowed)`。
- `createPair(tokenA, tokenB)` 必须要求 `tokenAllowed[tokenA] && tokenAllowed[tokenB]`。
- 默认拒绝 fee-on-transfer、rebasing、ERC777 callback、blacklist、pausable、tax token 和 decimals 极端异常 token。
- 如果已白名单 token 后续暴露异常，治理必须停止新增 Gauge 激励，并通过迁移流程引导退出相关 Pair。
- token delist 后禁止新建 Pair 和新增 Gauge，但不暂停已有 Pair 的 `swap/mint/burn`，用户仍可移除流动性。

协议手续费规则：

| 项目 | 规则 |
|---|---|
| 交易手续费 | 0.30%，即 `amountIn * 3 / 1000` |
| LP 手续费 | 默认全部进入 LP 储备，表现为 k 增长 |
| 协议费开关关闭 | `feeTo == address(0)`，不铸造协议费 LP |
| 协议费开关开启 | `feeTo != address(0)`，Pair 按 Uniswap V2 `_mintFee` 语义铸造协议费 LP |
| 协议费份额 | 协议收取 LP 手续费增长量的 1/6，约等于成交额的 0.05%；LP 保留约 0.25% |
| 开启权限 | `PairFactory.setFeeTo(feeCollector)`，仅 Governance Timelock 可执行 |
| 累计资产 | 协议费先以 Pair LP Token 累计到 FeeCollector |
| 分红资产 | FeeCollector 将 LP 退出并兑换为 FeeDistributor 的 `rewardToken` |
| checkpoint | FeeDistributor 按周 `tokensPerWeek[weekTs]` checkpoint rewardToken |

#### Router.sol

Router 是面向普通用户和外部调用方的推荐入口，负责在调用 Pair 前执行交易意图保护。

| Router 层保护 | 说明 |
|---|---|
| deadline | 避免过期交易被执行 |
| amount bounds | `amountOutMin`、`amountInMax`、`amountAMin`、`amountBMin` |
| path validation | 校验路径长度、交易对存在性和收款地址 |

Pair 的 k 值校验不是 Router 独有保护，而是 Pair 自身的 AMM 不变量。任何地址直接调用 Pair 仍会受到 k 值和手续费数学约束，但不会自动获得 Router 的 deadline、`amountOutMin`、`amountInMax` 等用户意图保护。

| 调用路径 | deadline | amount bounds | Pair k 值校验 |
|---|:---:|:---:|:---:|
| `Router.addLiquidity` | yes | yes | no |
| `Router.removeLiquidity` | yes | yes | no |
| `Router.swapExactTokensForTokens` | yes | yes | yes |
| `Router.swapTokensForExactTokens` | yes | yes | yes |
| 直接调用 `Pair.swap` | no | no | yes |

集成方安全边界：

- 用户交易、脚本交易和聚合器交易应优先走 Router。
- 如果外部合约直接调用 Pair，必须自行实现 deadline、滑点限制、报价校验和 MEV 风险控制。
- Pair 只保证池子不会被违反 AMM 数学约束的 swap 抽干，不保证调用者获得预期价格。

### 2. 预言机模块

#### TwapOracle.sol

固定窗口 TWAP 预言机，基于 Uniswap V2 累计价格机制。TWAP 只能降低短周期价格操纵风险，不能保证价格不可操纵；其安全性取决于池子流动性、窗口长度、攻击者资金成本、手续费成本和初始化阶段的价格质量。

| 属性 | 默认值 |
|---|---|
| 时间窗口 | `PERIOD = 24 hours`，部署后不可变 |
| 过期阈值 | `stalenessThreshold = 2 * PERIOD`，部署后不可变 |
| 更新权限 | 无需许可，任何人可调用 |
| 初始化规则 | 部署后记录初始快照，至少等待一个 PERIOD 后首次有效 update |
| 查询方式 | `consult(tokenIn, amountIn)` |
| 流动性门槛 | 每个 pair 配置 `minReserve0` / `minReserve1`，低于门槛时 update 和 consult 均 revert |

状态机：

```text
部署
  -> WAITING_FIRST_PERIOD
  -> update() before PERIOD: revert PERIOD_NOT_ELAPSED
  -> update() after PERIOD: READY
  -> no update for stalenessThreshold: STALE
  -> update() after PERIOD: READY
```

API：

| 函数 | 描述 |
|---|---|
| `update()` | 达到 PERIOD 后刷新累计价格快照和平均价格 |
| `consult(tokenIn, amountIn)` | 查询 TWAP 报价；未 ready 或 stale 时应 revert |
| `isReady()` | 是否至少完成一次有效 TWAP 初始化 |
| `isStale()` | 当前价格是否超过 `stalenessThreshold` 未更新 |
| `lastUpdated()` | 最近一次有效更新的时间戳 |
| `period()` | TWAP 窗口长度 |
| `stalenessThreshold()` | stale 判定阈值 |
| `minReserve0()` / `minReserve1()` | 当前 Oracle 对应 pair 的最小 reserve 门槛 |
| `hasSufficientLiquidity()` | 当前 reserve 是否满足最小流动性门槛 |

最小流动性门槛：

| 项目 | 规则 |
|---|---|
| 检查位置 | `TwapOracle.update()`、`TwapOracle.consult()`、`FeeCollector.harvest()` 的 route 检查 |
| 检查对象 | Oracle 绑定 pair 的 `reserve0` 和 `reserve1` |
| 单位 | token0/token1 最小单位，不做 decimals 归一化 |
| 默认值 | 部署配置必须显式填写，不能默认为 0 后上线 |
| 权限 | Governance Timelock 可修改，必须发出 `MinReserveUpdated(pair, old0, old1, new0, new1)` |
| 生效 | 下一次 `update()` / `consult()` / `harvest()` 立即生效 |

- `reserve0 < minReserve0` 或 `reserve1 < minReserve1` 时，Oracle 必须返回低流动性状态，`consult()` 和依赖该 Oracle 的 FeeCollector swap 必须 revert。
- 新 pair 上线前必须在 DeployConfig 中记录 min reserve，且 fork 测试覆盖低于门槛时的 revert。
- min reserve 是 TWAP 风险缓解，不是价格安全保证；低流动性、短窗口或初始化阶段仍不能作为强安全价格源。

设计局限：

- 不适用于借贷清算等要求强安全价格源的场景。
- 价格延迟至少一个 PERIOD，且如果 keeper 停止更新会进入 stale。
- 需要 keeper 或任意外部调用方定期触发 `update()`。
- 低流动性池、刚初始化的池、长时间未交易的池仍可能产生不可靠 TWAP。
- `isReady() == true` 只代表完成过首次有效更新，不代表当前价格仍然新鲜；集成方必须同时检查 `isStale() == false`。

TWAP 数学边界：

```text
price0Average = (price0CumulativeEnd - price0CumulativeStart) / timeElapsed
price1Average = (price1CumulativeEnd - price1CumulativeStart) / timeElapsed
```

`price0Average` 与 `price1Average` 只能在以下前置条件下近似互为倒数：

- 同一个 Pair、同一个 `[start, end]` 窗口、同一个 `timeElapsed`。
- 窗口内 reserve0 和 reserve1 均非零。
- 两个价格使用相同 UQ112x112 精度解释。
- 允许整数除法、定点数截断和累计值溢出差分带来的舍入误差。
- 如果窗口内存在多次 reserve 变化，两个 TWAP 是时间加权平均价格，不要求与窗口结束时 spot price 互逆。

### 3. 治理模块

#### GovToken.sol

标准 ERC-20 治理代币，带供应上限和受控铸造权限。

| 特性 | 描述 |
|---|---|
| 代币符号 | GOV，部署时配置 |
| 最大供应量 | 强制上限 |
| 铸造权限 | 仅授权 minter |
| 转账限制 | 无限制 |

##### 代币经济模型

| 项目 | 规则 |
|---|---|
| 最大供应量 | `GOV_TOKEN_CAP`，默认 `1,000,000,000 GOV` |
| 初始铸造 | `INITIAL_MINT = GOV_TOKEN_CAP * 40%`，默认 `400,000,000 GOV` |
| 初始接收方 | InitialAllocationVault / Treasury Timelock，不直接进入 Gauge |
| 排放来源 | Minter 每周 mint 到 EmissionVault |
| 排放频率 | 每周 epoch 一次，`Minter.updatePeriod()` 计算 `weeklyEmission` |
| 排放曲线 | v1 使用衰减周排放，`decayBps = 9900`，每周排放按 99% 衰减 |
| 通胀上限 | 任意 mint 后 `totalSupply <= GOV_TOKEN_CAP` |
| cap 达到后 | `weeklyEmission = 0`，Gauge 不再获得新增 base emission；只可分发 Vault 已有余额或历史 debt |
| 多余余额 | EmissionVault 中未分发 GOV 优先用于后续 epoch 和历史 debt 偿还；转入 treasury 只能由 Timelock 单独执行 |
| 紧急补发 | 不允许部署者直接 mint/notify；必须走治理授权的 Minter/EmissionManager |
| Timelock | Minter、EmissionManager、FeeCollector route、feeTo、Gauge 管理等高权限操作必须由 Governance Timelock 执行，DAO Multisig 作为 proposer/canceller |

供应量预算：

以下比例的基数是 `GOV_TOKEN_CAP`，不是 `INITIAL_MINT`。

| 类别 | 比例 | 锁定/释放 |
|---|---:|---|
| Liquidity Mining Reserve | 60% | 不在部署时预铸造；由 Minter 按周 mint 到 EmissionVault 后释放 |
| Treasury / DAO | 20% | 属于 `INITIAL_MINT`，部署时铸造到 InitialAllocationVault / Treasury Timelock |
| Team / Contributors | 10% | 属于 `INITIAL_MINT`，至少 1 年 cliff，线性释放 |
| Ecosystem / Partners | 5% | 属于 `INITIAL_MINT`，线性释放或治理拨款 |
| Initial Liquidity / Market Making | 5% | 属于 `INITIAL_MINT`，用于初始 GOV/WETH 等池子 |

`INITIAL_MINT` 只包含非 Liquidity Mining 的 40% 预算，即 Treasury / DAO、Team / Contributors、Ecosystem / Partners、Initial Liquidity / Market Making 四类之和。Liquidity Mining Reserve 的 60% 属于未来排放预算，不计入 `INITIAL_MINT`，不得在部署时预铸造。

以上比例是 PRD 默认值；正式部署前必须在 DeployConfig 中固化，部署后不得由单一 EOA 修改。

排放曲线选项：

```text
衰减周排放:
  weeklyEmission = previousWeeklyEmission * decayBps / 10000
  decayBps = 9900

cap 约束:
  weeklyEmission = min(weeklyEmission, GOV_TOKEN_CAP - totalSupply)
```

Minter 幂等规则：

| 状态 | 含义 |
|---|---|
| `activePeriod` | 最近一次成功 mint 的 epoch 起点 |
| `isMinted[epoch]` | 指定 epoch 是否已经执行过 mint |
| `emissionForEpoch[epoch]` | 指定 epoch 固化后的 `weeklyEmission` |
| `lastMintedAt` | 最近一次成功 mint 的区块时间 |

- `Minter.updatePeriod()` 是 permissionless，但必须严格幂等。
- `epoch = floor(block.timestamp / WEEK) * WEEK`。
- 若 `isMinted[epoch] == true`，`updatePeriod()` 必须直接返回或 revert 为 `AlreadyMinted(epoch)`，不得再次 mint。
- 成功路径必须按 Checks-Effects-Interactions：先设置 `isMinted[epoch] = true`、`activePeriod = epoch`、`emissionForEpoch[epoch] = weeklyEmission`，再调用 `GovToken.mint(emissionVault, weeklyEmission)`。
- `weeklyEmission == 0` 时也必须标记 `isMinted[epoch] = true`，防止同一 epoch 被重复尝试并产生不一致事件。
- 同一 epoch 的 `EmissionManager.finalizeEmission(epoch)` 只能读取已固化的 `emissionForEpoch[epoch]`，不得自行重新计算排放。

#### VotingEscrow.sol

锁定 GOV 代币 1 周到 4 年，获得随时间线性衰减的 veGOV 投票权。

```text
投票权 = 锁定数量 * 剩余锁定时间 / 最大锁定时间
```

| 函数 | 描述 |
|---|---|
| `createLock(amount, unlockTime)` | 创建锁仓 |
| `increaseAmount(amount)` | 追加锁仓数量 |
| `increaseUnlockTime(newUnlockTime)` | 延长锁仓时间 |
| `withdraw()` | 到期后提取 GOV |
| `balanceOf(account)` | 当前投票权 |
| `totalSupply()` | 当前实时 veGOV 总量 |
| `balanceOfAt(account, timestamp)` | 查询历史快照点的用户 veGOV，只用于 `timestamp <= block.timestamp` |
| `votingPowerAt(account, epoch)` | 查询当前已 checkpoint 锁仓在未来 epoch 的确定性投票权预测 |
| `totalSupplyAt(timestamp)` | 查询历史快照点的全局 veGOV 总量 |

锁仓模型：

| 项目 | v1 规则 |
|---|---|
| 锁仓数量 | 每个地址最多一笔 active lock |
| 多笔锁仓 | 不支持多笔独立锁；追加金额使用 `increaseAmount` |
| unlockTime 对齐 | 必须满足 `unlockTime % WEEK == 0`；不自动 floor 或 ceil，未对齐直接 revert |
| 最小锁定 | `unlockTime >= currentWeek + 1 WEEK` |
| 最大锁定 | `unlockTime <= currentWeek + MAX_LOCK_TIME` |
| 延长锁仓 | 只能延长，不能缩短 |
| 追加金额 | 只能在未过期 active lock 上追加 |
| 提前退出 | v1 不支持提前退出和罚金退出 |
| 到期提取 | `block.timestamp >= unlockTime` 后可 `withdraw()` |
| ve 形态 | account-based voting power，不是可转让 ERC-20 |
| veNFT | v1 不实现 ERC-721 veNFT |
| 转让 | veGOV 不可转让、不可 approve、不可 delegate transfer |
| 合约锁仓 | 允许合约锁仓，但集成方自行处理治理/领取权限 |

边界规则：

- `createLock` 要求用户没有 active lock；如果已有锁仓，必须使用 `increaseAmount` 或 `increaseUnlockTime`。
- `withdraw` 后该用户锁仓清零，可重新 `createLock`。
- `balanceOf(account)` 对过期锁返回 0，即使用户尚未 withdraw。
- `totalSupply()` 不包含已过期锁的 ve 权重，但底层 GOV 仍留在 VotingEscrow 直到用户 withdraw。
- 所有 lock 变更必须写入 user point 和 global point checkpoint，供 `balanceOfAt/totalSupplyAt` 历史查询与 `votingPowerAt` 未来投票权预测使用。

总供应量语义：

- `balanceOf(account)` 和 `totalSupply()` 表示当前区块时间下的实时线性衰减结果。
- 在数学定义上，`totalSupply()` 应等于所有未到期锁仓实时 ve 余额之和；实现中应通过全局 checkpoint 或 slope/bias 聚合计算该值，而不是依赖遍历用户。
- `balanceOfAt(account, timestamp)` 与 `totalSupplyAt(timestamp)` 只用于历史查询、FeeDistributor 和治理核对；当 `timestamp > block.timestamp` 时必须 revert，避免把历史快照 API 用作未来预测 API。
- `votingPowerAt(account, epoch)` 用于 GaugeController 未来 epoch 投票权计算，允许查询 `epoch >= block.timestamp`，但只基于当前已经 checkpoint 的 `lockedAmount`、`unlockTime`、slope/bias 线性预测。
- `votingPowerAt` 不包含尚未发生的未来 `increaseAmount`、`increaseUnlockTime` 或 `withdraw`；这些操作只有在真实交易执行并写入 checkpoint 后，才影响尚未冻结和未 checkpoint 的未来 epoch。
- 如果 `unlockTime <= epoch`，`votingPowerAt(account, epoch)` 返回 0。
- 因整数除法、周对齐和 checkpoint 延迟，测试应允许最小舍入误差；不应同时写成“严格等于”和“小于等于”两种不兼容语义。

### 4. 激励模块

#### GaugeController.sol

基于 veGOV 投票管理 Gauge 权重。GaugeController 只负责登记 Gauge、接收投票、固化每周权重；它不持有 GOV、不转账 GOV，也不调用 Gauge 的 `notifyRewardAmount`。

每个 epoch 固化权重后，EmissionManager 根据权重向各 Gauge 注入 GOV 奖励。

```text
gaugeAmount = weeklyEmission * gaugeWeight / totalWeight
```

##### 投票规则

| 规则 | 设计 |
|---|---|
| epoch 长度 | 1 周，`WEEK = 7 days` |
| 周边界 | `epochStart = floor(block.timestamp / WEEK) * WEEK` |
| 生效时间 | 本周投票默认从下一周 `epochStart + WEEK` 生效 |
| 投票权来源 | 使用投票生效 epoch 起点的确定性 ve 预测值 |
| 固定实现 | `VotingEscrow.votingPowerAt(user, nextEpoch)`，由已 checkpoint 的 lock slope/bias 计算，不使用分发或领取时当前余额 |
| 权重单位 | basis points，`MAX_VOTE_WEIGHT = 10000` |
| 多 Gauge 分配 | 用户可把 10000 bps 拆分给多个 Gauge |
| 归一化 | 用户所有 active gauge 的投票权重之和 `<= 10000` |
| 改票 | 允许改票，但同一用户同一 Gauge 受冷却期限制 |
| 撤票 | 支持 `reset(gauge)` 或 `resetAll()`，释放已占用 bps |
| 冷却期 | `VOTE_DELAY = 10 days`，防止同一投票权频繁跨池切换 |
| 禁用 Gauge | killed gauge 不能接收新投票，下一生效周权重归零；用户可无视冷却期撤销该 Gauge 投票 |
| 权重为 0 | 合法，表示该 Gauge 本周不分配 base emission |

投票数据结构：

| 数据 | 含义 |
|---|---|
| `voteWeight[user][gauge]` | 用户分配给某 Gauge 的 bps |
| `usedVoteWeight[user]` | 用户已使用的总 bps，最大 10000 |
| `lastVoted[user][gauge]` | 用户上次修改该 Gauge 投票的时间 |
| `gaugeVoters[gauge]` | 曾经给该 Gauge 投票的用户列表，用于分页 checkpoint |
| `hasVotedGauge[gauge][user]` | 防止同一用户重复加入 `gaugeVoters` |
| `pendingVote[user][gauge][epoch]` | 指定生效周的用户 bps 配置 |
| `isCheckpointed[gauge][epoch]` | 某 Gauge 在指定 epoch 是否已完成分页权重固化 |
| `checkpointCursor[gauge][epoch]` | 某 Gauge 在指定 epoch 已处理到的 voter 下标 |
| `gaugeWeight[gauge][epoch]` | 某 Gauge 在指定周的有效 ve 权重 |
| `totalWeight[epoch]` | 指定周所有 active gauge 的有效 ve 权重之和 |
| `isGauge[gauge]` | Gauge 是否已登记 |
| `isKilled[gauge]` | Gauge 是否被禁用 |

投票计算：

```text
nextEpoch = floor(block.timestamp / WEEK) * WEEK + WEEK
require(block.timestamp < nextEpoch - VOTE_FREEZE_WINDOW)
require(!isEpochCheckpointing[nextEpoch])
require(!isEpochCheckpointed[nextEpoch])

userVe = VotingEscrow.votingPowerAt(user, nextEpoch)
newGaugePower = userVe * weightBps / 10000

require(isGauge[gauge] && !isKilled[gauge])
require(weightBps <= 10000)
require(usedVoteWeight[user] - oldWeightBps + weightBps <= 10000)
require(block.timestamp >= lastVoted[user][gauge] + VOTE_DELAY)

pendingVote[user][gauge][nextEpoch] = weightBps
usedVoteWeight[user] = usedVoteWeight[user] - oldWeightBps + weightBps
```

撤票计算：

```text
targetEpoch = firstEpochNotFrozen()
oldWeightBps = voteWeight[user][gauge]

if isKilled[gauge]:
  // killed Gauge 不再产生新增 base emission，允许用户立即释放被占用 bps
  skip VOTE_DELAY
else:
  require(block.timestamp >= lastVoted[user][gauge] + VOTE_DELAY)

voteWeight[user][gauge] = 0
pendingVote[user][gauge][targetEpoch] = 0
usedVoteWeight[user] -= oldWeightBps
lastVoted[user][gauge] = block.timestamp
```

checkpoint 实现规则：

- 投票和 checkpoint 分离：`vote()` 只写入 `pendingVote`，不得在同一调用中执行 `checkpointGauge()`。
- `VOTE_FREEZE_WINDOW = 6 hours`，目标 epoch 开始前 6 小时进入冻结窗口。
- 冻结窗口开始后，任何影响该 `nextEpoch` 的 `vote/reset/voteMany` 必须 revert。
- `checkpointGauge(gauge, epoch, start, limit)` 只能在 `block.timestamp >= epoch - VOTE_FREEZE_WINDOW` 后执行。
- `checkpointGauge(gauge, epoch, start, limit)` 分页重算指定 Gauge 在指定 epoch 的有效权重。
- 每次重算使用 `VotingEscrow.votingPowerAt(user, epoch)` 与用户对该 Gauge 在该 epoch 生效的 bps。
- `limit` 主网默认最大 100 个 voter，防止单笔交易 gas 超限。
- 当 `checkpointCursor[gauge][epoch] == gaugeVoters[gauge].length` 时，标记 `isCheckpointed[gauge][epoch] = true`。
- 任一 Gauge 开始 checkpoint 后，`isEpochCheckpointing[epoch] = true`，该 epoch 的投票配置不可再修改。
- 所有 active Gauge 完成 checkpoint 后，Keeper 调用 `finalizeEpoch(epoch)`，设置 `isEpochCheckpointed[epoch] = true`。
- EmissionManager 固化或分发某个 epoch 前，必须验证 `isEpochCheckpointed[epoch] == true`。
- 如果存在未 checkpoint 的 active gauge，`GaugeController.finalizeEpoch(epoch)` 必须 revert；EmissionManager 不得将未 checkpoint gauge 当作 0 权重跳过。
- 用户可调用 `poke(user, gauges[])` 主动刷新自己未来 epoch 的投票权；Keeper 仍需执行分页 checkpoint 作为最终固化。

跨周规则：

- 本周 `N` 的投票不会改变已开始的本周排放，只影响 `N + 1` 或更晚的 epoch。
- 用户只能在目标 epoch 冻结窗口开始前修改该 epoch 的投票；checkpoint 开始后不得通过新投票 invalidated 已固化权重。
- 如果用户 veGOV 在下一周快照前衰减，`checkpointGauge()` 必须按 `votingPowerAt(user, nextEpoch)` 重新计算有效投票权。
- 如果用户延长锁仓或增加锁仓，新增 ve 只影响后续投票或后续 checkpoint，不回溯修改已分发 epoch。
- `checkpointGauge` 不盲目复制上一周权重，必须按 voter 在目标 epoch 的确定性 ve 预测值重算。
- `usedVoteWeight[user]` 表示用户对第一个未冻结未来 epoch 的当前 bps 配置，不用于回写已经 checkpoint 或已经分发的历史 epoch。
- `killGauge(gauge)` 不遍历所有 `gaugeVoters[gauge]` 自动释放 bps，避免治理交易 gas 不可控。
- 用户对 killed Gauge 调用 `reset(gauge)` 或 `resetAll()` 时，不受 `VOTE_DELAY` 限制，并从第一个未冻结未来 epoch 起释放 `usedVoteWeight`。
- 如果目标 epoch 已进入冻结窗口，释放只写入下一个未冻结 epoch；已经 checkpoint、finalized 或已分发的 epoch 不回溯修改。

Gauge bootstrap 规则：

- `addGauge` 只登记 Gauge，不设置治理权重。
- 新 Gauge 初始 `gaugeWeight == 0`，必须由 veGOV 用户投票后，才可在未冻结的后续 epoch 获得排放。
- Governance Timelock 不能直接写入 `gaugeWeight[gauge][epoch]` 或 `totalWeight[epoch]`，避免绕过 ve 投票模型。
- 如需启动初始流动性，必须由 DAO / Treasury 持有的 veGOV 账户按普通投票流程投票，且同样受 `VOTE_DELAY`、冻结窗口和 checkpoint 规则约束。

Gauge 生命周期：

| 状态 | 行为 |
|---|---|
| active | 可投票、可 checkpoint、可获得排放 |
| killed | 不接受新投票，下一生效周权重为 0，不获得新增 base emission；用户可免冷却释放该 Gauge 占用的 bps |
| revived | 治理恢复后可重新接受投票，但不会自动恢复历史权重 |
| removed | v1 不物理删除 Gauge；保留历史数据用于核对和 claim |

函数接口：

| 函数 | 描述 |
|---|---|
| `addGauge(gauge)` | 治理添加 Gauge，新 Gauge 初始权重为 0 |
| `killGauge(gauge)` | 治理禁用 Gauge |
| `reviveGauge(gauge)` | 治理恢复 Gauge |
| `vote(gauge, weightBps)` | 用户给单个 Gauge 设置 bps |
| `voteMany(gauges, weightsBps)` | 用户一次性分配多个 Gauge |
| `reset(gauge)` | 用户撤销某 Gauge 投票 |
| `resetAll()` | 用户撤销全部投票 |
| `checkpointGauge(gauge, epoch, start, limit)` | 分页固化某 Gauge 在指定 epoch 的有效权重 |
| `checkpointAll(gauges, epoch, limitPerGauge)` | 批量 checkpoint，内部仍按 Gauge 分页 |
| `finalizeEpoch(epoch)` | 所有 active Gauge checkpoint 完成后固化整个 epoch |
| `poke(user, gauges[])` | 用户或 Keeper 主动刷新用户未来 epoch 的投票权 |
| `gaugeRelativeWeight(gauge, epoch)` | 查询 `gaugeWeight / totalWeight` |

#### LiquidityGauge.sol

LP Token 质押合约，支持 Boost 收益增强与流式奖励分发。

```text
workingBalance = min(
  0.4 * userLpBalance + 0.6 * totalLpStaked * veUser / veTotal,
  userLpBalance
)

boost = workingBalance / (0.4 * userLpBalance)
```

说明：

- `userLpBalance` 是用户在该 Gauge 中质押的 LP 数量。
- `totalLpStaked` 是该 Gauge 中所有用户质押的 LP 总量。
- `veUser` 是用户当前 veGOV 余额。
- `veTotal` 是全局 veGOV 总供应量。
- 当 `veTotal == 0` 时，直接使用基础 working balance：`workingBalance = 0.4 * userLpBalance`，避免除零。
- 当 `userLpBalance == 0` 时，`workingBalance` 与 `boostOf` 均返回 0。
- 用户达到 2.5x Boost 的条件不是拥有 100% veGOV，而是 `veUser / veTotal >= userLpBalance / totalLpStaked`，即 ve 份额至少覆盖自己在该 Gauge 的 LP 份额。

working balance 会计边界：

- `workingBalanceOf(user)` 和 `workingSupply()` 是存储会计值，只在 `deposit`、`withdraw`、`getReward`、`kick` 或内部 `_checkpoint/_updateWorkingBalance` 时刷新。
- veGOV 会随时间线性衰减，但 Gauge 不会在每个区块自动遍历所有用户更新 working balance。
- 因此，任意自然时间点的“理论实时 Boost”可能低于存储的 `workingBalanceOf(user)`；调用 `kick(user)` 后才把该用户的存储值拉回当前 ve 状态。
- 不变量只能要求“每次刷新操作完成后，`workingSupply` 等于所有已存储 `workingBalanceOf` 之和”，不能要求它在 ve 衰减后的任意时刻等于所有用户理论实时 working balance 之和。

`kick(user)` 规则与滥用边界：

| 项目 | v1 规则 |
|---|---|
| 调用权限 | permissionless，任何人可调用 |
| 目的 | 只用于下调因 ve 衰减而过高的 stored working balance |
| 冷却期 | `KICK_DELAY = 1 day`，同一 user 两次有效 kick 之间必须间隔至少 1 天 |
| 有效性条件 | 重新计算后的 working balance 必须低于当前 stored working balance |
| 最小变化 | `minKickDeltaBps = 50`，变化小于 0.5% 时 revert，避免 dust griefing |
| 资金影响 | 不转移用户 LP、不转移用户奖励，只更新奖励会计权重 |
| gas 成本 | 由调用者承担；v1 不内置 kick 奖励，避免制造刷 kick 激励 |
| 用户自刷新 | 用户 `deposit/withdraw/getReward` 会刷新自身 working balance，不受 kick 冷却限制 |

滥用分析：

- 无冷却 permissionless kick 会造成 gas griefing 和频繁状态扰动，因此 v1 必须实现 `lastKick[user]` 与最小变化阈值。
- `kick` 只能在会降低 stored working balance 时成功；不能被用来频繁“刷新但无变化”。
- 调用方展示 estimated boost 与 stored boost 时应区分二者，并提示用户其 Boost 可能被 kick 刷新。
- Keeper 不需要主动 kick 所有用户；通常只在大户 ve 到期或明显衰减后触发。

| 用户状态 | working balance | Boost |
|---|---|---|
| 无 ve 锁仓或 `veTotal == 0` | `0.4 * userLpBalance` | 1.0x |
| ve 份额低于 LP 份额 | `0.4x ~ 1.0x userLpBalance` | 1.0x ~ 2.5x |
| ve 份额覆盖 LP 份额 | `userLpBalance` | 2.5x |

| 函数 | 描述 |
|---|---|
| `deposit(amount)` | 质押 LP Token，并刷新 working balance |
| `withdraw(amount)` | 取消质押，并刷新 working balance |
| `getReward()` | 领取 GOV 奖励 |
| `exit()` | 退出质押并领取奖励 |
| `kick(user)` | 满足冷却期和最小变化条件时，刷新目标用户衰减后的 Boost |
| `notifyRewardAmount(amount)` | 仅 EmissionManager 可调用，接收新一轮 GOV 奖励 |
| `earned(user)` | 查询待领取奖励 |

#### FeeCollector.sol

接收 PairFactory `feeTo` 产生的协议费 LP Token，将 LP 退出为底层资产，并在必要时通过白名单路由转换为 FeeDistributor 指定的 `rewardToken`。

关键要求：

- `harvest(pair)` 只能由 keeper 或授权角色调用。
- LP 退出与兑换必须使用合约内计算的 `amountOutMin`。
- 所有兑换前必须检查 TWAP 偏离阈值。
- 只能向授权的 FeeDistributor 调用 `notifyRewardAmount(amountHint)`。

FeeCollector TWAP guard：

| 参数 | 生产规则 |
|---|---|
| `maxTwapDeviationBps` | 默认 300 bps，即 Router quote 与 TWAP quote 最大偏离 3% |
| `minTwapCheckAmount[token]` | 固定为 0，所有 FeeCollector swap 都必须检查 TWAP |
| route oracle | 每条 swap route 的每一跳都必须配置 TwapOracle |
| stale 处理 | 任意 route oracle 未 ready 或 stale，`harvest` 必须 revert |
| 多跳检查 | 逐跳检查 Router quote 与 TWAP quote 的偏离，不只检查最终输出 |
| 参数权限 | route、oracle、阈值和偏离参数只能由 Governance Timelock 修改 |

`amountOutMin` 来源：

```text
twapQuoteOut = routeOracle[pathHash].consult(amountIn, path)
amountOutMin = twapQuoteOut * (10000 - maxSlippageBps) / 10000

require(amountOutMin > 0)
router.swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), deadline)
```

- `amountOutMin` 不由 Keeper 输入；Keeper 只能选择待 harvest 的 `pair`，以及使用 Timelock 已配置的 route。
- `maxSlippageBps` 是 Timelock 参数，主网默认不得高于 `maxTwapDeviationBps`。
- `deadline` 由 FeeCollector 使用 `block.timestamp + harvestDeadlineWindow` 生成，Keeper 不能传入任意长 deadline。
- 如果 TWAP oracle `isReady == false`、`isStale == true`、流动性低于门槛或 `twapQuoteOut == 0`，`harvest` 必须 revert。
- 多跳路径的最终 `amountOutMin` 按整条 route 的 TWAP quote 计算；逐跳 TWAP 只作为偏离检查，不允许 Keeper 传入松散下限。
- Router 的实际成交输出仍必须满足 `amountOutMin`；TWAP guard 只负责限制参考价格偏离，不能替代实际滑点下限。

#### FeeDistributor.sol

按周将 `rewardToken` 分配给 veGOV 持有人。FeeDistributor 必须使用历史 checkpoint 余额计算分红，不能使用领取时的当前 veGOV 余额。

```text
weekTs = floor(rewardTimestamp / WEEK) * WEEK

userShare[weekTs] =
  weeklyRewards[weekTs]
  * VotingEscrow.balanceOfAt(user, weekTs)
  / VotingEscrow.totalSupplyAt(weekTs)
```

核心数据结构：

| 数据 | 含义 |
|---|---|
| `tokensPerWeek[weekTs]` | 该周可分配的 `rewardToken` 数量 |
| `timeCursorOf[user]` | 用户已结算到的周游标 |
| `lastTokenTime` | 上次 rewardToken checkpoint 时间 |
| `accountedRewardBalance` | 已进入 FeeDistributor 会计、尚未 claim 转出的 rewardToken 余额 |
| `pendingRolloverWeek` | zero-ve rollover 尚未处理完时的起始周 |
| `maxRolloverWeeksPerTx` | 单笔交易最多处理的 zero-ve rollover 周数 |
| `VotingEscrow.balanceOfAt(user, weekTs)` | 用户在周快照点的历史 veGOV |
| `VotingEscrow.totalSupplyAt(weekTs)` | 全系统在周快照点的历史 veGOV |

周中改锁仓只影响后续周，不回溯已结算周。若某周 `VotingEscrow.totalSupplyAt(weekTs) == 0`，该周奖励不按当前余额补分，必须滚入下一周 `weekTs + WEEK`，并发出 `ZeroVeRollover(weekTs, weekTs + WEEK, rolloverAmount)`。

zero-ve rollover 执行时机：

- rollover 只能在 `notifyRewardAmount(amountHint)` 或 `checkpointToken()` 入账阶段执行。
- rollover 必须使用迭代循环，不允许递归调用。
- 单笔交易最多处理 `maxRolloverWeeksPerTx` 周，主网默认 52 周；超过上限后保留 `pendingRolloverWeek`，等待下一次 `checkpointToken()` 继续处理。
- 如果 `VotingEscrow.totalSupplyAt(currentWeek) == 0`，执行：
  - `rolloverAmount = tokensPerWeek[currentWeek]`
  - `tokensPerWeek[currentWeek + WEEK] += rolloverAmount`
  - `tokensPerWeek[currentWeek] = 0`
  - `pendingRolloverWeek = currentWeek + WEEK`
  - emit `ZeroVeRollover(currentWeek, currentWeek + WEEK, rolloverAmount)`
- 如果连续多周 `totalSupplyAt == 0`，循环继续向后滚，直到遇到 `totalSupplyAt(currentWeek) > 0`、`tokensPerWeek[currentWeek] == 0` 或达到 `maxRolloverWeeksPerTx`。
- 如果遇到 `totalSupplyAt(currentWeek) > 0` 或 `tokensPerWeek[currentWeek] == 0`，本轮 rollover 完成，必须清空 `pendingRolloverWeek`。
- 达到 `maxRolloverWeeksPerTx` 仍未完成时，`remainingAmount = tokensPerWeek[pendingRolloverWeek]`，必须 emit `ZeroVeRolloverPaused(pendingRolloverWeek, remainingAmount)`，不得 revert 已完成的 rollover。
- `claim(user)` 不负责执行 rollover，只读取已 checkpoint 的 `tokensPerWeek` 结果。
- `maxRolloverWeeksPerTx` 只能由 Governance Timelock 修改，范围为 4 到 208 周，防止 gas 超限或长期无人维护导致无法恢复。

FeeDistributor 入账必须使用 balance-delta 记账：

```text
actualBalance = rewardToken.balanceOf(address(this))
require(actualBalance >= accountedRewardBalance)
actualDelta = actualBalance - accountedRewardBalance

require(actualDelta > 0)
tokensPerWeek[weekTs] += actualDelta
accountedRewardBalance += actualDelta
emit RewardNotified(msg.sender, amountHint, actualDelta, weekTs)
```

- `notifyRewardAmount(amountHint)` 的 `amountHint` 只用于事件和前后端核对，不作为可信会计金额。
- `FeeDistributor` 不允许根据调用参数 `amountHint` 直接增加 `tokensPerWeek`。
- 用户 `claim` 成功转出 `paid` 后，必须同步执行 `accountedRewardBalance -= paid`。
- 如果有人误转 `rewardToken` 到 FeeDistributor，该金额会在下一次 `notifyRewardAmount` 或 `checkpointToken()` 中通过 balance-delta 进入分红会计，不能造成账面余额大于实际余额。
- v1 的 `rewardToken` 必须是标准 ERC-20；fee-on-transfer、rebasing、ERC777 callback 或转账税 token 不能作为 FeeDistributor rewardToken。balance-delta 是会计保护，不代表支持特殊 token。

---

## 资产与权限流总图

本协议采用两条互相独立的链上资金流：协议手续费分红流和 GOV 排放激励流。二者资产形态、会计对象和调用权限不同，不能混用。

```text
手续费分红流
-----------
Pair protocol fee accounting
  -> PairFactory.feeTo = FeeCollector
  -> FeeCollector receives protocol LP Token
  -> FeeCollector burns LP into token0/token1
  -> FeeCollector swaps token0/token1 into rewardToken
  -> FeeCollector transfers rewardToken to FeeDistributor
  -> FeeCollector calls FeeDistributor.notifyRewardAmount(amountHint)
  -> FeeDistributor records actual balance delta
  -> FeeDistributor distributes rewardToken to veGOV holders by weekly ve snapshot

GOV 排放激励流
-------------
Minter computes weeklyEmission
  -> GovToken.mint(EmissionVault, weeklyEmission)
  -> GaugeController checkpoints weekly gauge weights
  -> EmissionManager reads weights and computes gaugeAmount
  -> EmissionVault transfers GOV to LiquidityGauge
  -> EmissionManager calls LiquidityGauge.notifyRewardAmount(gaugeAmount)
  -> LiquidityGauge streams GOV to LP stakers by working balance
```

### 资产形态定义

| 环节 | 资产形态 | 说明 |
|---|---|---|
| 用户锁仓 | GOV | 用户将 GOV 锁入 VotingEscrow，获得 veGOV 投票权 |
| LP 质押 | Pair LP Token | 用户将指定 Pair 的 LP Token 质押到对应 LiquidityGauge |
| Pair/Factory 协议费 | Pair LP Token | 遵循 Uniswap V2 `feeTo` 语义，协议费以 LP Token 形式归集 |
| FeeCollector 中间态 | LP Token、token0、token1、rewardToken | FeeCollector 负责从 LP Token 转换到单一分红资产 |
| FeeDistributor 入账资产 | rewardToken | 单一 ERC-20，可配置为 GOV、WETH、USDC 等；FeeDistributor 不直接处理 LP Token |
| Gauge 激励资产 | GOV | 由 Minter 铸造，经 EmissionVault 转入 Gauge |
| Native ETH | 不作为会计资产 | v1 不提供 native ETH 用户入口；WETH 仅作为普通 ERC-20 资产接入 |

### FeeDistributor 与 `feeTo` 的关系

不能将 `PairFactory.setFeeTo(feeDistributor)` 作为默认设计。

原因是 Pair/Factory 的协议费资产形态是 Pair LP Token，而 `FeeDistributor(rewardToken, votingEscrow)` 的会计模型只接受并分发单一 `rewardToken`。如果直接把 `feeTo` 指向 FeeDistributor，会导致 FeeDistributor 收到 LP Token，但它无法知道该 LP 对应的 token0/token1、退出路径、兑换滑点、TWAP 保护和分红资产转换规则。

正确闭环是：

```text
PairFactory.setFeeTo(feeCollector)
FeeCollector.harvest(pair)
FeeCollector: LP Token -> token0/token1 -> rewardToken
FeeCollector -> FeeDistributor.notifyRewardAmount(amountHint)
```

FeeDistributor 只关心一件事：收到授权 notifier 转入的 `rewardToken`，再按 ve 快照分配。

### 手续费分红流程

1. Governance 设置 `PairFactory.setFeeTo(feeCollector)`。
2. Pair 在 `_mintFee` 或等价协议费逻辑中将 LP Token 铸造给 FeeCollector。
3. Keeper 调用 `FeeCollector.harvest(pair)`。
4. FeeCollector 持有 pair LP Token，并调用 Pair burn 或 Router removeLiquidity 退出为 token0/token1。
5. 如果 token0/token1 不是 `rewardToken`，FeeCollector 通过白名单路径兑换为 `rewardToken`。
6. 兑换必须使用 FeeCollector 合约内计算的 `amountOutMin`，所有兑换前必须检查 TWAP 偏离阈值。
7. FeeCollector 将 `rewardToken` 转入 FeeDistributor。
8. FeeCollector 调用 `FeeDistributor.notifyRewardAmount(amountHint)`，FeeDistributor 按实际 balance delta 记录本周或当前分红周期新增奖励。
9. veGOV 持有人按快照份额领取 `rewardToken`。

手续费模型说明：

| 问题 | 规则 |
|---|---|
| 0.30% 如何拆分 | feeTo 关闭时全部归 LP；feeTo 开启时协议获得 LP 手续费增长量的 1/6 |
| 协议费何时开启 | 默认关闭；主网上线后由 Governance/Timelock 调用 `setFeeTo(feeCollector)` 开启 |
| 谁能关闭 | Governance/Timelock 可将 `feeTo` 设为 `address(0)` |
| 协议费资产 | Pair LP Token，不是 token0/token1、GOV 或 ETH |
| 是否需要兑换 | 需要。FeeDistributor 只接受单一 `rewardToken` |
| 兑换路径 | FeeCollector 只能使用治理白名单 route |
| 兑换保护 | FeeCollector 根据 TWAP quote 和 `maxSlippageBps` 自动计算 `amountOutMin`，并检查 TWAP 偏离阈值 |
| 分红 checkpoint | FeeDistributor 按周将收到的 rewardToken 记入 `tokensPerWeek[weekTs]` |
| 未 harvest 费用 | 仍以 LP Token 或未铸造协议费形式留在 Pair/FeeCollector，不进入分红会计 |

### veGOV 分红快照规则

FeeDistributor 不使用“领取时的当前 ve 余额”回算历史收益，而是按固定周快照和 VotingEscrow 历史 checkpoint 计算。这样可以避免用户在手续费产生后才锁仓，却领取过去周期费用的时间套利。

```text
weekTs = floor(rewardTimestamp / WEEK) * WEEK

userShare[weekTs] =
  weeklyRewards[weekTs]
  * VotingEscrow.balanceOfAt(user, weekTs)
  / VotingEscrow.totalSupplyAt(weekTs)
```

规则：

- 快照点为每个 epoch 的周起点 `weekTs`，并通过 VotingEscrow 的历史 checkpoint 查询。
- `notifyRewardAmount(amountHint)` 会使用实际 balance delta 将新增 rewardToken 归入对应周的 `tokensPerWeek[weekTs]`。
- 用户本周中途增加锁仓、延长锁仓或解锁，只影响后续周快照，不回溯影响已 checkpoint 的历史周。
- 如果某周 `VotingEscrow.totalSupplyAt(weekTs) == 0`，该周奖励不分配，必须滚入下一周，不允许 treasury 提前提走。
- `FeeDistributor.claim(user)` 从 `timeCursorOf[user]` 开始逐周结算，并更新用户游标，避免重复领取。
- `claimable == 0` 时不 revert，更新用户游标并返回 0。

### GOV 排放流程

GOV 排放只通过 Minter、EmissionVault、EmissionManager、LiquidityGauge 四类合约完成。部署者和 GaugeController 都不直接向 Gauge 注入奖励。

1. 每周 epoch 开始，Keeper 或公开调用者触发 `Minter.updatePeriod()`。
2. Minter 根据排放曲线计算 `weeklyEmission`。
3. Minter 调用 `GovToken.mint(emissionVault, weeklyEmission)`。
4. Keeper 或公开调用者触发 `GaugeController.checkpointGauge()`，分页固化当前 epoch 已生效的 Gauge 权重。
5. Keeper 或任意调用者触发 `EmissionManager.finalizeEmission(epoch)`，一次性固化所有 eligible Gauge 的 expected/allocation/debt。
6. Keeper 或任意调用者触发 `EmissionManager.distributeMany(gauges, epoch)`，或对单个 Gauge 调用 `distributeGauge(gauge, epoch)`。
7. EmissionManager 只执行已固化的 `allocation[gauge][epoch]`，不在分批执行阶段重新计算比例。
8. EmissionVault 按 EmissionManager 指令将 GOV 转入 LiquidityGauge。
9. EmissionManager 调用 `LiquidityGauge.notifyRewardAmount(gaugeAmount)`。
10. LiquidityGauge 在奖励周期内按 working balance 线性释放 GOV。

### Gauge 权重到奖励注入

```text
require(allActiveGaugesCheckpointed(epoch))
require(!emissionFinalized[epoch])

if totalWeight(epoch) == 0:
  undistributedEmission += weeklyEmission
else:
  for each eligibleGauge:
    baseAmount[gauge] = weeklyEmission * gaugeWeight(gauge, epoch) / totalWeight(epoch)
    repayAmount[gauge] = min(rewardDebt[gauge], repayBudget * gaugeWeight(gauge, epoch) / totalWeight(epoch))
    expectedAmount[gauge] = baseAmount[gauge] + repayAmount[gauge]
    totalExpected += expectedAmount[gauge]

  availableForEpoch = min(EmissionVault.availableBalance(), totalExpected)

  for each eligibleGauge:
    allocation[gauge][epoch] = expectedAmount[gauge] * availableForEpoch / totalExpected
    rewardDebt[gauge] = rewardDebt[gauge] + expectedAmount[gauge] - allocation[gauge][epoch]

  emissionFinalized[epoch] = true
```

约束：

- `GaugeController` 只提供权重，不触碰 GOV。
- `GaugeController` 权重必须按 epoch 固化，EmissionManager 不能用未 checkpoint 的临时投票状态直接分发。
- 任何 active Gauge 未完成 `isCheckpointed[gauge][epoch]` 时，整轮 epoch 分发必须 revert。
- `finalizeEmission(epoch)` 的 `totalExpected` 口径必须是所有 eligible Gauge 的总和，不是 `distributeMany(gauges, epoch)` 传入子集。
- `distributeMany` 只能执行已固化的 `allocation[gauge][epoch]`，不得根据当时 Vault 余额重新计算比例。
- `EmissionManager` 只计算和调度分发，不 mint GOV。
- `EmissionVault` 只保管和转出 GOV，不决定权重。
- `EmissionVault.distributor` 必须配置为 `EmissionManager` 合约；Keeper 不直接调用 Vault 出金。
- `LiquidityGauge.notifyRewardAmount` 的唯一正常调用主体是 EmissionManager。
- `sum(allocation[gauge][epoch]) <= EmissionVault.availableBalance()` 必须在 finalize 阶段成立。
- killed gauge 和权重为 0 的 gauge 不获得新增 base emission。
- 分发采用按比例缩放，不采用按数组顺序“先到先得”的分发。

### Gauge 奖励余额不足处理

| 场景 | 处理 | 事件 |
|---|---|---|
| EmissionVault 余额不足 | `finalizeEmission(epoch)` 按所有 eligible Gauge 的 `expectedAmount` 全局比例缩放并固化 `allocation[gauge][epoch]`；未分配部分累积到 `rewardDebt[gauge]` | `RewardShortfall(gauge, epoch, expected, allocated)` |
| 单个 Gauge 转账失败 | `distributeGauge(gauge, epoch)` 原子 revert；`distributeMany(gauges, epoch)` best-effort 记录失败并继续其他 Gauge；该 Gauge 的 `allocation[gauge][epoch]` 保持待执行，不新增 `rewardDebt` | `DistributionFailed(gauge, epoch, reason)` |
| Gauge `notifyRewardAmount` 失败 | 单 Gauge 原子回滚；批量分发中通过隔离子调用回滚该 Gauge 的 Vault 转账与 notify，未执行的 allocation 留待重试，不立即新增 debt | `DistributionFailed(gauge, epoch, reason)` |
| `totalWeight == 0` | 本周不向 Gauge 注入，全部记入 `undistributedEmission`，后续 epoch 作为 repayBudget 释放 | `EmissionUndistributed(epoch, amount)` |
| Gauge 已下线 | 不再分配新增 base emission；历史 `rewardDebt[gauge]` 只能由 Timelock 清偿或取消 | `GaugeKilled(gauge)` |

Debt 清偿规则：

- `rewardDebt[gauge]` 为跨 epoch 累积债务，不按 epoch 分散存储。
- 每个新 epoch 先计算 `baseAmount`，再使用 `repayBudget` 按权重偿还历史 debt。
- `repayBudget` 来自 Vault 余额中超过本周 base emission 的可用部分，或来自 `undistributedEmission`。
- `rewardDebt[gauge]` 只能因实际补发而减少；治理取消 debt 必须由 Timelock 执行并发出事件。
- `allocation[gauge][epoch]` 是已固化待执行金额；分发失败不会改变该 allocation，后续可重试。

分发函数语义：

- `finalizeEmission(epoch)` 只计算并固化 `allocation[gauge][epoch]`、`rewardDebt[gauge]` 和 `emissionFinalized[epoch]`，不转账 GOV。
- `distributeGauge(gauge, epoch)` 是单 Gauge 原子分发，任意转账或 notify 失败都会 revert。
- `distributeMany(gauges, epoch)` 是批量 best-effort 执行；单个 Gauge 失败时捕获错误、发出 `DistributionFailed`，继续处理其他 Gauge。
- `distributeMany` 必须限制单次数组长度，主网默认最大 20 个 Gauge，避免 gas 超限。
- `distributeMany` 必须通过 external self-call 或等价隔离调用逐个调用 `distributeGauge`，确保单个 Gauge 的 Vault transfer、Gauge notify、distributed 标记在同一个子调用中原子成功或原子回滚。
- `distributeGauge` 执行顺序固定为：Vault transfer GOV to Gauge -> Gauge `notifyRewardAmount(amount)` -> 标记 `distributed[gauge][epoch] = true`。若任一步失败，整个子调用 revert。
- `distributed[gauge][epoch] == true` 时，重复调用 `distributeGauge(gauge, epoch)` 必须 revert，防止重复注入。

### `notifyRewardAmount` 调用主体

| 函数 | 奖励资产 | 唯一正常调用主体 | 被通知合约 | 用途 |
|---|---|---|---|---|
| `FeeDistributor.notifyRewardAmount(amountHint)` | rewardToken | FeeCollector | FeeDistributor | 按 balance delta 登记协议手续费分红 |
| `LiquidityGauge.notifyRewardAmount(amount)` | GOV | EmissionManager | LiquidityGauge | 注入 LP 质押挖矿奖励 |

注意：

- GaugeController 不调用任何 `notifyRewardAmount`。
- 部署者不直接调用 LiquidityGauge 的 `notifyRewardAmount` 注入初始奖励；初始排放也应走 Minter -> EmissionVault -> EmissionManager。
- 如果需要紧急补发奖励，应由治理授权 EmissionManager 执行，避免绕过统一会计。

## 角色与权限定义

### Governance Timelock 规格

v1 使用 OpenZeppelin `TimelockController` 作为生产权限中枢，不自研 Timelock。

| 项目 | 主网规则 |
|---|---|
| Timelock 实现 | OpenZeppelin `TimelockController`，依赖版本锁定到固定 commit |
| `minDelay` | 48 hours |
| `PROPOSER_ROLE` | DAO Multisig |
| `EXECUTOR_ROLE` | `address(0)`，允许任何人执行已成熟交易 |
| `CANCELLER_ROLE` | DAO Multisig |
| `DEFAULT_ADMIN_ROLE` | 初始化后由 Timelock 自身持有，Deployer EOA 必须 renounce |
| Guardian 绕过 | Emergency Guardian 不得绕过 Timelock 修改资金参数、转移资金、铸造 GOV 或更改路由 |
| 事件要求 | 所有 Timelock 排队、取消、执行交易必须保留链上事件 |

测试网 `minDelay = 1 hours`，仅用于演练部署与治理流程；主网不得低于 48 hours。

### 角色总表

| 角色 | 类型 | 定义 | 主要职责 |
|---|---|---|---|
| Deployer EOA | 临时 EOA | 仅部署阶段使用的外部账户 | 部署合约、执行初始化、随后放弃高权限 |
| Governance Timelock | 合约 | v1 中所有 `owner/admin` 权限的最终持有者 | 参数变更、feeTo、Gauge 管理、Minter 配置、路由白名单 |
| DAO Multisig | 多签 | Timelock proposer/canceller 或 treasury 管理者 | 发起治理交易、取消异常治理交易、管理 treasury |
| Emergency Guardian | 多签 | 有限紧急权限角色 | 暂停外围资金流、kill 高风险 Gauge、事后提交治理确认 |
| Keeper | EOA 或 bot | 无资金所有权的自动化执行者 | 触发 update/checkpoint/distribute/harvest 等周期任务 |
| Minter | 合约 | GovToken 的唯一铸造调用方 | 按排放曲线 mint GOV 到 EmissionVault |
| EmissionVault | 合约 | GOV 排放资金保管合约 | 只保管 GOV，并按 EmissionManager 指令转出 |
| EmissionManager | 合约 | Gauge 奖励调度合约 | 读取 GaugeController 权重，调度 Vault 转账并通知 Gauge |
| Emission Distributor | 合约角色 | EmissionVault 中的 `distributor` 地址，只能配置为 EmissionManager 合约 | 由 EmissionManager 调用 Vault 转出已固化 GOV allocation |
| FeeCollector | 合约 | 协议费 LP 收集与兑换合约 | 收集 LP、退出流动性、兑换 rewardToken、通知 FeeDistributor |
| GaugeController | 合约 | 权重登记与投票会计合约 | 管理 Gauge 权重，不持有或转移 GOV |
| veGOV Holder | 用户 | 锁仓 GOV 的治理参与者 | 投票 Gauge 权重，领取手续费分红 |

术语约定：

- 文档中的 Owner/Admin 均指 Governance Timelock，不再指部署者 EOA。
- 部署者 EOA 在初始化后不得保留 `owner`、`MINTER_ROLE`、`onlyDistributor`、`onlyNotifier` 等生产权限。
- Keeper 只负责触发公开或低权限白名单任务，不应持有 treasury、mint、route、feeTo、Vault distributor 等治理或资金权限。
- `onlyDistributor` 只用于 `EmissionVault.transferReward` 等 Vault 出金入口，授权地址必须是 `EmissionManager` 合约；Keeper EOA 不得拥有 `onlyDistributor`。
- `EmissionManager.finalizeEmission`、`distributeMany`、`distributeGauge` 是 permissionless 执行入口，任何人可触发，但只能执行已经 checkpoint、finalized、未 distributed 的 allocation。
- 多签不是单独合约权限标准；它通常作为 Timelock 的 proposer/canceller 或 Guardian 的签名主体。

### 暂停与紧急控制决策

v1 不设计全局 AMM 暂停开关：Pair 的 `swap/mint/burn/sync/skim` 不由 Guardian 暂停，避免单一紧急角色冻结基础流动性。

v1 采用有限暂停：

| 模块 | 可暂停动作 | 不应暂停动作 | 暂停权限 |
|---|---|---|---|
| FeeCollector | `harvest`、route 兑换 | 已进入 FeeDistributor 的领取 | Emergency Guardian |
| EmissionManager | 新一轮 `finalizeEmission`、`distributeMany`、`distributeGauge` | 已注入 Gauge 的用户领取 | Emergency Guardian |
| LiquidityGauge | 新增 `deposit`、新的 `notifyRewardAmount` | `withdraw`、`getReward` | Emergency Guardian |
| GaugeController | 用户侧 `vote`、`reset` | Timelock 的 `addGauge`、`reviveGauge`、历史权重查询 | Emergency Guardian |
| Pair / Router | 无全局暂停 | swap、add/remove liquidity | 不提供 pause |

所有暂停和恢复都必须发出事件，并在 24 小时内由 Governance Timelock 复核或替换为正式治理操作。

### 权限动作矩阵

| 动作 | 函数 | 执行方 | 权限 |
|---|---|---|---|
| 设置协议费接收地址 | `PairFactory.setFeeTo(address)` | Governance Timelock | `onlyOwner` |
| 收集与转换手续费 | `FeeCollector.harvest(address pair)` | Keeper | `onlyKeeper` |
| 白名单兑换路径 | `FeeCollector.setRoute(...)` | Governance Timelock | `onlyOwner` |
| 通知分红入账 | `FeeDistributor.notifyRewardAmount(uint256)` | FeeCollector | `onlyNotifier` |
| 固化 Gauge 权重 | `GaugeController.checkpointGauge(gauge,epoch,start,limit)` | Keeper / anyone | permissionless，受分页 gas 限制 |
| 添加 Gauge | `GaugeController.addGauge(address)` | Governance Timelock | `onlyOwner`，只登记 Gauge，不设置治理权重 |
| 禁用 Gauge | `GaugeController.killGauge(address)` | Governance Timelock / Emergency Guardian | `onlyOwner` 或有限 `onlyGuardian` |
| 恢复 Gauge | `GaugeController.reviveGauge(address)` | Governance Timelock | `onlyOwner` |
| 用户投票 | `GaugeController.vote(address,uint256)` | veGOV holder | `veBalance > 0`、bps 总和 `<= 10000`、满足冷却期 |
| 用户批量投票 | `GaugeController.voteMany(address[],uint256[])` | veGOV holder | 同上 |
| 用户撤票 | `GaugeController.reset(address)` / `resetAll()` | veGOV holder | 满足冷却期 |
| 铸造 GOV | `GovToken.mint(address,uint256)` | Minter | `MINTER_ROLE` |
| 保管 GOV | `EmissionVault` | - | 只接受 GovToken |
| 授权分发者 | `EmissionVault.setDistributor(address)` | Governance Timelock | `onlyOwner` |
| 固化排放分配 | `EmissionManager.finalizeEmission(uint256 epoch)` | Keeper / anyone | permissionless，只计算 allocation，不转账 |
| 分发到 Gauge | `EmissionManager.distributeMany(address[] gauges,uint256 epoch)` / `distributeGauge(address gauge,uint256 epoch)` | Keeper / anyone | permissionless，执行已固化 allocation，必须具备幂等保护 |
| Vault 转出 GOV | `EmissionVault.transferReward(...)` | EmissionManager | `onlyDistributor` |
| Gauge 奖励注入 | `LiquidityGauge.notifyRewardAmount(uint256)` | EmissionManager | `onlyRewardDistributor` |
| 暂停外围资金流 | `pause()` / module-specific pause | Emergency Guardian | `onlyGuardian` |
| 恢复暂停模块 | `unpause()` | Governance Timelock | `onlyOwner` |

---

## 安全模型

### 威胁分析

| 威胁 | 攻击向量 | 缓解措施 |
|---|---|---|
| 闪电贷价格操纵 | 单区块操纵现货价格 | TWAP 使用固定窗口平均价格，提高操纵成本；低流动性或初始化窗口仍需额外保护 |
| 三明治攻击 | 抢跑与尾随用户交易 | Router 入口使用 amount bounds 与 deadline，限制用户可接受的最差成交；不能阻止攻击交易发生 |
| 过期交易执行 | 交易长时间滞留后被执行 | Router deadline 检查；Pair 直接调用不提供 deadline |
| 重入攻击 | 代币转账回调 | 关键状态变更函数使用 reentrancy guard 与 CEI |
| 治理攻击 | 闪电借入 GOV 后投票 | VotingEscrow 要求锁仓，投票权随锁定时间计算 |
| LP 通胀攻击 | 首次存款者操纵份额 | 首次铸造永久锁定最小流动性 |
| 预言机过期 | update 长时间未调用 | 暴露 `isStale()` / `lastUpdated()`，`consult` 对 stale 数据 revert，keeper 定期调用 |
| 错误资产分发 | FeeDistributor 收到非 rewardToken | FeeCollector 中转转换，FeeDistributor 限制 notifier |
| 奖励注入越权 | 非授权地址调用 Gauge 注入奖励 | LiquidityGauge 限制 `onlyRewardDistributor` |
| Boost 除零 | `veTotal == 0` 时计算 `veUser / veTotal` | 回退为基础 working balance |
| 分红时间套利 | 用户在手续费产生后才锁仓并领取历史费用 | FeeDistributor 使用历史 checkpoint，不使用领取时当前 ve |

### 风险登记

| 风险 | 影响 | 处理策略 |
|---|---|---|
| 低流动性 TWAP 被操纵 | FeeCollector 兑换或外部集成读取错误价格 | 设置最小流动性门槛、stale 检查和 TWAP 偏离阈值 |
| fee-on-transfer/rebasing token 接入 | reserve、TWAP、Router quote 不准确 | v1 不支持，PairFactory 或部署脚本拒绝 |
| Gauge 权重集中 | GOV 排放被少数 veGOV 持有人引导 | 多 Gauge 投票透明化，权重按 epoch checkpoint |
| EmissionVault 余额不足 | Gauge 奖励短缺 | 记录 `rewardDebt`，下个 epoch 优先处理或治理决议 |
| FeeCollector 路由错误 | 协议费兑换损失 | route 白名单、Timelock、TWAP 偏离阈值、Guardian 暂停 harvest |
| 迁移执行错误 | 用户资产卡在旧合约或重复分发 | 旧合约保留 withdraw/claim，迁移脚本先 fork 测试 |
| dust 累积 | 小额资产留在 Pair/Gauge/FeeDistributor | 明确 dust 留存位置，不允许重复领取或破坏 reserve |
| Keeper 失败 | Oracle stale、排放延迟、手续费延迟 | permissionless 补跑、失败升级阈值、SLA/RTO |

### 系统不变量

| 编号 | 模块 | 不变量 |
|---|---|---|
| I-1 | Pair | swap 后 `balanceAdjusted` 乘积 `>= reserveBefore0 * reserveBefore1 * 1000^2` |
| I-2 | Pair | `totalSupply > 0` 时两个 reserve 均大于 0 |
| I-3 | VotingEscrow | `totalSupply()` 等于所有未到期锁仓实时 ve 余额之和，允许整数舍入误差 |
| I-4 | VotingEscrow | `withdraw()` 只能在 unlock time 后成功 |
| I-5 | Oracle | `consult` 只能在 `isReady == true` 且 `isStale == false` 时使用 |
| I-6 | Gauge | 已领取奖励总额不超过已通知奖励总额 |
| I-7 | Gauge | `workingBalanceOf(user) <= balanceOf(user)` |
| I-8 | Gauge | 每次刷新操作完成后，`sum(stored workingBalanceOf) == workingSupply`；不要求 ve 自然衰减后的理论实时值相等 |
| I-9 | FeeDistributor | 历史周分红使用 `balanceOfAt/totalSupplyAt` 固定快照，不用当前 ve 余额回算 |
| I-10 | Gauge | `veTotal == 0` 时所有用户只获得基础 Boost |
| I-11 | EmissionManager | `finalizeEmission(epoch)` 后 `sum(allocation[gauge][epoch]) <= availableForEpoch`，且分批 `distributeMany` 不得重新缩放 allocation |
| I-12 | Rewards | Fee 分红与 Gauge 排放使用不同 notifier，不能互相调用 |
| I-13 | GaugeController | 单用户投票 bps 总和 `<= 10000` |
| I-14 | GaugeController | killed gauge 在下一生效 epoch 权重为 0 |
| I-15 | GaugeController | 当前 epoch 已开始后，用户投票只影响未来 epoch |
| I-16 | GaugeController | Gauge 权重只能来自 veGOV 投票 checkpoint，Timelock 不能直接设置非零治理权重 |
| I-17 | Minter | 每个 epoch 最多 mint 一次，`isMinted[epoch] == true` 后重复 `updatePeriod()` 不得增加供应量 |
| I-18 | FeeDistributor | `tokensPerWeek` 增量只能来自 rewardToken balance delta，不可信任 `amountHint` 参数 |
| I-19 | FeeCollector | Keeper 不能输入 `amountOutMin` 或任意 deadline，滑点下限必须由合约根据 TWAP 自动计算 |
| I-20 | FeeDistributor | zero-ve rollover 单笔处理周数不得超过 `maxRolloverWeeksPerTx`，未完成时必须可续跑 |
| I-21 | Oracle | reserve 低于 `minReserve0/minReserve1` 时不得 update、consult 或被 FeeCollector harvest 使用 |
| I-22 | Permissions | Keeper EOA 不得拥有 EmissionVault `onlyDistributor`，Vault distributor 必须是 EmissionManager 合约 |

---

## 依赖策略

生产部署必须锁定所有外部依赖版本，不允许使用浮动版本依赖。

| 依赖 | 用途 | 版本策略 |
|---|---|---|
| OpenZeppelin Contracts | `TimelockController`、权限基础设施、SafeERC20 类工具 | 使用 `forge install` 固定到明确 commit |
| Foundry | 编译、测试、部署、Gas 报告 | 锁定到明确 `forge --version` 输出，CI、Gas 基准和部署环境必须完全一致 |
| Solidity compiler | 合约编译 | `foundry.toml` 固定 `solc_version = 0.8.20`，不使用浮动 pragma 作为部署编译版本 |

依赖要求：

- `remappings.txt` 必须锁定依赖路径。
- `lib/` 依赖必须通过 git submodule 或 Foundry dependency lock 管理。
- 主网部署前必须记录依赖 commit、compiler version、optimizer、via-ir、evm version。
- Foundry 版本必须记录完整输出，包括 version、commit SHA、build timestamp 和 build profile；不得只写最低版本范围。
- `foundry.toml`、依赖 commit、`forge --version` 输出和 Gas 快照共同构成可复现环境；任一项变化都必须重新跑测试、coverage、gas report 和 deploy dry-run。
- 不允许从未锁版本依赖直接部署主网。

---

## 快速开始

### 前置要求

| 工具 | 版本 |
|---|---|
| Foundry | 锁定为 `forge Version: 1.5.1-stable`，commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2` |
| Git | >= 2.30 |

### 安装

```bash
git clone <REPOSITORY_URL>
cd vetoken-dex

forge install
forge --version
cp .env.example .env
forge build
forge test
```

### 环境变量

```bash
DEPLOYER_PRIVATE_KEY=0x...
MAINNET_RPC_URL=<MAINNET_RPC_URL>
SEPOLIA_RPC_URL=<SEPOLIA_RPC_URL>
ETHERSCAN_API_KEY=YOUR_KEY

GOV_TOKEN_NAME="VeToken Governance"
GOV_TOKEN_SYMBOL="GOV"
GOV_TOKEN_CAP=1000000000e18
MAX_LOCK_TIME=126144000
ORACLE_PERIOD=86400
INITIAL_MINT=400000000e18
```

---

## 部署指南

### 部署顺序

```text
阶段 1：核心基础设施
1. Governance Timelock
2. GovToken(owner = deployer, cap, initialReceiver, INITIAL_MINT)
3. InitialAllocationVault / Treasury Timelock receives INITIAL_MINT
4. VotingEscrow(govToken, maxLockTime)
5. PairFactory(owner = deployer, allowlistEnabled = true)
6. Router(factory)

阶段 2：初始铸造与权限准备
7. GovToken 初始铸造 `INITIAL_MINT = GOV_TOKEN_CAP * 40%`
8. INITIAL_MINT 进入 InitialAllocationVault / Treasury Timelock
9. 按 DeployConfig 记录 Treasury / Team / Ecosystem / Initial Liquidity 分配额度
10. Liquidity Mining Reserve 不预铸造，保留为 Minter 后续周排放预算
11. PairFactory.setTokenAllowed(GOV, true)
12. PairFactory.setTokenAllowed(WETH, true)

阶段 3：初始交易池
13. PairFactory.createPair(GOV, WETH)
14. Router.addLiquidity(...)

阶段 4：预言机
15. TwapOracle(pair_GOV_WETH, period)
16. 等待 >= PERIOD
17. TwapOracle.update()

阶段 5：手续费分红
18. FeeDistributor(rewardToken, votingEscrow)
19. FeeCollector(factory, router, rewardToken, feeDistributor)
20. FeeDistributor.setNotifier(feeCollector)
21. FeeCollector.setRoute(...) and configure route oracles
22. PairFactory.setFeeTo(feeCollector)

阶段 6：排放激励
23. GaugeController(votingEscrow)
24. EmissionVault(govToken)
25. Minter(govToken, emissionVault)
26. EmissionManager(gaugeController, emissionVault)
27. LiquidityGauge(lpToken, govToken, votingEscrow)
28. GaugeController.addGauge(liquidityGauge)
29. LiquidityGauge.setRewardDistributor(emissionManager)
30. GovToken.setMinter(minter, true)
31. EmissionVault.setDistributor(emissionManager)
    - `distributor` 必须是 EmissionManager 合约地址，不得配置为 Keeper EOA 或多签。

阶段 7：权限移交与验证
32. 将 GovToken、PairFactory、GaugeController、FeeCollector、FeeDistributor、Minter、EmissionVault、EmissionManager 等 owner/admin 权限迁移到 Governance Timelock
33. 配置 DAO Multisig 为 Timelock proposer/canceller
34. 配置 Emergency Guardian 的有限暂停权限
35. Deployer EOA renounce 所有 owner/admin/minter/distributor/notifier 权限
36. 在区块浏览器验证所有合约
```

部署阶段不允许临时关闭 PairFactory allowlist。任何生产部署中的 Pair 创建都必须先完成 `setTokenAllowed(token, true)`，再调用 `createPair`。

### 部署命令

```bash
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv

forge script script/Deploy.s.sol:Deploy \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --slow \
  -vvvv
```

### 部署后检查清单

- 所有链上合约已验证。
- Governance Timelock 已部署，Deployer EOA 不持有生产 Owner/Admin 权限。
- PairFactory token allowlist 已启用，`GOV` 与 `WETH` 已在 createPair 前完成 `setTokenAllowed(token, true)`。
- PairFactory `feeTo` 指向 FeeCollector。
- FeeDistributor 的 `rewardToken` 与 FeeCollector 输出资产一致。
- GovToken 初始铸造等于非 Liquidity Mining 预算之和，即 `INITIAL_MINT = GOV_TOKEN_CAP * 40%`，且 `totalSupply <= GOV_TOKEN_CAP`。
- INITIAL_MINT 已进入 InitialAllocationVault / Treasury Timelock，Liquidity Mining Reserve 未预铸造。
- Minter、feeTo、FeeCollector route、Gauge 管理权限均由 Governance Timelock 持有，DAO Multisig 仅作为 proposer/canceller。
- Oracle 已完成至少一次有效 `update()`，`isReady() == true` 且 `isStale() == false`。
- 初始交易池已注入流动性。
- Gauge 已添加到 GaugeController。
- EmissionVault、Minter、EmissionManager 权限配置正确。
- EmissionVault `distributor == EmissionManager`，Keeper EOA 无 Vault 出金权限。
- 所有 Owner/Admin 权限已迁移到 Governance Timelock。
- DAO Multisig 与 Emergency Guardian 地址已配置并记录。

---

## 升级与迁移策略

v1 默认不使用透明代理或 UUPS 代理。核心资金合约按不可升级合约部署，通过治理参数、kill/revive、迁移脚本和新版本合约完成升级。

### 升级原则

| 模块 | v1 策略 |
|---|---|
| Pair | 不升级。发现问题时停止新增激励，部署新 Pair/Factory |
| Router | 可部署新 Router，旧 Router 不持有长期资金 |
| TwapOracle | 可部署新 Oracle，并由治理/集成方切换读取地址 |
| GovToken | 不升级，cap 和 minter 权限必须保持稳定 |
| VotingEscrow | 不升级。迁移需要用户主动 withdraw/lock 或治理批准迁移合约 |
| GaugeController | 不升级。可部署新 controller，并让新 EmissionManager 读取新权重 |
| LiquidityGauge | 不升级。可 kill 旧 Gauge，部署新 Gauge，引导 LP withdraw/deposit |
| FeeCollector | 可部署新 FeeCollector，并通过 Timelock 更新 `feeTo` |
| FeeDistributor | 不升级或谨慎迁移。新版本需从明确 weekTs 开始接收 rewardToken |
| EmissionManager | 可部署新版本，并由 Timelock 更新 Vault distributor |
| EmissionVault | 不升级。仅通过 Timelock 切换授权 distributor |

### 迁移流程

```text
1. Governance Timelock 公告迁移计划和目标合约地址
2. 暂停受影响的外围资金流，例如 EmissionManager.distributeMany / distributeGauge 或 FeeCollector.harvest
3. 对旧合约执行 checkpoint，固定历史会计
4. 部署新合约并完成权限配置
5. 将新增流量切到新合约，例如新 Router、新 Gauge、新 FeeCollector
6. 保留旧合约 withdraw/getReward/claim 入口
7. 用户主动迁移 LP、Gauge stake 或 lock
8. 完成核对后恢复新合约资金流
```

### 状态迁移边界

| 状态 | 迁移方式 |
|---|---|
| Pair reserves | 不直接迁移；用户移除旧 LP 后添加到新 Pair |
| LP Token | 不强制迁移；新 Pair 产生新 LP Token |
| Gauge stake | 用户从旧 Gauge withdraw，再 deposit 到新 Gauge |
| pending GOV rewards | 旧 Gauge 保留 `getReward` |
| veGOV locks | v1 不自动迁移；除非部署专门 migrator 并经治理批准 |
| FeeDistributor historical claims | 旧 FeeDistributor 保留 claim；新 FeeDistributor 从新 weekTs 开始 |
| Gauge votes | 新 GaugeController 需要用户重新投票 |
| emission debt | 由 EmissionManager 导出并在新版本中显式导入，或由治理取消/补偿 |

### 紧急修复边界

- Emergency Guardian 只能暂停外围资金流或 kill Gauge，不能升级合约。
- Governance Timelock 才能切换 FeeCollector、EmissionManager distributor、Gauge 管理参数。
- 任何迁移脚本必须先在 fork 测试中验证资产守恒和用户可退出。
- 迁移完成前旧合约不得关闭用户 withdraw、claim、getReward 入口。

---

## 参数配置

| 参数 | 默认值 | 最小/最大值 | 治理方式 | 生效方式 | 所在合约 |
|---|---|---|---|---|---|
| 交换手续费 | 0.30% | v1 固定 | 部署后不可变 | 立即 | Pair |
| 协议手续费开关 | off | off/on | Timelock | 设置 `feeTo` 后生效 | PairFactory |
| 协议手续费份额 | LP 手续费增长量的 1/6 | v1 固定 | 部署后不可变 | `feeTo` 开启后生效 | Pair |
| PairFactory token allowlist | enabled | allowlisted ERC-20 only | Timelock | 下次 createPair 生效 | PairFactory |
| FeeCollector route | 无 | 白名单 route | Timelock | 下次 harvest 生效 | FeeCollector |
| FeeCollector TWAP 偏离阈值 | 300 bps | 0 / 1000 bps | Timelock | 下次 harvest 生效 | FeeCollector |
| FeeCollector 最大滑点 | 300 bps | 0 / `maxTwapDeviationBps` | Timelock | 下次 harvest 生效 | FeeCollector |
| FeeCollector deadline 窗口 | 5 minutes | 1 minute / 30 minutes | Timelock | 下次 harvest 生效 | FeeCollector |
| FeeCollector 最小 TWAP 检查金额 | 0 | v1 固定 | 部署后不可变 | 立即 | FeeCollector |
| FeeDistributor rewardToken | 部署配置 | 单一 ERC-20 | 部署后不可变 | 部署时 | FeeDistributor |
| FeeDistributor rollover 上限 | 52 weeks | 4 / 208 weeks | Timelock | 下次 checkpoint 生效 | FeeDistributor |
| TWAP PERIOD | 24 小时 | 部署配置 | 部署后不可变 | 部署时 | TwapOracle |
| Oracle stale 阈值 | 2 * PERIOD | 固定 | 部署后不可变 | 部署时 | TwapOracle |
| Oracle 最小 reserve0/reserve1 | DeployConfig 显式配置 | 大于 0 | Timelock | 下次 update/consult/harvest 生效 | TwapOracle |
| GOV cap | 1,000,000,000 GOV | 部署配置 | 部署后不可变 | 部署时 | GovToken |
| 初始铸造 | 400,000,000 GOV | `GOV_TOKEN_CAP * 40%` | 部署后不可变 | 部署时 | GovToken |
| 周排放 | 部署配置 | 只能下调，不能上调，且不超过 cap 剩余额 | Timelock | 下一 epoch | Minter |
| 排放衰减率 | 9900 bps | v1 固定 | 部署后不可变 | 部署时 | Minter |
| 最大锁定时间 | 4 年 | v1 固定 | 部署后不可变 | 部署时 | VotingEscrow |
| 最小锁定期限 | 1 周 | v1 固定 | 部署后不可变 | 部署时 | VotingEscrow |
| Gauge 投票冷却 | 10 天 | 1 天 / 21 天 | Timelock | 下一次投票 | GaugeController |
| Gauge kick 冷却 | 1 天 | 1 小时 / 7 天 | Timelock | 下一次 kick | LiquidityGauge |
| Gauge kick 最小变化 | 50 bps | 0 / 1000 bps | Timelock | 下一次 kick | LiquidityGauge |
| Gauge 权重上限 | 10000 bps | 固定 | 部署后不可变 | 立即 | GaugeController |
| 奖励周期 | 7 天 | 1 天 / 30 天 | Timelock | 下一轮 notify | LiquidityGauge |
| AMM 永久锁定最小 LP | 1000 wei | 固定 | 部署后不可变 | 部署时 | Pair |
| Boost 基础系数 | 0.4 | 固定 | 部署后不可变 | 立即 | LiquidityGauge |
| Boost 最大倍数 | 2.5x | 由基础系数决定 | 部署后不可变 | 立即 | LiquidityGauge |

## 参数治理策略

| 参数类别 | 策略 |
|---|---|
| 不变量参数 | AMM 手续费、协议费份额、永久锁定最小 LP、Boost 公式、最大锁定时间等 v1 不变量部署后不可变 |
| 高风险参数 | `feeTo`、FeeCollector route、Minter 排放、Gauge kill/revive、reward distributor 必须经 Timelock |
| Timelock 延迟 | 主网固定 48 小时，测试网固定 1 小时 |
| 紧急权限 | 有限 pause/kill 类操作可由 Emergency Guardian 执行，但必须有事件，并在 24 小时内交由 Governance Timelock 复核 |
| 参数上限 | 所有可治理参数必须在合约内写入 min/max，不能只依赖脚本校验 |
| 生效延迟 | 排放、Gauge 权重、投票冷却等经济参数默认下一 epoch 生效，避免同区块治理套利 |
| 事件要求 | 每次参数变更必须发出包含 oldValue/newValue/effectiveTime 的事件 |

---

## 测试

```bash
forge test
forge test --match-path "test/unit/*"
forge test --match-path "test/integration/*"
forge test --match-path "test/invariant/*" --fuzz-runs 10000
forge test --gas-report
forge coverage --report lcov
```

### 测试覆盖率目标

| 模块 | 目标 | 关键路径 |
|---|---:|---|
| Pair | >= 95% | swap k 值校验、mint/burn 数学、重入防护 |
| Router | >= 95% | deadline、滑点检查、多跳、边界金额 |
| Oracle | >= 90% | PERIOD、溢出处理、未初始化状态、stale 状态 |
| VotingEscrow | >= 95% | 锁定/解锁、衰减计算、历史 checkpoint |
| GaugeController | >= 90% | 投票权重、epoch checkpoint |
| LiquidityGauge | >= 95% | 奖励累积、Boost、kick |
| FeeCollector | >= 90% | LP 收集、兑换、滑点保护、权限 |
| FeeDistributor | >= 90% | 快照分配、领取、epoch 处理 |
| EmissionManager | >= 90% | 权重分配、短缺债务、失败跳过 |

### 关键测试场景

- FeeCollector 收到 LP Token 后正确退出为 token0/token1，并兑换为 FeeDistributor 的 `rewardToken`。
- 直接将 PairFactory `feeTo` 指向 FeeDistributor 的路径不作为支持路径，FeeDistributor 不接受 LP Token 入账。
- 只有 FeeCollector 能调用 `FeeDistributor.notifyRewardAmount`。
- 只有 EmissionManager 能调用 `LiquidityGauge.notifyRewardAmount`。
- GaugeController 投票权重 checkpoint 后，EmissionManager 按 `gaugeWeight / totalWeight` 计算周奖励。
- GaugeController 使用 `VotingEscrow.votingPowerAt(user, nextEpoch)` 计算未来 epoch 投票权，不使用分发或领取时当前 ve。
- `VotingEscrow.balanceOfAt(user, futureTimestamp)` 必须 revert；未来投票权只能通过 `votingPowerAt(user, epoch)` 查询。
- `votingPowerAt` 必须覆盖锁仓到期、延长锁仓、追加锁仓、冻结窗口后变更不回溯等场景。
- `addGauge(gauge)` 后新 Gauge 初始权重必须为 0，未获得 veGOV 投票前不能分配 base emission。
- `vote()` 只写入 `pendingVote`，不得在同一调用中执行 `checkpointGauge()`。
- `VOTE_FREEZE_WINDOW` 开始后，影响目标 epoch 的 `vote/reset/voteMany` 必须 revert。
- `checkpointGauge()` 只能在目标 epoch 冻结窗口开始后执行。
- `finalizeEpoch(epoch)` 只能在所有 active Gauge checkpoint 完成后成功。
- `isEpochCheckpointed[epoch] == false` 时，EmissionManager 分发必须 revert。
- 用户可把最多 10000 bps 分配给多个 Gauge，超过上限应 revert。
- 用户可改票和撤票，但同一用户同一 Gauge 在 `VOTE_DELAY` 内重复修改应 revert。
- 本周投票只影响下一周或更晚 epoch，不改变已开始 epoch 的排放。
- killed gauge 不接受新投票，下一生效 epoch 权重为 0，且不获得新增 base emission。
- 用户对 killed gauge 调用 `reset(gauge)` 必须绕过 `VOTE_DELAY`，释放 `usedVoteWeight`；但不得回溯修改已经 checkpoint 或已经分发的 epoch。
- revived gauge 不自动恢复历史权重，需要用户重新投票；治理不能设置新初始权重。
- `totalWeight(epoch)` 等于所有 active gauge 在该 epoch 的 `gaugeWeight` 之和。
- `Minter.updatePeriod()` 同一 epoch 多次调用不得重复 mint；`weeklyEmission == 0` 时也必须标记 `isMinted[epoch]`。
- `EmissionManager.finalizeEmission(epoch)` 必须读取 `Minter.emissionForEpoch(epoch)`，不能自行重新计算周排放。
- `finalizeEmission(epoch)` 使用所有 eligible Gauge 的 `expectedAmount` 计算 `totalExpected`，并按全局比例固化 `allocation[gauge][epoch]`。
- `distributeMany(gauges, epoch)` 不重新计算比例，只执行已固化 allocation；不同批次执行不得改变 allocation。
- `distributeMany` 通过隔离子调用逐个执行 `distributeGauge`，单个 Gauge 失败不得回滚其他 Gauge 的成功分发。
- EmissionVault 余额不足时在 finalize 阶段记录 `rewardDebt`，且不使整轮分发不可恢复。
- `totalWeight == 0` 时不向 Gauge 注入奖励。
- FeeDistributor 使用 `VotingEscrow.balanceOfAt(user, weekTs)` 与 `VotingEscrow.totalSupplyAt(weekTs)` 计算历史周分红。
- 用户在某周手续费产生后才锁仓，不能领取该周已 checkpoint 的历史分红。
- `FeeDistributor.claim(user)` 更新 `timeCursorOf[user]`，同一周不能重复领取。
- `FeeDistributor.notifyRewardAmount(amountHint)` 必须按 actual balance delta 入账；`amountHint` 偏大、偏小或有人误转 rewardToken 时，会计不得大于实际余额。
- `FeeDistributor` 对 fee-on-transfer、rebasing、ERC777 callback 或转账税 rewardToken 的部署配置必须拒绝。
- zero-ve 连续多周时，FeeDistributor 必须按 `maxRolloverWeeksPerTx` 分批 rollover，达到上限后可由后续 `checkpointToken()` 续跑。
- `FeeCollector.harvest` 中 Keeper 不能传入 `amountOutMin`；测试必须验证合约按 TWAP quote 和 `maxSlippageBps` 自动计算滑点下限。
- `FeeCollector.harvest` 在 stale oracle、低流动性、`twapQuoteOut == 0`、实际成交低于合约计算 `amountOutMin` 时必须 revert。
- `VotingEscrow.totalSupply()` 与所有用户实时 `balanceOf` 求和一致，测试允许最小整数舍入误差。
- `VotingEscrow.totalSupplyAt(timestamp)` 与历史 checkpoint 一致，不受当前锁仓变化回溯影响。
- VotingEscrow `unlockTime` 必须按周对齐，低于最小锁定或超过最大锁定应 revert。
- VotingEscrow 每用户只能有一笔 active lock；重复 `createLock` 应 revert。
- veGOV 不可转让，不实现 ERC-20 transfer/approve，也不实现 ERC-721 veNFT。
- 直接调用 `Pair.swap` 时没有 Router 的 deadline 与 amount bounds；集成测试应覆盖该边界。
- 滑点保护只能限制最差成交结果，不能阻止三明治交易本身发生。
- TWAP 在低流动性池、初始化窗口和 stale 状态下不可作为可靠价格源。
- Oracle `update/consult` 和 FeeCollector route 检查必须在 reserve 低于 `minReserve0/minReserve1` 时 revert。
- Oracle `consult()` 在未 ready 或 stale 时 revert。
- Oracle `lastUpdated()`、`period()`、`stalenessThreshold()` 返回正确值。
- `veTotal == 0` 时 Boost 回退为基础 working balance，不发生除零。
- 用户 ve 份额覆盖 LP 份额时 Boost 才达到 2.5x。
- `kick(user)` 在冷却期内重复调用应 revert。
- `kick(user)` 在 working balance 没有下降或下降低于 `minKickDeltaBps` 时应 revert。
- `kick(user)` 不得改变用户 LP principal 或已累积奖励所有权。
- GovToken mint 不得突破 `GOV_TOKEN_CAP`；cap 达到后 `weeklyEmission == 0`。
- 非 Liquidity Mining 初始分配总和必须等于 `INITIAL_MINT`；Liquidity Mining Reserve 不预铸造，后续由 Minter 按周 mint，二者合计不得超过 cap。
- Minter 排放参数变更必须经过 Timelock，并从下一 epoch 生效。
- Deployer EOA 初始化后不得保留 owner/admin/minter/distributor/notifier 权限。
- Emergency Guardian 只能暂停外围资金流，不能暂停 Pair/Router 全局交易。
- Keeper 地址不得拥有 Timelock、Minter、Vault、route、feeTo 或 Guardian 权限。
- Keeper 地址不得拥有 EmissionVault `distributor` 权限；`distributeMany` 只能通过 permissionless EmissionManager 入口触发。
- PairFactory 对 token 地址排序后 CREATE2 地址稳定，同一 token pair 不能重复创建。
- PairFactory 未白名单 token 时 `createPair` 必须 revert；白名单 token 后才能创建 Pair。
- 部署脚本不得临时关闭 PairFactory allowlist。
- Router 只支持 ERC-20 路径；WETH 按普通 ERC-20 使用，Pair 不接收 native ETH。
- fee-on-transfer、rebasing、ERC777 callback token 在 v1 不作为支持资产，相关用例应 revert 或在集成清单中拒绝。
- feeTo 关闭时不铸造协议费 LP；feeTo 开启后协议费 LP 铸造给 FeeCollector。
- FeeCollector harvest 后 FeeDistributor 只增加 `rewardToken` 会计，不记录 LP Token。

## 验收标准

### 功能验收

| 类别 | 标准 |
|---|---|
| AMM | mint/burn/swap、CREATE2 地址、token 排序、协议费开关、WETH-as-ERC20 路径全部有单元和集成测试 |
| Governance | GovToken cap、初始分配、Minter 周排放、Timelock 权限全部有测试 |
| Gauge | 多 Gauge 投票、冷却期、跨周生效、killed/revived、权重归一化全部有测试 |
| Fee 分红 | LP -> token0/token1 -> rewardToken -> FeeDistributor -> ve holder 全流程测试通过 |
| Oracle | ready、stale、lastUpdated、低流动性/初始化窗口风险用例覆盖 |
| Upgrade/Migration | kill old Gauge、deploy new Gauge、old claim/withdraw、new deposit 全流程测试通过 |

### 覆盖率验收

- `forge coverage` 总行覆盖率不低于 90%。
- Critical 合约（Pair、Router、VotingEscrow、LiquidityGauge）行覆盖率不低于 95%。
- 权限、失败路径、边界值、stale、cap reached、zero weight、zero ve、feeTo off/on 必须有负向测试。

### Gas 验收

- `forge test --gas-report` 必须生成报告。
- 核心操作 Gas 不应超过 Gas 基准表 20%，超过需在 PR 中解释。
- `EmissionManager.finalizeEmission` 必须说明 active Gauge 数量对 Gas 的影响。
- `EmissionManager.distributeMany` 必须说明传入 Gauge 数量对 Gas 的影响，并限制单次批量大小。
- `FeeCollector.harvest` 必须针对 1-hop 和 multi-hop route 分别记录 Gas。
- Gas 报告必须记录 solc 版本、optimizer、optimizer runs、via-ir、初始储备、Gauge 数量。

### 数值验收

- 所有除法和定点数计算必须在测试中断言舍入方向。
- dust 留存位置必须可解释，并在测试中验证不会导致用户可重复领取或池子资产减少。
- 非 18 decimals token 必须至少覆盖 swap、addLiquidity、removeLiquidity 测试。
- `uint112` reserve 上限、SafeCast downcast、TWAP 累计值 wraparound 必须有边界测试。

### 安全验收

- 所有高权限函数必须有 `onlyOwner`、`onlyRole`、Timelock 或 Guardian 约束。
- 所有 Owner/Admin 权限必须在部署后迁移到 Governance Timelock。
- Guardian 权限必须只覆盖有限暂停和 kill 高风险 Gauge，不得拥有 mint、feeTo、route 或 Vault 转账权限。
- 所有参数变更必须有事件，事件包含 oldValue、newValue 和 effectiveTime。
- 不变量测试必须覆盖 Pair adjusted-balance k 校验、Gauge reward conservation、Gauge stored workingSupply、VotingEscrow supply、FeeDistributor historical checkpoint。
- TWAP 互逆性质测试必须限定在同一 Pair、同一窗口、非零 reserve、相同 UQ112x112 精度和允许舍入误差的前置条件下。

---

## 主网上线闸门

以下任一条件未满足时，不得执行主网部署或开启协议手续费与排放。

| 类别 | 必须满足 |
|---|---|
| 编译 | `forge build` 通过，Solidity、optimizer、via-ir、evm version 与部署配置一致 |
| 单元测试 | `forge test` 全部通过 |
| 覆盖率 | 总行覆盖率 >= 90%，Critical 合约覆盖率 >= 95% |
| 不变量 | AMM、VotingEscrow、Gauge、FeeDistributor、EmissionManager 不变量测试通过 |
| 静态分析 | Slither 无 High / Critical，已确认 findings 必须有书面说明 |
| Gas | Gas 表无 `待基准测试` 项，核心操作未超过基准 20% |
| 权限 | Deployer EOA 无 owner、admin、minter、notifier、guardian 权限；Keeper EOA 无 EmissionVault distributor 权限 |
| Timelock | Governance Timelock 已部署，主网 `minDelay = 48 hours`，DAO Multisig 角色配置完成 |
| Guardian | Emergency Guardian 只能暂停外围资金流，不能转移资金或改资金参数 |
| Token allowlist | PairFactory token allowlist 已启用，初始 token 白名单已配置 |
| Initial mint | `INITIAL_MINT = GOV_TOKEN_CAP * 40%` 已进入 InitialAllocationVault / Treasury Timelock，Liquidity Mining Reserve 未预铸造 |
| Gauge checkpoint | `VOTE_FREEZE_WINDOW`、`checkpointGauge`、`finalizeEpoch` 和 `isEpochCheckpointed` 全流程测试通过 |
| FeeCollector | route、oracle、`maxTwapDeviationBps` 已配置，`minTwapCheckAmount = 0`，并 fork 测试通过 |
| Oracle | 初始 Oracle 已完成首次有效 update，`isReady == true`、`isStale == false`，且每条 route 的 `minReserve0/minReserve1 > 0` |
| FeeDistributor | notifier 指向 FeeCollector，zero-ve 连续多周 rollover 和 `maxRolloverWeeksPerTx` 续跑测试通过 |
| Emission | Minter、EmissionVault、EmissionManager 权限完整，Vault distributor 为 EmissionManager 合约，shortfall/debt 测试通过 |
| 部署记录 | 所有部署地址写入 `deployments/{chainId}.json`，区块浏览器验证完成 |
| 回滚计划 | 迁移/暂停/恢复脚本已在 fork 环境演练 |

主网上线分阶段执行：

1. 部署合约并完成验证。
2. 迁移所有 Owner/Admin 权限到 Timelock。
3. 配置 allowlist、FeeCollector route、Oracle、Gauge。
4. 小额开启流动性与 Gauge 排放。
5. 观察至少 1 个 epoch 后，由 Timelock 开启 `feeTo = FeeCollector`。

---

## Gas 基准

### 测量方法

Gas 基准必须使用固定环境测量，避免不同编译器、optimizer 或初始状态导致数据不可比较。

| 项目 | 设定 |
|---|---|
| Solidity | `foundry.toml` 固定 `solc_version = 0.8.20` |
| Foundry | 必须等于锁定版本 `forge Version: 1.5.1-stable`，commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2` |
| EVM version | 以 `foundry.toml` 为准，固定为部署目标链兼容版本 |
| optimizer | enabled |
| optimizer runs | 200，除非 DeployConfig 明确覆盖 |
| via-ir | 默认 false；如开启必须单独生成 Gas 基准 |
| 测量命令 | `forge test --gas-report` |
| 统计口径 | 取 warm state 下同一测试用例的 gas report，不混用 fork 网络波动数据 |
| token decimals | 默认测试 token 使用 18 decimals；非 18 decimals 单独测试 |
| 初始流动性 | Pair 基准使用已存在 Pair，储备量固定为 `100 ether / 100_000 ether` 或测试中明确记录 |
| 用户状态 | Gauge 基准需记录用户 LP、veGOV、working balance 是否已初始化 |
| Oracle 状态 | Oracle 基准需区分 first update、normal update、stale recovery |

Gas 报告 PRD：

- 每次修改核心合约后必须重新运行 `forge test --gas-report`。
- 如果核心操作超过下表基准 20%，PR 必须说明原因。
- `FeeCollector.harvest` 必须分别记录 no-swap、1-hop swap、multi-hop swap。
- `EmissionManager.finalizeEmission` 必须按 active Gauge 数量记录，例如 1、5、20、100 个 Gauge。
- `EmissionManager.distributeMany` 必须按传入 Gauge 数量记录，例如 1、5、20 个 Gauge。
- 表中 `待基准测试` 项不能进入主网部署清单，必须在实现后补齐。
- 当前 Gas 表为 PRD target；主网上线前必须由 `forge snapshot` 生成真实数据并替换所有 `待基准测试` 项。

| 操作 | Gas 消耗 | 备注 |
|---|---:|---|
| Pair.swap | ~105,000 | 单次交换 |
| Router.swapExactTokensForTokens（2 跳） | ~230,000 | 含代币转账 |
| Router.addLiquidity | ~180,000 | 已有交易对 |
| Router.removeLiquidity | ~160,000 | - |
| TwapOracle.update | ~35,000 | 3 次 SSTORE |
| TwapOracle.consult | ~5,000 | view 调用 |
| VotingEscrow.createLock | ~200,000 | 新建锁仓 |
| LiquidityGauge.deposit | ~165,000 | 奖励更新 + Boost 重算 |
| LiquidityGauge.kick | ~55,000 | 仅在满足冷却期和最小变化阈值时刷新 Boost |
| LiquidityGauge.getReward | ~80,000 | 领取奖励 |
| GaugeController.vote | ~100,000 | - |
| FeeCollector.harvest | 待基准测试 | 受 LP 退出和路由兑换影响 |
| EmissionManager.finalizeEmission | 待基准测试 | 受 active Gauge 数量影响 |
| EmissionManager.distributeMany | 待基准测试 | 受 Gauge 数量影响 |

---

## 数值精度与舍入策略

### decimals 与单位

| 项目 | 策略 |
|---|---|
| ERC-20 decimals | 不假设固定 18 decimals，所有 token 金额按最小单位处理 |
| GOV decimals | 18 decimals |
| LP Token decimals | 18 decimals |
| price / TWAP | 使用 UQ112x112 定点数 |
| bps | 10000 = 100%，用于投票权、衰减率、阈值 |
| rewardPerToken | 使用 `1e18` 精度累积，向下取整 |

### 舍入方向

| 场景 | 舍入 |
|---|---|
| swap 输出 | 向下取整，保护池子和 LP |
| swap 输入反推 | 向上取整，确保用户支付足额输入 |
| addLiquidity quote | 按 Router 计算结果向下取可用量，剩余 token 退回用户 |
| removeLiquidity 输出 | 向下取整，dust 留在 Pair |
| LP mint | 向下取整，首次 mint 扣除 `MINIMUM_LIQUIDITY` |
| LP burn | 向下取整，dust 留在 Pair |
| VotingEscrow ve | 向下取整，避免凭空增加投票权 |
| Gauge reward | 向下取整，dust 留在 Gauge 或进入下一轮奖励会计 |
| FeeDistributor claim | 向下取整，未分配 dust 留在合约并可进入后续 checkpoint |

### dust 与小金额

- `amount == 0` 的状态变更入口必须 revert；view 查询和 `claimable == 0` 的 claim 按各自函数语义返回 0。
- 小额 swap 如果计算出的 `amountOut == 0` 必须 revert。
- 小额 LP mint 如果 `liquidity == 0` 必须 revert。
- 小额 reward claim 如果 `claimable == 0`，更新用户游标并返回 0，不 revert，不改变用户游标以外的奖励会计。
- Pair 中因舍入产生的 dust 留在 Pair，可通过 `skim` 处理超过 reserve 的余额，但不能破坏 reserve 会计。

### 上下溢策略

- Solidity `^0.8.20` 默认检查算术上下溢。
- 仅 Uniswap V2 累计价格差分允许依赖 `uint256` 溢出回绕语义；该逻辑必须用明确注释和测试覆盖。
- reserve 使用 `uint112` 时，余额超过 `type(uint112).max` 必须 revert。
- 时间戳压缩或差分计算必须覆盖 wraparound 测试。
- 所有 downcast 必须使用 SafeCast 或显式边界检查。

---

## 链上运维手册

本章节只描述链上合约脚本运维。前端、索引器、监控平台不在本仓库交付范围；合约层仅提供事件和状态，方便脚本和人工核对链上结果。

### 运维角色

| 角色 | 责任 |
|---|---|
| Keeper Bot | 定时执行 update、checkpoint、finalize emission、distribute、harvest |
| Keeper Operator | 维护 keeper 私钥、RPC、任务调度、失败重试 |
| Protocol Engineer | 判断失败原因、准备手动补跑或修复脚本 |
| Emergency Guardian | 执行有限暂停、kill 高风险 Gauge |
| Governance Timelock | 执行永久参数变更、恢复暂停、升级治理配置 |

Keeper 私钥不得拥有 Timelock、Minter、Vault distributor、route、feeTo 或 Guardian 权限。

### Keeper 任务

| 任务 | 频率 | 可手动执行者 | 失败升级阈值 | 脚本 |
|---|---|---|---|---|
| `TwapOracle.update()` | 每个 PERIOD 后 | Keeper / anyone | 超过 `stalenessThreshold` 立即升级 | `script/keeper/UpdateOracle.s.sol` |
| `GaugeController.checkpointGauge()` | 每周 epoch 冻结窗口开始后分页执行 | Keeper / anyone | epoch 开始后 6 小时未完成升级 | `script/keeper/CheckpointGauge.s.sol` |
| `GaugeController.finalizeEpoch()` | 所有 active Gauge checkpoint 完成后 | Keeper / anyone | epoch 开始后 6 小时未完成升级 | `script/keeper/CheckpointGauge.s.sol` |
| `Minter.updatePeriod()` | 每周 epoch 边界后 | Keeper / anyone | epoch 开始后 6 小时未完成升级 | `script/keeper/DistributeEmission.s.sol` |
| `EmissionManager.finalizeEmission(epoch)` | `Minter.updatePeriod()` 与 `finalizeEpoch()` 完成后 | Keeper / anyone | epoch 开始后 8 小时未完成升级 | `script/keeper/DistributeEmission.s.sol` |
| `EmissionManager.distributeMany(gauges, epoch)` | 每周 | Keeper / anyone | epoch 开始后 12 小时未完成升级 | `script/keeper/DistributeEmission.s.sol` |
| `FeeCollector.harvest(pair)` | 按需或每周 | Keeper | 目标 pair 超过 7 天未 harvest 升级 | `script/keeper/CheckpointFees.s.sol` |
| `FeeDistributor.checkpointToken()` | 每周 | Keeper / anyone | 收到 rewardToken 后 24 小时未 checkpoint 升级 | `script/keeper/CheckpointFees.s.sol` |

### SLA / RTO / RPO

| 项目 | 目标 |
|---|---|
| Oracle freshness SLA | `isStale() == false` 的时间占比 >= 99% |
| Emission distribution SLA | 每个 epoch 开始后 12 小时内完成分发 |
| Fee checkpoint SLA | rewardToken 入账后 24 小时内完成 checkpoint |
| RTO Critical | 发现 Critical 事故后 2 小时内完成有限暂停或风险入口关闭 |
| RTO High | 发现 High 事故后 12 小时内完成缓解方案 |
| RPO | 链上状态为最终记录；脚本失败不得造成不可重放的链下状态损失 |

### 手动补跑规则

- Oracle update、Gauge checkpoint、Minter update 均为 permissionless，任何人可补跑。
- Emission distribution 为 permissionless 执行入口，任何人可补跑；补跑只能执行已固化 allocation，不能改变权重、金额或收款 Gauge。
- FeeCollector harvest 涉及兑换路径和滑点，只允许 Keeper 或 Guardian/Timelock 指定的补救地址执行。
- 手动补跑必须记录交易哈希、区块高度、调用参数和失败原因。
- 同一 epoch 的 distribute 必须具备幂等保护，重复调用不得重复注入奖励。

### 紧急处理流程

| 事故 | 触发条件 | 处置 |
|---|---|---|
| Oracle stale | `isStale() == true` 或 keeper update 连续失败 | 手动 `update()`；失败则调用方停止依赖该 Oracle |
| FeeCollector 路由异常 | TWAP 偏离、兑换失败、route 疑似错误 | Guardian 暂停 `harvest`，Timelock 修正 route |
| Gauge 奖励异常 | `RewardShortfall`、重复 distribute、错误 Gauge 收款 | 暂停 EmissionManager 新分发，保留 withdraw/getReward |
| 恶意或错误 Gauge | Gauge 被攻击、LP Token 异常 | Guardian `killGauge`，下一 epoch 权重归零 |
| 权限泄露 | Keeper 或 Guardian 私钥泄露 | 立即撤销角色，Timelock 轮换权限 |
| Critical 合约漏洞 | 可导致资金损失或错误 mint | Guardian 执行有限暂停，Timelock 准备修复/迁移 |

紧急流程：

1. 分级：Protocol Engineer 判断 Critical / High / Medium / Low。
2. 止损：Emergency Guardian 只能暂停外围资金流或 kill Gauge，不暂停 Pair/Router 全局交易。
3. 复核：24 小时内提交 Governance Timelock 复核交易或恢复计划。
4. 修复：部署修复合约、迁移脚本或参数变更。
5. 恢复：Timelock 执行 `unpause` 或恢复参数。
6. 复盘：输出 RCA，补充测试、不变量与运维脚本。

---

## 贡献指南

- Fork 本仓库。
- 创建特性分支：`git checkout -b feature/amazing-feature`。
- 优先补充测试。
- 确保 `forge test` 通过。
- 运行 Gas 快照：`forge snapshot`。
- 提交更改并创建 Pull Request。

### 代码规范

- 遵循 Solidity 风格指南。
- public / external 函数必须有 NatSpec。
- 优先使用自定义错误，减少 require 字符串。
- 关键状态变更必须发出事件。
- 遵循 CEI 模式。

---

## 许可证

本项目采用 MIT 许可证，详见 LICENSE 文件。

---

## 致谢

- Uniswap V2：AMM 核心设计。
- Curve Finance：ve 代币经济学。
- Solidly / Velodrome：ve(3,3) 机制。
- OpenZeppelin：安全基础设施。
- Foundry：开发框架。

当前版本：v1 contracts-only，定位为准备上线的生产级智能合约协议工程。
