# Aave V3 闪电贷 + 双 Uniswap V2 跨池套利 计划

## Summary

在 `src/flash-loan/` 下独立开发（不参考本项目其他模块代码）：Fork 主网测试环境中，部署自定义 ERC20 `TokenC` 与两套官方 Uniswap V2（Factory + Router02），创建两个价差池 **PoolC**（TokenC 便宜）与 **PoolE**（TokenC 昂贵）。在一笔交易内：从主网 Aave V3 `flashLoanSimple` 闪电借入 WETH → 在 PoolC 用 WETH 兑换 TokenC → 在 PoolE 用 TokenC 兑回 WETH → 偿还 Aave 本息（0.05% premium），利润以 WETH 留存在套利合约中。

最后增加端到端实测：启动本地 `anvil --fork-url 主网`，`forge create` 部署两套官方 Uniswap、`forge script` 部署 TokenC/建池/套利合约并真实发交易执行套利，`cast` 验证利润。

## Current State Analysis

- Foundry 项目，`foundry.toml` 已配置 `rpc_endpoints.mainnet = "${MAINNET_RPC_URL}"`，`.env` 中 `MAINNET_RPC_URL` 已有值，可直接 fork 主网。
- `lib/` 已安装官方依赖：`v2-core`（UniswapV2Factory/Pair，Solidity =0.5.16）、`v2-periphery`（UniswapV2Router02，=0.6.6）、`forge-std`、OpenZeppelin。
- `remappings.txt` 已有 `@uniswap/v2-core/=lib/v2-core/`，**缺** `@uniswap/v2-periphery` 映射。
- 官方 V2 合约是 0.5.16/0.6.6 旧版本编译器，无法被 0.8.x 直接 import 并 `new`，需用「编译锚点 + `vm.deployCode`」技巧部署（Foundry 标准做法）。
- `src/flash-loan/` 目录为空，从零开始。
- Aave V3 主网地址（fork 环境直接使用）：
  - PoolAddressesProvider: `0x2f39d218133AFaF890136494c88a6Cd7CBf82924`
  - Pool（代理）: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`
  - WETH9: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
  - flashLoanSimple 费率 0.05%（5 bps）
- 用户决策：① 池子使用主网原生 WETH（不部署自定义 WETH，只部署 TokenC）；② 使用官方 Uniswap V2 合约部署两套实例。

## Proposed Changes

### 1. 新建 `src/flash-loan/TokenC.sol` — 自定义 ERC20

- `pragma solidity ^0.8.30`，自包含实现（不依赖 OZ、不参考项目内其他 Token 合约）。
- 标准 ERC20（name "Token C"、symbol "TKC"、18 decimals、Transfer/Approval 事件）。
- 构造函数一次性铸造 `10_000_000 * 1e18` 给部署者（测试中足够添加两池流动性）。

### 2. 新建 `src/flash-loan/FlashLoanArbitrage.sol` — 套利合约（核心）

自包含最小接口（文件内定义，不 import lib 的旧版本接口）：
- `IAavePool.flashLoanSimple(receiver, asset, amount, params, referralCode)`
- `IUniswapV2RouterMinimal.swapExactTokensForTokens / getAmountsOut`（调用 0.6.6 Router02 部署实例，跨版本外部调用无问题）
- `IERC20Minimal.{balanceOf, transfer, approve}`

合约逻辑：
- 不可变量：`aavePool`、`weth`、`routerC`（PoolC 所在 Uniswap #1）、`routerE`（PoolE 所在 Uniswap #2）、`tokenC`、`owner`。
- `startArbitrage(uint256 borrowAmount, uint256 minTokenCOut, uint256 minWethOut)`：发起 `flashLoanSimple(address(this), WETH, borrowAmount, "", 0)`。
- `executeOperation(asset, amount, premium, initiator, params)`（Aave 回调，`require(msg.sender == aavePool)`）：
  1. `weth.approve(routerC, amount)` → `routerC.swapExactTokensForTokens(amount, minTokenCOut, [WETH, TokenC], address(this), deadline)`，得到 TokenC 数量；
  2. `tokenC.approve(routerE, tokenCAmount)` → `routerE.swapExactTokensForTokens(tokenCAmount, minWethOut, [TokenC, WETH], address(this), deadline)`，得到 WETH；
  3. `totalDebt = amount + premium`，`require` 兑回 WETH ≥ `totalDebt + minProfit(>0)`（无利可图即回滚，保证原子性）；
  4. `weth.approve(aavePool, totalDebt)`，Aave 在回调返回后自动划扣；剩余 WETH 即利润留存合约。
- `withdrawProfit()`：仅 owner 提取合约内 WETH 余额。

### 3. 新建部署锚点 `src/flash-loan/V2CoreAnchor.sol` 与 `src/flash-loan/V2RouterAnchor.sol`

- `V2CoreAnchor.sol`：`pragma solidity =0.5.16`，import 官方 `UniswapV2Factory.sol`，空合约 —— 让 forge 用 0.5.16 编译出 artifact，供测试 `vm.deployCode("UniswapV2Factory.sol", abi.encode(feeToSetter))` 部署。
- `V2RouterAnchor.sol`：`pragma solidity =0.6.6`，import 官方 `UniswapV2Router02.sol`，空合约 —— 同理供 `vm.deployCode("UniswapV2Router02.sol", abi.encode(factory, weth))` 部署。
- 注：这是 Foundry 跨版本部署的必需技巧（非业务逻辑），锚点文件为本模块独立新建。

### 4. 新建 `test/flash-loan/FlashLoanArbitrage.t.sol` — Fork 主网测试

`setUp()`：
1. `vm.createSelectFork(vm.rpcUrl("mainnet"))`（不固定区块号，避免归档节点限制）；
2. 绑定主网 WETH/Aave Pool 常量地址；
3. `vm.deployCode` 部署两套 Uniswap：`factoryA + routerA`（Uniswap #1）、`factoryB + routerB`（Uniswap #2），均指向主网 WETH；
4. 部署 `TokenC`（测试合约持有全部供应量）；`vm.deal` + `WETH.deposit{value: 200 ether}` 为测试合约准备流动性资金；
5. 创建价差池并经各自 Router `addLiquidity`（先 approve）：
   - **PoolC**（TokenC 便宜）：`1,000,000 TKC + 100 WETH` → 1 WETH ≈ 10,000 TKC
   - **PoolE**（TokenC 昂贵）：`100,000 TKC + 100 WETH` → 1 WETH ≈ 1,000 TKC（10 倍价差）

`test_flashLoanArbitrage()`（单笔交易完成全流程）：
1. 部署 `FlashLoanArbitrage(aavePool, WETH, routerA, routerB, TokenC)`；
2. 记录套利合约初始 WETH 余额（0）；用 router 的 `getAmountsOut` 预估并设置 `minTokenCOut/minWethOut`（允许适当滑点）；
3. `arb.startArbitrage(5 ether, minTokenCOut, minWethOut)` —— 闪电贷、两笔兑换、还款全部在该调用内原子完成；
4. 断言与教学日志（console2.log）：
   - 套利后合约 WETH 利润 > 0（预期约 27 WETH 量级，见下方估算）；
   - 合约内 TokenC 余额为 0（全部兑出）；
   - 两池价格较初始收敛（PoolC TKC 价格上升、PoolE 下降）；
   - Aave 还款成功隐含于交易不回滚（flashLoanSimple 未足额还款必 revert）。

`test_revertWhen_NoProfit()`（负向用例）：借用过量（如 90 ether）导致滑点吞噬利润时，`require` 使整笔交易回滚，验证原子性。

利润量级验算（0.3% 手续费、借 5 WETH）：
- PoolC：`(5·997·1,000,000)/(100·1000+5·997) ≈ 47,483 TKC`
- PoolE：`(47,483·997·100)/(100,000·1000+47,483·997) ≈ 32.13 WETH`
- 还款 `5 + 0.0025 = 5.0025 WETH` → 利润 ≈ **27.1 WETH**

### 5. 新建 `script/flash-loan/DeployFlashLoanArb.s.sol` — anvil 部署 + 执行脚本

同一文件包含两个 Script 合约（自包含最小接口，与套利合约一致）：

- `DeployFlashLoanArb`：从环境变量读取 `FACTORY_C/FACTORY_E/ROUTER_C/ROUTER_E`（由 forge create 预先部署的官方 V2 合约地址）；broadcast 中：部署 `TokenC` → `WETH.deposit{value: 200 ether}`（anvil 账户默认有 10000 ETH）→ approve 两个 Router → `createPair` 建两个池 → `addLiquidity` 注入价差流动性（PoolC: 1,000,000 TKC + 100 WETH；PoolE: 100,000 TKC + 100 WETH）→ 部署 `FlashLoanArbitrage`；将所有地址 `vm.writeJson` 持久化到 `deployments/flash-loan-arb-local.json`。
- `ExecuteArbitrage`：`vm.readFile` 读取地址 JSON，用 Router `getAmountsOut` 预估 minOut（1% 滑点余量），broadcast 中调用 `arb.startArbitrage(5 ether, minTokenCOut, minWethOut)` 真实发交易执行套利，并 log 套利合约 WETH 利润余额。

### 6. 编辑 `remappings.txt` 与 `foundry.toml`

- `remappings.txt` 增加一行：`@uniswap/v2-periphery/=lib/v2-periphery/`（`@uniswap/v2-core` 映射已存在，Router02 锚点需要此映射编译）。
- `foundry.toml` 的 `fs_permissions` 增加 `{ access = "read", path = "./deployments" }`（ExecuteArbitrage 读取地址 JSON 用；写权限已有）。

### 7. 本地 anvil 部署与实测流程（命令序列）

1. `source .env && anvil --fork-url $MAINNET_RPC_URL`（后台常驻，端口 8545，`foundry.toml` 已配 `rpc_endpoints.local`）。
2. 用 anvil 默认账户 #0 私钥 `forge create` 部署 4 个官方 V2 合约（forge 会自动用 solc 0.5.16/0.6.6 编译 lib 内源码）：
   - `lib/v2-core/contracts/UniswapV2Factory.sol:UniswapV2Factory` ×2（feeToSetter = 账户 #0 地址）
   - `lib/v2-periphery/contracts/UniswapV2Router02.sol:UniswapV2Router02` ×2（constructor-args = 各自 factory + 主网 WETH 地址）
3. `FACTORY_C=.. FACTORY_E=.. ROUTER_C=.. ROUTER_E=.. forge script script/flash-loan/DeployFlashLoanArb.s.sol:DeployFlashLoanArb --rpc-url http://127.0.0.1:8545 --broadcast -vvv`。
4. 套利前 `cast call` 记录套利合约 WETH 余额（应为 0）。
5. `forge script ...:ExecuteArbitrage --rpc-url http://127.0.0.1:8545 --broadcast -vvv` 真实执行闪电贷套利。
6. 套利后 `cast call $WETH "balanceOf(address)(uint256)" $ARB` 验证利润 ≈ 27 WETH；交易未回滚即证明 Aave 本息已偿清。

## Assumptions & Decisions

- 池子使用主网原生 WETH（用户已确认）；Aave 借出/偿还的 WETH 可直接进池，无需自定义 WETH 与兑换桥接。
- Uniswap 使用官方 v2-core/v2-periphery（用户已确认）；两套独立 Factory+Router，各建一个 TokenC/WETH 池。
- 「不参考本项目其他代码」= 业务代码全新编写于 `src/flash-loan/`；官方 lib 依赖与 Foundry 必要技巧（编译锚点、vm.deployCode）不在此限制内。
- 套利利润以 WETH 留存在套利合约，由 owner 提取；除 fork 测试外，另提供 anvil 部署脚本 + 实测流程（用户补充要求），官方 V2 合约在 anvil 上用 `forge create` 部署（0.8.x 脚本无法直接 `new` 旧版本合约）。
- Aave V3 主网 Pool 地址与 0.05% 费率为硬编码常量（写入合约/测试并注释来源）。
- `minProfit` 内置为 `> 0`（仅要求利润为正），精确阈值由测试的 minOut 参数控制，避免过度设计。

## Verification

1. `forge build` —— 全部合约（0.5.16 / 0.6.6 / 0.8.30 三版本）编译通过。
2. `forge test --match-path test/flash-loan/FlashLoanArbitrage.t.sol -vvv` ——
   - fork 主网成功、两套 Uniswap 部署并建池；
   - 价差断言通过（PoolC/PoolE 初始价差 10 倍）；
   - 正向用例：一笔交易内完成闪电贷→双池兑换→还款，日志输出借入量、TKC 兑得量、WETH 兑回量、还款额、利润额，利润 > 0；
   - 负向用例：无利润场景整体回滚。
3. anvil 端到端实测（见"本地 anvil 部署与实测流程"）：
   - anvil fork 主网启动成功，4 个官方 V2 合约 `forge create` 部署成功；
   - 部署脚本完成 TokenC 部署、双池建池与注流动性，地址写入 `deployments/flash-loan-arb-local.json`；
   - 执行脚本真实发交易完成闪电贷套利（tx 不回滚 = Aave 本息已偿清）；
   - `cast call` 验证套利合约 WETH 余额从 0 变为 ≈ 27 WETH。
4. （可选）`forge snapshot` 记录 gas，观察单笔套利交易成本。
