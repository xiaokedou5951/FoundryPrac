# StakingPool 测试说明

本目录测试 `src/stake-pool/StakingPool.sol`，覆盖 ETH 质押挖矿 + Aave V3 借贷集成的核心行为。测试在 Fork 主网环境下运行，直接使用线上现成的 Aave V3 合约，无需安装 Aave 库。

## 环境与前置

- 测试框架：Foundry（`forge-std/Test`）。
- 运行方式：Fork 以太坊主网（`vm.createSelectFork(vm.rpcUrl("mainnet"))`）。
- 依赖 `.env` 中的 `MAINNET_RPC_URL`。运行前确认已配置：
  ```bash
  # .env
  MAINNET_RPC_URL=https://...
  ```

## 主网地址常量

| 常量 | 地址 | 说明 |
| --- | --- | --- |
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | 主网 WETH9 |
| `AAVE_POOL` | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` | Aave V3 Pool 代理 |
| `AWETH` | `0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8` | Aave V3 aWETH（`symbol="aEthWETH"`） |

> 注：当前主网 Pool 实现已不再暴露 `getReserveTokensAddresses`，因此 aWETH 地址不通过 Pool 查询，而是作为构造参数传入。地址通过链上 `symbol()` 校验为 `aEthWETH`。

## setUp 流程

1. Fork 主网。
2. 部署 `StakingPool(AAVE_POOL, WETH, AWETH)`，构造时内部部署 `KKToken`（`minter = StakingPool`）。
3. 读取 `pool.kkToken()` 与 `pool.aWeth()`。
4. 给 `user1`、`user2` 各发放 100 ETH（`vm.deal`）。

## 测试用例

### 1. `test_stake_supplies_to_aave`
验证需求 3：`stake()` 内已集成 Aave `Pool.supply()`。
- user1 质押 1 ETH。
- 断言 `aWeth.balanceOf(pool) ≈ 1 ether`（容 1~2 wei 取整误差）。
- 断言 `pool.totalStaked() == 1 ether`、用户质押量 == 1 ether。

### 2. `test_reward_single_user`
验证需求 1：每区块 10 KK，单人质押全额获得。
- user1 质押 1 ETH。
- `vm.roll` 推进 10 个区块。
- `pendingReward(user1) == 100 ether`（10 区块 × 10 KK）。
- `claimReward()` 后 `kk.balanceOf(user1) == 100 ether`。

### 3. `test_reward_pro_rata`
验证需求 1：按"质押数量 × 质押时长"公平分配。
- user1 在区块 N 质押 1 ETH（全程）。
- 区块 N+10，user2 质押 1 ETH（半程加入）。
- 区块 N+20，两人各 `claimReward()`。
- 期望：user1 = 150 KK，user2 = 50 KK（区间 1 的 100 KK 全归 user1；区间 2 的 100 KK 平分）。
- 用 `console2.log` 打印实际数值。

### 4. `test_unstake_returns_eth_and_settles_kk`
验证解除质押流程。
- user1 质押 2 ETH，`vm.roll` 推进 5 个区块。
- 调 `unstake(2 ether)`。
- 断言用户收回 ETH ≈ 2 ether（容 1~2 wei 取整）。
- 断言 `aWeth.balanceOf(pool) == 0`、`totalStaked == 0`、用户质押量 == 0。
- 断言 KK 已结算 == 50 ether（5 区块 × 10 KK）。

### 5. `test_owner_claim_interest_access_control`
验证利息提取权限。
- user2（非 owner）调 `ownerClaimInterest()`，期望 revert `"StakePool: not owner"`。

### 6. `test_owner_claim_interest_happy_path`
验证利息提取 happy path（0 利息情形）。
- user1 质押 1 ETH。
- 刚质押无利息：`aWeth.balanceOf(pool) ≈ totalStaked`。
- owner（测试合约本身）调 `ownerClaimInterest()`：不应 revert，因 `interest == 0` 不触发 Aave withdraw。
- 断言 aWETH 与 totalStaked 保持不变。

## 关于 Aave scaled-balance 取整

Aave V3 的 aToken 余额按 `scaledBalance × liquidityIndex` 计算。当 `liquidityIndex ≠ 1e27`（主网 WETH 的 index ≈ 1.069）时，supply 后 `balanceOf` 可能比质押量少 1~2 wei，`withdraw(amount)` 也可能因 `AMOUNT_GREATER_THAN_USER_BALANCE` 回滚。

合约侧已在 `unstake` / `ownerClaimInterest` 中处理：cap 在 aWETH 余额、按实际收到的 WETH 计量退还。测试侧对涉及 aWETH / ETH 返还的断言使用 `assertApproxEqAbs(..., 1000)`（容忍 1000 wei）。

## 测试辅助技巧

- `vm.pauseGasMetering()` / `vm.resumeGasMetering()`：在 pranked 用户调用期间暂停 gas 计量，使 ETH 余额断言不受 gas 扣费影响，便于精确比较 `address(user).balance` 前后差值。
- `vm.startPrank` / `vm.stopPrank`：模拟用户身份调用 `stake` / `unstake` / `claimReward`。
- `vm.roll`：推进区块号以累计 KK 奖励。

## 运行命令

```bash
# 编译
forge build

# 仅运行本目录测试（带 trace）
forge test --match-contract StakingPoolTest -vvv

# 带完整 trace 调试
forge test --match-contract StakingPoolTest -vvvvv
```

预期结果：6 个用例全部通过。
