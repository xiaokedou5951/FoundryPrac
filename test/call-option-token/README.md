# Call Option Token 测试说明

本目录包含看涨期权 Token（`call-option-token`）模块的 Foundry 单元测试，覆盖需求 1~5 的全部功能与边界条件。

## 测试文件

| 文件 | 说明 |
|------|------|
| [CallOptionToken.t.sol](./CallOptionToken.t.sol) | 综合测试合约，41 个测试用例 |

被测合约位于 [`src/call-option-token/`](../../src/call-option-token/)：

- `OptionToken.sol` — 期权 ERC20 主体（发行 / 行权 / 过期赎回 / 销毁）
- `OptionSwapPool.sol` — 恒定乘积（x·y=k）AMM 交易对
- `MockUSDT.sol` — 6 位精度 USDT 模拟币

## 快速运行

```bash
# 运行全部测试（带详细输出）
forge test --match-path test/call-option-token/CallOptionToken.t.sol -vvv

# 仅重跑失败用例
forge test --match-path test/call-option-token/CallOptionToken.t.sol --rerun

# 查看测试覆盖率
forge coverage --match-path "test/call-option-token/.*"
```

## 测试环境（setUp）

每个测试执行前 `setUp()` 完成如下初始化：

| 角色 | 地址来源 | 资金 |
|------|----------|------|
| `owner`（项目方） | `address(this)` 测试合约自身 | 1,000,000 USDT |
| `alice`（用户） | `makeAddr("alice")` | 1,000,000 USDT + 100 ETH |
| `bob`（用户） | `makeAddr("bob")` | 1,000,000 USDT + 100 ETH |

合约部署参数：

- `MockUSDT` — 6 位精度
- `OptionToken` — `strikePrice = 3000 * 1e6`（3000 USDT / 1 ETH），`expiryDate = block.timestamp + 30 days`
- `OptionSwapPool` — 绑定上述 `OptionToken` 与 `MockUSDT`

> 注：`alice` / `bob` 预持 ETH 与 USDT，故涉及余额断言时一律采用 **前后差额** 比对，避免与初始预发金额耦合。

## 测试分组与用例清单

测试按 `// ===== Section =====` 注释分为 6 组，共 41 个用例。

### 1. 部署测试（4）

验证构造函数状态初始化与参数校验。

| 用例 | 验证点 |
|------|--------|
| `test_Deployment` | usdt / strikePrice / expiryDate / owner / name / symbol / decimals / collateral 全部正确 |
| `test_Deployment_ZeroUsdt_Reverts` | 零地址 USDT → `"COT: zero usdt"` |
| `test_Deployment_ZeroStrike_Reverts` | 行权价为 0 → `"COT: zero strike"` |
| `test_Deployment_PastExpiry_Reverts` | 到期日不晚于当前 → `"COT: past expiry"` |

### 2. 需求 2：发行（6）

项目方 `issue()` 转入 ETH、1:1 铸造期权 Token。

| 用例 | 验证点 |
|------|--------|
| `test_Issue_MintsOneToOne` | 10 ETH → 10 期权，余额/总供应/抵押物/ETH 扣减正确 |
| `test_Issue_EmitsEvent` | 触发 `Issued(owner, 5 ether)` 事件 |
| `test_Issue_MultipleAccumulates` | 多次发行累加（3+7=10） |
| `test_Issue_NotOwner_Reverts` | 非 owner 调用 revert（`onlyOwner`） |
| `test_Issue_ZeroEth_Reverts` | `msg.value==0` → `"COT: zero eth"` |
| `test_Issue_AfterExpired_Reverts` | 过期赎回后再发行 → `"COT: expired"` |

### 3. 需求 3：AMM 交易对（8）

`OptionSwapPool` 流动性注入、双向 swap、滑点保护、抽离流动性。

| 用例 | 验证点 |
|------|--------|
| `test_AddLiquidity_UpdatesReserves` | 注入后 reserve / 池内余额正确 |
| `test_AddLiquidity_NotOwner_Reverts` | 非 owner 注入 → `"OSP: not owner"` |
| `test_GetAmountOut_Correct` | `getAmountOut` 公式数值精确匹配（含 0.3% 手续费） |
| `test_SwapUSDTForOption_UserBuysOption` | USDT→期权：输出、储备变动正确 |
| `test_SwapUSDTForOption_Slippage_Reverts` | `minOut=type(uint256).max` → `"OSP: slippage"` |
| `test_SwapOptionForUSDT_Reverse` | 期权→USDT：反向交易储备变动正确 |
| `test_RemoveLiquidity_OwnerRecovers` | owner 一次性取回池内两币 |
| `test_RemoveLiquidity_NotOwner_Reverts` | 非 owner → `"OSP: not owner"` |

### 4. 需求 4：行权（11）

到期日当天 `[expiryDate, expiryDate+1 days)` 用户行权：销毁期权、付 USDT、释放 ETH。

| 用例 | 验证点 |
|------|--------|
| `test_Exercise_FullFlow` | 发行→AMM 买入→行权完整链路 |
| `test_Exercise_AtExpiryDate_Success` | 到期日当天行权成功，期权销毁、ETH 释放 |
| `test_Exercise_BeforeExpiry_Reverts` | 到期前 1 秒 → `"COT: not yet expiry"` |
| `test_Exercise_LastSecondOfWindow_Success` | 窗口右端点 -1 秒仍可行权 |
| `test_Exercise_AfterWindow_Reverts` | `expiryDate+1 days` → `"COT: exercise window closed"` |
| `test_Exercise_ZeroAmount_Reverts` | 数量为 0 → `"COT: zero amount"` |
| `test_Exercise_InsufficientApproval_Reverts` | 未 approve USDT → revert |
| `test_Exercise_PartialAndMultipleUsers` | 多用户部分行权，ETH/USDT 结算正确 |
| `test_GetExerciseCost_Calculation` | 行权成本换算（1/0.5/2 ETH → 3000/1500/6000 USDT） |
| `test_IsExerciseWindow` | 窗口布尔在 4 个时间点切换正确 |
| `test_IsPastWindow` | `isPastWindow` 在 `expiryDate+1 days` 后为 true |

### 5. 需求 5：过期销毁 / 赎回（8）

窗口结束后项目方 `expireAndReclaim()` 赎回 ETH，`burnFrom()` 销毁任意账户剩余期权。

| 用例 | 验证点 |
|------|--------|
| `test_ExpireAndReclaim_OwnerGetsEth` | owner 收回全部剩余 ETH，`expired=true` |
| `test_ExpireAndReclaim_EmitsEvent` | 触发 `ExpiredAndReclaimed` 事件 |
| `test_ExpireAndReclaim_WindowOpen_Reverts` | 窗口未结束 → `"COT: window still open"` |
| `test_ExpireAndReclaim_NotOwner_Reverts` | 非 owner → revert |
| `test_ExpireAndReclaim_Twice_Reverts` | 重复赎回 → `"COT: already expired"` |
| `test_ExpireAndReclaim_AfterPartialExercise` | 部分行权后赎回剩余 ETH |
| `test_BurnFrom_BeforeExpired_Reverts` | 过期前 burnFrom → `"COT: not expired yet"` |
| `test_BurnFrom_AfterExpired_BurnsAnyAccount` | 过期后可销毁任意账户期权（“销毁所有”） |
| `test_BurnFrom_NotOwner_Reverts` | 非 owner → revert |
| `test_AfterExpired_ExerciseAndIssue_Revert` | 过期后行权/发行均被禁 |

### 6. 端到端 + 边界（2）

| 用例 | 验证点 |
|------|--------|
| `test_FullLifecycle` | 发行→AMM 买入→部分行权→抽池→赎回→销毁剩余，终态归零 |
| `test_Exercise_AllCollateral_DrainsContract` | 全量行权后合约 ETH 余额归零 |

## 需求 ↔ 测试覆盖映射

| 需求 | 功能 | 覆盖分组 |
|------|------|----------|
| 1 | 创建时确认价格与行权日期 | 部署测试 |
| 2 | 项目方按 ETH 发行期权 | 发行测试 |
| 3 | 期权/USDT 低价交易对 | AMM 交易对测试 |
| 4 | 到期日当天行权 | 行权测试 |
| 5 | 过期销毁所有期权并赎回标的 | 过期销毁/赎回测试 |

## 常用 Forge Cheatcode

本测试集依赖以下 Foundry cheatcode：

| Cheatcode | 用途 |
|-----------|------|
| `makeAddr(name)` | 生成确定性测试地址（alice / bob） |
| `vm.deal(addr, amt)` | 给地址打 ETH |
| `vm.warp(ts)` | 推进区块时间（模拟到期/过期） |
| `vm.prank(addr)` / `vm.startPrank` | 模拟特定 caller 调用 |
| `vm.expectRevert(reason)` | 断言 revert 原因 |
| `vm.expectEmit(...)` | 断言事件发射 |

## 注意事项

1. **行权窗口严格 = 到期日当天**：`[expiryDate, expiryDate + 1 days)`。`expiryDate + 1 days` 起进入过期阶段，行权被禁、赎回开启。
2. **`burnFrom` 须在 `expireAndReclaim` 之后**：合约要求 `expired==true` 才允许 `burnFrom`，故「过期清理」顺序为：`removeLiquidity()` → `expireAndReclaim()` → `burnFrom(...)`。
3. **AMM 无 LP 代币**：流动性由 owner 独占，`removeLiquidity()` 一次性抽离全部两币（用于过期清理）。
4. **行权 USDT 归项目方**：合约仅持有 ETH 抵押物；行权时 USDT 经 `transferFrom` 直接从用户转给 `owner()`。
5. **1:1 发行**：1 wei ETH 对应 1 单位期权（均 18 位精度），故 `exercise(amount)` 释放的 ETH wei 数 = 销毁的期权数量。
