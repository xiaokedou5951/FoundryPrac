# StakingPool 功能开发计划（ETH 质押挖矿 + Aave V3 借贷利息）

## 概要 (Summary)

在 `src/stake-pool/` 目录下独立开发一套 ETH 质押挖矿系统，不引用本项目其它模块代码。模块包含：

1. **KKToken** — 自包含 ERC20 奖励代币（仅由 StakingPool 铸造）。
2. **StakingPool** — 核心合约：
   - `stake()`：用户质押 ETH → 自动包装为 WETH → 调用 Aave V3 `Pool.supply()` 存入借贷市场赚取利息 → 同时按 "质押数量 × 质押时长" 公平分配 KK 奖励（每区块 10 KK）。
   - `unstake()`：从 Aave 取回本金 → 解包为 ETH → 退还用户，并结算 KK 奖励。
   - `claimReward()`：单独领取已累计的 KK。
   - `ownerClaimInterest()`：owner 提取 Aave 上累积的 aWETH 利息。
3. **测试**：Fork 主网 + 直接使用现成 Aave V3（`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`）与 WETH9（`0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`），无需安装 Aave 库。

## Current State Analysis（当前状态分析）

- `src/stake-pool/` 目录当前为空。
- 项目 Solidity 版本：`^0.8.30`（最新合约如 `FlashLoanArbitrage.sol`、`TokenC.sol`、`TokenBank.sol` 均用此版本）。
- `flash-loan` 模块确立的"独立模块"风格：自包含 ERC20（`TokenC.sol`，不依赖第三方库）、行内最小接口（`IAavePool`、`IERC20Minimal`）、主网地址作为常量、fork 主网测试。本计划沿用该风格，使 `stake-pool` 自成一体。
- `foundry.toml` 已配置 `MAINNET_RPC_URL` 端点与 `optimizer`；`remappings.txt` 中 `@openzeppelin/...` 可用，但本模块**不依赖** OZ 以保持独立。
- `.env` 已含 `MAINNET_RPC_URL`，fork 测试可直接 `vm.createSelectFork(vm.rpcUrl("mainnet"))`。
- 测试约定：`import {Test, console2} from "forge-std/Test.sol"`，断言用 `assertEq/assertGt`，错误用 `vm.expectRevert(bytes("..."))`。
- Owner 利润提取模式（`FlashLoanArbitrage.withdrawProfit()`）已在项目中使用；利息归 owner 与之对齐。

## Proposed Changes（具体改动）

### 文件 1：`src/stake-pool/KKToken.sol`（新建）

**What**：自包含 ERC20 奖励代币，18 位精度，常量 `name="KK Token"`/`symbol="KK"`，`minter` 字段在构造时锁定为部署者（即 StakingPool 合约地址）。

**Why**：奖励代币必须可被 StakingPool 受控铸造；自包含（不引入 OZ）与 `TokenC.sol` 一致，保持模块独立。

**How**：
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract KKToken {
    string public constant name = "KK Token";
    string public constant symbol = "KK";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable minter; // 仅 StakingPool 可铸造

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);

    constructor() { minter = msg.sender; } // 部署者=StakingPool

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "KK: not minter");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external returns (bool) { _transfer(msg.sender, to, value); return true; }
    function approve(address spender, uint256 value) external returns (bool) { allowance[msg.sender][spender] = value; emit Approval(msg.sender, spender, value); return true; }
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "KK: insufficient allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }
    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "KK: insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to]   += value;
        emit Transfer(from, to, value);
    }
}
```

### 文件 2：`src/stake-pool/StakingPool.sol`（新建）

**What**：核心质押合约。构造时内部 `new KKToken()`（于是 KKToken.minter = 本合约地址）。在 `stake()` 内集成 Aave V3 `supply()`。

**Why（满足需求 1/2/3）**：
- 需求 1：KK 每区块产 10 个，按 "数量×时长" 公平分配 → 采用 MasterChef 经典 "累计每份奖励 (accRewardPerShare)" 模型，自然实现按质押数量与质押时长的加权公平分配。
- 需求 2/3：在 `stake()` 内将 ETH 包成 WETH 后调用 Aave `Pool.supply()`，把"在借贷市场做一笔存款"的方法直接集成进质押流程；`unstake()` 调 `Pool.withdraw()` 取回。
- 利息归 owner（已确认）。

**行内最小接口（自包含，不引入第三方库）**：
```solidity
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
}
interface IERC20Min { function balanceOf(address) external view returns (uint256); }
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address onBehalfOf) external returns (uint256);
    function getReserveTokensAddresses(address asset)
        external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
}
```

**状态变量与常量**：
```solidity
address public immutable aavePool;  // Aave V3 Pool 代理
address public immutable weth;     // WETH9
address public immutable aWeth;    // 构造期向 Pool 查询得到
address public immutable owner;     // 部署者，提取利息
address public immutable kkToken;  // 内部部署的 KKToken

uint256 public constant REWARD_PER_BLOCK = 10 * 1e18; // 每区块 10 KK
uint256 public constant ACC_PRECISION = 1e12;

uint256 public lastRewardBlock;     // 上次更新 accRewardPerShare 的区块
uint256 public accRewardPerShare;   // 累计每 1 wei 质押应得的 KK（×1e12）
uint256 public totalStaked;         // 当前供给 Aave 的 ETH 本金合计

struct UserInfo { uint256 amount; uint256 rewardDebt; }
mapping(address => UserInfo) public userInfo;
```

**构造函数**：
```solidity
constructor(address _aavePool, address _weth) {
    aavePool = _aavePool;
    weth = _weth;
    owner = msg.sender;
    kkToken = address(new KKToken()); // minter = 本合约
    lastRewardBlock = block.number;
    (address aToken,,) = IPool(_aavePool).getReserveTokensAddresses(_weth);
    aWeth = aToken;
    require(aWeth != address(0), "StakePool: bad aToken");
}
```

**奖励更新（内部 `_updateReward`）**：MasterChef 标准——若 `totalStaked==0` 仅前移 `lastRewardBlock`；否则 `accRewardPerShare += blocks * REWARD_PER_BLOCK * ACC_PRECISION / totalStaked`。

**结算（内部 `_settlePending`）**：`pending = user.amount * accRewardPerShare / ACC_PRECISION - user.rewardDebt`，若 >0 调 `KKToken.mint(user, pending)`。`rewardDebt` 由调用方在改变 amount 后重置为 `amount * acc / prec`（标准 MasterChef 模式）。

**`stake()` payable**（CEI + Aave 集成）：
```
1. require(msg.value > 0)
2. _updateReward(); 若已有质押则 _settlePending(msg.sender)
3. IWETH(weth).deposit{value: msg.value}()              // ETH -> WETH
4. IWETH(weth).approve(aavePool, msg.value)            // 授权 Aave 划扣
5. IPool(aavePool).supply(weth, msg.value, address(this), 0)  // 存入借贷市场
6. userInfo.amount += msg.value; totalStaked += msg.value
7. userInfo.rewardDebt = userInfo.amount * acc / prec   // 重置基线
8. emit Staked
```

**`unstake(uint256 amount)`**（CEI：先更账，再发 ETH）：
```
1. 校验 0 < amount <= userInfo.amount
2. _updateReward(); _settlePending(msg.sender)
3. IPool(aavePool).withdraw(weth, amount, address(this)) // 取回 WETH 到本合约
4. IWETH(weth).withdraw(amount)                          // WETH -> ETH
5. 更新账目：userInfo.amount -= amount; totalStaked -= amount;
   userInfo.rewardDebt = userInfo.amount * acc / prec     // CEI：在外部 ETH 转账前完成
6. (bool ok,) = msg.sender.call{value: amount}(""); require(ok)  // 最后发 ETH
7. emit Unstaked
```

**`claimReward()`**：`_updateReward(); _settlePending(msg.sender); rewardDebt = amount*acc/prec;`

**`ownerClaimInterest()`**：仅 owner；`interest = aWeth.balanceOf(this) - totalStaked`；若 >0 则 `Pool.withdraw(weth, interest, address(this))` → `WETH.withdraw` → 转 ETH 给 owner。仅取利息，不动各用户本金。

**`pendingReward(user)` view**：按当前 `block.number` 预估（含未结算的 acc 增量）。

**`receive() external payable {}`**：接收 `WETH.withdraw` 解包回来的 ETH。

**事件**：`Staked`、`Unstaked`、`RewardClaimed`、`InterestClaimed`。

**重入**：依赖 CEI（与 `TokenBank.sol` 注释一致的"先减记录再转账"项目约定），`unstake` 中状态在外部 ETH 转账前已更新；不引入 OZ ReentrancyGuard 以保持自包含。

### 文件 3：`test/stake-pool/StakingPool.t.sol`（新建）

**What**：Fork 主网测试，沿用 `FlashLoanArbitrage.t.sol` 的 fork 模式。

**setUp**：
```solidity
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

function setUp() public {
    vm.createSelectFork(vm.rpcUrl("mainnet"));
    pool = new StakingPool(AAVE_POOL, WETH);
    kk = KKToken(pool.kkToken());
    user1 = address(0x1111); user2 = address(0x2222);
    vm.deal(user1, 100 ether); vm.deal(user2, 100 ether);
}
```

**测试用例**：
1. `test_stake_supplies_to_aave` — user1 质押 1 ETH 后：`aWeth.balanceOf(pool) == 1 ether`、`pool.totalStaked() == 1 ether`。（证明需求 3：`supply` 已被集成且成功）
2. `test_reward_single_user` — user1 质押 1 ETH 于区块 N；`vm.roll(N+10)`；断言 `pendingReward(user1) == 100 ether`（10 区块 × 10 KK/区块 全归单人）；`claimReward()` 后 `kk.balanceOf(user1) == 100 ether`。
3. `test_reward_pro_rata` — user1 质押 1 ETH，user2 质押 1 ETH（各占 50%）；`vm.roll` 若干块；两人 pending 各占一半，验证"按数量×时长公平分配"。
4. `test_unstake_returns_eth_and_settles_kk` — 质押 + roll + `unstake` 后用户 ETH 本金返还、KK 已结算、`aWeth` 余额相应下降。
5. `test_owner_claim_interest_access_control` — 非 owner 调 `ownerClaimInterest()` revert（`StakePool: not owner`）。
6. `test_owner_claim_interest_happy_path` — 质押后立即 `ownerClaimInterest()`（无利息时 interest=0，不 revert），验证 owner 路径与 Aave `withdraw` 调用通畅。

注：Aave 真实利息需"时间 + 借贷利用率"才能显著产生，难以在单测中确定性复现；用例 1/6 已充分验证"存款/取款方法被正确集成并执行成功"这一核心交付（需求 3 的本质）。用例 6 的 0 利息分支保证 `ownerClaimInterest` 逻辑无副作用。

## Assumptions & Decisions（假设与决策）

1. **利息归属**：归 Pool owner（已与用户确认）。用户仅获 KK 奖励；Aave 利息由 owner 经 `ownerClaimInterest()` 提取。
2. **奖励模型**：MasterChef "accRewardPerShare" 累计法，等价于按 "质押数量 × 持有时长" 加权分配；每区块固定产 10 KK，无总量上限（题目未给上限）。`block.number` 作为时间轴。
3. **Aave 集成方式**：ETH 先 `WETH.deposit` 包成 WETH，再 `Pool.supply(WETH, amount, address(this), 0)`；不用 WETHGateway（地址不确定），仅依赖已知的 Pool 与 WETH9（与 `flash-loan` 一致）。`aWeth` 地址由构造期 `Pool.getReserveTokensAddresses(WETH)` 动态查询，避免硬编码可能出错的 aToken 地址。
4. **自包含**：KKToken、IWETH、IERC20Min、IPool 均在本模块内定义，不引入 OZ/其它模块，与 `flash-loan` 的"独立模块"风格一致。
5. **重入防护**：采用 CEI（项目 `TokenBank.sol` 既有约定），不引入 ReentrancyGuard 以保持自包含。
6. **Solidity 版本**：`^0.8.30`，对齐项目最新合约。
7. **部署顺序**：StakingPool 构造内 `new KKToken()`，使 KKToken.minter 自动等于 StakingPool 地址，无需额外 setMinter 步骤。
8. **fork 不固定区块号**：与 `flash-loan` 测试一致，避免归档节点限制；aWETH 地址查询在运行时完成，适配任意 fork 区块。

## Verification Steps（验证步骤）

1. `forge build` — 编译通过（`^0.8.30`，无外部库依赖）。
2. `forge test --match-contract StakingPoolTest -vvv` — 全部用例通过：
   - 验证 `supply` 集成（aWETH 余额 == 质押量）。
   - 验证 KK 奖励数值（单人 100 KK、双人各 50%）。
   - 验证 `unstake` 本金返还 + aWETH 下降。
   - 验证 owner 权限与 0 利息 happy path。
3. `forge test -vvv --gas-report` — 查看 stake/unstake gas，确认无异常膨胀。
4. （可选）`forge script script/stake-pool/Deploy.s.sol` — 若需本地部署脚本，按 `script/flash-loan` 模式新增；当前计划不含脚本文件，除非后续追加。

## 非目标（明确不做）

- 不实现利息按比例分给质押者（已确认归 owner）。
- 不引入 OZ / Aave 库依赖。
- 不引用本项目其它模块（flash-loan、TokenBank 等）的代码，仅在风格上保持一致。
- 不做 KK 代币二级市场/兑换，不做治理。
