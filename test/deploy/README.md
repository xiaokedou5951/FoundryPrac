# Foundry 一键部署 + 验证（通用指南）

使用 Foundry 单条命令完成任意合约在任意 EVM 链上的部署与 Etherscan 兼容浏览器（Etherscan / Polygonscan / BscScan 等）的源码验证。本文档以 Sepolia + MyToken 为示例，但流程对所有链与合约通用。

## 通用流程概览

```
.env 环境变量  ──►  foundry.toml 别名映射  ──►  forge script 一条命令  ──►  部署 + 验证完成
```

把下方所有 `<占位符>` 替换为你实际的链与合约信息即可套用。

## 前置条件

### 1. 环境变量

在项目根目录的 `.env` 中配置（注意加入 `.gitignore` 避免泄露私钥）：

```bash
# 以 Sepolia 为例；其他链把 RPC_URL 换成对应链的 endpoint 即可
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/你的KEY
PRIVATE_KEY=0x你的私钥
ETHERSCAN_API_KEY=你的EtherscanKey
```

不同链的 API key 变量名建议按链命名（如 `POLYGONSCAN_API_KEY`、`BSCSCAN_API_KEY`），避免混用。同一 Etherscan 家族账号下多链 key 通常通用，但部分链（如 Arbitrum）需单独申请。

### 2. foundry.toml 已配置别名

[foundry.toml](../../foundry.toml) 中需包含 `[rpc_endpoints]` 与 `[etherscan]` 两段，**key 必须一致**（都用同一个 `<CHAIN_ALIAS>`）：

```toml
[rpc_endpoints]
sepolia = "${SEPOLIA_RPC_URL}"
mainnet = "${MAINNET_RPC_URL}"
polygon = "${POLYGON_RPC_URL}"
# ... 任意添加其他链

[etherscan]
sepolia = { key = "${ETHERSCAN_API_KEY}" }
mainnet = { key = "${ETHERSCAN_API_KEY}" }
polygon = { key = "${POLYGONSCAN_API_KEY}" }
# ... 任意添加其他链
```

> 别名是任意字符串，可自定义（如 `sepolia`、`matic`、`bsc`），只要 `[rpc_endpoints]` 与 `[etherscan]` 中使用相同字符串即可。

### 3. 钱包有目标链的原生代币

- Sepolia ETH：https://sepoliafaucet.com/
- Polygon Mumbai/Amoy MATIC：https://faucet.polygon.technology/
- BSC Testnet BNB：https://testnet.bnbchain.org/faucet-smart

### 4. 部署脚本已编写

参考 [script/MyToken.s.sol](../../script/MyToken.s.sol) 模板：

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {YourContract} from "../src/YourContract.sol";

contract YourScript is Script {
    function run() public {
        vm.startBroadcast();
        // 在此处 new 你的合约，传入构造函数参数（若有）
        new YourContract(/* ctor args */);
        vm.stopBroadcast();
    }
}
```

## 一条命令完成部署 + 验证

```bash
source .env

forge script script/<SCRIPT>.s.sol:<ScriptName> \
  --rpc-url <CHAIN_ALIAS> \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### 参数说明（通用）

| 参数 | 作用 |
|------|------|
| `script/<SCRIPT>.s.sol:<ScriptName>` | 部署脚本路径与脚本合约名（用 `:` 分隔） |
| `--rpc-url <CHAIN_ALIAS>` | `foundry.toml` 中 `[rpc_endpoints]` 配置的链别名（不是 URL 本身） |
| `--private-key $PRIVATE_KEY` | 部署账户私钥（也可改用 `--ledger`、`--keystore`、`--interactive`） |
| `--broadcast` | 将交易实际发送到链上 |
| `--verify` | 部署完成后自动调用浏览器 API 验证源码 |

构造函数参数由 Foundry 从 broadcast artifact 中自动提取编码，**无需** 手动传 `--constructor-args`（除非自动验证失败，见下文）。

### 何时需要加 `--slow`

`--slow` 控制的是**多笔交易的提交策略**，与出块速度无关：

- 默认（不加）：Foundry 把脚本中所有交易**并发批量提交**，不等前一笔回执就发下一笔
- 加 `--slow`：**串行提交**，每笔交易等到回执确认后才发下一笔

只在**脚本里有 ≥2 笔交易、且后续交易依赖前一笔结果**时才需要加。例如：

```solidity
vm.startBroadcast();
Counter c = new Counter();   // tx1：部署
c.setNumber(100);            // tx2：调用 tx1 部署出的合约，依赖 tx1 的地址
vm.stopBroadcast();
```

若脚本只有一笔 `new YourContract(...)`（如本项目的 [MyToken.s.sol](../../script/MyToken.s.sol)），加 `--slow` 只是多等一个区块再退出，无实际收益，建议省略。

### 示例：MyToken 部署到 Sepolia

```bash
forge script script/MyToken.s.sol:MyTokenScript \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

## 验证失败时的手动补验证

若 `--verify` 自动验证未通过（网络抖动、API 限流等），部署本身已成功。用终端输出的合约地址手动补一次：

```bash
forge verify-contract <CONTRACT_ADDRESS> \
  --chain-id <CHAIN_ID> \
  --constructor-args <ABI_ENCODED_ARGS> \
  --etherscan-api-key $<CHAIN>_API_KEY \
  <SRC_PATH>:<ContractName>
```

其中：
- `<CHAIN_ID>`：链的数字 chainId（见下表）
- `<ABI_ENCODED_ARGS>`：构造函数参数的 ABI 编码，用 `cast abi-encode` 生成
- `<SRC_PATH>:<ContractName>`：源码路径与合约名

### 示例：MyToken 手动验证（无构造参数可省略 `--constructor-args`）

```bash
# 有构造参数（string name_, string symbol_）
forge verify-contract 0x... \
  --chain-id 11155111 \
  --constructor-args $(cast abi-encode "f(string,string)" "MyToken" "MTK") \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  src/MyToken.sol:MyToken

# 无构造参数
forge verify-contract 0x... \
  --chain-id 11155111 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  src/Counter.sol:Counter
```

查询验证状态：

```bash
forge verify-check --chain-id <CHAIN_ID> \
  --etherscan-api-key $<CHAIN>_API_KEY <GUID>
```

## 常用链 chainId 与浏览器对照

| 链 | chainId | 浏览器 | API key 申请 |
|----|---------|--------|--------------|
| Ethereum Mainnet | 1 | https://etherscan.io | https://etherscan.io/myapikey |
| Ethereum Sepolia | 11155111 | https://sepolia.etherscan.io | 同上（Etherscan 账号通用） |
| Polygon | 137 | https://polygonscan.com | https://polygonscan.com/myapikey |
| Polygon Amoy | 80002 | https://amoy.polygonscan.com | 同上 |
| BNB Smart Chain | 56 | https://bscscan.com | https://bscscan.com/myapikey |
| BSC Testnet | 97 | https://testnet.bscscan.com | 同上 |
| Arbitrum One | 42161 | https://arbiscan.io | https://arbiscan.io/myapikey |
| Base | 8453 | https://basescan.org | https://basescan.org/myapikey |
| Optimism | 10 | https://optimistic.etherscan.io | https://optimistic.etherscan.io/myapikey |

> Etherscan 系列产品共用同一个 Etherscan 账号，但**每个子链需要单独在对应站点生成 API key**（一个账号可创建多把 key，分别绑定不同链）。

## 为什么部署时 `--verify` 不用传 `--etherscan-api-key`，手动验证却要传？

两条命令查找 `[etherscan]` 表中 API key 的方式不同：

| 命令 | 查找 `[etherscan]` 的方式 | 是否需要 `--etherscan-api-key` |
|------|--------------------------|------------------------------|
| `forge script --rpc-url <CHAIN_ALIAS> --verify` | 用**别名** 同时查 `[rpc_endpoints]` 和 `[etherscan]` 两张表 | 否（自动） |
| `forge verify-contract --chain-id <CHAIN_ID>` | 用 **chainId 数字** 查表，但 `[etherscan]` 若按别名配置则类型不匹配 | 是（必须显式传） |

### 让手动验证也不传 `--etherscan-api-key`（可选）

把 [foundry.toml](../../foundry.toml) 的 `[etherscan]` 改成用 **chainId** 作为 key：

```toml
[etherscan]
11155111 = { key = "${ETHERSCAN_API_KEY}" }
137      = { key = "${POLYGONSCAN_API_KEY}" }
```

这样手动验证命令即可省略 `--etherscan-api-key`：

```bash
forge verify-contract <CONTRACT_ADDRESS> \
  --chain-id 11155111 \
  --constructor-args <ABI_ENCODED_ARGS> \
  src/MyToken.sol:MyToken
```

> ⚠️ `[etherscan]` 同一文件内建议只用一种 key 风格（别名或 chainId），不要混用。改成 chainId 风格后，部署时 `--verify` 仍能正常工作（Foundry 会从 RPC 返回的 chainId 反查 `[etherscan]`）。

## 环境变量自检

执行前快速确认关键变量已加载（按你实际用的链替换变量名）：

```bash
echo "RPC:   $<CHAIN>_RPC_URL"
echo "KEY:   ${PRIVATE_KEY:+已设置}"
echo "SCAN:  ${<CHAIN>SCAN_API_KEY:+已设置}"
```

三个值都非空即可执行部署命令。

## 常见问题

| 现象 | 排查方向 |
|------|---------|
| `insufficient funds for gas` | 钱包缺目标链原生代币，去对应水龙头领取 |
| `Environment variable XXX not found` | 未 `source .env` 或变量名拼写错误 |
| `tls handshake eof` | RPC 提供商网络问题，更换为 Alchemy / Infura / Ankr / LlamaNodes |
| `Failed to verify contract: Already verified` | 已验证过，无需处理，直接访问浏览器查看 |
| `could not find RPC URL for alias <name>` | `foundry.toml` 中 `[rpc_endpoints]` 缺少该别名条目 |
| `nonce too low` | 等几秒重试，或 `cast nonce <YOUR_ADDRESS> --rpc-url <CHAIN_ALIAS>` 查看当前 nonce |
| `Compiler version commit does not match` | 部署时与验证时的 solc 版本不一致，确保 `foundry.toml` 的 `solc` 配置未变 |
| `Contract name does not match` | `verify-contract` 末尾的 `<SRC>:<Name>` 中 Name 拼错，注意一个文件可含多个 contract |

## 部署成功后

在对应链的浏览器（如 https://sepolia.etherscan.io/）搜索部署后的合约地址，即可看到带源码的已验证合约页面，可直接通过浏览器的 "Read Contract" / "Write Contract" 面板与合约交互。
