# RebaseToken 测试说明

本目录测试 `src/rebase-token/RebaseToken.sol`，覆盖通缩型 rebase ERC20 的核心行为：起始发行量 1 亿、时间门控、单年/多年复利通缩、rebase 后 `balanceOf` 与 `totalSupply` 正确缩放、rebase 后转账换算、原始余额不变性、标准授权代扣。**纯 Foundry 环境，无需 fork 主网、无外部依赖**。

## 环境与前置

- 测试框架：Foundry（`forge-std/Test`）。
- 无 RPC、无 fork、无 `.env` 依赖，开箱即跑。
- 依赖：项目已安装的 `lib/forge-std`。

## 合约设计速览（scaling-factor / gons 模式）

为理解 rebase 型 Token 的实现原理，合约**从零实现 IERC20**（不继承 OZ ERC20，因其 `_balances` 为 private 难以干净叠加缩放逻辑），核心是引入一个全局缩放因子 `rebaseFactor`：

| 概念 | 含义 |
| --- | --- |
| `_rawBalances[u]` | 用户"原始量"余额（gons），构造后只在转账时变化 |
| `rawTotalSupply` | 原始总量，构造时 = 1 亿，之后不变 |
| `rebaseFactor` | 全局缩放因子，初值 `WAD = 1e18`（即 1.0） |
| `balanceOf(u)` | `= _rawBalances[u] * rebaseFactor / WAD`（弹性余额） |
| `totalSupply()` | `= rawTotalSupply * rebaseFactor / WAD`（弹性总量） |
| `elasticToRaw(e)` | `= e * WAD / rebaseFactor`（弹性量→原始量，转账换算用） |
| `rawToElastic(r)` | `= r * rebaseFactor / WAD`（原始量→弹性量） |

`rebase()` 每过一年将 `rebaseFactor *= 99 / 100`（下调 1%）。**一次调用即可让全部持仓人余额同步通缩**，无需遍历持仓人 —— 这是该模式相对"逐账户实际 burn"的核心优势。

### 通缩曲线（起始 1 亿，逐年复利下降 1%）

| 时间点 | rebaseFactor | totalSupply |
| --- | --- | --- |
| 第 0 年（构造） | `1.0e18` | 100,000,000 |
| 第 1 年 rebase 后 | `0.99e18` | 99,000,000 |
| 第 2 年 rebase 后 | `0.9801e18` | 98,010,000 |
| 第 3 年 rebase 后 | `0.970299e18` | 97,029,900 |

符合需求"税后每过一年在上一年的发行量基础上下降 1%"。

### 关键设计决策

- **从零实现 IERC20**：暴露 rebase 原理，避免 OZ private 状态绕路；仍产出标准 `Transfer`/`Approval` 事件与接口。
- **`rebase()` permissionless**：本代币仅通缩、无铸币风险，教学优先；NatSpec 注明生产环境应改为 owner/oracle 限制。
- **每次 rebase 仅下调 1%、需满 1 年、计时器重置为 `block.timestamp`**：最贴合"每过一年下降 1%"的字面语义，心智模型最简；多年代通缩通过多次 `warp+rebase` 实现。
- **`elasticToRaw` 用地板除**：0.99^n 在 WAD 下对测试涉及的小 n 取整干净（99M、98.01M、97.0299M 均精确）。
- **不实现 mint/burn**：需求未要求，保持最小化聚焦 rebase 原理。

## setUp 流程

1. 创建测试账户：`deployer = vm.addr(1)`、`user2 = makeAddr("user2")`、`user3 = makeAddr("user3")`。
2. `vm.prank(deployer)` 下部署 `RebaseToken`：构造函数铸造 1 亿原始量给 `deployer`，置 `lastRebaseTimestamp = block.timestamp`、`rebaseFactor = WAD`。
3. `block.timestamp` 初值为 1（forge 测试环境默认）。

## 测试用例

### 1. `test_initial_state`
验证初始发行量与状态。
- 断言 `name`/`symbol`/`decimals`。
- 断言 `totalSupply() == 100_000_000e18`、`balanceOf(deployer) == 100_000_000e18`。
- 断言 `rebaseFactor == 1e18`、`rebaseCount == 0`、`rawBalanceOf(deployer) == 100_000_000e18`。

### 2. `test_rebase_reverts_before_interval`
验证时间门控（未满一年不可通缩）。
- 构造后立即调 `rebase()`，期望 revert `"Rebase: interval not elapsed"`。

### 3. `test_rebase_reverts_one_sec_before`
验证边界严格性。
- `vm.warp(block.timestamp + 365 days - 1)`（差 1 秒满一年）后调 `rebase()`，期望 revert。

### 4. `test_single_year_rebase`
验证单年通缩 1%。
- `_advanceOneYear()` → `rebase()`。
- 断言 `totalSupply() == 99_000_000e18`、`balanceOf(deployer) == 99_000_000e18`。
- 断言 `rebaseFactor == 0.99e18`、`rebaseCount == 1`。

### 5. `test_multi_year_compounding_rebase`
验证多年复利通缩（核心需求：在上年基础上下降 1%）。
- 第 1 年：100M → 99M
- 第 2 年：99M → 98.01M
- 第 3 年：98.01M → 97.0299M（`assertApproxEqAbs(..., 1)` 容 1 wei 取整）
- 断言 `rebaseCount == 3`。

### 6. `test_balance_reflects_rebase_after_transfer`
验证 rebase 后用户余额正确缩放（覆盖需求"balanceOf() 可反应通缩后的用户的正确余额"）。
- deployer 转 50M 给 user2 → 两端各 50M。
- `_advanceOneYear()` → `rebase()` → 两端均缩放为 49.5M、`totalSupply` = 99M。

### 7. `test_transfer_after_rebase`
验证 rebase 后转账的 raw↔elastic 换算正确。
- `_advanceOneYear()` → `rebase()` → deployer 持 99M。
- deployer 转 49.5M 给 user3 → 两端正确、`totalSupply` 不变（转账不改变弹性总量）。
- 断言 `rawToElastic(rawBalanceOf(deployer)) == 49.5M`（raw→elastic 一致）。

### 8. `test_raw_balance_unchanged_after_rebase`
佐证 scaling-factor 原理：rebase 只动因子，不动原始余额。
- rebase 前：`rawBalanceOf(deployer) == 100M`、`balanceOf(deployer) == 100M`。
- `_advanceOneYear()` → `rebase()`。
- 断言 `rawBalanceOf(deployer)` 前后**不变**、`balanceOf(deployer)` 缩为 99M、`rawToElastic(raw) == 99M`。

### 9. `test_approve_transferFrom`
验证标准授权与代扣。
- deployer 授权 user2 共 10M。
- user2 代扣 6M 给 user3。
- 断言 deployer 余额 94M、user3 余额 6M、剩余授权 4M。

### 10. `test_approve_infinite_allowance_no_decrement`
验证无限授权不扣减。
- deployer 授权 user2 `type(uint256).max`。
- user2 代扣 1M，断言 `allowance` 仍为 `type(uint256).max`。

### 11. `test_transferFrom_exceeds_allowance_reverts`
验证超额代扣回滚。
- 授权 5M，代扣 6M，期望 revert `"ERC20: insufficient allowance"`。

### 12. `testFuzz_rebase_n_years`
fuzz 验证 n 年复利通缩一般式。
- `vm.assume(n > 0 && n <= 10)`。
- 循环 n 次 `_advanceOneYear() + rebase()`。
- 期望 `totalSupply() ≈ 100_000_000e18 × (99/100)^n`，用 `assertApproxEqAbs(..., 1e6)` 容整。
- 断言 `rebaseCount == n`，并 `console2.log` 打印实际值。

## 关于 vm.warp 时间推进的坑

forge 测试环境 `block.timestamp` 初值为 **1**（不是 0）。若用绝对 `vm.warp(365 days)`：
- `lastRebaseTimestamp = 1`（构造时）
- warp 后 `block.timestamp = 31536000`
- 校验 `block.timestamp >= lastRebaseTimestamp + 365 days` → `31536000 >= 31536001` → **false，revert**

为规避 off-by-one，本测试统一使用相对推进 helper：

```solidity
function _advanceOneYear() internal {
    vm.warp(block.timestamp + 365 days);
}
```

推进后 `block.timestamp` 与 `lastRebaseTimestamp` 之差恰好 `365 days`，`>=` 判定通过。多年场景每次推进均以"当前时间 + 1 年"为基准，自然累积。

## 测试辅助技巧

- `_advanceOneYear()`：相对推进 1 年的内部 helper，规避 forge `block.timestamp` 初值 off-by-one。
- `vm.prank(sender)`：模拟特定账户身份调用 `transfer` / `approve` / `transferFrom`。
- `vm.expectRevert(bytes(...))`：断言下一次调用按特定错误字符串回滚。
- `assertApproxEqAbs(actual, expected, maxDelta)`：容忍整数取整误差（用于 `0.99^n` 涉及的尾数）。
- `vm.assume(...)`：fuzz 用例中过滤不合理输入范围。

## 运行命令

```bash
# 编译
forge build

# 仅运行本目录测试（带 trace）
forge test --match-contract RebaseTokenTest -vv

# 完整 trace 调试
forge test --match-contract RebaseTokenTest -vvvvv

# 单独跑 fuzz 用例
forge test --match-test testFuzz_rebase_n_years -vv
```

预期结果：12 个用例全部通过（fuzz 默认 257 runs）。
