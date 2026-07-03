// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {Bank} from "../../src/Bank_Contract.sol";

contract BankTest is Test {
    Bank public bank;
    address public admin;
    address public user1;
    address public user2;
    address public user3;
    address public user4;

    // 在每个测试用例执行前设置测试环境
    function setUp() public {
        // 设置管理员地址
        admin = address(this);
        
        // 创建测试用户地址
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");
        
        // 给测试用户一些ETH
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(user3, 10 ether);
        vm.deal(user4, 10 ether);
        
        // 部署Bank合约
        bank = new Bank();
    }
    
    // 测试1：检查存款前后用户在Bank合约中的存款额更新是否正确
    function testDeposit() public {
        // 初始存款额应为0
        assertEq(bank.deposits(user1), 0);
        
        // 用户1存款1 ETH
        uint256 depositAmount = 1 ether;
        vm.prank(user1);
        bank.deposit{value: depositAmount}();
        
        // 检查存款后余额是否正确
        assertEq(bank.deposits(user1), depositAmount);
        
        // 再次存款0.5 ETH
        uint256 secondDepositAmount = 0.5 ether;
        vm.prank(user1);
        bank.deposit{value: secondDepositAmount}();
        
        // 检查总存款额是否正确
        assertEq(bank.deposits(user1), depositAmount + secondDepositAmount);
    }
    
    // 测试2：检查存款金额的前3名用户是否正确
    function testTopDepositors() public {
        // 测试场景1：只有1个用户存款
        vm.prank(user1);
        bank.deposit{value: 1 ether}();
        
        (address[3] memory topAddrs, uint[3] memory amounts) = bank.getTopDepositors();
        assertEq(topAddrs[0], user1);
        assertEq(amounts[0], 1 ether);
        assertEq(topAddrs[1], address(0));
        assertEq(amounts[1], 0);
        assertEq(topAddrs[2], address(0));
        assertEq(amounts[2], 0);
        
        // 测试场景2：有2个用户存款
        vm.prank(user2);
        bank.deposit{value: 2 ether}();
        
        (topAddrs, amounts) = bank.getTopDepositors();
        assertEq(topAddrs[0], user2);
        assertEq(amounts[0], 2 ether);
        assertEq(topAddrs[1], user1);
        assertEq(amounts[1], 1 ether);
        assertEq(topAddrs[2], address(0));
        assertEq(amounts[2], 0);
        
        // 测试场景3：有3个用户存款
        vm.prank(user3);
        bank.deposit{value: 1.5 ether}();
        
        (topAddrs, amounts) = bank.getTopDepositors();
        assertEq(topAddrs[0], user2);
        assertEq(amounts[0], 2 ether);
        assertEq(topAddrs[1], user3);
        assertEq(amounts[1], 1.5 ether);
        assertEq(topAddrs[2], user1);
        assertEq(amounts[2], 1 ether);
        
        // 测试场景4：有4个用户存款，但只记录前3名
        vm.prank(user4);
        bank.deposit{value: 0.5 ether}();
        
        (topAddrs, amounts) = bank.getTopDepositors();
        assertEq(topAddrs[0], user2);
        assertEq(amounts[0], 2 ether);
        assertEq(topAddrs[1], user3);
        assertEq(amounts[1], 1.5 ether);
        assertEq(topAddrs[2], user1);
        assertEq(amounts[2], 1 ether);
        // user4不应该在前3名中
        
        // 测试场景5：同一用户多次存款
        vm.prank(user1);
        bank.deposit{value: 2 ether}();
        
        (topAddrs, amounts) = bank.getTopDepositors();
        assertEq(topAddrs[0], user1);
        assertEq(amounts[0], 3 ether); // 1 + 2 = 3 ether
        assertEq(topAddrs[1], user2);
        assertEq(amounts[1], 2 ether);
        assertEq(topAddrs[2], user3);
        assertEq(amounts[2], 1.5 ether);
    }
    
    // 测试3：检查只有管理员可取款，其他人不可以取款
    function testWithdrawOnlyAdmin() public {
        // 先存入一些ETH
        vm.prank(user1);
        bank.deposit{value: 1 ether}();
        
        // 确认合约余额
        assertEq(address(bank).balance, 1 ether);
        
        // 非管理员尝试取款，应该失败
        vm.prank(user1);
        vm.expectRevert("Only admin can withdraw");
        bank.withdraw();
        
        // 获取管理员地址
        address bankAdmin = bank.admin();
        uint256 adminBalanceBefore = bankAdmin.balance;
        
        // 使用 prank 模拟管理员调用
        vm.prank(bankAdmin);
        bank.withdraw();
        
        uint256 adminBalanceAfter = bankAdmin.balance;
        
        // 检查管理员余额增加了1 ETH
        assertEq(adminBalanceAfter - adminBalanceBefore, 1 ether);
        
        // 检查合约余额为0
        assertEq(address(bank).balance, 0);
    }
    
    // 添加receive函数以接收ETH
    receive() external payable {}
}