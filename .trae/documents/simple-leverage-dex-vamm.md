# SimpleLeverageDEX (vAMM 杠杆 DEX) 实现计划

## Summary

补全 `src/simple-leverage-dex/SimpleLeverageDEX.sol` 中所有 TODO，基于 vAMM（虚拟恒定乘积 `vK = vETH * vUSDC`）机制实现一个极简杠杆 DEX，包含开仓 / 平仓 / 清算三大核心方法，并配套 MockUSDC 代币、Foundry 测试与说明文档。实现遵循项目既有约定（中文注释、`@dev` NatSpec、模块自包含、`test/<module>/` + `README.md`）。

## Current State Analysis

现有合约 [SimpleLeverageDEX.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/simple-leverage-dex/SimpleLeverageDEX.sol) 框架已就位但存在以下缺口：

1. **USDC 未初始化**：`IERC20 public USDC;` 声明但构造函数 `constructor(uint vEth, uint vUSDC)` 从未赋值，`openPosition` 中 `USDC.transferFrom` 会因零地址 revert。
2. **`openPosition` TODO**：`pos.position` 在 long / short 两个分支均未赋值。
3. **`closePosition` 空实现**：无平仓、无 vAMM 状态回滚、无 USDC 结算。
4. **`liquidatePosition` TODO**：仅读取 position 与 pnl，缺少清算条件校验、清算人≠本人校验、清算奖励分配。
5. **`calculatePnL` 空实现**：未根据当前 vAMM 价格计算虚拟盈亏。

项目约定（来自 [StakingPool.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/stake-pool/StakingPool.sol)、[KKToken.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/stake-pool/KKToken.sol)、[MiniSwapPool.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/uniswap-demo/MiniSwapPool.sol)）：
- 每个模块自包含，mock 代币放模块目录内（如 `KKToken`）。
- 中文注释 + `@dev`/`@title` NatSpec。
- AMM 用 `x*y=k` 模式（见 `MiniSwapPool.getAmountOut`）。
- 测试放 `test/<module>/<Contract>.t.sol`，并配 `README.md`；用 `forge-std/Test`、`vm.prank`、`vm.expectRevert`、`assertEq`、`console2.log`。
- Solidity 版本由各合约自声明；本合约保持 `^0.8.36`。

## vAMM 设计（机制说明）

核心：`vK = vETHAmount * vUSDCAmount` 恒定（构造时确定，全周期不变）。价格 ≈ `vUSDCAmount / vETHAmount`。

### 开仓 `openPosition(_margin, level, long)`
- `amount = _margin * level`（总敞口，vUSDC 计价）；`borrowed = amount - _margin`（虚拟借入）。
- 真实划转：`USDC.transferFrom(msg.sender, address(this), _margin)`。
- **做多**：用 `amount` vUSDC 向 vAMM 买入 vETH。
  - `vUSDCAmount += amount`
  - `newVETH = vK / vUSDCAmount`（减少）
  - `vETHBought = vETHAmount - newVETH`
  - `vETHAmount = newVETH`
  - `position = int256(vETHBought)`（正）
- **做空**：向 vAMM 卖出 vETH、取出 `amount` vUSDC（借入 vETH 做空）。
  - `require(vUSDCAmount > amount)`（防下溢）
  - `vUSDCAmount -= amount`
  - `newVETH = vK / vUSDCAmount`（增加）
  - `vETHSold = newVETH - vETHAmount`
  - `vETHAmount = newVETH`
  - `position = -int256(vETHSold)`（负）

### 平仓 `closePosition()`（不考虑协议亏损）
1. `pnl = calculatePnL(msg.sender)`（基于当前 vAMM 状态）
2. 反向回滚 vAMM：
   - 做多：`vETHAmount += uint(position)`；`vUSDCAmount = vK / vETHAmount`；`vusdcOut = 旧vUSDC - 新vUSDC`
   - 做空：`vETHAmount -= uint(-position)`；`vUSDCAmount = vK / vETHAmount`；`vusdcIn = 新vUSDC - 旧vUSDC`
3. 结算：`equity = int256(margin) + pnl`；`payout = equity > 0 ? uint256(equity) : 0`（亏空不追讨 = 不考虑协议亏损）。
4. `USDC.transfer(msg.sender, payout)`；`delete positions[msg.sender]`。

### 盈亏 `calculatePnL(user)`（view）
- 做多（position>0）：假设卖出 `position` vETH 回 vAMM → `vusdcOut`；`pnl = int256(vusdcOut) - int256(margin + borrowed)`。
- 做空（position<0）：假设买回 `|position|` vETH → `vusdcIn`；`pnl = int256(margin + borrowed) - int256(vusdcIn)`。
- 含义：价格不变时 `vusdcOut≈amount`、`vusdcIn≈amount` → `pnl≈0`；价格朝有利方向移动则 `pnl>0`。

### 清算 `liquidatePosition(_user)`
- 校验：`position != 0`；`msg.sender != _user`；`pnl < -int256(margin * 80 / 100)`（亏损 > 保证金 80%）。
- 反向回滚 vAMM（同平仓逻辑）。
- 清算奖励 = 剩余权益 `equity = int256(margin) + pnl`（此时 `0 < equity < 0.2*margin`）→ `reward = equity > 0 ? uint256(equity) : 0` 转 USDC 给 `msg.sender`（利润归清算人）。
- `delete positions[_user]`。

## Proposed Changes

### 1. 修改 [SimpleLeverageDEX.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/simple-leverage-dex/SimpleLeverageDEX.sol)

- **构造函数**：增加 `address _usdc` 参数并赋值 `USDC = IERC20(_usdc)`，保留 `vK = vEth * vUSDC` 逻辑。
- **事件**：新增 `OpenPosition`、`ClosePosition`、`Liquidate`（含 user/long/position/margin/borrowed/pnl/reward 字段）。
- **`openPosition`**：补 `require(level >= 1 && _margin > 0)`；按上面设计补 long/short 两分支 `pos.position` 赋值与 vAMM 状态更新；末尾 emit。
- **`closePosition`**：完整实现 4 步（pnl → 反向回滚 → 结算 → delete）。
- **`liquidatePosition`**：补 3 条 require + 反向回滚 + 清算奖励 USDC 转账 + emit + delete（保留已有 `delete`）。
- **`calculatePnL`**：按设计返回 int256，复用 vAMM 数学（只读）。
- **内部辅助**：无额外 helper（保持极简，平仓/清算内联反向回滚）。

### 2. 新建 [MockUSDC.sol](file:///Users/mac/learn/web3/2026/07/FoundryPrac/src/simple-leverage-dex/MockUSDC.sol)

简单 ERC20，6 位精度（真实 USDC 精度，与 vUSDCAmount 单位一致），开放 `mint` 供测试发放：
- 继承 OpenZeppelin `ERC20`；`decimals()=6`；构造 `"Mock USDC"/"USDC"`；`mint(address to, uint256 amount)` 外部可调。

### 3. 新建 `test/simple-leverage-dex/SimpleLeverageDEX.t.sol`

setUp：部署 `MockUSDC` → 部署 `SimpleLeverageDEX(10 ether, 30000e6, usdc)`（初始价 3000 USDC/ETH）→ 给 user/priceMover/liquidator 铸 USDC 并 approve。价格变动由 `priceMover` 在同一 vAMM 开仓推动（做多推高、做空压低）。

测试用例：
1. `test_open_long_then_close_no_price_move`：开多立即平仓，`pnl≈0`，收回 ≈ margin（容 1 USDC 取整）。
2. `test_open_short_then_close_no_price_move`：开空立即平仓，`pnl≈0`。
3. `test_long_profit_when_price_up`：user 开多 → priceMover 开大单做多推价 → user 平仓获利（`pnl>0`，到账 > margin）。
4. `test_short_profit_when_price_down`：user 开空 → priceMover 开大单做空压价 → user 平仓获利。
5. `test_liquidate_long_on_crash`：user 10x 做多 → priceMover 做空砸盘使亏损 > 80% margin → liquidator 清算获 reward（`reward>0` 且 < 0.2*margin），仓位删除。
6. `test_cannot_liquidate_self`：`vm.prank(user)` 清算自己 → revert。
7. `test_cannot_liquidate_when_not_liquidatable`：未达阈值清算 → revert。
8. `test_cannot_open_twice`：已有仓位再开 → revert。

### 4. 新建 `test/simple-leverage-dex/README.md`

说明 vAMM 机制、setUp、各用例意图与数值选择（参照 [stake-pool README](file:///Users/mac/learn/web3/2026/07/FoundryPrac/test/stake-pool/README.md) 风格）。

## Assumptions & Decisions

1. **USDC 注入方式**：构造函数新增 `_usdc` 参数（而非内部部署）——USDC 是用户预先持有的真实代币，注入地址更贴近真实部署，与 `StakingPool` 注入 WETH/Aave 地址一致。配套 `MockUSDC` 供测试。
2. **精度**：MockUSDC = 6 位（真实 USDC），`vUSDC` 初始量同样用 6 位（`30000e6`），`vETH` 用 18 位（`10 ether`），保证 `margin*level` 与 `vUSDCAmount` 同单位可加减。`vK` 单位混合但仅作恒定常数，不影响 AMM 数学。
3. **PnL 公式**：`pnl = 当前仓位价值 − 入场总成本(margin+borrowed)`，价格不变时为 0（金融正确）。注释中"对比当前仓位和借的 vUSDC"按此语义实现（总成本 = margin+borrowed）。
4. **"不考虑协议亏损"**：平仓结算 `payout = max(0, margin+pnl)`，不追讨负权益；不对协议偿付能力做额外校验（测试场景保证合约 USDC 余额充足，由 priceMover 的亏损保证金覆盖盈利方）。
5. **清算阈值**：`pnl < -margin*80/100`（亏损 > 80% 保证金），清算人 ≠ 用户，奖励 = 剩余权益 `max(0, margin+pnl)`。
6. **vAMM 局限**：做空开仓需 `vUSDCAmount > amount`；平仓反向回滚在极端 vAMM 状态下可能下溢 revert——极简实现接受此限制，测试用合理数值规避。
7. **杠杆上限**：仅 `require(level >= 1)`，不设上限（极简教学；真实场景需限杠杆与滑点保护，超出本次范围）。

## Verification Steps

1. `forge build` — 编译通过（含 SimpleLeverageDEX、MockUSDC、测试）。
2. `forge test --match-contract SimpleLeverageDEXTest -vvv` — 全部用例通过：
   - 无价格变动平仓 `pnl≈0`、收支平衡；
   - 价格有利方向移动产生正 PnL；
   - 清算触发条件、奖励归属、权限校验均符合预期。
3. 关键断言示例：
   - `test_long_profit_when_price_up`：`user` 到账 USDC > `margin`（即 `payout = margin + pnl > margin`）。
   - `test_liquidate_long_on_crash`：`reward > 0` 且 `reward < margin * 20 / 100`；清算后 `positions[user].position == 0`。
   - `test_cannot_liquidate_self` / `test_cannot_liquidate_when_not_liquidatable`：`vm.expectRevert`。
4. 输出 `console2.log` 关键数值（entry/close vAMM 状态、pnl、payout/reward）便于人工核验 vAMM 数学。
