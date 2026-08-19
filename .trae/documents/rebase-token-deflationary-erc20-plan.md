# 通缩型 Rebase Token 实现计划

## Summary

在 `src/rebase-token/` 目录下从零实现一个通缩型 rebase ERC20（`RebaseToken`），并在 `test/rebase-token/` 下编写 Foundry 测试，验证 rebase 后用户余额按通缩因子正确缩放。核心采用 **scaling-factor（gons/raw 余额）模式**：用户余额以"原始量"存储，对外暴露的 `balanceOf` / `totalSupply` 通过全局 `rebaseFactor` 缩放，从而一次 `rebase()` 调用即可让全部持有者余额同步通缩，无需遍历持仓人。

## Current State Analysis（探索结论）

- 目标目录 `src/rebase-token/` 已存在但为空，需新建合约与测试。
- 项目约定（基于 `src/Counter.sol`、`src/flash-loan/FlashLoanArbitrage.sol`、`src/MemeToken.sol`、`test/stake-pool/StakingPool.t.sol`）：
  - `pragma solidity ^0.8.30`，新文件 `SPDX-License-Identifier: MIT`。
  - 导入：OpenZeppelin 走 `@openzeppelin/contracts/...`，测试走 `forge-std/Test.sol`，均使用具名导入 `{X}`。
  - 注释：NatSpec `/// @dev` / `@title`，业务逻辑用中文，分区用 `// ===== 标题 =====`。
  - 测试：`contract XxxTest is Test`，`setUp()` 初始化，`test_<scenario>` 命名，时间用 `vm.warp`，`assertEq` / `assertApproxEqAbs`，可用 `vm.pauseGasMetering()`。
- 依赖就绪：`lib/forge-std`、`lib/openzeppelin-contracts` 均已安装。
- 关键技术决策：OpenZeppelin `ERC20` 的 `_balances` / `_totalSupply` 为 private，难以干净地叠加 scaling-factor 逻辑；且本任务目标是"理解 rebase 型 Token 的实现原理"，**从零实现 IERC20** 更清晰、更有教学价值。因此不继承 OZ ERC20，自行实现标准 ERC20 接口 + rebase 机制。

## Proposed Changes

### 文件 1：`src/rebase-token/RebaseToken.sol`（新建）

**职责**：通缩型 rebase ERC20 合约。

**核心数学（WAD = 1e18 表示 1.0）**：
- `balanceOf(u) = _rawBalances[u] * rebaseFactor / WAD`
- `totalSupply() = _rawTotalSupply * rebaseFactor / WAD`
- 转账时把弹性量换算为原始量：`rawAmount = elasticAmount * WAD / rebaseFactor`
- `rebase()`：`rebaseFactor = rebaseFactor * 99 / 100`（即下调 1%）

**通缩曲线（起始 1 亿，18 位精度）**：
| 时间点 | rebaseFactor | totalSupply |
|---|---|---|
| 第 0 年（构造） | 1.0e18 | 100,000,000 |
| 第 1 年 rebase 后 | 0.99e18 | 99,000,000 |
| 第 2 年 rebase 后 | 0.9801e18 | 98,010,000 |
| 第 3 年 rebase 后 | 0.970299e18 | 97,029,900 |

逐次复利通缩，符合"在上一年的发行量基础上下降 1%"。

**合约内容**：
- 常量：`name="Rebase Deflation Token"`、`symbol="RBDT"`、`decimals=18`、`WAD=1e18`、`INITIAL_SUPPLY=100_000_000 * 1e18`、`REBASE_INTERVAL=365 days`、`DEFLATION_NUMERATOR=99`、`DEFLATION_DENOMINATOR=100`。
- 状态：`rebaseFactor`（初值 `WAD`）、`rawTotalSupply`、`lastRebaseTimestamp`（构造时 = `block.timestamp`）、`rebaseCount`、`_rawBalances` mapping、`_allowances` mapping。
- 事件：`Transfer`、`Approval`、`Rebase(uint256 oldFactor, uint256 newFactor, uint256 newTotalSupply, uint256 timestamp)`。
- 构造函数：铸造 1 亿原始量给 `msg.sender`，置 `lastRebaseTimestamp = block.timestamp`，emit `Transfer(0, msg.sender, INITIAL_SUPPLY)`。
- ERC20 视图：`balanceOf`、`totalSupply`、`allowance`（均按上述公式）。
- ERC20 写：`transfer`、`approve`、`transferFrom`（含 `type(uint256).max` 无限授权短路）。
- 内部：`_transfer(from, to, amount)`（先 `elasticToRaw`，再校验并增减 `_rawBalances`，emit 弹性量的 `Transfer`）、`elasticToRaw`、`rawToElastic`（设为 public view，便于测试与调试）。
- `rebase()`：
  - `require(block.timestamp >= lastRebaseTimestamp + REBASE_INTERVAL, "Rebase: interval not elapsed")`
  - `rebaseFactor = rebaseFactor * 99 / 100`
  - `lastRebaseTimestamp = block.timestamp`；`rebaseCount++`
  - emit `Rebase`，返回 `totalSupply()`。
- 访问控制：`rebase()` 设为 permissionless（任何人可触发）。本代币只通缩、无铸币风险，且教学优先；NatSpec 注明生产环境应改为 owner/oracle 限制。
- 不实现 mint/burn（需求未要求，保持最小化）。

### 文件 2：`test/rebase-token/RebaseToken.t.sol`（新建）

**职责**：覆盖初始状态、时间门控、单次/多次复利通缩、rebase 后余额正确性、rebase 后转账换算、原始量不变性、标准授权代扣。

**测试用例**（`contract RebaseTokenTest is Test`，`setUp` 部署 `RebaseToken`，用 `vm.addr(1)` 作 deployer、`makeAddr` 作 user2/user3）：

1. `test_initial_state`：name/symbol/decimals、`totalSupply()==100_000_000e18`、deployer `balanceOf==100_000_000e18`、`rebaseFactor==1e18`、`rebaseCount==0`。
2. `test_rebase_reverts_before_interval`：构造后立即 `rebase()`，`vm.expectRevert("Rebase: interval not elapsed")`。
3. `test_single_year_rebase`：`vm.warp(365 days)` → `rebase()` → 断言 `totalSupply()==99_000_000e18`、deployer `balanceOf()==99_000_000e18`、`rebaseFactor==0.99e18`、`rebaseCount==1`。
4. `test_multi_year_compounding_rebase`：连续 3 次 `vm.warp(365 days)+rebase()`，分别断言 `totalSupply()` 为 99M、98.01M、97.0299M（用 `assertApproxEqAbs(..., 1)` 容 1 wei 取整），验证"在上年基础上下降 1%"的复利。
5. `test_balance_reflects_rebase_after_transfer`：deployer 转 50M 给 user2 → `vm.warp(365 days)` → `rebase()` → 两人余额均按 0.99 缩放（各 49.5M、49.5M），`totalSupply` 同步为 99M。
6. `test_transfer_after_rebase`：`vm.warp+rebase` 后，deployer（99M）转 49.5M 给 user3 → 两端余额正确，验证 `elasticToRaw` 在新因子下换算无误。
7. `test_raw_balance_unchanged_after_rebase`：rebase 前后调用 `elasticToRaw(balanceOf(deployer))` 或暴露的原始量视图一致，证明 rebase 只动 `rebaseFactor`，不动 `_rawBalances`。
8. `test_approve_transferFrom`：标准授权 + 代扣 + 无限授权短路。
9. `testFuzz_rebase_n_years(uint8 n)`：`vm.assume(n<=10)`，循环 n 次 `warp+rebase`，断言 `totalSupply()` ≈ `100_000_000e18 * (99/100)^n`（容差 1e6 wei），覆盖复利通缩一般情形。

**测试约定**：MIT 许可、`pragma ^0.8.30`、`import {Test, console2}`、`import {RebaseToken} from "../../src/rebase-token/RebaseToken.sol"`、中文 NatSpec、`assertApproxEqAbs` 处理 0.99^n 的微小整数取整。

## Assumptions & Decisions

1. **scaling-factor 模式**（gons）：而非"遍历持仓人实际 burn"或"惰性 per-user 调整"。原因：一次 rebase 全员同步、gas 恒定、最贴合 AMPL 等真实 rebase 代币原理，最具教学价值。
2. **从零实现 IERC20**，不继承 OZ ERC20：OZ `_balances` 为 private 难以干净叠加 scaling 逻辑；从零实现更能暴露 rebase 原理。仍产出标准 Transfer/Approval 事件与接口，符合 ERC20。
3. **`rebase()` permissionless**：本代币仅通缩，无铸币风险，教学优先；NatSpec 注明生产应改 owner/oracle 限制。
4. **每次 rebase 仅下调 1%、需满 1 年、计时器重置为 `block.timestamp`**：最贴合"每过一年下降 1%"的字面语义，心智模型最简；多年代通缩通过多次 `warp+rebase` 实现（测试用例 4、9 已覆盖）。若一次跨多年，需多次调用补齐。
5. **`elasticToRaw` 用地板除**：0.99^n 在 WAD 下对测试涉及的小 n 取整干净（99M、98.01M、97.0299M 均精确），不引入可观测漂移；注释中说明此行为。
6. **不实现 mint/burn**：需求未要求，保持最小化聚焦 rebase 原理。
7. **`REBASE_INTERVAL = 365 days`**：用 365 天表示"一年"，测试用 `vm.warp(365 days)` 驱动。

## Verification Steps

1. `forge build` —— 合约与测试编译通过、无 warning（除已知）。
2. `forge test --match-contract RebaseTokenTest -vv` —— 9 个用例（含 1 个 fuzz）全部 PASS。
3. 重点人工核对：
   - 用例 3：单年 rebase 后 `totalSupply` 恰为 99,000,000e18。
   - 用例 4：三年复利依次为 99M / 98.01M / 97.0299M。
   - 用例 5/6：rebase 后 `balanceOf` 与转账换算正确（覆盖需求"balanceOf() 可反应通缩后的用户的正确余额"）。
   - 用例 7：原始量在 rebase 前后不变（佐证 scaling-factor 原理）。
4. `forge test --match-test testFuzz_rebase_n_years -vv` —— fuzz 用例通过，复利通缩一般式成立。
5. 可选：`forge coverage --match-contract RebaseToken` 查看合约行覆盖。
