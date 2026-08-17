# Flash Swap 跨池闪电套利测试说明

## 概述

本模块演示基于 Uniswap V2 闪电兑换（Flash Swap）的跨池套利，涉及以下合约：

- **TokenA / TokenB**（`src/flash-swap/`）— 基于 OpenZeppelin ERC20 的测试代币，初始供应 1,000,000 枚全部铸造给部署者
- **UniswapV2Factory × 2** — 官方 [v2-core](https://github.com/Uniswap/v2-core) 工厂合约（Solidity 0.5.16），部署两份形成两个相互独立的 Uniswap
- **PoolA / PoolB** — 两个 Uniswap 各自创建的 TokenA/TokenB 交易对，通过错配储备制造价差：
  - PoolA：10000 TokenA / 10000 TokenB（价格 1:1）
  - PoolB：10000 TokenA / 20000 TokenB（价格 1:2，TokenA 在 PoolB 更值钱）
- **FlashSwapArbitrage** — 闪电套利合约（逻辑参考 V2 官方 ExampleFlashSwap 示例）

## 套利流程

```
1. startArbitrage(100e18)
   └─ 调 PoolA.pair.swap() 闪电借出 100 TokenA（V2 先发货、后回调）

2. uniswapV2Call 回调
   ├─ 把收到的 TokenA 全部转入 PoolB，按 x*y=k 兑出约 197.4 TokenB
   ├─ 计算偿还 PoolA 所需的 TokenB ≈ 101.3（含 0.3% 手续费的 getAmountIn 定价）
   ├─ require(兑得数量 > 偿还数量)，否则 revert "FlashSwap: NO_PROFIT"
   └─ 将 101.3 TokenB 还回 PoolA 的 Pair，剩余 ≈ 96.1 TokenB 留存为利润
```

关键原理：V2 Pair 的 K 值检查允许用**任一侧代币**偿还闪电贷（只要求还款后满足不变量），因此「借 TokenA、还 TokenB」合法。

## 测试结果

5 个测试全部通过。`test_Arbitrage_MakesProfit` 实测利润：

```
借入 100 TokenA → 利润 96.1175563739892690962 TokenB
```

## 运行测试

```bash
# 运行全部 flash-swap 测试
forge test --match-path "test/flash-swap/FlashSwapArbitrage.t.sol" -vvv

# 运行单个测试
forge test --match-path "test/flash-swap/FlashSwapArbitrage.t.sol" \
  --match-test test_Arbitrage_MakesProfit -vvv
```

## 测试环境

| 项目 | 值 |
|------|-----|
| Solidity | 0.8.30（测试合约）/ 0.5.16（官方 v2-core） |
| 框架 | Foundry (forge-std) |
| 依赖 | OpenZeppelin v5.x、Uniswap v2-core v1.0.1（git submodule） |

## 测试账户与常量

### 测试账户

| 角色 | 说明 |
|------|------|
| `address(this)` | 测试合约自身，既是代币部署者也是流动性提供者（LP） |
| `alice` | 普通用户，用于越权场景测试 |

### 流动性常量

| 常量 | 值 | 说明 |
|------|-----|------|
| `POOL_A_LIQ_TOKENA` | 10,000 × 10¹⁸ | PoolA 的 TokenA 储备 |
| `POOL_A_LIQ_TOKENB` | 10,000 × 10¹⁸ | PoolA 的 TokenB 储备（1:1） |
| `POOL_B_LIQ_TOKENA` | 10,000 × 10¹⁸ | PoolB 的 TokenA 储备 |
| `POOL_B_LIQ_TOKENB` | 20,000 × 10¹⁸ | PoolB 的 TokenB 储备（1:2，制造价差） |

## 测试用例清单（5 个）

### 1. 套利盈利测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_Arbitrage_MakesProfit` | 借入 100 TokenA 后套利合约获得 TokenB 利润；与手算期望值（PoolB 兑出量 − PoolA 偿还量）误差在 0.1% 以内；两池价格收敛（PoolA 中 TokenA 变贵、PoolB 中变便宜） |

### 2. 无利润回滚测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_RevertWhen_NoProfit` | 独立搭建价差仅 0.2% 的两池（手续费合计约 0.6%，吞掉全部利润），执行套利 revert `FlashSwap: NO_PROFIT` |

### 3. 利润提取测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_Withdraw` | owner 调用 `withdraw()` 后利润全额到账，合约余额清零 |
| `test_Withdraw_OnlyOwner` | 非 owner 调用 `withdraw()` revert `FlashSwap: NOT_OWNER` |

### 4. 回调鉴权测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_RevertWhen_UnauthorizedCallback` | 非 PoolA 地址直接调用 `uniswapV2Call()` revert `FlashSwap: UNAUTHORIZED` |

## 核心公式

```solidity
// PoolB 兑出数量（Uniswap V2 标准 0.3% 手续费公式）
amountBOut = amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997);

// 偿还 PoolA 所需 TokenB（等价于"在 PoolA 内卖出 amountIn"的 getAmountIn 定价）
amountRepay = reserveA_TokenB * amountIn * 1000 / ((reserveA_TokenA - amountIn) * 997) + 1;
```

## 为什么不用 v2-periphery

本模块只依赖 v2-core，未引入 v2-periphery（Router02 等），原因如下：

**1. 需要的能力 v2-core 全部具备**

| 操作 | v2-core 直接实现 | periphery 提供的替代 |
|------|-----------------|---------------------|
| 创建池 | `factory.createPair()` | Router 转发调用 |
| 加流动性 | `transfer` + `pair.mint()` | `Router.addLiquidity()` |
| 闪电兑换 | `pair.swap(..., data)` + `uniswapV2Call` | 无（官方 ExampleFlashSwap 也只依赖 Pair） |

闪电兑换机制本身完全实现在 v2-core 的 Pair 中（`swap` 先发货 → 回调 → 再校验 K 值），与 periphery 无关。

**2. Router 的核心价值在本场景用不上**

Router 主要解决 WETH 兑换、多跳路由、滑点/截止时间保护、按比例计算加池数量。本场景两池均由部署者自己按固定比例（1:1 / 1:2）注入流动性以故意制造价差，无滑点保护需求；代币为纯 ERC20，不涉及 ETH。

**3. 编译器版本负担**

v2-core 为 Solidity 0.5.16，v2-periphery 为 0.6.6 —— 引入 periphery 意味着额外管理一个旧版 solc，跨版本编译复杂度翻倍。

**4. 依赖最小化**

少一个 git submodule，安装、CI 与审计面都更小。

> 若后续需要真实 ETH 交易对、多路径套利（A→B→C）或让他人通过 Router 加流动性，则应引入 `UniswapV2Router02`。

## 注意事项

- **data 必须非空**：V2 Pair 仅在 `data.length > 0` 时才触发 `uniswapV2Call` 回调，`startArbitrage` 中传入 `abi.encode(msg.sender)`，否则回调不会执行、Pair 会因收不到还款 revert `INSUFFICIENT_INPUT_AMOUNT`
- **回调期间 `getReserves()` 返回借用前储备**：V2 Pair 在回调结束后才调用 `_update` 结算储备，因此回调内读取的是闪电借出前的储备量
- **跨版本部署**：官方 v2-core 为 Solidity 0.5.16，与 0.8.x 测试合约不能直接互相 import。测试通过 `vm.deployCode("UniswapV2Factory.sol", ...)` 从 artifact 部署；artifact 由 `src/flash-swap/V2Core.sol` 锚点文件（pragma =0.5.16）以独立编译组件生成
- **添加流动性无需 Router**：直接向 Pair 转入两种代币后调用 `pair.mint()`，适合本地测试与脚本部署
- `token0` / `token1` 由两个代币地址排序决定，测试与合约内部均按代币身份动态判断方向，不硬编码顺序
