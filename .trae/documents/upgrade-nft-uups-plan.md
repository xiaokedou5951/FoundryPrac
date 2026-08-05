# UUPS 代理升级 NFT 合约计划

## 总结
修复并完善 ERC721_Upgrade_V1.sol 和 ERC721_Upgrade_V2.sol，添加缺失的导入和继承，创建部署脚本和测试文件，验证 UUPS 代理升级流程。

## 当前状态分析

### 问题
1. **ERC721_Upgrade_V1.sol** 缺少必要的导入和继承：
   - 未导入 `ERC721Upgradeable` 和 `OwnableUpgradeable`
   - 合约未继承这两个基础合约
   - 导致 `__ERC721_init`、`__Ownable_init`、`__UUPSUpgradeable_init`、`onlyOwner`、`_mint` 等函数不可用

2. **ERC721_Upgrade_V2.sol** 存在问题：
   - `version` 状态变量使用普通存储位置，可能与未来升级冲突
   - `initializeV2` 应使用 `reinitializer(2)` 修饰符而非 `onlyOwner`

3. **缺少部署脚本和测试文件**

## 修改方案

### 1. 修复 ERC721_Upgrade_V1.sol
- 添加导入：`ERC721Upgradeable`、`OwnableUpgradeable`
- 添加继承：`ERC721Upgradeable`、`OwnableUpgradeable`
- 添加 `__ERC721_init`、`__Ownable_init` 的调用（已有）

### 2. 修复 ERC721_Upgrade_V2.sol
- 使用 `reinitializer(2)` 修饰符替代 `onlyOwner`
- 保持状态变量在存储布局末尾（当前 `version` 位置正确）

### 3. 创建部署脚本 script/upgrade-nft/DeployUpgradeNFT.s.sol
- 部署 V1 实现合约
- 部署 ERC1967Proxy，初始化数据为 `initialize("UpgradeNFT", "UNFT")`
- 通过代理调用 mint 测试功能
- 部署 V2 实现合约
- 通过代理调用 `upgradeToAndCall` 升级到 V2
- 调用 `initializeV2` 完成 V2 初始化
- 验证版本号和功能

### 4. 创建测试文件 test/upgrade-nft/ERC721UpgradeTest.t.sol
- 测试初始化
- 测试 mint 功能
- 测试升级到 V2
- 测试 V2 功能
- 测试权限控制

## 验证步骤
1. 运行 `forge build` 确认编译通过
2. 运行 `forge test --match-path test/upgrade-nft/ERC721UpgradeTest.t.sol -vvv` 运行测试
3. 可选：运行部署脚本验证完整流程
