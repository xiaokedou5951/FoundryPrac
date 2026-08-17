# Flash Swap 跨池套利功能开发计划（修订版）

## 概述

在 `src/flash-swap/` 下独立开发闪电兑换（Flash Swap）套利功能，**所有业务代码全部新写，不参考、不复用本仓库任何已有功能模块的代码**：

- 引入官方 Uniswap v2-core 子模块（用于部署两个 Uniswap，属外部官方依赖而非仓库已有代码）
- 新写两个独立 ERC20 合约：`TokenA`、`TokenB`（基于 OpenZeppelin `ERC20` 实现，仓库已有该依赖）
- 本地测试网（anvil）部署：TokenA、TokenB + 两个 UniswapV2Factory + PoolA/PoolB，错配储备制造价差
- 新写套利合约（逻辑参考 Uniswap V2 官方 ExampleFlashSwap 示例）：从 PoolA 闪电借出 TokenA → 在 PoolB 兑换成 TokenB → 以 TokenB 偿还 PoolA Pair，剩余 TokenB 即利润

## 现状

- `src/flash-swap/` 目录存在但为空，所有合约、测试、脚本均从零新建
- 仓库现有代码（price-oracle、uniswap-demo、MyERC20、BaseScript 等）**一律不引用、不继承、不复制**
- 仅允许的基础依赖：`forge-std`（Foundry 测试/脚本框架，运行 `forge test` / `forge script` 所必需）与官方 `v2-core` 子模块

## 实施步骤

### 第 1 步：引入官方 Uniswap v2-core 子模块

```bash
forge install Uniswap/v2-core --no-commit
```

- 生成 `lib/v2-core/` 并追加 `.gitmodules`
- 在 `remappings.txt` 追加：`@uniswap/v2-core/=lib/v2-core/`
- 只引入 v2-core：添加流动性用「直接 transfer + pair.mint()」，兑换直接调 pair.swap()，无需 Router/WETH/periphery

### 第 2 步：新建 `src/flash-swap/TokenA.sol` 与 `src/flash-swap/TokenB.sol`

两个**独立合约文件**，合约名分别为 `TokenA`、`TokenB`，均继承 `@openzeppelin/contracts/token/ERC20/ERC20.sol`：

```solidity
// TokenA.sol（TokenB.sol 结构相同，仅名称/符号不同）
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenA is ERC20 {
    constructor() ERC20("Token A", "TKA") {
        _mint(msg.sender, 1_000_000 * 10 ** 18); // 初始供应量给部署者
    }
}
// TokenB：name "Token B"，symbol "TKB"，供应量同为 1,000,000e18
```

- 供应量固定，无需额外 mint 函数，满足全部场景（发币、加流动性、套利）

### 第 3 步：新建 `src/flash-swap/FlashSwapArbitrage.sol` — 核心套利合约

逻辑参考 V2 官方 ExampleFlashSwap 示例（非仓库代码），全部新写：

```text
状态变量（immutable，构造时固定）：
  tokenA / tokenB / pairA / pairB / owner

startArbitrage(uint256 amountTokenA) external
  - 按 tokenA 是 pairA 的 token0 还是 token1 决定方向：
    pairA.swap(amountTokenA, 0, this, "") 或 pairA.swap(0, amountTokenA, this, "")

uniswapV2Call(sender, amount0, amount1, data) external
  - require(msg.sender == pairA)
  - 判断借出的是 TokenA（amount0>0 或 amount1>0），借出量 amountBorrowed
  - ① 把收到的 TokenA 转入 pairB，按 x*y=k（含 0.3% 手续费）计算输出：
      amountBOut = amountBorrowed*997*reserveB_Out / (reserveB_In*1000 + amountBorrowed*997)
    调 pairB.swap(...) 取回 TokenB 到本合约
  - ② 计算偿还 pairA 所需 TokenB（回调内 getReserves() 仍是借用前储备）：
      amountRepay = reserveA_B * amountBorrowed * 1000 / ((reserveA_A - amountBorrowed) * 997) + 1
    （满足 balance0Adj * balance1Adj >= reserve0 * reserve1 * 1000²，
      即"借 TokenA、还 TokenB"合法）
  - require(amountBOut > amountRepay, "FlashSwap: NO_PROFIT")
  - 将 amountRepay 个 TokenB transfer 回 pairA（msg.sender），剩余 TokenB 留存为利润

withdraw(address token) external — 仅 owner 提取利润
内部纯函数 getAmountOut(...) — UniswapV2 标准 997/1000 公式
接口导入：@uniswap/v2-core/contracts/interfaces/ 下的 IUniswapV2Pair / IUniswapV2Factory
```

数值验证（PoolA 储备 10000A/10000B，PoolB 储备 10000A/20000B，借 100 TokenA）：
- 偿还 PoolA ≈ 101.3 TokenB；PoolB 兑出 ≈ 197.4 TokenB → **利润 ≈ 96.1 TokenB**
- 实测（测试与 anvil 部署均验证）：利润 96.1175563739892690962 TokenB

### 第 4 步：新建 `test/flash-swap/FlashSwapArbitrage.t.sol` — 测试

`setUp()` 全部用新合约搭建：部署 TokenA、TokenB、两个 UniswapV2Factory、createPair 得 PoolA/PoolB；直接向 Pair 转 token 后 `pair.mint(address(this))` 添加流动性：
- PoolA：10000e18 TokenA + 10000e18 TokenB（价格 1:1）
- PoolB：10000e18 TokenA + 20000e18 TokenB（价格 1:2 → 套利空间）
- 部署 FlashSwapArbitrage(tokenA, tokenB, pairA, pairB)

测试用例：
1. `test_Arbitrage_MakesProfit`：`startArbitrage(100e18)` 后套利合约 TokenB 余额 > 0（与手算期望值 assertApproxEqRel 比对）；两池价格收敛（PoolA 中 TokenA 价格上升、PoolB 中下降）
2. `test_RevertWhen_NoProfit`：借入量过小（手续费占比过高，如 1e6 wei）→ `vm.expectRevert("FlashSwap: NO_PROFIT")`
3. `test_Withdraw`：利润可由 owner 提取
4. `test_RevertWhen_UnauthorizedCallback`：非 pairA 地址直接调 `uniswapV2Call` → revert

### 第 5 步：新建 `script/flash-swap/DeployFlashSwap.s.sol` — 本地测试网部署脚本

直接继承 `forge-std/Script`（不继承 BaseScript、不使用 saveContract），全新实现：
- 私钥：`vm.envOr("PRIVATE_KEY", uint256(0xac09...))`（anvil 默认账户 #0，可用 .env 覆盖）
- 流程（单脚本完成全部部署 + 演示）：
  1. 部署 TokenA、TokenB
  2. 部署 FactoryA、FactoryB（`new UniswapV2Factory(address(this))`）
  3. `createPair(tokenA, tokenB)` 得 PoolA、PoolB
  4. 直接 transfer + `pair.mint()` 添加错配流动性（1:1 / 1:2）
  5. 部署 FlashSwapArbitrage
  6. 调 `startArbitrage(100e18)` 演示一次套利，console.log 打印利润
  7. console.log 打印全部合约地址

## 涉及文件清单

| 操作 | 文件 |
|---|---|
| 新增子模块 | `lib/v2-core/`（forge install，含 .gitmodules 变更） |
| 修改 | `remappings.txt`（追加 @uniswap/v2-core 映射） |
| 新建 | `src/flash-swap/TokenA.sol`（合约名 TokenA） |
| 新建 | `src/flash-swap/TokenB.sol`（合约名 TokenB） |
| 新建 | `src/flash-swap/FlashSwapArbitrage.sol` |
| 新建 | `test/flash-swap/FlashSwapArbitrage.t.sol` |
| 新建 | `script/flash-swap/DeployFlashSwap.s.sol` |

## 假设与决策

1. **完全新代码**：不引用仓库内任何已有功能代码；TokenA/TokenB 基于 OpenZeppelin ERC20（外部标准库，非仓库已有功能代码）
2. **只用 v2-core**：无需 Router/WETH/periphery；ExampleFlashSwap 仅作官方示例参考
3. **还款币种为 TokenB**：V2 Pair 的 K 值检查允许用任一侧代币偿还闪电贷，"借 TokenA、还 TokenB"合法，与需求提示一致
4. **套利方向固定**：PoolA 价格 1:1、PoolB 中 TokenA 更值钱（1:2）→ 从 PoolA 借 TokenA 去 PoolB 卖出
5. token0/token1 由地址排序决定，合约内部动态判断，不硬编码
6. 部署者 = 流动性提供者 = anvil 默认账户，简化本地演示

## 验证方式

```bash
forge build                                        # 编译通过（含 0.5.16 v2-core）
forge test --match-path "test/flash-swap/*" -vvv   # 全部测试通过

# 本地测试网端到端验证
anvil                                              # 终端 1 启动本地链
forge script script/flash-swap/DeployFlashSwap.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast -vvv  # 部署 + 套利演示，日志显示利润 > 0
```
