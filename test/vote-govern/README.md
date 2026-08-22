# vote-govern —— 基于 Token 投票治理管理 Bank 资金

独立模块，演示"可计票 Token + DAO 治理 + 国库资金管理"完整链路。全部手写实现（与仓库其它模块教学风格一致）。

## 合约

| 合约 | 文件 | 职责 |
| --- | --- | --- |
| `VoteToken` | `src/vote-govern/VoteToken.sol` | 可计票 ERC20（固定供应）：委托 + 历史检查点 + `getPriorVotes`，防闪电贷投票 |
| `Bank` | `src/vote-govern/Bank.sol` | 原生 ETH 资金银行；`withdraw(to, amount)` 仅 admin 可调用 |
| `Governor` | `src/vote-govern/Governor.sol` | Compound-Bravo 风格手写治理；作为 Bank admin，投票驱动提案执行 |

## 治理流程

```
部署 VoteToken → 部署 Governor → 部署 Bank(admin=governor) → 注资 Bank → 持币者 delegate

持币者 propose(targets=[bank], calldatas=[withdraw(recipient, amount)])
        │  (votingDelay 后进入投票期)
        ▼
持币者 castVote(id, support)   // support: 0 反对 / 1 赞成 / 2 弃权
        │  (votingPeriod 结束)
        ▼
通过条件: forVotes > againstVotes 且 for+abstain >= quorum(totalSupply * 4%)
        │
        ▼
execute(id) → governor 以 admin 身份调用 Bank.withdraw(recipient, amount)
            → ETH 从国库直达提案指定收款人
```

计票防闪电贷：`castVote` 读取 `token.getPriorVotes(voter, proposalSnapshot)`，快照块为过去块，转账/借入不会影响历史票数。

## 关键设计

- **VoteToken**：继承 OZ `ERC20`(v5.6.1)，重写 `_update` 钩子在 transfer/mint/burn 时移动投票权；每账户维护 `{fromBlock, votes}` 检查点序列，`getPriorVotes` 二分查找历史值。未显式委托时默认委托给自身（与 COMP/UNI 一致），避免未委托代币无法计入。
- **Bank**：`constructor(address admin)` 直接把 admin 设为 Governor；无内部账本，`withdraw` 仅做余额检查后转账，天然无重入风险。
- **Governor**：不引用 Bank（Bank 只是提案 payload 的 `target`），避免循环依赖。`Proposal` 含 `mapping(voter=>Receipt)`，故 `_proposals` 为 internal，经 `getActions/getReceipt/getProposalTally` 等视图访问。`execute` 采用 CEI：先置 `executed=true` 再对外 call。

## 运行

### 测试

```bash
forge test --match-path test/vote-govern/VoteGovern.t.sol -vvv
```

覆盖 41 项：VoteToken 计票/委托/检查点二分查找边界、Bank 权限与余额校验、Governor 状态机（Pending→Active→Succeeded/Defeated）、quorum 与多数、端到端 `execute→Bank.withdraw` 资金到账、cancel。

### 部署（本地 anvil）

```bash
anvil   # 另开终端
forge script script/vote-govern/DeployVoteGovern.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast -vvv
```

部署三合约 + 注资 10 ETH + 部署者自委托，并打印地址与参数。脚本内不演示完整投票（跨账户签名不便），见脚本注释中的链下组合示例。

### 完整多选民演示（demo.sh）

`test/vote-govern/demo.sh` 用 shell + cast 在真实 anvil 链上编排完整治理流程，
覆盖 forge script 做不到的两件事：多账户各自签名投票、用 `cast rpc anvil_mine` 在
各阶段之间真实推进区块（`vm.roll` 无法随 `--broadcast` 上链）。

```bash
bash test/vote-govern/demo.sh          # 默认端口 8546，可用 PORT=xxx 覆盖
```

流程：部署三合约 + 国库注资 → 分发代币给 alice/bob/carol 并各自委托 →
提案 1（alice 赞成/bob 赞成/carol 弃权，200k ≥ quorum 40k）→ Succeeded →
carol 执行 → alice 到账 1 ETH → 提案 2（仅 carol 10k 赞成，quorum 不足）→
Defeated → execute 正确 revert。链不存在时自动启动临时 anvil 并在退出时回收。
