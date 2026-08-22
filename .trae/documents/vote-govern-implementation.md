# vote-govern 模块实现计划：基于 Token 投票治理管理 Bank 资金

## 概述 (Summary)

在 `src/vote-govern/`（当前为空目录）下开发一个独立、自包含的治理模块，实现"基于 Token 投票治理管理 Bank 资金"的完整链路：

1. **VoteToken** —— 可计票的 ERC20：实现委托 (delegation) + 历史检查点 (checkpoint) + `getPriorVotes(account, blockNumber)`，防止闪电贷投票。
2. **Bank** —— 原生 ETH 资金银行：`withdraw(address to, uint256 amount)` 仅 admin（即 Governor）可调用。
3. **Governor** —— 治理合约（手写 Compound-Bravo 风格）：通过发起提案 → Token 投票 → 法定人数与多数表决 → 执行，调用 `Bank.withdraw` 把资金打给提案指定的收款人。

配套：完整测试 `test/vote-govern/VoteGovern.t.sol`、部署脚本 `script/vote-govern/DeployVoteGovern.s.sol`、`test/vote-govern/README.md`。

## 当前状态分析 (Current State Analysis)

- `src/vote-govern/` 目录存在但为空，纯新模块。
- 项目约定（来自 Phase 1 探索，真实文件依据）：
  - `pragma solidity ^0.8.30`；`// SPDX-License-Identifier: MIT`。
  - OpenZeppelin 导入路径：`@openzeppelin/contracts/...`，版本 **v5.6.1**（`lib/openzeppelin-contracts/package.json` 确认）。
  - ERC20 基类 `lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol` 提供 **virtual `_update(address from, address to, uint256 value)`** 钩子，所有 mint/burn/transfer 均经此（L176-204），是移动投票权检查点的理想切入点。
  - 中文注释：合约级 `/** ... */`、函数级 `/// @dev`；错误串带模块前缀（如 `OptionToken.sol` 用 `"COT: zero usdt"`）。
  - 模块自包含 Mock token（参考 `src/call-option-token/MockUSDT.sol`）。
  - 测试约定：`test/<module>/Xxx.t.sol`，`import {Test, console} from "forge-std/Test.sol"`，`setUp()`，命名 `test_Xxx_Yyy_Reverts`，中文注释（参考 `test/call-option-token/CallOptionToken.t.sol`）。
  - 部署脚本约定：`script/<module>/Deploy*.s.sol`，`forge-std/Script.sol`，anvil 默认 PK，`vm.startBroadcast(pk)` + `console.log` 地址（参考 `script/call-option-token/DeployCallOptionToken.s.sol`）。
  - 每个 `test/<module>/` 目录有 `README.md`。
- 参考但不复用：`src/Bank_Contract.sol`（同款 ETH Bank + admin withdraw 的练习合约，风格参考，本模块需独立 Bank）、`src/TokenBank.sol`（ERC20 银行，非本需求）。
- 既有依赖：`lib/forge-std`、`lib/openzeppelin-contracts`。

## 决策与假设 (Assumptions & Decisions)

- **实现路线**：全部手写（VoteToken 的检查点/委托 + Governor 的 propose/vote/execute），与仓库手写教学风格一致（已与用户确认）。
- **VoteToken 资产模型**：继承 OZ `ERC20`（保证标准 ERC20 行为，与 `OptionToken.sol` 一致），在 `_update` 钩子上手写投票权移动。**固定供应**：构造时一次性 mint 给部署者，不再开放 mint/burn（治理代币最真实、最简单；且使 quorum 可用"当前 totalSupply"计算，无需历史供应快照）。
- **自动委托自身**：账户未显式委托时，默认把投票权记给自己（`_delegateeOf(a) = delegates[a]==0 ? a : delegates[a]`），与 COMP/UNI 一致，避免"未委托代币无法计入/锁死"。
- **Bank**：原生 ETH，`constructor(address _admin)` 直接把 admin 设为 Governor；`withdraw(address to, uint256 amount)` 仅 admin（已与用户确认）。
- **Governor 不在构造期引用 Bank**：Bank 只是提案 payload 里的 `target` 之一，避免循环依赖。部署顺序：VoteToken → Governor → Bank(governor) → 注资 → 分发代币。
- **投票计量**：snapshot = 提案所在区块 `block.number`；`votingDelay` 后开投票，`votingPeriod` 后结束；计票用 `token.getPriorVotes(voter, snapshotBlock)`，要求 `snapshotBlock < block.number`（投票时必满足）。
- **Quorum**：`quorumVotes = token.totalSupply() * quorumNumerator / 100`（quorumNumerator 为百分比，构造参数，默认 4 即 4%）。固定供应下"当前 totalSupply == snapshot 时 totalSupply"，正确。
- **通过条件**：`forVotes > againstVotes` **且** `(forVotes + abstainVotes) >= quorumVotes`（弃权计入法定人数、不计入多数）。
- **无 Timelock / 无 EIP712 签名投票 / 无委托代理**：本练习范围不含，列为未来扩展。
- **取消提案**：保留一个最小 `cancel`（仅 proposer、未执行时），降低范围复杂度但补全语义。

## 提议变更 (Proposed Changes)

### 文件 1：`src/vote-govern/VoteToken.sol`

**职责**：可计票 ERC20（检查点 + 委托）。继承 OZ `ERC20`。

**关键状态**
```solidity
struct Checkpoint { uint32 fromBlock; uint224 votes; }   // 单 storage slot
mapping(address => address) public delegates;          // 账户 => 委托对象
mapping(address => Checkpoint[]) public checkpoints;    // 每账户投票权历史
uint256 public immutable INITIAL_SUPPLY;               // 固定供应记录（视图用）
```

**函数**
- `constructor(uint256 initialSupply) ERC20("Vote Governance Token","VGT")`：`require(initialSupply>0)`；`_mint(msg.sender, initialSupply)`（经 `_update` 自动建检查点）。
- `delegate(address delegatee) external`：`require(delegatee != address(0))`；取 `old = _delegateeOf(msg.sender)`；写 `delegates[msg.sender]=delegatee`；`_moveVotingPower(old, delegatee, balanceOf(msg.sender))`；emit `DelegateChanged`、`DelegateVotesChanged`。
- `getCurrentVotes(address account) external view returns (uint256)`：返回该账户最新检查点 votes（无则 0）—— 仅展示用，不计票。
- `getPriorVotes(address account, uint256 blockNumber) external view returns (uint256)`：`require(blockNumber < block.number, "VGT: future block")`；二分查找 `checkpoints[account]` 中 `fromBlock <= blockNumber` 的最新条目，返回其 votes（早于首条返回 0）。
- internal `_delegateeOf(address a) returns address`：`d=delegates[a]; return d==address(0)? a : d;`
- internal `_writeCheckpoint(address delegatee, uint256 newVotes)`：若最新条目 `fromBlock == block.number` 则原地改 votes；否则 push `{uint32(block.number), uint224(newVotes)}`。
- internal `_moveVotingPower(address from, address to, uint256 amount)`：`from==to||amount==0` 直接返回；若 `from!=0`：`_writeCheckpoint(from, getCurrentVotes(from)-amount)`；若 `to!=0`：`_writeCheckpoint(to, getCurrentVotes(to)+amount)`。
- override `_update(address from, address to, uint256 value) internal virtual`：`super._update(from,to,value)`；再计算 `fromD=(from==address(0)?address(0):_delegateeOf(from))`、`toD=(to==address(0)?address(0):_delegateeOf(to))`，`_moveVotingPower(fromD, toD, value)`。注意 mint（from=0）只增 toD，burn（to=0）只减 fromD。

**事件**：`DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate)`、`DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes)`。

**错误前缀**：`"VGT: ..."`。

### 文件 2：`src/vote-govern/Bank.sol`

**职责**：原生 ETH 资金银行；admin=Governor。

**状态**
```solidity
address public admin;
event Withdraw(address indexed to, uint256 amount);
event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
```

**函数**
- `constructor(address _admin) payable`：`require(_admin != address(0), "Bank: zero admin")`；`admin=_admin`。
- `receive() external payable {}`：接受任意注资（ETH）。
- `withdraw(address to, uint256 amount) external`：`require(msg.sender==admin, "Bank: not admin")`；`require(to!=address(0), "Bank: zero to")`；`require(amount>0 && address(this).balance>=amount, "Bank: insufficient")`；`(bool ok,)=to.call{value:amount}("")`；`require(ok,"Bank: transfer failed")`；emit `Withdraw(to, amount)`。（无内部账本，天然无重入风险。）
- `setAdmin(address newAdmin) external`：`require(msg.sender==admin,"Bank: not admin")`；`require(newAdmin!=address(0))`；emit `AdminChanged`；`admin=newAdmin`。（便利测试/迁移。）
- `balance() external view returns (uint256)`：`address(this).balance`。

### 文件 3：`src/vote-govern/Governor.sol`

**职责**：手写 Compound-Bravo 风格治理；作为 Bank admin。

**状态**
```solidity
enum ProposalState { Pending, Active, Canceled, Defeated, Succeeded, Executed }
struct Receipt { bool hasVoted; uint8 support; uint256 votes; }
struct Proposal {
  address proposer; address[] targets; uint256[] values; bytes[] calldatas; string description;
  uint256 snapshotBlock; uint256 startBlock; uint256 endBlock;
  uint256 forVotes; uint256 againstVotes; uint256 abstainVotes;
  bool canceled; bool executed;
  mapping(address => Receipt) receipts;
}
IVoteToken public immutable token;
uint256 public immutable votingDelay;   // 提案后多少区块开始投票（构造参数，测试用 1）
uint256 public immutable votingPeriod;  // 投票持续区块数（构造参数，测试用 10）
uint256 public immutable quorumNumerator; // 百分比，默认 4 => 4%
uint256 public proposalCount;
mapping(uint256 => Proposal) public proposals;
```
> 注：`IVoteToken` 为本模块内对 VoteToken 的接口抽象（`getPriorVotes`、`totalSupply`），Governor 仅依赖该接口，便于测试 mock；接口定义置于本文件顶部或 VoteToken.sol 内（推荐放 Governor.sol 顶部，避免循环）。

**函数**
- `constructor(address token_, uint256 votingDelay_, uint256 votingPeriod_, uint256 quorumNumerator_)`：校验非 0/非 0/`quorumNumerator_<=100`；设 immutable。
- `name() external pure returns (string memory)`：`"VoteGovernor"`。
- `propose(address[] targets, uint256[] values, bytes[] calldatas, string description) external returns (uint256)`：长度一致且 >0；`require(token.getPriorVotes(msg.sender, block.number-1) > 0, "Gov: proposer no votes")`；`id=++proposalCount`；填字段：`snapshotBlock=block.number`、`startBlock=block.number+votingDelay`、`endBlock=startBlock+votingPeriod`；emit `ProposalCreated`；return id。
- `castVote(uint256 proposalId, uint8 support) external returns (uint256)`：`require(state(id)==ProposalState.Active,"Gov: not active")`；`require(support<=2,"Gov: bad support")`；`Proposal storage p=proposals[id]`；`require(!p.receipts[msg.sender].hasVoted,"Gov: voted")`；`votes=token.getPriorVotes(msg.sender, p.snapshotBlock)`；按 support 累加 `forVotes/againstVotes/abstainVotes`；写 receipt；emit `VoteCast`；return votes。
- `execute(uint256 proposalId) external payable`：`require(state(id)==Succeeded,"Gov: not succeeded")`；`Proposal storage p`；`require(!p.executed && !p.canceled)`；**CEI：先置 `p.executed=true`**；遍历 `i`：`(bool ok,)=p.targets[i].call{value:p.values[i]}(p.calldatas[i]); require(ok,"Gov: call failed")`；emit `ProposalExecuted`。
- `cancel(uint256 proposalId) external`：`require(proposals[id].proposer==msg.sender,"Gov: not proposer")`；`require(!proposals[id].executed && !proposals[id].canceled)`；置 `canceled=true`；emit `ProposalCanceled`。
- `state(uint256 proposalId) public view returns (ProposalState)`：canceled→Canceled；executed→Executed；`block.number<startBlock`→Pending；`block.number<=endBlock`→Active；否则 `_voteSucceeded && _quorumReached`→Succeeded 否则 Defeated。
- internal `_voteSucceeded(uint256 id) returns bool`：`proposals[id].forVotes > proposals[id].againstVotes`。
- internal `_quorumReached(uint256 id) returns bool`：`proposals[id].forVotes + proposals[id].abstainVotes >= quorumVotes(id)`。
- views：`quorumVotes(uint256 id) public view returns (uint256)`=`token.totalSupply()*quorumNumerator/100`；`proposalSnapshot(id)`、`proposalDeadline(id)`、`getActions(id)`（targets/values/calldatas）、`getReceipt(id,voter)`、`getProposalTally(id)`（for/against/abstain）。
- `receive() external payable {}`：接受执行回流的 ETH。

**事件**：`ProposalCreated(uint256 indexed id, address proposer, address[] targets, uint256[] values, string description, uint256 startBlock, uint256 endBlock)`、`VoteCast(uint256 indexed id, address indexed voter, uint8 support, uint256 votes)`、`ProposalExecuted(uint256 indexed id)`、`ProposalCanceled(uint256 indexed id)`。

**错误前缀**：`"Gov: ..."`。

### 文件 4：`test/vote-govern/VoteGovern.t.sol`

**约定**：与 `CallOptionToken.t.sol` 一致；中文注释；`setUp()` 部署三合约并准备代币/ETH；用 `vm.roll` 推进区块（注意：投票计量依赖区块号，setUp 中先完成"部署者委托自身 + 向 voters 转账 + voters 委托自身"，再 `vm.roll(block.number+1)`，确保后续 propose 时 `getPriorVotes(block.number-1)` 能命中检查点）。

**测试参数**：`votingDelay=1`、`votingPeriod=10`、`quorumNumerator=4`、初始供应 `1_000_000e18`（部署者全持，向 alice/bob 各转 100_000e18，各自 `delegate(self)`）；Bank 注资 10 ETH。

**VoteToken 用例**：部署/构造校验；`delegate` 后 `getCurrentVotes` 正确；转账触发投票权移动（fromD→toD）；多次委托切换；`getPriorVotes` 历史快照正确（含二分边界、早于首条返回 0）；`getPriorVotes` 当前/future 区块 revert；自动委托自身（未显式委托也计票）。

**Bank 用例**：`receive` 注资；admin（governor）`withdraw` 成功且到账；非 admin revert；`to=0` revert；余额不足 revert。

**Governor 用例（端到端为主）**：
- `propose`：无投票权者 revert；正常返回 id 与 `ProposalCreated`；状态 Pending。
- 状态机：propose( Pending ) → `vm.roll(startBlock)` Active → `vm.roll(endBlock+1)` Succeeded/Defeated。
- `castVote`：未到 startBlock revert；结束 revert；重复投票 revert；support 非法 revert；用 `getPriorVotes(snapshot)` 计票正确。
- Quorum：for+abstain 达标 vs 不达标；for>against vs for<against。
- `execute`：未结束 revert；Defeated revert；已执行 revert；成功执行后调用 `Bank.withdraw(recipient, amount)`，收款人到账 ETH；governor 作为 bank.admin 通过。
- `cancel`：proposer 可取消，取消后 execute revert；非 proposer revert。
- **端到端**：propose(withdraw alice 1 ETH) → alice+bob 投 for → roll 过 endBlock → execute → assert alice 收到 1 ETH、Bank 余额减 1 ETH、`executed=true`。

### 文件 5：`script/vote-govern/DeployVoteGovern.s.sol`

**约定**：与 `DeployCallOptionToken.s.sol` 一致；anvil 默认 PK，`vm.envOr("PRIVATE_KEY", ...)`，`vm.startBroadcast(pk)`。

**流程**：部署 VoteToken(`1_000_000e18`) → Governor(token, votingDelay=1, votingPeriod=1000, quorumNumerator=4) → Bank(governor) → `bank.transfer(10 ether)`（注资）→ 部署者 `token.delegate(address(this))` 自委托（演示）→ `console.log` 三个地址 + 参数 + Bank 余额。仅部署与注资，不在脚本里跑完整投票（跨账户签名不便）。

### 文件 6：`test/vote-govern/README.md`

简述模块三合约职责、部署/测试命令（`forge test --match-path test/vote-govern/VoteGovern.t.sol -vvv`、`forge script script/vote-govern/DeployVoteGovern.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv`）、治理流程图（propose→vote→execute→Bank.withdraw）。

## 验证步骤 (Verification)

1. **编译**：`forge build` 全量通过（含新模块，无 pragma/导入冲突）。
2. **测试**：`forge test --match-path test/vote-govern/VoteGovern.t.sol -vvv` 全部通过；覆盖率含状态机各分支、权限 revert、端到端资金到账。
3. **gas/格式**：`forge fmt` 通过（风格与仓库一致）。
4. **部署脚本**：本地 `anvil` 启动后 `forge script script/vote-govern/DeployVoteGovern.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvv` 成功部署三合约并注资，地址打印正确。
5. **回归**：`forge build`/`forge test` 全量不破坏既有模块。

## 实施顺序 (Execution Order)

1. 写 `src/vote-govern/VoteToken.sol`。
2. 写 `src/vote-govern/Bank.sol`。
3. 写 `src/vote-govern/Governor.sol`（含 `IVoteToken` 接口）。
4. `forge build` 预编译排查。
5. 写 `test/vote-govern/VoteGovern.t.sol` → `forge test --match-path ... -vvv` 调通。
6. 写 `script/vote-govern/DeployVoteGovern.s.sol`。
7. 写 `test/vote-govern/README.md`。
8. `forge fmt` + 全量 `forge build`/`forge test` 收尾。
