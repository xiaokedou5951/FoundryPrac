# NFTMarket Gas 优化计划

## 一、当前状态分析

### 1.1 合约概述
- **文件路径**: `/Users/mac/learn/web3/2026/07/FoundryPrac/src/NFTMarketGasOptimize.sol`
- **合约功能**: NFT 市场，支持上架、购买、取消上架等操作
- **主要特点**:
  - 使用 `require` 进行错误检查（字符串错误消息）
  - 使用 `mapping` 存储 Listing 信息
  - 包含 `tokensReceived` 回调函数处理代币转账
  - 测试文件位于 `test/nft/NFTMarket.t.sol`

### 1.2 测试依赖
- 测试文件使用 `vm.expectRevert("error message")` 验证错误
- 需要同步修改测试文件以支持自定义错误

### 1.3 编译配置
- `foundry.toml` 中未启用优化器
- 建议启用优化器以获得更好的 gas 效率

## 二、优化方案（按优先级排序）

### 2.1 使用自定义错误替代 require 字符串（高优先级）

**原因**: 自定义错误比字符串错误节省大量 gas（部署时节省 ~50%，运行时节省 ~20-40%）

**修改位置**:
- 第58行: `"NFTMarket: payment token address cannot be zero"`
- 第65行: `"NFTMarket: price must be greater than zero"`
- 第68行: `"NFTMarket: NFT contract address cannot be zero"`
- 第73-78行: `"NFTMarket: caller is not owner nor approved"`
- 第103行: `"NFTMarket: listing is not active"`
- 第106行: `"NFTMarket: caller is not the seller"`
- 第119行: `"NFTMarket: listing is not active"`
- 第122行: `"NFTMarket: insufficient token balance"`
- 第129行: `"NFTMarket: token transfer failed"`
- 第141行: `"NFTMarket: caller is not the payment token contract"`
- 第144行: `"NFTMarket: invalid data length"`
- 第149行: `"NFTMarket: listing is not active"`
- 第152行: `"NFTMarket: incorrect payment amount"`
- 第159行: `"NFTMarket: token transfer to seller failed"`
- 第174行: `"NFTMarket: listing is not active"`
- 第177行: `"NFTMarket: insufficient token balance"`
- 第184行: `"NFTMarket: token transfer with callback failed"`

**实现方式**:
```solidity
// 在合约开头定义错误
error NFTMarket__InvalidPaymentTokenAddress();
error NFTMarket__InvalidPrice();
error NFTMarket__InvalidNFTContractAddress();
error NFTMarket__NotOwnerOrApproved();
error NFTMarket__ListingNotActive();
error NFTMarket__NotSeller();
error NFTMarket__InsufficientTokenBalance();
error NFTMarket__TokenTransferFailed();
error NFTMarket__NotPaymentTokenContract();
error NFTMarket__InvalidDataLength();
error NFTMarket__IncorrectPaymentAmount();
error NFTMarket__TokenTransferToSellerFailed();
error NFTMarket__TokenTransferWithCallbackFailed();

// 替换 require 语句
// 原: require(_price > 0, "NFTMarket: price must be greater than zero");
// 新: if (_price == 0) revert NFTMarket__InvalidPrice();
```

### 2.2 将 paymentToken 声明为 immutable（高优先级）

**原因**: immutable 变量在部署后值固定，每次访问节省 ~200 gas

**修改位置**:
- 第36行: `IExtendedERC20 public immutable paymentToken;`

**注意事项**:
- immutable 变量不能在构造函数之后修改
- 需要确保构造函数中已正确初始化

### 2.3 使用 unchecked 增量（中优先级）

**原因**: Solidity 0.8+ 默认检查溢出，但 uint256 实际不会溢出

**修改位置**:
- 第91行: `nextListingId++;` 改为 `unchecked { ++nextListingId; }`

**实现方式**:
```solidity
// 创建新的上架信息
uint256 listingId = nextListingId;
listings[listingId] = Listing({
    seller: owner,
    nftContract: _nftContract,
    tokenId: _tokenId,
    price: _price,
    isActive: true
});

// 增加listingId计数器
unchecked {
    ++nextListingId;
}
```

### 2.4 缓存多次访问的存储变量（中优先级）

**原因**: 从 storage 读取一次消耗 ~2100 gas（冷访问）或 ~100 gas（热访问），从 memory 读取只消耗 ~3 gas

**修改位置**:

#### buyNFT 函数（第116-136行）:
```solidity
function buyNFT(uint256 _listingId) external {
    // 检查上架信息是否存在且处于活跃状态
    Listing storage listing = listings[_listingId];
    require(listing.isActive, "NFTMarket: listing is not active");

    // 缓存多次使用的变量
    address seller = listing.seller;
    uint256 price = listing.price;
    address nftContractAddr = listing.nftContract;
    uint256 tokenId = listing.tokenId;

    // 检查买家是否有足够的代币
    require(paymentToken.balanceOf(msg.sender) >= price, "NFTMarket: insufficient token balance");

    // 将上架信息标记为非活跃
    listing.isActive = false;

    // 处理代币转账（买家 -> 卖家）
    bool success = paymentToken.transferFrom(msg.sender, seller, price);
    require(success, "NFTMarket: token transfer failed");

    // 处理NFT转移（卖家 -> 买家）
    IERC721(nftContractAddr).transferFrom(seller, msg.sender, tokenId);

    // 触发NFT售出事件
    emit NFTSold(_listingId, msg.sender, seller, nftContractAddr, tokenId, price);
}
```

#### tokensReceived 函数（第139-168行）:
```solidity
function tokensReceived(address from, uint256 amount, bytes calldata data) external override returns (bool) {
    // 检查调用者是否为支付代币合约
    require(msg.sender == address(paymentToken), "NFTMarket: caller is not the payment token contract");

    // 解析附加数据，获取listingId
    require(data.length == 32, "NFTMarket: invalid data length");
    uint256 listingId = abi.decode(data, (uint256));

    // 检查上架信息是否存在且处于活跃状态
    Listing storage listing = listings[listingId];
    require(listing.isActive, "NFTMarket: listing is not active");

    // 缓存多次使用的变量
    address seller = listing.seller;
    address nftContractAddr = listing.nftContract;
    uint256 tokenId = listing.tokenId;

    // 检查转入的代币数量是否等于NFT价格
    require(amount == listing.price, "NFTMarket: incorrect payment amount");

    // 将上架信息标记为非活跃
    listing.isActive = false;

    // 将代币转给卖家
    bool success = paymentToken.transfer(seller, amount);
    require(success, "NFTMarket: token transfer to seller failed");

    // 处理NFT转移（卖家 -> 买家）
    IERC721(nftContractAddr).transferFrom(seller, from, tokenId);

    // 触发NFT售出事件
    emit NFTSold(listingId, from, seller, nftContractAddr, tokenId, amount);

    return true;
}
```

#### buyNFTWithCallback 函数（第171-185行）:
```solidity
function buyNFTWithCallback(uint256 _listingId) external {
    // 检查上架信息是否存在且处于活跃状态
    Listing storage listing = listings[_listingId];
    require(listing.isActive, "NFTMarket: listing is not active");

    // 缓存多次使用的变量
    uint256 price = listing.price;

    // 检查买家是否有足够的代币
    require(paymentToken.balanceOf(msg.sender) >= price, "NFTMarket: insufficient token balance");

    // 编码listingId作为附加数据
    bytes memory data = abi.encode(_listingId);

    // 调用transferWithCallbackAndData函数，将代币转给市场合约并附带listingId数据
    bool success = paymentToken.transferWithCallbackAndData(address(this), price, data);
    require(success, "NFTMarket: token transfer with callback failed");
}
```

### 2.5 优化 Listing 结构体存储布局（低优先级）

**原因**: Solidity 按 32 字节槽存储结构体，优化布局可以减少槽使用

**当前布局**:
- `address seller` (20 字节) → 槽 0 (剩余 12 字节)
- `address nftContract` (20 字节) → 槽 1 (剩余 12 字节)
- `uint256 tokenId` (32 字节) → 槽 2
- `uint256 price` (32 字节) → 槽 3
- `bool isActive` (1 字节) → 槽 4
- **总计**: 5 个槽

**优化建议**:

方案 1：使用 uint96（节省 2 个槽）
```solidity
struct Listing {
    address seller;      // 20 字节 → 槽 0
    uint96 price;        // 12 字节 → 与 seller 共享槽 0（20+12=32）
    address nftContract; // 20 字节 → 槽 1
    uint96 tokenId;      // 12 字节 → 与 nftContract 共享槽 1（20+12=32）
    bool isActive;       // 1 字节 → 槽 2
}
```
- **总计**: 3 个槽（节省 2 个槽）
- **价格范围**: 最大 2^96 - 1 ≈ 7.9 × 10^28（约 79 万亿亿）
- **TokenId 范围**: 最大 2^96 - 1（足够大）

方案 2：使用 uint128（节省 1 个槽）
```solidity
struct Listing {
    address seller;      // 20 字节 → 槽 0（剩余 12 字节）
    uint128 price;       // 16 字节 → 槽 1（新槽，16 字节 > 12 字节剩余空间）
    address nftContract; // 20 字节 → 槽 2（剩余 12 字节）
    uint96 tokenId;      // 12 字节 → 与 nftContract 共享槽 2（20+12=32）
    bool isActive;       // 1 字节 → 槽 3
}
```
- **总计**: 4 个槽（节省 1 个槽）
- **价格范围**: 最大 2^128 - 1 ≈ 3.4 × 10^38

**建议**: 方案 1 更优，uint96 的价格范围已经足够大。但由于这是重大结构变更，建议暂时保持现状，除非明确的价格范围需求。

### 2.6 启用编译器优化（配置优化）

**原因**: Solidity 优化器可以自动进行许多 gas 优化

**修改位置**: `foundry.toml`

**实现方式**:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
optimizer = true
optimizer_runs = 200  # 适合一般使用场景
# optimizer_runs = 1000000  # 如果部署成本更重要
# optimizer_runs = 1  # 如果执行成本更重要

fs_permissions = [
    { access = "write", path = "./deployments" }
]
```

**参数说明**:
- `optimizer_runs = 200`: 平衡部署成本和执行成本
- `optimizer_runs = 1000000`: 最小化部署成本
- `optimizer_runs = 1`: 最小化执行成本

## 三、测试文件创建计划

### 3.1 测试文件说明
- **原测试文件**: `/Users/mac/learn/web3/2026/07/FoundryPrac/test/nft/NFTMarket.t.sol` - 保持不变，用于对比
- **新测试文件**: `/Users/mac/learn/web3/2026/07/FoundryPrac/test/nft-gas-opt/NFTMarketGasOptimize.t.sol` - 新创建

### 3.2 新测试文件内容

#### 导入自定义错误:
```solidity
import "../../src/NFTMarketGasOptimize.sol";

// 错误已经通过导入自动可用，无需额外定义
```

#### 替换 vm.expectRevert 调用:

**原代码**:
```solidity
vm.expectRevert("NFTMarket: price must be greater than zero");
```

**新代码**:
```solidity
vm.expectRevert(NFTMarket.NFTMarket__InvalidPrice());
// 或者使用完全限定名
vm.expectRevert(abi.encodeWithSelector(NFTMarket.NFTMarket__InvalidPrice.selector));
```

**具体修改位置**:
- 第181行: `vm.expectRevert("NFTMarket: caller is not owner nor approved");` → `vm.expectRevert(NFTMarket.NFTMarket__NotOwnerOrApproved.selector);`
- 第193行: `vm.expectRevert("NFTMarket: price must be greater than zero");` → `vm.expectRevert(NFTMarket.NFTMarket__InvalidPrice.selector);`
- 第205行: `vm.expectRevert("NFTMarket: NFT contract address cannot be zero");` → `vm.expectRevert(NFTMarket.NFTMarket__InvalidNFTContractAddress.selector);`
- 第339行: `vm.expectRevert("NFTMarket: listing is not active");` → `vm.expectRevert(NFTMarket.NFTMarket__ListingNotActive.selector);`
- 第362行: `vm.expectRevert("NFTMarket: insufficient token balance");` → `vm.expectRevert(NFTMarket.NFTMarket__InsufficientTokenBalance.selector);`
- 第385行: `vm.expectRevert("NFTMarket: incorrect payment amount");` → `vm.expectRevert(NFTMarket.NFTMarket__IncorrectPaymentAmount.selector);`

## 四、实施步骤

### 步骤 1: 创建优化后的合约文件
1. 复制 `NFTMarket.sol` 为 `NFTMarketGasOptimize.sol`
2. 确保文件路径正确：`/Users/mac/learn/web3/2026/07/FoundryPrac/src/NFTMarketGasOptimize.sol`

### 步骤 2: 启用编译器优化
1. 修改 `foundry.toml`，添加优化器配置
2. 验证编译是否成功

### 步骤 3: 添加自定义错误定义
1. 在 `NFTMarketGasOptimize.sol` 合约开头定义所有自定义错误
2. 确保错误命名清晰且具有描述性

### 步骤 4: 替换 require 语句
1. 将所有 `require` 语句替换为 `if (!condition) revert CustomError();`
2. 按函数逐个替换，确保逻辑正确
3. 优先替换以下函数（按 gas 使用频率）:
   - `buyNFT` (最频繁调用)
   - `tokensReceived` (回调购买)
   - `buyNFTWithCallback` (辅助购买)
   - `list` (上架)
   - `cancelListing` (取消)

### 步骤 5: 声明 immutable 变量
1. 将 `paymentToken` 声明为 `immutable`
2. 确保构造函数中正确初始化

### 步骤 6: 添加 unchecked 块
1. 在 `nextListingId++` 处添加 `unchecked` 块
2. 使用前置增量 `++nextListingId` 以获得更好的 gas 效率

### 步骤 7: 缓存存储变量
1. 在 `buyNFT`、`tokensReceived`、`buyNFTWithCallback` 函数中缓存常用变量
2. 创建局部内存变量存储 `seller`、`price`、`nftContract`、`tokenId`

### 步骤 8: 创建新的测试文件
1. 创建测试目录：`/Users/mac/learn/web3/2026/07/FoundryPrac/test/nft-gas-opt/`
2. 创建测试文件：`NFTMarketGasOptimize.t.sol`
3. 复制 `test/nft/NFTMarket.t.sol` 的内容作为基础
4. 修改导入路径指向 `NFTMarketGasOptimize.sol`
5. 修改合约名称和测试合约名称：
   - `NFTMarket` → `NFTMarketGasOptimize`
   - `NFTMarketTest` → `NFTMarketGasOptimizeTest`
6. 更新所有 `vm.expectRevert` 调用以支持自定义错误
7. **保持原测试文件不变**：`test/nft/NFTMarket.t.sol` 不做任何修改

### 步骤 9: 验证和测试
1. 运行所有单元测试: `forge test`
2. 运行 gas 报告: `forge test --gas-report`
3. 对比优化前后的 gas 消耗：
   - 运行原测试: `forge test --match-path test/nft/NFTMarket.t.sol --gas-report`
   - 运行优化测试: `forge test --match-path test/nft-gas-opt/NFTMarketGasOptimize.t.sol --gas-report`
   - 对比两个版本的 gas 消耗数据

## 五、预期收益

### 5.1 Gas 节省估算

| 优化项 | 部署成本节省 | 执行成本节省 | 备注 |
|--------|-------------|-------------|------|
| 自定义错误 | ~50% | ~20-40% | 最显著优化 |
| immutable 变量 | - | ~200 gas/次访问 | 每次调用节省 |
| unchecked 增量 | - | ~30-40 gas | 每次上架节省 |
| 缓存存储变量 | - | ~100-2000 gas | 每次购买节省 |
| 编译器优化 | 10-20% | 5-15% | 自动优化 |

### 5.2 具体场景节省

**上架 NFT (list 函数)**:
- 优化前: ~150,000 gas
- 优化后: ~120,000 gas (节省 ~20%)

**购买 NFT (buyNFT 函数)**:
- 优化前: ~100,000 gas
- 优化后: ~75,000 gas (节省 ~25%)

**回调购买 (tokensReceived 函数)**:
- 优化前: ~120,000 gas
- 优化后: ~90,000 gas (节省 ~25%)

## 六、风险评估

### 6.1 低风险
- ✅ 自定义错误: 仅改变错误处理方式，逻辑不变
- ✅ immutable 变量: 编译器保证安全性
- ✅ unchecked 增量: uint256 不会溢出
- ✅ 编译器优化: 自动优化，风险极低

### 6.2 需要注意
- ⚠️ 缓存存储变量: 需要确保不会在缓存后修改原值（当前代码无此问题）
- ⚠️ 测试更新: 需要同步更新所有测试用例
- ⚠️ 向后兼容: 自定义错误改变了接口，需评估是否有外部依赖

### 6.3 暂不实施
- ❌ 结构体布局优化: 风险较高，需要详细评估价格范围
- ❌ 其他激进优化: 保持代码可读性和安全性

## 七、验证步骤

### 7.1 编译验证
```bash
forge build
```

### 7.2 测试验证
```bash
forge test
forge test -vvvv  # 详细输出
```

### 7.3 Gas 报告
```bash
forge test --gas-report
```

### 7.4 快照对比
```bash
forge snapshot
# 对比 .gas-snapshot 文件
```

## 八、假设与决策

### 8.1 技术假设
- Solidity 版本保持在 ^0.8.30
- 使用 Foundry 作为开发和测试框架
- 目标是优化执行 gas 成本，而非部署成本
- 价格范围使用 uint256（不限制为 uint128）

### 8.2 设计决策
- ✅ 采用自定义错误而非 require 字符串
- ✅ 将 paymentToken 声明为 immutable
- ✅ 使用 unchecked 增量优化
- ✅ 缓存存储变量以减少 gas
- ✅ 启用编译器优化（runs = 200）
- ❌ 暂不优化结构体布局（保持简单性）
- ❌ 不使用汇编优化（保持可读性）

### 8.3 测试策略
- 同步更新测试文件以支持自定义错误
- 保持所有现有测试用例的功能不变
- 使用 gas 报告对比优化效果