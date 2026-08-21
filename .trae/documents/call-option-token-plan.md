# 看涨期权 Token（Call Option Token）实现计划

## 概述（Summary）

在 `src/call-option-token/` 下新建一个自包含的 Foundry 模块，实现一个以 ETH 为标的、以 USDT 为计价/行权货币的看涨期权 ERC20 Token，覆盖需求 1–5：创建时设定行权价与行权日 → 项目方按 ETH 1:1 发行期权 → 项目方在 AMM 池中以较低价挂出「期权Token/USDT」交易对供用户买入 → 用户在到期日当天按行权价用 USDT 行权换 ETH 并销毁期权 → 过期后项目方销毁剩余期权并赎回 ETH。

模块构成（3 个合约 + 1 个测试 + 1 个部署脚本）：

| 文件 | 角色 |
|------|------|
| `src/call-option-token/MockUSDT.sol` | 模拟 USDT（6 位精度，开放 mint，仅测试/教学用） |
| `src/call-option-token/OptionToken.sol` | 期权 ERC20 主体：创建参数、发行、行权、过期赎回 |
| `src/call-option-token/OptionSwapPool.sol` | 恒定乘积（x*y=k）AMM 池：期权Token ↔ USDT 交易对 |
| `test/call-option-token/CallOptionToken.t.sol` | 综合测试（部署/发行/AMM/行权/过期赎回/边界） |
| `script/call-option-token/DeployCallOptionToken.s.sol` | 本地 anvil 一键部署 + 演示脚本 |

## 当前状态分析（Current State Analysis）

- `src/call-option-token/` 目录已存在但为空（greenfield）。
- 项目为标准 Foundry 工程（无 `package.json`，依赖以 git submodule 形式放在 `lib/`）：`openzeppelin-contracts`（v5，`Ownable(msg.sender)` 构造）、`forge-std`、`v2-core`、`v2-periphery`、`uniswap-lib`。
- `remappings.txt`：`@openzeppelin/contracts/`、`@uniswap/v2-core/`、`forge-std/`。
- `foundry.toml`：`src=src`、`out=out`、`libs=lib`、optimizer on（runs=200）、含 sepolia/mainnet/local RPC。
- 项目惯例（经阅读 `Vesting.sol`、`StakingPool.sol`、`FlashSwapArbitrage.sol`、`MockUSDC.sol`、`MyERC20.sol`、`TokenVesting.t.sol`、`DeployFlashSwap.s.sol`、`BaseScript.s.sol` 确认）：
  - `pragma solidity ^0.8.30;`、`// SPDX-License-Identifier: MIT`、命名导入 `{X} from "@openzeppelin/..."`。
  - 中文 NatSpec、`@title`/`@dev` 注释 + 流程说明；事件驱动状态变更。
  - `Ownable` 表「项目方」角色，`onlyOwner` 守卫；错误信息带模块前缀 `require(..., "COT: REASON")`。
  - 自包含模块：mock 代币 + 主合约（参考 `simple-leverage-dex/MockUSDC.sol + SimpleLeverageDEX.sol`、`stake-pool/KKToken.sol + StakingPool.sol`）。
  - 测试：`test/<feature>/<Name>.t.sol`，`makeAddr` + `vm.warp` + `vm.prank` + `vm.expectRevert`，`// ===== Section =====` 分组，`test_X_YY_Reverts` 命名。
  - 脚本：`script/<feature>/Deploy*.s.sol`，`vm.startBroadcast(pk)`/`stopBroadcast()`，`console.log` 地址，anvil 默认私钥经 `vm.envOr("PRIVATE_KEY", ...)` 覆盖。

## 关键设计决策（Assumptions & Decisions）

> 已与用户确认的两点：
> 1. **需求 3 交易对**：采用 **AMM 恒定乘积池**（`OptionSwapPool`，x\*y=k），项目方注入期权Token+USDT 初始流动性且定价较低，用户用 USDT 兑换期权Token。
> 2. **需求 4 行权时间窗**：**仅到期日当天** —— 行权窗口为 `[expiryDate, expiryDate + 1 days)`，窗口结束后才允许项目方过期赎回。

其余默认决策（基于需求语义与项目惯例）：

- **标的 = ETH**：直接用 `msg.value` 收付原生 ETH，不引入 WETH（与需求「标的（ETH）」一致，保持简单）。
- **1:1 发行**：1 ETH（1e18 wei）铸造 1 期权 Token（18 位精度，沿用 ERC20 默认 decimals=18）。
- **「标的的价格」= 行权价 `strikePrice`**（需求 1），单位为 **USDT per 1 ETH**，存储按 USDT 6 位精度，例如 `3000 * 1e6` 表示 3000 USDT/ETH。
- **行权计价货币 = USDT**：行权时用户支付 USDT（行权价）给项目方，合约释放 ETH 给用户。用 ETH 计价行权会出现「付 ETH 换 ETH」的循环，故排除。
- **行权 USDT 归项目方**：合约仅持有 ETH 抵押物；行权时 `usdt.transferFrom(用户, owner, usdtCost)`，ETH 从合约转给用户。
- **过期销毁「所有」期权**：标准 ERC20 无法由一方销毁他人代币，故提供 owner-only 的 `burnFrom(account, amount)`（仅 `expired==true` 后可用）作为「销毁所有期权Token」的工具，配合 `expireAndReclaim()` 一次性赎回剩余 ETH。

## 提议变更（Proposed Changes）

### 1) `src/call-option-token/MockUSDT.sol`（新建）

仿 `src/simple-leverage-dex/MockUSDC.sol`：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDT
/// @dev call-option-token 模块自包含的模拟 USDT（6 位精度，与真实 USDT 一致）。
///      开放 mint 供测试/本地环境发放，生产环境不应使用。
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

### 2) `src/call-option-token/OptionToken.sol`（新建，核心合约）

`is ERC20, Ownable`，OZ v5 `Ownable(msg.sender)`。owner = 项目方（部署者）。

**状态变量**

```solidity
IERC20 public immutable usdt;          // 计价/行权货币（USDT）
uint256 public immutable strikePrice;  // 行权价（USDT 6 位精度 / 1 ETH），如 3000e6
uint256 public immutable expiryDate;   // 到期日（unix 秒）
bool public expired;                   // 是否已执行过期赎回
```

ETH 抵押物即 `address(this).balance`，期权总供应 = 已发行 ETH 总量（1:1）。

**构造函数（需求 1：创建时确认价格与行权日期）**

```solidity
constructor(address _usdt, uint256 _strikePrice, uint256 _expiryDate)
    ERC20("Call Option Token", "COT")
    Ownable(msg.sender)
{
    require(_usdt != address(0), "COT: zero usdt");
    require(_strikePrice > 0, "COT: zero strike");
    require(_expiryDate > block.timestamp, "COT: past expiry");
    usdt = IERC20(_usdt);
    strikePrice = _strikePrice;
    expiryDate = _expiryDate;
}
```

**`issue()`（需求 2：项目方发行，onlyOwner，payable）**

转入 ETH → 1:1 铸造期权 Token 给 owner。

```solidity
function issue() external payable onlyOwner {
    require(msg.value > 0, "COT: zero eth");
    require(!expired, "COT: expired");
    _mint(msg.sender, msg.value);          // 1 wei ETH : 1 unit 期权（均 18 位）
    emit Issued(msg.sender, msg.value);
}
```

**`exercise(uint256 optionAmount)`（需求 4：用户行权，仅到期日当天）**

CEI 顺序：先 `_burn` → 再收 USDT（`transferFrom` 用户→owner）→ 再转 ETH 给用户。

```solidity
function exercise(uint256 optionAmount) external {
    require(block.timestamp >= expiryDate, "COT: not yet expiry");
    require(block.timestamp < expiryDate + 1 days, "COT: exercise window closed");
    require(optionAmount > 0, "COT: zero amount");
    require(!expired, "COT: expired");

    uint256 ethAmount = optionAmount;                              // 1:1
    uint256 usdtCost = (ethAmount * strikePrice) / 1e18;           // USDT(6) per ETH(18)
    // 例：optionAmount=1e18, strikePrice=3000e6 -> usdtCost=3000e6

    _burn(msg.sender, optionAmount);                               // 销毁期权
    require(usdt.transferFrom(msg.sender, owner, usdtCost), "COT: usdt pay failed");
    (bool ok, ) = msg.sender.call{value: ethAmount}("");           // 释放 ETH
    require(ok, "COT: eth transfer failed");

    emit Exercised(msg.sender, optionAmount, usdtCost, ethAmount);
}
```

> 注：行权前用户须先 `usdt.approve(optionToken, ...)` 授权。

**`expireAndReclaim()`（需求 5：过期赎回，onlyOwner，窗口结束后）**

```solidity
function expireAndReclaim() external onlyOwner {
    require(block.timestamp >= expiryDate + 1 days, "COT: window still open");
    require(!expired, "COT: already expired");
    expired = true;
    uint256 ethBal = address(this).balance;
    // 先销毁合约自持的期权（若有回流）
    uint256 selfBal = balanceOf(address(this));
    if (selfBal > 0) _burn(address(this), selfBal);
    (bool ok, ) = owner.call{value: ethBal}("");
    require(ok, "COT: reclaim failed");
    emit ExpiredAndReclaimed(owner, ethBal);
}
```

**`burnFrom(address account, uint256 amount)`（需求 5 配套：销毁任意处剩余期权，onlyOwner，仅过期后）**

实现「销毁所有期权Token」—— 用于清空 AMM 池/未行权用户手中的剩余期权。

```solidity
function burnFrom(address account, uint256 amount) external onlyOwner {
    require(expired, "COT: not expired yet");
    require(amount > 0, "COT: zero amount");
    _burn(account, amount);
    emit ForceBurned(account, amount);
}
```

**视图函数**

- `getExerciseCost(uint256 optionAmount) external view returns (uint256)` → `(optionAmount * strikePrice) / 1e18`
- `isExerciseWindow() external view returns (bool)` → `block.timestamp >= expiryDate && block.timestamp < expiryDate + 1 days`
- `isPastWindow() external view returns (bool)` → `block.timestamp >= expiryDate + 1 days`
- `collateral() external view returns (uint256)` → `address(this).balance`

**事件**

```solidity
event Issued(address indexed issuer, uint256 ethAmount);
event Exercised(address indexed user, uint256 optionAmount, uint256 usdtPaid, uint256 ethReceived);
event ExpiredAndReclaimed(address indexed issuer, uint256 ethReclaimed);
event ForceBurned(address indexed from, uint256 amount);
```

### 3) `src/call-option-token/OptionSwapPool.sol`（新建，AMM 交易对 / 需求 3）

手写恒定乘积池（x\*y=k，含 0.3% 手续费），风格对齐 `src/uniswap-demo/MiniSwapPool.sol`。无 LP 代币：owner 注入/抽离流动性，任意人可 swap。owner = 项目方。

**状态变量**

```solidity
IERC20 public immutable optionToken;
IERC20 public immutable usdt;
uint256 public reserveOption;
uint256 public reserveUsdt;
address public immutable owner;
```

**核心函数**

```solidity
constructor(address _optionToken, address _usdt);   // owner = msg.sender

// 项目方注入流动性（定价较低的 USDT/期权 比例 = “较低的价格”）
function addLiquidity(uint256 optionAmount, uint256 usdtAmount) external onlyOwner;

// 用户买入期权：USDT -> OptionToken
function swapUSDTForOption(uint256 usdtIn, uint256 minOptionOut) external;

// 用户卖出期权：OptionToken -> USDT
function swapOptionForUSDT(uint256 optionIn, uint256 minUsdtOut) external;

// 项目方抽离全部流动性（过期清理 / 赎回前用）
function removeLiquidity() external onlyOwner;

// 恒定乘积输出（0.3% 手续费），与 MiniSwapPool 一致
function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    public pure returns (uint256);
```

`getAmountOut`：`(amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)`

swap 内部顺序（CEI + 防重入）：计算输出 → `require` 滑点 → `transferFrom` 输入币 → 更新储备 → `transfer` 输出币。

**事件**：`LiquidityAdded(optionAmount, usdtAmount)`、`LiquidityRemoved(optionAmount, usdtAmount)`、`Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut)`。

### 4) `test/call-option-token/CallOptionToken.t.sol`（新建）

`is Test`，setUp：部署 MockUSDT、OptionToken（`strikePrice=3000e6`、`expiryDate=block.timestamp+30 days`）、OptionSwapPool；给用户 `makeAddr` 并 mint USDT。沿用 `TokenVesting.t.sol` 分组风格与命令注释 `forge test --match-path test/call-option-token/CallOptionToken.t.sol -vvv`。

测试分组：

- **部署**：状态初始化正确；`zero usdt`/`zero strike`/`past expiry` 构造 revert。
- **发行（issue）**：付 ETH → owner 1:1 收到期权；非 owner revert；`msg.value==0` revert；`expired` 后 revert。
- **AMM 池**：`addLiquidity` 储备更新 + 事件；`getAmountOut` 数值正确；`swapUSDTForOption` 用户获期权、储备变动、滑点 revert；`swapOptionForUSDT` 反向；`removeLiquidity` owner 取回（非 owner revert）。
- **行权（exercise）**：到期前 revert；`vm.warp(expiryDate)` 当天行权成功（付 USDT strike、收 ETH、期权销毁、供应量下降）；`expiryDate + 1 days - 1` 仍可行权；`expiryDate + 1 days` 窗口关闭 revert；非持仓者/授权不足 revert；部分行权 + 多用户场景。
- **过期赎回**：窗口未结束调用 `expireAndReclaim` revert；`vm.warp(expiryDate+1 days)` 后 owner 赎回全部剩余 ETH、`expired=true`、事件；重复调用 revert；`burnFrom` 在 `expired` 前 revert、`expired` 后可清空池/用户剩余期权；过期后 `exercise`/`issue` 均 revert。
- **边界**：行权全部 ETH 后合约余额归零；`getExerciseCost`/`isExerciseWindow`/`isPastWindow` 视图正确。

### 5) `script/call-option-token/DeployCallOptionToken.s.sol`（新建）

`is Script`，`run()`：`vm.envOr("PRIVATE_KEY", ANVIL_DEFAULT_PK)` → `startBroadcast` → 部署 MockUSDT、OptionToken（`strikePrice=3000e6`、`expiryDate=block.timestamp+7 days`）、OptionSwapPool → 项目方 `issue(10 ether)` 铸期权 → `approve` 后 `addLiquidity(期权数量, 较低 USDT 数量)` 创建交易对 → `stopBroadcast` → `console.log` 所有地址。运行说明注释对齐 `DeployFlashSwap.s.sol`（anvil + `forge script ... --rpc-url http://127.0.0.1:8545 --broadcast -vvv`）。

## 端到端数据流

1. 部署：MockUSDT → OptionToken(usdt, 3000e6, now+30d) → OptionSwapPool(optionToken, usdt)。
2. 项目方 `issue{value: 10 ether}()` → owner 得 10e18 期权，合约持 10 ETH 抵押。
3. 项目方 `optionToken.approve(pool, X)` + `usdt.mint/approve` → `pool.addLiquidity(X 期权, Y USDT)`（Y/X 较低，如 50 USDT/期权）= **创建交易对**。
4. 用户 `usdt.approve(pool, ...)` → `pool.swapUSDTForOption(usdtIn, minOut)` → **买入期权**。
5. `vm.warp(expiryDate)`：用户 `usdt.approve(optionToken, strikeCost)` → `optionToken.exercise(amt)` → 付 USDT strike 给 owner、收 ETH、期权销毁。
6. `vm.warp(expiryDate+1 days)`：项目方 `pool.removeLiquidity()` 取回池内剩余 → `optionToken.expireAndReclaim()` 赎回剩余 ETH → `burnFrom(...)` 销毁残余期权。

## 验证步骤（Verification）

1. 编译：`forge build`（应无报错；solc ^0.8.30，OZ v5 `Ownable(msg.sender)` 与 remappings 已就绪）。
2. 测试：`forge test --match-path test/call-option-token/CallOptionToken.t.sol -vvv` 全绿。
3. 覆盖率自检：行权窗口边界（`expiryDate-1` / `expiryDate` / `expiryDate+1 days-1` / `expiryDate+1 days`）、AMM 滑点、过期赎回与 `burnFrom` 权限均已覆盖。
4. 本地部署演示：`anvil` 后执行 `forge script script/call-option-token/DeployCallOptionToken.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv`，确认日志中三个合约地址与流动性注入成功。
5. 行权价换算抽检：`exercise(1e18)` 在 `strikePrice=3000e6` 下恰好扣 3000e6 USDT、释放 1e18 ETH。

## 不在本次范围

- 不接入真实 Uniswap V2 / Chainlink 喂价（教学自包含模块）。
- 不做可升级代理（沿用模块惯例使用普通合约）。
- 不实现 LP 代币 / 手续费分成（池由 owner 独占，简化模型）。
