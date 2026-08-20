// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @dev simple-leverage-dex 模块自包含的模拟 USDC（6 位精度，与真实 USDC 一致）。
///      开放 mint 供测试/本地环境发放，生产环境不应使用。
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    /// @dev 真实 USDC 为 6 位精度
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev 任意人可铸造（仅测试/教学用）
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
