# Bank 合约测试说明

本目录存放 [`Bank`](../../src/Bank_Contract.sol) 合约的 Foundry 单元测试。

## 被测合约简介

`Bank` 是一个简单的存款合约，核心功能：

- **存款**：用户通过 `deposit()` 或直接向合约转 ETH（触发 `receive()`）存款，金额累加到 `deposits[msg.sender]`。
- **Top 3 存款榜**：内部维护 `topDepositors`（前 3 名地址数组），每次存款后自动重新排序。
- **管理员提取**：部署者为 `admin`，仅 `admin` 可调用 `withdraw()` 提走合约全部余额。
- **管理员变更**：`admin` 可通过 `setAdmin()` 转移权限，并触发 `AdminChanged` 事件。

## 测试文件

- [`Bank.t.sol`](./Bank.t.sol) — `BankTest` 合约，包含 3 个测试用例。

## 测试用例

| 测试函数 | 验证内容 |
| --- | --- |
| `testDeposit` | 存款前后 `deposits(user)` 余额正确累加（含多次存款）。 |
| `testTopDepositors` | 覆盖 5 个场景：1~4 个用户存款、同一用户多次存款时，`getTopDepositors()` 返回的前 3 名地址与金额均正确。 |
| `testWithdrawOnlyAdmin` | 非管理员调用 `withdraw()` 应 revert `"Only admin can withdraw"`；管理员调用后合约余额清零、admin 余额增加对应金额。 |

## 测试环境（setUp）

- 使用 `makeAddr` 创建 4 个测试用户 `user1`~`user4`。
- 用 `vm.deal` 给每个用户预置 10 ETH。
- 部署 `Bank`，合约的 `admin` 即测试合约自身（`address(this)`）。
- 测试合约实现 `receive()` 以接收 ETH（用于管理员提取后的余额校验）。

## 运行方式

在项目根目录执行：

```shell
# 运行本目录下所有测试
forge test --match-path "test/bank/*"

# 仅运行 BankTest
forge test --match-contract BankTest

# 运行单个测试用例（-vv 控制日志详细度）
forge test --match-test testTopDepositors -vvv

# 直接指定测试文件运行（-vv 控制日志详细度）
forge test test/bank/Bank.t.sol -vv
```

## 测试运行结果

执行 `forge test --match-path "test/bank/*" -vv` 的输出：

```text
No files changed, compilation skipped

Ran 3 tests for test/bank/Bank.t.sol:BankTest
[PASS] testDeposit() (gas: 84785)
[PASS] testTopDepositors() (gas: 278823)
[PASS] testWithdrawOnlyAdmin() (gas: 86551)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.51ms (794.42µs CPU time)

Ran 1 test suite in 798.04ms (1.51ms CPU time): 3 tests passed, 0 failed, 0 skipped (3 total tests)
```

| 用例 | 结果 | Gas |
| --- | --- | --- |
| `testDeposit` | PASS | 84,785 |
| `testTopDepositors` | PASS | 278,823 |
| `testWithdrawOnlyAdmin` | PASS | 86,551 |

合计：3 通过 / 0 失败 / 0 跳过，单套件耗时 1.51ms。

## 用到的关键 Cheatcode

- `makeAddr(name)`：生成确定性测试地址。
- `vm.deal(addr, amount)`：给地址设置 ETH 余额。
- `vm.prank(addr)`：将下一次调用的 `msg.sender` 设为指定地址。
- `vm.expectRevert(msg)`：断言下一次调用 revert 并匹配错误信息。
