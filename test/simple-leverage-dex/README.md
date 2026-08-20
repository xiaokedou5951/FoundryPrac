# SimpleLeverageDEX 测试说明

本目录测试 `src/simple-leverage-dex/SimpleLeverageDEX.sol`，覆盖基于 **vAMM（虚拟恒定乘积）** 的极简杠杆 DEX 的核心行为：开仓 / 平仓 / 清算。

## vAMM 机制

核心不变量：`vK = vETHAmount * vUSDCAmount`（构造时确定，全周期不变）。瞬时价格 ≈ `vUSDCAmount / vETHAmount`。

| 操作 | vUSDCAmount | vETHAmount | position |
| --- | --- | --- | --- |
| 做多开仓 | `+= amount` | `= vK / vUSDCAmount`（↓） | `+vETHBought` |
| 做空开仓 | `-= amount` | `= vK / vUSDCAmount`（↑） | `-vETHSold` |
| 做多平仓 | `= vK / vETHAmount`（↓还原） | `+= position`（↑还原） | 清零 |
| 做空平仓 | `= vK / vETHAmount`（↑还原） | `-= |position|`（↓还原） | 清零 |

- `amount = margin * level`（总敞口，vUSDC 计价）；`borrowed = amount - margin`（虚拟借入）。
- **PnL** = 当前仓位虚拟价值 − 入场总成本 `margin + borrowed`；价格不变时为 0（vAMM 反向回滚精确还原）。
- **零和**：盈利方收益由亏损方保证金承担（priceMover 即亏损方），协议不增发不亏空。
- **平仓结算**：`payout = max(0, margin + pnl)`，亏空不追讨（"不考虑协议亏损"）。
- **清算**：`pnl < -margin * 80%`（亏损 > 80% 保证金）即可清算；剩余权益 `max(0, margin+pnl)` 作为奖励归清算人。

## 业务原理解读（以做多获利为例）

> 一句话：**做多 = 押注涨价，借别人的钱放大购买力，低买高卖赚差价。**
> 借钱放大了收益，也放大了风险——跌太多保证金扛不住就被清算。

以 `test_long_profit_when_price_up` 为例：初始池 10 ETH × 30000 USDC（瞬时价 3000），user 参数 `margin=100, level=3`。

### 第一步：开仓 `openPosition`（借钱买 ETH）

- 购买力 `amount = margin × level = 100 × 3 = 300 USDC`：其中 100 是自掏保证金（`USDC.transferFrom` 真实转账进合约），200 是协议**虚拟借入**（仅记账 `pos.borrowed`，不凭空印币）。
- 用 300 USDC 向 vAMM 买 ETH：往池子塞 USDC、按 `vK` 取出 ETH，得到约 0.099 ETH，记为 `position`（正 = 做多持仓）。成交均价 ≈ 3030，略高于瞬时价 3000，差额即买入滑点。

### 第二步：价格上涨（有人把价炒上去）

另一笔大单做多往池子塞入大量 USDC、抽走 ETH → vETHAmount 大减、vUSDCAmount 大增 → 价格被推到约 5400。user 啥也没做，手里 0.099 ETH 变得更值钱（浮盈）。

### 第三步：平仓 `closePosition`（卖回 ETH 落袋）

把 0.099 ETH 卖回池子，按当前高价换回约 528 USDC：

```
pnl   = 卖出所得 − 入场总成本 = 528 − 300 = +228 USDC
payout = 保证金 + pnl        = 100 + 228 = 328 USDC   // 实际拿回
```

user 掏 100、拿回 328、净赚 228。杠杆把收益放大 3 倍；代价是 ETH 跌约 33% 保证金即全亏（触发 `liquidatePosition`）。做空（`long=false`）则完全反向：借 ETH 高价卖出、跌了低价买回赚差价。

### 滑点不在某行代码里"扣"，是 vAMM 数学的副产品

`calculatePnL` 中 `vusdcOut = vUSDCAmount - vK / (vETHAmount + position)`：分母里含"你卖回的量"，**卖得越多，分母越大，单位 ETH 换回的 USDC 越少**——这就是卖出砸价（滑点）。

本例：按线性价 `0.099 × 5412 ≈ 536`，vAMM 实际给 `528`，差额约 `8` 即卖出滑点。`pnl=228` 是 `vusdcOut - 总成本` 的真实结果，**买卖两端滑点都已算入**，无需额外扣费。池子越深、单笔占比越小 → 滑点越小。

## 环境与前置

- 测试框架：Foundry（`forge-std/Test`）。
- 纯本地环境，无需 fork 主网、无需 `.env`。
- MockUSDC（6 位精度，真实 USDC 精度）与 vUSDCAmount 同单位，保证 `margin*level` 与 vUSDCAmount 可加减。

## setUp 流程

1. 部署 `MockUSDC`。
2. 部署 `SimpleLeverageDEX(10 ether, 30000e6, usdc)` → 初始价 3000 USDC/ETH。
3. 给 `user` / `priceMover` / `liquidator` 各铸 100000 USDC 并对 dex 无限授权。

价格变动由 `priceMover` 在同一 vAMM 开仓推动：做多推高价格、做空压低价格。

## 测试用例

### 1. `test_open_long_then_close_no_price_move`
2x 做多后立即平仓（无其他交易）。vAMM 精确反向回滚 → `pnl == 0`，用户拿回全部 margin。

### 2. `test_open_short_then_close_no_price_move`
2x 做空后立即平仓。`pnl == 0`，收支精确平衡。

### 3. `test_long_profit_when_price_up`
user 3x 做多 → priceMover 10000 USDC 敞口做多推价 → user 平仓获利（`pnl ≈ +228 USDC`，净收益 > margin）。

### 4. `test_short_profit_when_price_down`
user 3x 做空 → priceMover 10000 USDC 敞口做空压价 → user 平仓获利（`pnl ≈ +168 USDC`）。

### 5. `test_liquidate_long_on_crash`
user 5x 做多（高杠杆）→ priceMover 3000 USDC 做空砸盘使 user 亏损落入 (80%, 100%) margin 区间 → liquidator 清算。
- `pnl ≈ -92`，阈值 `-80`，触发清算。
- 奖励 = 剩余权益 `margin + pnl ≈ 7 USDC`（`0 < reward < 20% margin`）。
- 仓位删除。

### 6. `test_cannot_liquidate_self`
清算人 = 用户本人 → revert `cannot liquidate self`。

### 7. `test_cannot_liquidate_when_not_liquidatable`
user 做多且价格上涨（盈利，远未达清算）→ 清算 revert `not liquidatable`。

### 8. `test_cannot_open_twice`
已有仓位再次开仓 → revert `Position already open`。

## 运行

```bash
forge test --match-contract SimpleLeverageDEXTest -vvv
```

关键日志（`-vvv` 输出）展示各场景的 pnl / 阈值 / 奖励，便于人工核验 vAMM 数学。
