# NFTMarket 测试说明

本目录存放 `NFTMarket` 合约的 Foundry 单元测试，对应源合约 [src/NFTMarket.sol](../../src/NFTMarket.sol)。

## 一、测试目标合约简介

`NFTMarket` 是一个基于 ERC20 支付代币的 NFT 挂单交易市场，主要能力：

- **挂单（list）**：NFT 持有者或被授权方将某个 NFT 以指定价格挂出。
- **取消挂单（cancelListing）**：卖家取消尚在活跃状态的挂单。
- **普通购买（buyNFT）**：买家通过 `transferFrom` 完成支付并取得 NFT。
- **回调购买（buyNFTWithCallback / tokensReceived）**：买家调用支付代币的 `transferWithCallbackAndData`，市场合约在 `tokensReceived` 回调中完成撮合。

核心不变量：**市场合约自身永远不持有支付代币**——所有代币在成交时直接由买家转入卖家账户。

## 二、测试环境

| 组件 | 说明 |
| --- | --- |
| 框架 | Foundry / forge-std |
| Solidity | ^0.8.0 |
| 被测合约 | `NFTMarket`（构造时传入支付代币地址） |
| 测试文件 | [NFTMarket.t.sol](./NFTMarket.t.sol) |

### 测试账户

| 角色 | 地址 | 初始资产 |
| --- | --- | --- |
| `seller` | `address(1)` | tokenId=1 的 NFT |
| `buyer` | `address(2)` | 1000 支付代币 |
| `operator` | `address(3)` | 无（用于授权场景） |

### Mock 合约

测试文件内置两个轻量 Mock，避免依赖 OpenZeppelin 等外部库：

- **`MockERC20`**：实现 `IExtendedERC20`，包含 `transferWithCallback` / `transferWithCallbackAndData`，通过 `ITokenReceiver.tokensReceived` 触发市场回调逻辑；提供 `mint` 便于测试中按需铸币。
- **`MockERC721`**：实现 `IERC721` 的最小集合（`ownerOf`、`transferFrom`、`approve`、`setApprovalForAll` 等），并通过 `_isApprovedOrOwner` 校验转账权限。

## 三、测试用例

按功能分组，共 14 个用例（含 1 个模糊测试、1 个不变量测试）。

### 1. 挂单（list）

| 用例 | 预期 | 关键断言 |
| --- | --- | --- |
| `testListNFTSuccess` | 卖家本人挂单成功 | `NFTListed` 事件被发出；`listings[0]` 各字段匹配；`nextListingId` 自增为 1 |
| `testListNFTFailureNotOwner` | 非 owner / 未授权者挂单回滚 | revert `NFTMarket: caller is not owner nor approved` |
| `testListNFTFailureZeroPrice` | 价格为 0 回滚 | revert `NFTMarket: price must be greater than zero` |
| `testListNFTFailureZeroAddress` | NFT 合约地址为零地址回滚 | revert `NFTMarket: NFT contract address cannot be zero` |
| `testListNFTByApprovedOperator` | `setApprovalForAll` 的操作员可挂单 | 挂单记录中 `seller` 仍为 NFT 真 owner，而非操作员 |
| `testListNFTByApprovedForToken` | 单 tokenId `approve` 的被授权方可挂单 | 同上，`seller` 仍为 NFT 真 owner |

### 2. 普通购买（buyNFT）

| 用例 | 预期 | 关键断言 |
| --- | --- | --- |
| `testBuyNFTSuccess` | 买家正常购买成功 | `NFTSold` 事件；NFT 所有权转给 buyer；卖家收到代币；挂单置为 inactive |
| `testBuySelfNFT` | 卖家自购自有挂单 | NFT 所有权不变；挂单置为 inactive |
| `testBuyNFTTwice` | 同一挂单被重复购买 | 第二次 revert `NFTMarket: listing is not active` |
| `testBuyNFTInsufficientBalance` | 买家余额仅为一半价格 | revert `NFTMarket: insufficient token balance` |

### 3. 回调购买（transferWithCallbackAndData）

| 用例 | 预期 | 关键断言 |
| --- | --- | --- |
| `testBuyNFTWithCallbackSuccess` | 通过 `transferWithCallbackAndData` 直接转账触发回调购买 | `NFTSold` 事件；NFT 归属与代币转移正确；挂单 inactive |
| `testBuyNFTWithCallbackIncorrectAmount` | 回调支付金额为价格 2 倍 | revert `NFTMarket: incorrect payment amount` |

> 注：测试中直接调用 `paymentToken.transferWithCallbackAndData(market, price, abi.encode(listingId))`，而非源合约的 `buyNFTWithCallback` 包装函数，以更贴近真实回调路径并便于 `vm.expectRevert` 捕获。

### 4. 模糊测试

| 用例 | 输入空间 | 说明 |
| --- | --- | --- |
| `testFuzz_ListAndBuyNFT` | `fuzzPrice` ∈ [0.01, 10000] token；随机 `fuzzBuyer` 地址 | 随机价格 + 随机买家走完整挂单-购买流程；`vm.assume` 排除零地址、seller、market、test 合约本身 |

### 5. 不变量测试

| 用例 | 不变量 | 验证方式 |
| --- | --- | --- |
| `testInvariant_NoTokenBalance` | 市场合约自身永不持有支付代币 | 在普通购买、二次挂单后回购、回调购买三种路径下分别断言 `paymentToken.balanceOf(market) == 0` |

## 四、运行方式

在项目根目录执行：

```bash
# 运行该测试文件全部用例
forge test --match-path test/nft/NFTMarket.t.sol -vv

# 仅运行某文件的某用例
forge test --match-path test/nft/NFTMarket.t.sol --match-test testListNFTSuccess -vvv

# 仅运行某类用例
forge test --match-test testListNFT -vv
forge test --match-test testBuyNFT -vv
forge test --match-test testFuzz -vvv

# 不变量测试
forge test --match-test testInvariant -vv
```

推荐 `-vv` 及以上等级：`-vv` 打印断言栈迹，`-vvv` 打印 fuzz 用例的具体输入，便于复现失败路径。

## 五、覆盖矩阵

| 合约函数 | 直接覆盖的用例 |
| --- | --- |
| `list` | 6 个挂单用例 + fuzz |
| `buyNFT` | 4 个普通购买用例 + fuzz + 不变量 |
| `tokensReceived` | 2 个回调用例 + 不变量 |
| `buyNFTWithCallback` | 间接（被回调用例替代直接路径） |
| `cancelListing` | **未覆盖**（源合约已实现，但本测试未直接验证，建议后续补充） |
| 构造函数零地址校验 | 间接通过 setUp 覆盖正向路径 |

> 待补：`cancelListing` 的权限与状态变更、构造函数零地址 revert、`tokensReceived` 来自非支付代币合约的 revert 分支。
