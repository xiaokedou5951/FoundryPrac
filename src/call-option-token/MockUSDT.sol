// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDT
/// @dev call-option-token 模块自包含的模拟 USDT（6 位精度，与真实 USDT 一致）。
///      开放 mint 供测试/本地环境发放，生产环境不应使用。
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev 任意人可铸造（仅测试/教学用）
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
