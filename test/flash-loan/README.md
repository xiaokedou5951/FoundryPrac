# Aave V3 闪电贷 + 双 Uniswap V2 跨池套利测试说明

## 概述

本目录测试在 Fork 主网环境下，**一笔交易内**完成 Aave V3 闪电贷 → 双 Uniswap V2 池跨池兑换 → 还款的原子套利流程。涉及的合约（全部位于 [`src/flash-loan/`](../../src/flash-loan/)）：

- **TokenC**（`TokenC.sol`）— 自包含 ERC20（不依赖第三方库），构造时一次性铸造 10,000,000 枚给部署者，用于添加两池流动性
- **FlashLoanArbitrage**（`FlashLoanArbitrage.sol`）— 套利合约，调用 Aave V3 `flashLoanSimple` 闪电借入 WETH，在 PoolC 兑换 TokenC，在 PoolE 兑回 WETH，偿还本息后留存利润
- **官方 Uniswap V2**（来自 git submodule）— 部署两套独立 `UniswapV2Factory + UniswapV2Router02`，各创建一个 TokenC/WETH 池形成价差：
  - **PoolC**（Uniswap #1）：1,000,000 TKC + 100 WETH（1 WETH ≈ 10,000 TKC，TokenC 便宜）
  - **PoolE**（Uniswap #2）：100,000 TKC + 100 WETH（1 WETH ≈ 1,000 TKC，TokenC 昂贵 10 倍）
- **编译锚点**（`V2CoreAnchor.sol` / `V2RouterAnchor.sol`）— 让 forge 用 solc 0.5.16 / 0.6.6 编译官方 v2-core / v2-periphery，生成测试用 `vm.deployCode` 部署的 artifact

## 套利流程

```
1. startArbitrage(5 ether, minTokenCOut, minWethOut)
   └─ 调 Aave V3 Pool.flashLoanSimple(receiver=this, asset=WETH, amount=5 ether, params, 0)

2. Aave 先把 5 WETH 转给本合约，再回调 executeOperation(asset, amount, premium, initiator, params)
   ├─ WETH.approve(routerC, 5 ether)
   ├─ routerC.swapExactTokensForTokens(5 WETH → TokenC)   # PoolC：得 ≈ 47,482 TKC
   ├─ TokenC.approve(routerE, tokenCAmount)
   ├─ routerE.swapExactTokensForTokens(TokenC → WETH)      # PoolE：得 ≈ 32.13 WETH
   ├─ totalDebt = 5 + 0.0025 = 5.0025 WETH  （Aave flashLoanSimple 费率 0.05%）
   ├─ require(wethReceived > totalDebt)                   # 无利可图即 revert "FlashLoan: NO_PROFIT"
   └─ WETH.approve(AAVE_POOL, totalDebt)                  # Aave 在回调返回后自动 transferFrom 划扣

3. 剩余 ≈ 27.13 WETH 留存在套利合约，由 owner 调 withdrawProfit() 提取
```

关键原理：Aave V3 `flashLoanSimple` 在回调结束后自动从 receiver 划扣 `amount + premium`，因此合约只需 `approve` 授权；如还款不足整笔交易回滚，保证原子性。

## 测试结果

2 个测试全部通过。`test_flashLoanArbitrage_profitPositive` 实测：

```
借入 5 WETH
  → TokenC bought:    47,482.973758155927037195
  → WETH received:     31.911240391874889224 (估算)
  → Profit WETH:       27.127509642147984829
```

与计划估算 ≈ 27.1 WETH 完全吻合。

## 运行测试

```bash
# 运行全部 flash-loan 测试（需先在 .env 配置 MAINNET_RPC_URL）
forge test --match-path "test/flash-loan/FlashLoanArbitrage.t.sol" -vv

# 运行单个测试
forge test --match-path "test/flash-loan/FlashLoanArbitrage.t.sol" \
  --match-test test_flashLoanArbitrage_profitPositive -vvv
```

> 测试需要 Fork 主网以访问 Aave V3 Pool 与主网 WETH9。确保 `.env` 中 `MAINNET_RPC_URL` 已配置（参考 `env_sample`）。

### 配置 MAINNET_RPC_URL

本模块所有测试与 anvil 实测均依赖主网 RPC 端点（用于 fork 主网访问 Aave V3 Pool 和 WETH9）。`foundry.toml` 已配置：

```toml
[rpc_endpoints]
mainnet = "${MAINNET_RPC_URL}"
```

测试中通过 `vm.rpcUrl("mainnet")` 读取该值，anvil 通过 `--fork-url $MAINNET_RPC_URL` 使用。

#### 配置步骤

1. 复制示例环境文件（若尚未配置 `.env`）：

   ```bash
   cp env_sample .env
   ```

2. 在 `.env` 中填入主网 RPC URL。可使用任意以太坊主网端点：

   | 提供方 | 端点示例 | 说明 |
   |--------|----------|------|
   | PublicNode（公共免费） | `https://ethereum-rpc.publicnode.com` | `env_sample` 默认值，无需注册 |
   | Alchemy | `https://eth-mainnet.g.alchemy.com/v2/<API_KEY>` | 需注册获取 API key，更稳定 |
   | Infura | `https://mainnet.infura.io/v3/<API_KEY>` | 需注册获取 API key |
   | 自建节点 | `http://<your-node>:8545` | 自建 / Erigon / Reth 等 |

   `.env` 示例：

   ```bash
   MAINNET_RPC_URL="https://ethereum-rpc.publicnode.com"
   ```

3. 验证配置生效：

   ```bash
   # 加载 .env 后测试 RPC 是否可达
   source .env && cast block-number --rpc-url $MAINNET_RPC_URL
   # 输出当前主网区块号即配置成功
   ```

4. 运行测试（forge 自动加载 `.env`）：

   ```bash
   forge test --match-path "test/flash-loan/FlashLoanArbitrage.t.sol" -vv
   ```

#### 常见问题

| 现象 | 原因 / 解决 |
|------|-------------|
| `Failed to read cache file ... No such file or directory` | 首次 fork 时的缓存警告，可忽略 |
| `server returned an error response: ... Insufficient funds` | anvil 账户未用对默认私钥，参考 [anvil 端到端实测](#本地-anvil-端到端实测) 章节 |
| `EvmError: Revert` 无具体错误信息 | 多半是 gas 不足或 init code hash 不匹配，参考 [关键技术问题](#测试中解决的关键技术问题) 章节 |
| RPC 限流（HTTP 429） | 公共端点易限流，可换 Alchemy/Infura 或加 `--no-rpc-rate-limit` |


## 测试环境

| 项目 | 值 |
|------|-----|
| Solidity | 0.8.30（测试与业务合约）/ 0.5.16（官方 v2-core）/ 0.6.6（官方 v2-periphery） |
| 框架 | Foundry (forge-std) |
| 依赖 | 官方 [v2-core](https://github.com/Uniswap/v2-core)、[v2-periphery](https://github.com/Uniswap/v2-periphery)、[uniswap-lib](https://github.com/Uniswap/uniswap-lib)（git submodules） |
| 链环境 | Fork 主网（`vm.createSelectFork(vm.rpcUrl("mainnet"))`，不固定区块号） |

## 主网地址常量

| 常量 | 地址 | 说明 |
|------|------|------|
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 主网原生 WETH9，作为 Aave 借贷资产 + 两个池的计价资产 |
| `AAVE_POOL` | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | Aave V3 Pool 代理合约（闪电贷入口） |

Aave V3 `flashLoanSimple` 费率为 **0.05%（5 bps）**。

## 流动性配置

| 池 | TokenC 储备 | WETH 储备 | 隐含价格 |
|----|------------|-----------|----------|
| PoolC | 1,000,000 × 10¹⁸ | 100 × 10¹⁸ | 1 WETH ≈ 10,000 TKC（TokenC 便宜） |
| PoolE | 100,000 × 10¹⁸ | 100 × 10¹⁸ | 1 WETH ≈ 1,000 TKC（TokenC 昂贵 10 倍） |

10 倍价差用于教学演示，确保套利利润显著。

## 测试用例清单（2 个）

### 1. 套利盈利测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_flashLoanArbitrage_profitPositive` | 借入 5 WETH 后套利合约 WETH 利润 > 0（实测 ≈ 27.13 WETH）；合约内 TokenC 余额为 0（全部兑出）；交易未回滚即隐含 Aave 本息已偿清。日志输出借入量、TokenC 兑得量、WETH 兑回量（估算）、利润额 |

### 2. 无利润原子回滚测试

| 测试函数 | 验证内容 |
|----------|----------|
| `test_revertWhen_overBorrowMakesNoProfit` | 借入 90 WETH 致 PoolC 滑点剧烈、兑回 WETH 不足以覆盖本息，`require(wethReceived > totalDebt)` 触发 revert `FlashLoan: NO_PROFIT`；验证套利的原子性 |

## 核心公式

```solidity
// Uniswap V2 标准 0.3% 手续费输出公式（PoolC、PoolE 兑换定价）
amountOut = amountIn * 997 * reserveOut / (reserveIn * 1000 + amountIn * 997);

// Aave V3 flashLoanSimple 还款总额
totalDebt = amount + (amount * 5 / 10000);  // 0.05% premium
```

利润量级验算（借 5 WETH）：
- PoolC：`5 * 997 * 1,000,000 / (100 * 1000 + 5 * 997) ≈ 47,483 TKC`
- PoolE：`47,483 * 997 * 100 / (100,000 * 1000 + 47,483 * 997) ≈ 32.13 WETH`
- 还款 `5 + 0.0025 = 5.0025 WETH` → 利润 ≈ **27.1 WETH**

## 测试中解决的关键技术问题

### 1. Uniswap V2 init code hash 不匹配

`UniswapV2Library.pairFor`（在 v2-periphery 中）硬编码了主网上线时官方 v2-core Pair 的 initcode hash `0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`。但本地 forge 编译 v2-core 0.5.16 Pair 的 initcode hash 不同（不同 solc 配置/optimizer/metadata），导致 `Router.addLiquidity` 内部 `getReserves` 用的 pairFor 地址与 Factory.createPair 实际部署的 Pair 地址错位，报 `call to non-contract address`。

**解决**：将 [lib/v2-periphery/contracts/libraries/UniswapV2Library.sol](../../lib/v2-periphery/contracts/libraries/UniswapV2Library.sol) 中的硬编码 hash 替换为本地编译产物计算的 hash `0x2d53f8ada688437d62471edc172514a1e124654169caa2657976eda0c3b8712c`（用 `cast keccak $(jq -r '.bytecode.object' out/UniswapV2Pair.sol/UniswapV2Pair.json)` 算出）。已在源码处加注释说明。

> 如改用主网 fork 上的真实 Uniswap（不本地部署 Factory），则需还原为官方 hash。

### 2. 跨版本编译部署

官方 v2-core 为 Solidity 0.5.16、v2-periphery 为 0.6.6，与 0.8.x 测试合约不能同文件互相 import。处理方式：

- `src/flash-loan/V2CoreAnchor.sol`：`pragma solidity =0.5.16`，import 官方 `UniswapV2Factory.sol`，空合约体——让 forge 以 0.5.16 编译出 artifact
- `src/flash-loan/V2RouterAnchor.sol`：`pragma solidity =0.6.6`，import 官方 `UniswapV2Router02.sol`，同理
- 测试中通过 `vm.deployCode("UniswapV2Factory.sol", abi.encode(feeToSetter))` 跨版本部署

### 3. 主网账户余额冲突

`vm.createSelectFork(mainnet)` 后，测试合约地址在主网真实链上可能已有少量 WETH 预存余额，导致 `assertEq(balance, 200 ether)` 失败。改用 `assertGe` 容忍既有余额。

## 本地 anvil 端到端实测

除 forge test 外，本模块配套 [`script/flash-loan/DeployFlashLoanArb.s.sol`](../../script/flash-loan/DeployFlashLoanArb.s.sol) 可在本地 anvil 上完成端到端部署与执行：

```bash
# 1. 启动 anvil fork 主网（后台运行）
source .env && anvil --fork-url $MAINNET_RPC_URL --port 8545

# 2. 用 anvil 默认账户 #0 部署 4 个官方 V2 合约（forge 自动用 solc 0.5.16/0.6.6 编译）
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ACCT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
FACTORY_C=$(forge create lib/v2-core/contracts/UniswapV2Factory.sol:UniswapV2Factory \
  --private-key $PK --broadcast --constructor-args $ACCT \
  --rpc-url http://127.0.0.1:8545 | grep -i 'deployed to:' | awk '{print $3}')
# ... 同理部署 FACTORY_E、ROUTER_C、ROUTER_E

# 3. 部署 TokenC、双池流动性、套利合约
FACTORY_C=$FACTORY_C FACTORY_E=$FACTORY_E ROUTER_C=$ROUTER_C ROUTER_E=$ROUTER_E \
PRIVATE_KEY=$PK \
forge script script/flash-loan/DeployFlashLoanArb.s.sol:DeployFlashLoanArb \
  --rpc-url http://127.0.0.1:8545 --broadcast -vv

# 4. 验证套利前余额为 0
cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "balanceOf(address)(uint256)" <arb> --rpc-url http://127.0.0.1:8545

# 5. 执行套利（提高 gas 估算避免 Aave 回调 gas 不足）
PRIVATE_KEY=$PK forge script script/flash-loan/DeployFlashLoanArb.s.sol:ExecuteArbitrage \
  --rpc-url http://127.0.0.1:8545 --broadcast --gas-estimate-multiplier 300 -vv

# 6. 验证利润
cast call 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  "balanceOf(address)(uint256)" <arb> --rpc-url http://127.0.0.1:8545
# → 27127509642147984829 (≈ 27.13 WETH)
```

部署地址持久化到 [`deployments/flash-loan-arb-local.json`](../../deployments/flash-loan-arb-local.json)。

### Aave 回调 gas 不足问题

`flashLoanSimple` 内部对 `executeOperation` 走 63/64 gas rule。forge script 默认 gas 估算偏紧，导致回调最末 `WETH.approve(AAVE_POOL, totalDebt)` 出现 `OutOfGas`、整笔交易回滚。解决：执行脚本时加 `--gas-estimate-multiplier 300` 提高 tx gasLimit。

## 注意事项

- **Fork 主网必需**：测试依赖主网 Aave V3 Pool 与 WETH9，无主网 fork 无法运行
- **deadline 设置**：fork 主网时 `block.timestamp` 是 fork 区块的过去时间，若用 `block.timestamp` 作为 Router 的 `deadline` 会立即触发 `EXPIRED`。合约与脚本统一使用 `block.timestamp + 600`（10 分钟余量）
- **minOut 滑点保护**：测试与执行脚本用 `router.getAmountsOut` 估算输出后乘以 99/100（1% 滑点余量）作为 `amountOutMin`，避免广播时实际输出与模拟略有差异导致 swap 回滚
- **子模块改动**：`lib/v2-periphery/contracts/libraries/UniswapV2Library.sol` 第 24 行的 init code hash 已替换为本地编译值。若改用主网 fork 真实 Uniswap 需还原
- **`vm.deployCode` 路径**：传入 `"UniswapV2Factory.sol"` 等合约文件名即可（forge 自动从 `out/` 解析）；新版 forge 需校验返回地址的 `code.length > 0`
- **不参考本项目其他代码**：本模块业务合约（TokenC、FlashLoanArbitrage）完全独立实现，自包含最小接口，不 import 项目内其他模块
