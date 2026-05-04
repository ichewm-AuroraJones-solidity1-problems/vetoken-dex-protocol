# VeToken DEX Protocol

> 基于 ve(3,3) 机制的去中心化交易协议，集成时间加权投票、流动性 Gauge 和 TWAP 预言机 — 构建于 Uniswap V2 核心机制之上。

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

---

## 目录

- [项目概述](#项目概述)
- [系统架构](#系统架构)
- [合约结构](#合约结构)
- [核心模块](#核心模块)
  - [AMM 模块](#1-amm-模块)
  - [预言机模块](#2-预言机模块)
  - [治理模块](#3-治理模块)
  - [激励模块](#4-激励模块)
- [安全模型](#安全模型)
- [快速开始](#快速开始)
- [部署指南](#部署指南)
- [参数配置](#参数配置)
- [测试](#测试)
- [Gas 基准](#gas-基准)
- [审计](#审计)
- [运维手册](#运维手册)
- [贡献指南](#贡献指南)
- [许可证](#许可证)

---

## 项目概述

VeToken DEX 是一个全栈 DeFi 协议，整合了以下组件：

| 组件 | 描述 |
|------|------|
| **AMM** | Uniswap V2 恒定乘积做市商，0.3% 交易手续费 |
| **Router** | 多跳交换路由，三层滑点保护机制 |
| **预言机** | 固定窗口 TWAP 预言机（24小时），抗操纵定价 |
| **veToken** | 投票托管治理，时间加权投票权 |
| **Gauge** | 流动性挖矿，基于 Gauge 权重分配代币排放 |
| **手续费分配** | 协议手续费收入分配给 veToken 持有者 |

### 设计理念

```text
┌─────────────────────────────────────────────────────────────┐
│ 用户提供流动性 → 获得 LP 代币                                   │
│ LP 代币质押到 Gauge → 获得 GOV 代币排放奖励                     │
│ GOV 锁定到 VotingEscrow → 获得 veGOV（投票权）                 │
│ veGOV 持有者投票决定 Gauge 权重 → 引导排放方向                   │
│ veGOV 持有者获得协议手续费收入分红                               │
│ 锁定时间越长 = 投票权越大 → 对齐长期利益                          │
└─────────────────────────────────────────────────────────────┘
```
---
## 系统架构

                       ┌──────────────┐
                       │   前端界面    │
                       └──────┬───────┘
                              │
                       ┌──────▼───────┐
                       │    Router    │ ← 滑点保护
                       └──────┬───────┘
                              │
           ┌──────────────────┼──────────────────┐
           │                  │                  │
    ┌──────▼───────┐   ┌──────▼───────┐   ┌──────▼───────┐
    │  Pair (A/B)  │   │  Pair (B/C)  │   │  Pair (A/C)  │
    └──────┬───────┘   └──────────────┘   └──────────────┘
           │
    ┌──────▼───────┐
    │ OracleSimple │ ← TWAP 价格馈送
    └──────────────┘

    ┌──────────────┐      ┌────────────────┐      ┌────────────────┐
    │   GovToken   │─────▶│  VotingEscrow  │─────▶│GaugeController │
    └──────────────┘      │    (veGOV)     │      └───────┬────────┘
                          └───────┬────────┘              │
                                  │               ┌───────▼────────┐
                          ┌───────▼────────┐      │ LiquidityGauge │
                          │ FeeDistributor │      │  (每个池一个)    │
                          └────────────────┘      └────────────────┘
                
---
## 合约结构
```
src/
├── amm/
│   ├── Pair.sol                    # 恒定乘积 AMM 交易池
│   ├── PairFactory.sol             # 确定性交易对部署工厂
│   ├── Router.sol                  # 交换/流动性路由 + 滑点保护
│   └── interfaces/
│       ├── IPair.sol
│       ├── IPairFactory.sol
│       └── IRouter.sol
├── oracle/
│   ├── ExampleOracleSimple.sol     # 固定窗口 TWAP 预言机
│   └── interfaces/
│       └── IOracleSimple.sol
├── governance/
│   ├── GovToken.sol                # ERC-20 治理代币（可铸造）
│   ├── VotingEscrow.sol            # ve 锁仓机制（ERC-721）
│   └── interfaces/
│       ├── IGovToken.sol
│       └── IVotingEscrow.sol
├── incentives/
│   ├── GaugeController.sol         # Gauge 权重投票 & 排放路由
│   ├── LiquidityGauge.sol          # 质押 + 奖励分发
│   ├── FeeDistributor.sol          # 协议手续费 -> veToken 持有者
│   └── interfaces/
│       ├── IGaugeController.sol
│       ├── ILiquidityGauge.sol
│       └── IFeeDistributor.sol
└── libraries/
    ├── UQ112x112.sol               # 112.112 定点数算术
    ├── Math.sol                    # sqrt, min, max
    └── SafeCast.sol                # 安全的 uint 向下转型
script/
├── Deploy.s.sol                    # 完整部署脚本
├── DeployTestnet.s.sol             # 测试网部署（含 Mock）
└── helpers/
    └── DeployConfig.sol            # 链特定参数配置
test/
├── unit/                           # 单元测试
│   ├── Pair.t.sol
│   ├── Router.t.sol
│   └── VotingEscrow.t.sol
├── integration/                    # 集成测试
│   └── FullCycle.t.sol
└── invariant/                      # 不变量测试
    └── PairInvariant.t.sol
```
---

## 核心模块

### 1. AMM 模块

#### Pair.sol

恒定乘积自动化做市商（x × y = k）。

| 函数 | 描述 |
|------|------|
| `mint(to)` | 存入代币 → 铸造 LP 代币 |
| `burn(to)` | 销毁 LP 代币 → 取回代币 |
| `swap(amount0Out, amount1Out, to)` | 执行交换，包含 k 值校验 |
| `skim(to)` | 强制余额与储备量对齐（多余部分发给 to） |
| `sync()` | 强制储备量与余额对齐 |

**核心不变量：** 每次 swap 后，`balance0Adjusted × balance1Adjusted ≥ reserve0 × reserve1 × 1000²`

**src/amm/interfaces/IPair.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPair {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);

    /// @notice 上一次收取协议费时的 k 值
    function kLast() external view returns (uint256);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 由 Factory 调用一次，设置交易对的两个代币
    function initialize(address token0, address token1) external;

    /// @notice 铸造 LP token，调用前需先将两种代币转入 Pair
    /// @return liquidity 铸造的 LP 数量
    function mint(address to) external returns (uint256 liquidity);

    /// @notice 销毁 LP token 取回底层资产，调用前需先将 LP 转入 Pair
    /// @return amount0 返还的 token0 数量
    /// @return amount1 返还的 token1 数量
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice 执行兑换，调用前需先将输入代币转入 Pair
    /// @param amount0Out 期望获得的 token0 数量
    /// @param amount1Out 期望获得的 token1 数量
    /// @param to 接收地址
    /// @param data 非空则触发 flash swap 回调
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice 将余额同步到 reserves（处理意外转入的代币）
    function skim(address to) external;

    /// @notice 强制 reserves 匹配实际余额
    function sync() external;
}
```

#### IPairFactory
**src/amm/interfaces/IPairFactory.sol**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPairFactory {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 totalPairs);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 协议手续费接收地址（address(0) 表示不收取）
    function feeTo() external view returns (address);

    /// @notice 有权修改 feeTo 的管理员
    function feeToSetter() external view returns (address);

    /// @notice 查询两个代币对应的 Pair 地址
    function getPair(address tokenA, address tokenB) external view returns (address pair);

    /// @notice 按索引获取 Pair 地址
    function allPairs(uint256 index) external view returns (address pair);

    /// @notice 已创建的 Pair 总数
    function allPairsLength() external view returns (uint256);

    /// @notice 用于 CREATE2 部署时计算地址的 init code hash
    function pairCodeHash() external pure returns (bytes32);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 创建交易对，使用 CREATE2 确定性部署
    /// @return pair 新创建的 Pair 合约地址
    function createPair(address tokenA, address tokenB) external returns (address pair);

    /// @notice 设置协议费接收地址
    function setFeeTo(address) external;

    /// @notice 转移 feeToSetter 权限
    function setFeeToSetter(address) external;
}
```

#### Router.sol — 滑点保护

三层防护机制，抵御价格操纵和 MEV 攻击：
```
┌─────────────────────────────────────────────────────────────────┐
│ 第一层：DEADLINE（时间保护）                                       │
│ ──────────────────────────                                      │
│ modifier ensure(uint256 deadline)                               │
│ • 防止过期交易被执行                                               │
│ • 用户设置：block.timestamp + N 秒                                │
│ • 交易在 mempool 中等太久 → 自动撤销                                │
│                                                                 │
│ 第二层：AMOUNT BOUNDS（金额保护）                                   │
│ ─────────────────────────────                                   │
│ • swapExactTokensForTokens: amountOutMin（最少获得）              │
│ • swapTokensForExactTokens: amountInMax（最多支付）               │
│ • addLiquidity: amountAMin, amountBMin（最少投入）                │
│ • removeLiquidity: amountAMin, amountBMin（最少取回）             │
│ • 防止在不利价格下执行交易                                          │
│                                                                 │
│ 第三层：K 值校验（Pair 层面）                                       │
│ ─────────────────────────                                       │
│ • 在 Pair.swap() 内部强制执行                                     │
│ • 数学上保证不可能抽干储备                                          │
│ • 验证时已扣除 0.3% 手续费                                         │
└─────────────────────────────────────────────────────────────────┘
```
| Router 函数 | 时间保护 | 金额保护 | K值校验 |
|-------------|:--------:|:--------:|:-------:|
| `addLiquidity` | ✅ | `amountAMin`, `amountBMin` | — |
| `removeLiquidity` | ✅ | `amountAMin`, `amountBMin` | — |
| `swapExactTokensForTokens` | ✅ | `amountOutMin` | ✅ |
| `swapTokensForExactTokens` | ✅ | `amountInMax` | ✅ |

**滑点保护完整流程图：**
``` text
用户前端操作                               合约层保护
──────────                               ──────────

① 设置滑点容忍度（如 1%）                  amountOutMin = 预期输出 × (1 - 1%)
   例：3000 × 0.99 = 2970 USDC

② 设置交易截止时间（如 20 分钟）            deadline = block.timestamp + 1200

③ 点击「交换」 →                          Router.swapExactTokensForTokens(
                                            amountIn: 1 ETH,
                                            amountOutMin: 2970 USDC, ← 滑点保护
                                            path: [WETH, USDC],
                                            to: 用户地址,
                                            deadline: now + 1200 ← 时间保护
                                          )

等待打包中...

情况 A: 20分钟内被打包，输出 2980 USDC
→ 2980 ≥ 2970 ✅ 交易成功

情况 B: 20分钟内被打包，但被三明治攻击，输出仅 2950 USDC
→ 2950 < 2970 ❌ revert "INSUFFICIENT_OUTPUT_AMOUNT"

情况 C: 网络拥堵，25分钟后才被打包
→ block.timestamp > deadline ❌ revert "EXPIRED"
```

**src/amm/interfaces/IRouter.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRouter {
    // ═══════════════════════════════════════════
    //              IMMUTABLES
    // ═══════════════════════════════════════════
    function factory() external view returns (address);
    function WETH() external view returns (address);

    // ═══════════════════════════════════════════
    //            ADD LIQUIDITY
    // ═══════════════════════════════════════════

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    // ═══════════════════════════════════════════
    //           REMOVE LIQUIDITY
    // ═══════════════════════════════════════════

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    // ═══════════════════════════════════════════
    //                 SWAP
    // ═══════════════════════════════════════════

    /// @notice 指定输入数量，换取尽可能多的输出
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice 指定输出数量，花费尽可能少的输入
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice 用精确数量的 ETH 换 Token
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice 用 Token 换精确数量的 ETH
    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice 用精确数量的 Token 换 ETH
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice 用 ETH 换精确数量的 Token
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    // ═══════════════════════════════════════════
    //            PURE HELPERS
    // ═══════════════════════════════════════════

    /// @notice 根据比例计算等价数量
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB);

    /// @notice 给定输入计算输出（含 0.3% 手续费）
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);

    /// @notice 给定输出计算所需输入
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn);

    /// @notice 沿路径计算每一跳的输出
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /// @notice 沿路径计算每一跳的输入
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}
```
---

### 2. 预言机模块

#### ExampleOracleSimple.sol

固定窗口 TWAP 预言机，基于 Uniswap V2 累计价格机制。

**工作原理：**
``` text
时间轴: T0 ─────── 24小时窗口 ─────── T1 ─────── 24小时窗口 ─────── T2
        │                            │                            │
    [快照₀]                      [快照₁]                      [快照₂]
        │                            │
      平均价格 =                   平均价格 =
  (累计值₁ - 累计值₀)          (累计值₂ - 累计值₁)
     ÷ (T1 - T0)                  ÷ (T2 - T1)
```

**src/oracle/interfaces/IOracleSimple.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracleSimple {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event OracleUpdated(uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 预言机绑定的 Pair
    function pair() external view returns (address);

    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice TWAP 窗口期（秒），如 86400 = 24h
    function PERIOD() external view returns (uint256);

    /// @notice 上次更新时的累积价格快照
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);

    /// @notice 上次更新的时间戳
    function blockTimestampLast() external view returns (uint32);

    /// @notice 查询 TWAP 价格
    /// @param token 输入代币地址（必须是 token0 或 token1）
    /// @param amountIn 输入数量
    /// @return amountOut 等价的输出数量
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 更新 TWAP 快照，需间隔 >= PERIOD
    /// @dev 任何人都可调用（Keeper 定期触发）
    function update() external;
}
```
#### 为什么用 TWAP 而不是现货价格？
- 现货价格（瞬时）： 攻击者用闪电贷在 1 个区块内就能操纵 → 不安全
- TWAP（24小时平均）： 攻击者必须持续 24 小时维持虚假价格 → 成本极高，几乎不可能

| 属性 | 值 |
|------|-----|
| 时间窗口 | 24 小时（可配置） |
| 存储槽位 | 3 个（cumulative0, cumulative1, timestamp） |
| 更新权限 | 无需许可（任何人可调用） |
| 每次更新 Gas | ~35,000 |
| 抗操纵性 | 攻击者需维持整个 PERIOD 的虚假价格 |

#### API 接口：

```solidity
// 刷新 TWAP 平均价格（间隔 ≥ PERIOD 才会实际更新）
function update() external;

// 查询价格：输入 amountIn 的 tokenIn，输出多少 tokenOut
function consult(address tokenIn, uint256 amountIn)
    external view returns (uint256 amountOut);

// 预言机是否已初始化（至少完成一次完整的 update 周期）
function isReady() external view returns (bool);
```

#### 状态机：
``` text
[部署] ── 构造函数记录快照₀ ──→ [等待首次 update]
                                    │
                            ≥ 24小时后调用 update()
                                    │
                                    ▼
                              [就绪] ←── 后续 update() 持续刷新价格
                           initialized = true
                           consult() 可用
```

#### 设计局限
- 不适用于借贷/清算场景（那种需要 Chainlink 级别的保障）
- 价格延迟最多一个 PERIOD
- 需要外部调用者定期触发 update()
---

### 3. 治理模块
#### GovToken.sol
**标准 ERC-20 治理代币，带有受控铸造功能。**

|特性	|详情|
|------|-----|
|代币符号|GOV（可配置）|
|最大供应量|	强制上限|
|铸造权限|限制为授权的铸造者|
|转账|无限制|

**src/governance/interfaces/IGovToken.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IGovToken is IERC20 {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event MinterUpdated(address indexed previousMinter, address indexed newMinter);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 代币名称
    function name() external view returns (string memory);

    /// @notice 代币符号
    function symbol() external view returns (string memory);

    /// @notice 精度（18）
    function decimals() external view returns (uint8);

    /// @notice 当前有权铸造的地址（通常是 LiquidityGauge 或 Minter 合约）
    function minter() external view returns (address);

    /// @notice 最大供应量上限
    function MAX_SUPPLY() external view returns (uint256);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 铸造代币，仅 minter 可调用
    /// @param to 接收地址
    /// @param amount 铸造数量
    function mint(address to, uint256 amount) external;

    /// @notice 设置新的 minter 地址，仅 owner 可调用
    function setMinter(address newMinter) external;
}
```
#### VotingEscrow.sol
**锁定 GOV 代币 1 周 – 4 年 → 获得 veGOV 投票权。**

```text
投票权 = 锁定数量 × (剩余锁定时间 / 最大锁定时间)

示例：
  锁定 1000 GOV，期限 4 年 → 1000 veGOV
  锁定 1000 GOV，期限 2 年 → 500 veGOV
  锁定 1000 GOV，期限 1 年 → 250 veGOV

  投票权随时间线性衰减 → 激励用户续锁
```

|函数	|描述|
|------|-----|
|createLock(amount, unlockTime)	|锁定代币，获得 veGOV|
|increaseAmount(amount)	|向现有锁仓追加代币|
|increaseUnlockTime(newUnlockTime)	|延长锁定期限|
|withdraw()	|锁定到期后提取代币|
|balanceOf(account)	|当前投票权（持续衰减中）|
|totalSupply()	|veGOV 总供应量|

**src/governance/interfaces/IVotingEscrow.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVotingEscrow {
    // ═══════════════════════════════════════════
    //                 STRUCTS
    // ═══════════════════════════════════════════
    struct LockedBalance {
        int128 amount;
        uint256 end; // 锁定到期时间（按 week 对齐）
    }

    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 value,
        uint256 lockTime,
        uint256 timestamp
    );
    event Withdraw(address indexed provider, uint256 indexed tokenId, uint256 value, uint256 timestamp);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 锁仓的底层 ERC-20 代币
    function token() external view returns (address);

    /// @notice 当前已发行的 veNFT 总数
    function tokenId() external view returns (uint256);

    /// @notice 查询某个 veNFT 的锁仓信息
    function locked(uint256 _tokenId) external view returns (LockedBalance memory);

    /// @notice 查询某个 veNFT 在当前时刻的投票权重
    /// @dev 权重 = amount * (lockEnd - now) / MAX_LOCK_TIME，线性衰减
    function balanceOfNFT(uint256 _tokenId) external view returns (uint256);

    /// @notice 查询某个 veNFT 在指定时间点的投票权重
    function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view returns (uint256);

    /// @notice 全局总投票权重
    function totalSupply() external view returns (uint256);

    /// @notice 指定时间点的全局总投票权重
    function totalSupplyAt(uint256 _t) external view returns (uint256);

    /// @notice 最大锁定时间（4 年 = 4 * 365 * 86400）
    function MAX_LOCK_TIME() external view returns (uint256);

    /// @notice 查询 veNFT 的 owner
    function ownerOf(uint256 _tokenId) external view returns (address);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 创建锁仓，铸造 veNFT
    /// @param _value 锁入的代币数量
    /// @param _lockDuration 锁定时长（秒），会向下对齐到整周
    /// @return _tokenId 新铸造的 veNFT ID
    function createLock(uint256 _value, uint256 _lockDuration) external returns (uint256 _tokenId);

    /// @notice 增加锁仓数量（不改变到期时间）
    function increaseAmount(uint256 _tokenId, uint256 _value) external;

    /// @notice 延长锁定时间（不增加数量）
    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external;

    /// @notice 到期后提取全部代币，销毁 veNFT
    function withdraw(uint256 _tokenId) external;

    /// @notice 合并两个 veNFT（将 _from 并入 _to）
    function merge(uint256 _from, uint256 _to) external;
}
```
---
### 4. 激励模块

#### GaugeController.sol
**src/incentives/interfaces/IGaugeController.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGaugeController {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event GaugeAdded(address indexed gauge);
    event VoteForGauge(address indexed voter, uint256 indexed tokenId, address indexed gauge, uint256 weight);
    event NewEpoch(uint256 epoch, uint256 timestamp);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice VotingEscrow 合约地址
    function votingEscrow() external view returns (address);

    /// @notice 一个 epoch 的时长（7 天）
    function EPOCH_DURATION() external view returns (uint256);

    /// @notice 当前 epoch 编号
    function currentEpoch() external view returns (uint256);

    /// @notice 某个 gauge 在当前 epoch 的权重占比 (basis points, 10000 = 100%)
    function gaugeWeight(address gauge) external view returns (uint256);

    /// @notice 某个 gauge 的相对权重（归一化后，精度 1e18）
    /// @dev relativeWeight = gaugeWeight / totalWeight
    function gaugeRelativeWeight(address gauge) external view returns (uint256);

    /// @notice 某个 gauge 在指定 epoch 的相对权重
    function gaugeRelativeWeightAt(address gauge, uint256 epoch) external view returns (uint256);

    /// @notice 全部已注册的 gauge 列表
    function gauges() external view returns (address[] memory);

    /// @notice gauge 是否已注册
    function isGauge(address gauge) external view returns (bool);

    /// @notice 查询某个 veNFT 在本 epoch 剩余可用投票权重
    function usedVotePower(uint256 tokenId) external view returns (uint256);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 注册新 gauge（仅 governance/owner）
    function addGauge(address gauge) external;

    /// @notice 移除 gauge（仅 governance/owner）
    function removeGauge(address gauge) external;

    /// @notice 用 veNFT 给 gauge 投票
    /// @param tokenId 投票者持有的 veNFT
    /// @param gaugeVotes 数组：每个元素 = (gauge地址, 权重百分比)
    function vote(uint256 tokenId, address[] calldata gaugeAddresses, uint256[] calldata weights) external;

    /// @notice 重置某个 veNFT 的所有投票
    function reset(uint256 tokenId) external;

    /// @notice 推进到新 epoch，结算权重（Keeper 调用）
    function checkpoint() external;
}
```

**基于 veGOV 投票管理 Gauge 权重。**
每周流程：
  1. veGOV 持有者调用 vote(gauge, weight)
  2. Controller 汇总投票 → 计算 gauge_relative_weight
  3. 排放按比例分配：

     gauge 排放 = 每周总排放 × gauge 相对权重

#### LiquidityGauge.sol
**src/incentives/interfaces/ILiquidityGauge.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILiquidityGauge {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardNotified(uint256 amount, uint256 epoch);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 该 Gauge 对应的 LP token（即 Pair 地址）
    function stakingToken() external view returns (address);

    /// @notice 奖励代币（GovToken）
    function rewardToken() external view returns (address);

    /// @notice GaugeController 地址
    function controller() external view returns (address);

    /// @notice 该 Gauge 内的 LP 总质押量
    function totalSupply() external view returns (uint256);

    /// @notice 某用户的质押余额
    function balanceOf(address account) external view returns (uint256);

    /// @notice 每单位质押 LP 累积的奖励（精度 1e18）
    function rewardPerTokenStored() external view returns (uint256);

    /// @notice 实时计算的 rewardPerToken
    function rewardPerToken() external view returns (uint256);

    /// @notice 某用户当前可领取的奖励数量
    function earned(address account) external view returns (uint256);

    /// @notice 当前 epoch 的奖励发放速率（token/sec）
    function rewardRate() external view returns (uint256);

    /// @notice 当前奖励周期结束时间
    function periodFinish() external view returns (uint256);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 质押 LP token
    /// @param amount 质押数量
    function deposit(uint256 amount) external;

    /// @notice 质押并代为指定接收者（用于 Router 集成）
    function depositFor(address account, uint256 amount) external;

    /// @notice 取回质押的 LP token
    /// @param amount 取回数量
    function withdraw(uint256 amount) external;

    /// @notice 领取累积的奖励
    /// @return reward 领取的奖励数量
    function getReward() external returns (uint256 reward);

    /// @notice 取回全部质押 + 领取奖励
    function exit() external;

    /// @notice 由 Controller/Minter 调用，通知本 epoch 分配到的奖励总量
    /// @param amount 本期奖励总量
    function notifyRewardAmount(uint256 amount) external;
}
```

**LP 代币质押合约，带有流式奖励分发。**
|函数	|描述|
|------|-----|
|deposit(amount)	|质押 LP 代币|
|withdraw(amount)	|取消质押 LP 代币|
|claim()	|领取累积的 GOV 奖励|
|notifyRewardAmount(amount)	|管理员：注入新一轮奖励|
**奖励数学模型**： 基于 Synthetix StakingRewards 模式，按秒累计奖励。

#### FeeDistributor.sol
**src/incentives/interfaces/IFeeDistributor.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeDistributor {
    // ═══════════════════════════════════════════
    //                  EVENTS
    // ═══════════════════════════════════════════
    event CheckpointToken(uint256 timestamp, uint256 tokens);
    event Claimed(uint256 indexed tokenId, uint256 amount, uint256 epoch);

    // ═══════════════════════════════════════════
    //              READ FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice VotingEscrow 合约
    function votingEscrow() external view returns (address);

    /// @notice 分发的代币（可以是某个稳定币或 WETH，取决于协议费收集方式）
    function token() external view returns (address);

    /// @notice 起始时间戳（向下对齐到 epoch 起点）
    function startTime() external view returns (uint256);

    /// @notice 每个 epoch 分配的 fee token 总量
    function tokensPerEpoch(uint256 epoch) external view returns (uint256);

    /// @notice 某个 veNFT 上次领取到哪个 epoch
    function lastClaimEpoch(uint256 tokenId) external view returns (uint256);

    /// @notice 某个 veNFT 可领取的累计待领金额
    function claimable(uint256 tokenId) external view returns (uint256);

    // ═══════════════════════════════════════════
    //             WRITE FUNCTIONS
    // ═══════════════════════════════════════════

    /// @notice 记录新的 fee token 到当前 epoch（Keeper 调用）
    /// @dev 读取合约余额增量，分配到本 epoch
    function checkpointToken() external;

    /// @notice 记录 VotingEscrow 的 totalSupply 快照
    function checkpointTotalSupply() external;

    /// @notice 领取指定 veNFT 的累积手续费分红
    /// @param tokenId veNFT ID
    /// @return amount 领取的数量
    function claim(uint256 tokenId) external returns (uint256 amount);

    /// @notice 批量领取多个 veNFT 的分红
    function claimMany(uint256[] calldata tokenIds) external returns (uint256[] memory amounts);
}
```

**按比例将协议交易手续费分配给 veGOV 持有者。**

用户份额 = (用户 veGOV / 总 veGOV) × 每周手续费收入

---
## 安全模型

### 威胁分析

|威胁	|攻击向量	|缓解措施|
|------|--------|--------|
|闪电贷价格操纵	|借入 → 操纵池子 → 获利	|预言机使用 24h TWAP；单区块操纵无效|
|三明治攻击（MEV）	|抢跑 + 尾跑用户交易	|Router: amountOutMin + deadline|
|过期交易执行	|交易在波动期间被延迟打包	|Router: deadline 修饰符|
|重入攻击	|代币转账时的回调	|Pair 所有状态修改函数加 nonReentrant|
|治理攻击	|闪电借入 GOV → 投票	|VotingEscrow 要求时间锁；无法闪电治理|
|LP 代币通胀攻击	|首存者操纵	|首次铸造时永久锁定最小流动性（1000 wei）|
|预言机过期	|update() 长时间未被调用	|前端/Keeper 监控；isReady() 检查|
|累计价格溢出	|Uint256 溢出	|设计如此：溢出算术是正确的（差值有效）|

### 权限控制矩阵

|函数	|调用者	|权限|
|------|--------|--------|
|Pair.mint/burn/swap	|Router / EOA	|无需许可|
|Pair.skim/sync	|任何人	|无需许可|
|OracleSimple.update	|任何人	|无需许可|
|GovToken.mint	|铸造者角色	|角色限制|
|GaugeController.addGauge	|管理员	|仅 Owner|
|GaugeController.vote	|veGOV 持有者	|余额 > 0|
|LiquidityGauge.notifyReward	|GaugeController	|授权调用者|
|PairFactory.setFeeTo	|管理员	|仅 Owner|

### 系统不变量

|编号	|模块	|不变量	|执行方式|
|------|--------|--------|--------|
|I-1	|Pair	|reserve0 × reserve1 ≤ k（k 扣除手续费后永不减少）	|swap() 内部校验|
|I-2	|Pair	|totalSupply > 0 ⟹ reserve0 > 0 ∧ reserve1 > 0	|burn() 逻辑保证|
|I-3	|VotingEscrow	|∑ balanceOf(user) ≤ totalSupply（任意时间点）	|衰减公式|
|I-4	|VotingEscrow	|withdraw() 仅在 unlock_time 之后成功	|时间检查|
|I-5	|Oracle	|price0Average × price1Average ≈ 2^224（互为倒数）	|数学恒等式|
|I-6	|Gauge	|∑ 已领取奖励 ≤ 总通知奖励	|奖励会计逻辑|
|I-7	|Router	|输出金额在外部调用之前计算完毕	|CEI 模式|
---

## 快速开始

### 前置要求

|工具	|版本	|安装方式|
|------|--------|--------|
|Foundry	|≥ 0.2.0	|curl -L https://foundry.paradigm.xyz | bash && foundryup|
|Node.js	|≥ 18.0	|部署脚本需要|
|Git	|≥ 2.30	|—|

### 安装
```bash
# 克隆仓库
git clone [https://github.com/your-org/vetoken-dex.git](https://github.com/your-org/vetoken-dex.git)
cd vetoken-dex

# 安装依赖
forge install

# 复制环境配置
cp .env.example .env
# 编辑 .env 填入私钥和 RPC URL

# 编译
forge build

# 运行测试
forge test
```

### 环境变量

```bash
# .env
DEPLOYER_PRIVATE_KEY=0x...
MAINNET_RPC_URL=[https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY](https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY)
SEPOLIA_RPC_URL=[https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY](https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY)
ETHERSCAN_API_KEY=YOUR_KEY

# 协议参数
GOV_TOKEN_NAME="VeToken Governance"
GOV_TOKEN_SYMBOL="GOV"
GOV_TOKEN_CAP=1000000000e18          # 10 亿总量上限
MAX_LOCK_TIME=126144000              # 4 年（秒）
ORACLE_PERIOD=86400                  # 24 小时（秒）
INITIAL_MINT=100000000e18            # 初始铸造 1 亿
```
---

## 部署指南

### 部署顺序
依赖关系必须按精确顺序部署：
```text
阶段 1：核心基础设施
───────────────────
步骤 1  → GovToken
步骤 2  → VotingEscrow(govToken, maxLockTime)
步骤 3  → PairFactory()
步骤 4  → Router(factory)

阶段 2：初始交易池
───────────────────
步骤 5  → PairFactory.createPair(GOV, WETH)
步骤 6  → Router.addLiquidity(...)  // 注入初始流动性

阶段 3：预言机
───────────────────
步骤 7  → ExampleOracleSimple(pair_GOV_WETH)
步骤 8  → [等待 ≥ 24 小时]
步骤 9  → ExampleOracleSimple.update()  // 首次 TWAP 计算

阶段 4：激励系统
───────────────────
步骤 10 → FeeDistributor(rewardToken, votingEscrow)
步骤 11 → PairFactory.setFeeTo(feeDistributor)
步骤 12 → GaugeController(votingEscrow)
步骤 13 → LiquidityGauge(lpToken, govToken, gaugeController)
步骤 14 → GaugeController.addGauge(liquidityGauge, gaugeType, weight)

阶段 5：激活
───────────────────
步骤 15 → GovToken.setMinter(gaugeController)  // 移交铸造权
步骤 16 → LiquidityGauge.notifyRewardAmount(initialReward)  // 启动排放
步骤 17 → 在区块浏览器上验证所有合约
```

### 部署命令

```bash
# 测试网（Sepolia）
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv

# 主网（请谨慎操作）
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --slow \
  -vvvv
```

### 部署后检查清单

- 所有合约已在 Etherscan 上验证
- 预言机 update() 已调用且 isReady() == true
- 核心交易池已注入初始流动性
- 手续费接收地址设置正确
- 铸造者角色已转移给 GaugeController
- 管理员已设置为多签钱包（从部署者 EOA 转移）
- 前端已指向正确的合约地址
- Subgraph 已部署并开始索引
- 监控/告警系统已配置
---

## 参数配置

### 协议参数

|参数	|默认值	|范围	|所在合约|
|------|--------|--------|--------|
|交换手续费	|0.3%（3/1000）	|硬编码	|Pair.sol|
|协议手续费份额	|交换手续费的 1/6	|0 或 1/6	|Pair.sol|
|预言机 PERIOD	|24 小时	|≥ 10 分钟	|ExampleOracleSimple.sol|
|最大锁定时间	|4 年	|不可变	|VotingEscrow.sol|
|WEEK 常量	|7 天	|不可变	|VotingEscrow.sol|
|最小锁定期限	|1 周	|不可变	|VotingEscrow.sol|
|奖励周期	|7 天	|可配置	|LiquidityGauge.sol|
|最小流动性	|1000 wei	|硬编码	|Pair.sol|

### 前端推荐参数

|参数	|建议默认值	|说明|
|------|--------|--------|
|滑点容忍度	|0.5% – 1.0%	|用户可调节|
|交易截止时间	|20 分钟	|用户可调节|
|价格影响警告	|> 1%	|显示警告 UI|
|价格影响阻断	|> 15%	|要求用户二次确认|
|预言机过期警告	|> 2 × PERIOD	|提示预言机数据可能不新鲜|
---

## 测试

### 测试套件
```bash
# 运行所有测试
forge test

# 仅单元测试
forge test --match-path "test/unit/*"

# 集成测试
forge test --match-path "test/integration/*"

# 不变量/模糊测试（扩展运行）
forge test --match-path "test/invariant/*" --fuzz-runs 10000

# Fork 测试（需要 RPC）
forge test --match-path "test/fork/*" --fork-url $MAINNET_RPC_URL

# Gas 报告
forge test --gas-report

# 覆盖率报告
forge coverage --report lcov
genhtml lcov.info -o coverage/
open coverage/index.html
```

### 测试覆盖率目标

|模块	|目标	|关键路径|
|------|--------|--------|
|Pair	|≥ 95%	|swap k值校验、mint/burn 数学、重入防护|
|Router	|≥ 95%	|所有滑点检查、多跳、边界金额|
|Oracle	|≥ 90%	|PERIOD 强制执行、溢出处理、未初始化状态|
|VotingEscrow	|≥ 95%	|锁定/解锁时间逻辑、衰减计算、溢出|
|GaugeController	|≥ 90%	|投票权重计算、epoch 转换|
|LiquidityGauge	|≥ 95%	|奖励累积、存取款时序|
|FeeDistributor	|≥ 90%	|领取计算、epoch 处理|

### 关键测试场景
**Swap 测试：**
- 精确输入交换，输出满足最小值
- 精确输入交换，输出不足时 revert（滑点保护）
- 精确输出交换，输入在最大值范围内
- 精确输出交换，所需输入超过最大值时 revert
- 多跳交换（3+ 代币路径）
- 超过 deadline 后交换 revert
- 零金额交换 revert
- 超过储备量的交换 revert

**预言机测试：**
- 初始化完成前 consult() revert
- PERIOD 内重复 update() 为 no-op
- TWAP 反映时间加权平均（非现货价格）
- 正确处理累计价格溢出
- 大额 swap 后价格反映 TWAP（非瞬时价格）

**VotingEscrow 测试：**
- 投票权与锁定时间成正比
- 投票权线性衰减
- 解锁前无法提取
- 可延长锁定时间
- 可追加锁定金额
- 总供应量 = 所有余额之和

**不变量测试：**
- Pair k 值永不减少（模糊测试）
- VotingEscrow 总供应量一致性（模糊测试）
- Gauge 总分发 ≤ 总通知金额（模糊测试）
---

## Gas 基准

|操作	|Gas 消耗	|备注
|------|--------|--------|
|Pair.swap	|~105,000	|单次交换|
|Router.swapExactTokensForTokens（2跳）	|~230,000	|含代币转账|
|Router.addLiquidity	|~180,000	|已有交易对|
|Router.removeLiquidity	|~160,000	|—|
|OracleSimple.update	|~35,000	|3 次 SSTORE|
|OracleSimple.consult	|~5,000	|View 调用|
|VotingEscrow.createLock	|~200,000	|新建锁仓|
|LiquidityGauge.deposit	|~120,000	|含奖励更新|
|LiquidityGauge.claim	|~80,000	|领取奖励|
|GaugeController.vote	|~100,000	|—|
---

## 审计

### 推荐审计范围：
- 关键（Critical）： Pair.sol、Router.sol、VotingEscrow.sol
- 高危（High）： GaugeController.sol、LiquidityGauge.sol、FeeDistributor.sol
- 中危（Medium）： ExampleOracleSimple.sol、PairFactory.sol、GovToken.sol

### 漏洞赏金计划
**主网上线后将建立漏洞赏金计划：**

|严重程度	|奖励|
|------|--------|
|严重（资金丢失）	|最高 $100,000|
|高危（资金锁定 / 操纵）	|最高 $25,000|
|中危（恶意干扰 / DoS）	|最高 $5,000|
|低危（信息性）	|最高 $1,000|
---

## 运维手册

### Keeper 任务

|任务	|频率	|重要性	|脚本|
|------|--------|--------|--------|
|OracleSimple.update()	|每 ~24 小时	|高	|script/keeper/UpdateOracle.s.sol|
|GaugeController.checkpoint()	|每周	|高	|script/keeper/Checkpoint.s.sol|
|FeeDistributor.checkpointToken()	|每周	|中	|script/keeper/FeeCheckpoint.s.sol|

### 紧急处理流程

**场景：发现严重漏洞**
```text
1. 暂停（如有暂停机制）：
   → owner.pause()

2. 通告：
   → Discord 公告
   → Twitter 安全通知
   → 前端显示警告横幅

3. 评估：
   → 确定受影响资金规模
   → 评估漏洞利用可行性

4. 缓解：
   → 部署修复合约
   → 必要时迁移状态
   → 如需救援，协调 MEV 搜索者进行白帽抢跑

5. 事后复盘：
   → 根本原因分析
   → 流程改进
   → 如适用，补偿受影响用户
```

### 监控告警

|监控指标	|阈值	|处理方式|
|------|--------|--------|
|预言机过期	|> 48小时未更新	|立即调用 update()|
|池子 TVL 骤降	|1小时内下降 > 30%	|调查原因|
|异常交换规模	|> 池子储备的 10%	|审查是否有操纵|
|合约 ETH 余额	|> 0（应为 0）	|调查滞留资金|
|治理提案	|任何新提案	|审查并通报|
---

## 贡献指南

- Fork 本仓库
- 创建特性分支（git checkout -b feature/amazing-feature）
- 先写测试（鼓励 TDD）
- 确保所有测试通过（forge test）
- 运行 Gas 快照（forge snapshot）
- 提交更改（git commit -m 'feat: 添加某功能'）
- 推送分支（git push origin feature/amazing-feature）
- 创建 Pull Request

### 代码规范

- 遵循 Solidity 风格指南
- 所有 public/external 函数必须有 NatSpec 文档
- 优先使用自定义错误（Custom Error）而非 require 字符串（节省 Gas）
- 所有状态变更必须发出事件（Event）
- 强制遵循 CEI（检查-生效-交互）模式
---

## 许可证
- 本项目采用 MIT 许可证 - 详见 LICENSE 文件。
---

## 致谢
- Uniswap V2 — AMM 核心设计
- Curve Finance — ve 代币经济学
- Solidly / Velodrome — ve(3,3) 机制
- OpenZeppelin — 安全基础设施
- Foundry — 开发框架










