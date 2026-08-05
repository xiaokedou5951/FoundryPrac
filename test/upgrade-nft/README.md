# UUPS 可升级 ERC721 合约

## 概述

本项目演示了使用 **UUPS（Universal Upgradeable Proxy Standard）** 模式实现 ERC721 NFT 合约的可升级架构。通过代理模式，可以在不改变合约地址和状态的前提下升级合约逻辑。

## 架构说明

```
用户调用 --> ERC1967Proxy (代理合约，存储状态)
                |
                | delegatecall
                v
         实现合约 (V1 / V2，无状态，纯逻辑)
```

- **代理合约**：`ERC1967Proxy`，存储所有状态（NFT 持有者、余额等），地址固定不变
- **实现合约**：V1/V2，只包含业务逻辑，通过 `delegatecall` 在代理上下文中执行

## 合约说明

### ERC721_Upgrade_V1

- 继承自 `Initializable`、`ERC721Upgradeable`、`OwnableUpgradeable`、`UUPSUpgradeable`
- 构造函数中调用 `_disableInitializers()` 防止实现合约被直接初始化
- `initialize()` 使用 `initializer` 修饰符，替代构造函数进行初始化
- `mint()` 仅 owner 可调用
- `_authorizeUpgrade()` 仅 owner 可授权升级

### ERC721_Upgrade_V2

- 继承自 `ERC721_Upgrade_V1`
- 新增 `version` 状态变量（追加在存储布局末尾，保证兼容性）
- `initializeV2()` 使用 `reinitializer(2)` 修饰符，确保只执行一次

## 测试用例

| 测试函数 | 说明 |
|---------|------|
| `test_Initialization` | 验证代理初始化后 name、symbol、owner 正确 |
| `test_Mint` | 验证 owner 可以正常铸造 NFT |
| `test_MintOnlyOwner` | 验证非 owner 无法铸造 NFT |
| `test_UpgradeToV2` | 验证从 V1 升级到 V2 成功，版本号正确 |
| `test_StatePreservationAfterUpgrade` | 验证升级后原有状态（NFT 持有者、余额等）完整保留 |
| `test_V2Functionality` | 验证升级后 V2 新功能正常工作 |
| `test_UpgradeOnlyOwner` | 验证非 owner 无法执行升级操作 |

## 运行测试

```bash
# 运行所有升级相关测试
forge test --match-path test/upgrade-nft/ERC721UpgradeTest.t.sol -vvv

# 运行单个测试
forge test --match-test test_StatePreservationAfterUpgrade -vvvv
```

## 部署脚本

部署脚本位于 `script/upgrade-nft/DeployUpgradeNFT.s.sol`，完整演示了：

1. 部署 V1 实现合约
2. 部署 ERC1967Proxy 并初始化
3. 通过代理调用 mint
4. 部署 V2 实现合约
5. 通过 `upgradeToAndCall` 升级到 V2
6. 验证升级后状态保留和新功能

```bash
# 本地运行部署脚本（anvil）
forge script script/upgrade-nft/DeployUpgradeNFT.s.sol --fork-url local --broadcast

# 部署到 Sepolia 测试网
forge script script/upgrade-nft/DeployUpgradeNFT.s.sol --rpc-url sepolia --broadcast --verify
```

## 升级注意事项

1. **存储布局兼容性**：V2 新增的状态变量必须追加在末尾，不能修改或删除已有变量
2. **初始化函数**：每次升级使用 `reinitializer(version)` 标记新版本初始化函数，version 必须递增
3. **函数选择器冲突**：新增函数不能与已有函数产生选择器冲突
4. **实现合约保护**：构造函数中 `_disableInitializers()` 防止实现合约被恶意初始化
