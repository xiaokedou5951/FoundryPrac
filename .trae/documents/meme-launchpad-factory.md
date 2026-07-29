# Meme 发射平台工厂合约实现计划

## 概述

基于 EIP-1167 最小代理（Minimal Proxy）模式，创建一个 Meme 发射平台工厂合约，使 Meme 发行者能以较低 Gas 成本部署 ERC20 代币。

## 当前状态分析

- 项目使用 Foundry 框架，Solidity 版本 `^0.8.30`
- 已引入 OpenZeppelin v5.5.0（含 ERC20、Clones 库等）
- remappings: `@openzeppelin/contracts/` → `lib/openzeppelin-contracts/contracts/`
- 现有合约：MyERC20、TokenBank、NFTMarket 等，无工厂/代理模式实现
- 测试文件放在 `test/` 下，按模块分子目录（如 `test/bank/`、`test/nft/`）

## 需要创建的文件

### 1. `src/MemeToken.sol` — Meme 代币实现合约（模板）

最小代理模式中的"实现合约"，所有代理合约共享代码但拥有独立存储。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MemeToken is ERC20 {
    uint256 public maxSupply;    // 总发行量
    uint256 public perMint;      // 每次铸造数量
    uint256 public mintPrice;    // 每次铸造费用 (wei)
    address public issuer;       // Meme 发行者
    address public factory;      // 工厂合约地址

    constructor() ERC20("Meme Token", "MEME") {}

    function initialize(
        string memory symbol,
        uint256 _totalSupply,
        uint256 _perMint,
        uint256 _price,
        address _issuer,
        address _factory
    ) external {
        require(maxSupply == 0, "Already initialized");
        require(_perMint > 0 && _price > 0 && _issuer != address(0), "Invalid params");

        _symbol = symbol;           // 设置代币代号
        maxSupply = _totalSupply;
        perMint = _perMint;
        mintPrice = _price;
        issuer = _issuer;
        factory = _factory;
    }

    function mint(address to) external {
        require(msg.sender == factory, "Only factory can mint");
        require(ERC20.totalSupply() + perMint <= maxSupply, "Exceeds max supply");
        _mint(to, perMint);
    }
}
```

**关键设计决策：**
- `constructor` 设定固定名称 "Meme Token"（需求要求名字固定），symbol 留空由 `initialize` 设置
- `initialize` 通过 `maxSupply == 0` 检查防止重复初始化
- `mint` 仅工厂合约可调用，确保费用逻辑在工厂层统一执行
- 铸造前检查 `totalSupply + perMint <= maxSupply` 防止超发

**注意：** OpenZeppelin ERC20 v5 的 `_symbol` 是 `private`，无法直接赋值。需要通过其他方式设置 symbol，比如重写 `symbol()` 函数或使用自定义存储变量。

### 2. `src/MemeFactory.sol` — Meme 工厂合约

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MemeToken} from "./MemeToken.sol";

contract MemeFactory {
    address public owner;
    address public implementation;
    mapping(address => bool) public isMemeToken;

    event MemeDeployed(address indexed tokenAddr, address indexed issuer, string symbol, uint256 totalSupply, uint256 perMint, uint256 price);
    event MemeMinted(address indexed tokenAddr, address indexed minter, uint256 amount, uint256 fee);

    constructor() {
        owner = msg.sender;
        implementation = address(new MemeToken());
    }

    function deployMeme(
        string calldata symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    ) external returns (address) {
        require(bytes(symbol).length > 0, "Empty symbol");
        require(totalSupply > 0 && perMint > 0 && price > 0, "Invalid params");
        require(totalSupply % perMint == 0, "totalSupply must be divisible by perMint");

        // 使用最小代理部署新实例
        address proxy = Clones.clone(implementation);

        // 初始化代理实例
        MemeToken(proxy).initialize(symbol, totalSupply, perMint, price, msg.sender, address(this));

        // 记录合法的 Meme Token
        isMemeToken[proxy] = true;

        emit MemeDeployed(proxy, msg.sender, symbol, totalSupply, perMint, price);
        return proxy;
    }

    function mintMeme(address tokenAddr) external payable {
        require(isMemeToken[tokenAddr], "Not a valid Meme token");

        MemeToken token = MemeToken(tokenAddr);
        uint256 price = token.mintPrice();
        require(msg.value >= price, "Insufficient payment");

        // 铸造 perMint 数量的代币
        token.mint(msg.sender);

        // 费用分配：1% 给项目方，99% 给 Meme 发行者
        uint256 projectFee = price / 100;
        uint256 issuerFee = price - projectFee;

        (bool ok1,) = owner.call{value: projectFee}("");
        require(ok1, "Project fee transfer failed");

        (bool ok2,) = token.issuer().call{value: issuerFee}("");
        require(ok2, "Issuer fee transfer failed");

        // 退还多余的 ETH
        if (msg.value > price) {
            (bool ok3,) = msg.sender.call{value: msg.value - price}("");
            require(ok3, "Refund failed");
        }

        emit MemeMinted(tokenAddr, msg.sender, token.perMint(), price);
    }
}
```

**关键设计决策：**
- `implementation` 在构造函数中部署一次，之后通过 `Clones.clone()` 创建最小代理
- `isMemeToken` 映射确保 `mintMeme` 只对工厂创建的合法代币生效
- 费用分配：`price / 100` 给项目方（1%），剩余给发行者（99%），避免精度损失
- 多付的 ETH 自动退还给调用者

### 3. `test/meme/MemeFactory.t.sol` — 测试文件

测试用例覆盖：

**A. deployMeme 测试**
- 成功部署 Meme 代币，验证参数正确设置
- 非法参数（空 symbol、0 totalSupply 等）应 revert

**B. mintMeme 费用分配测试**
- 验证每次铸造后，1% 费用到项目方，99% 费用到发行者
- 验证费用金额精确计算

**C. 铸造数量与总量控制测试**
- 每次铸造数量等于 perMint
- 多次铸造直到 totalSupply 耗尽
- 超过 totalSupply 时 revert
- 不够一次 perMint 时 revert

**D. 安全性测试**
- 非 factory 调用 mint 应 revert
- 对非工厂创建的地址调用 mintMeme 应 revert
- 支付不足时应 revert

## 关于 ERC20 _symbol 的处理

OpenZeppelin v5 的 ERC20 中 `_symbol` 是 `private` 的，无法在子合约中直接赋值。解决方案：

**方案：** 在 MemeToken 中增加 `string private _tokenSymbol` 存储变量，重写 `symbol()` 函数返回 `_tokenSymbol`，在 `initialize` 中设置 `_tokenSymbol`。

## 实现步骤

1. 创建 `src/MemeToken.sol` — Meme 代币实现合约
2. 创建 `src/MemeFactory.sol` — Meme 工厂合约
3. 创建 `test/meme/MemeFactory.t.sol` — 测试文件
4. 运行 `forge test` 验证所有测试通过

## 验证步骤

```bash
forge build
forge test -vvv
```

确认：
- 所有测试通过
- 费用分配比例正确（1% / 99%）
- 铸造数量正确，不超 totalSupply
- 最小代理部署成功且 Gas 成本较低
