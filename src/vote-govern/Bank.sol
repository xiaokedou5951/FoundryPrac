// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title Bank
 * @dev 原生 ETH 资金银行。管理员（admin）通常为治理合约 Governor。
 *
 *   功能（对应需求二之 1）：
 *   - withdraw(address to, uint256 amount)：仅 admin 可调用，把 ETH 拨付给 to。
 *   - receive()：接受任意 ETH 注资（国库充值）。
 *   - setAdmin()：admin 可迁移管理员（测试 / 治理升级用）。
 *
 *   安全：合约无内部账本，withdraw 仅做余额检查后转账，天然无重入风险。
 *   真实调用方为 Governor（admin），由治理提案触发 Bank.withdraw 完成资金使用。
 */
contract Bank {
    address public admin;

    // ===== 事件 =====
    event Withdraw(address indexed to, uint256 amount);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event Received(address indexed from, uint256 amount);

    /**
     * @param _admin 管理员地址（部署后即治理合约 Governor）。
     */
    constructor(address _admin) payable {
        require(_admin != address(0), "Bank: zero admin");
        admin = _admin;
    }

    /// @dev 接受 ETH 注资（国库充值）。
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /**
     * @dev 仅管理员：把 amount ETH 拨付给 to。
     *      治理提案执行时，Governor（作为 admin）调用本方法把资金打给提案指定收款人。
     */
    function withdraw(address to, uint256 amount) external {
        require(msg.sender == admin, "Bank: not admin");
        require(to != address(0), "Bank: zero to");
        require(amount > 0, "Bank: zero amount");
        require(address(this).balance >= amount, "Bank: insufficient");

        // 无内部状态可被重入破坏，直接转账
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Bank: transfer failed");

        emit Withdraw(to, amount);
    }

    /// @dev 迁移管理员（仅当前 admin）。
    function setAdmin(address newAdmin) external {
        require(msg.sender == admin, "Bank: not admin");
        require(newAdmin != address(0), "Bank: zero admin");
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev 当前国库 ETH 余额。
    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}
