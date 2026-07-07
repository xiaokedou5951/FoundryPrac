// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {TokenBank} from "../../src/TokenBank.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// 测试命令：forge test test/bank/TokenBank.t.sol -vvv
contract TokenBankTest is Test {
    using SafeERC20 for IERC20;

    TokenBank public bank;
    IERC20 public token;
    address public alice;
    address public bob;
    address public mike;
    uint256 public mainnetForkId;
    function setUp() public {
        uint forkBlock = 25_477_500;
        mainnetForkId = vm.createSelectFork(vm.rpcUrl("mainnet"), forkBlock);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        mike = address(0x10);

        // 打印这三个地址
        console.log(alice, bob, mike);

        // 构建合约
        token = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        bank = new TokenBank(address(token));
    }

    function test_Deposit() public {
        vm.selectFork(mainnetForkId);
        assertEq(vm.activeFork(), mainnetForkId);

        // 调用token.approve(tokenBank地址, 金额)来授权TokenBank合约
        vm.prank(alice);
        token.forceApprove(address(bank), 1 ether);

        // 作弊修改token代币中alice余额
        deal(address(token), alice, 1 ether);
        
        // 调用bank.deposit()来存款
        vm.prank(alice);
        bank.deposit(0.5 gwei);
        
        // 检查bank合约中alice的余额是否为0.5 gwei
        assertEq(bank.balanceOf(alice), 0.5 gwei);
    }

    function test_Withdraw() public {
        vm.selectFork(mainnetForkId);
        assertEq(vm.activeFork(), mainnetForkId);

        // 先存款：授权 + 设置余额 + 存入 0.5 gwei
        vm.prank(alice);
        token.forceApprove(address(bank), 1 ether);

        deal(address(token), alice, 1 ether);

        vm.prank(alice);
        bank.deposit(0.5 gwei);

        // 存款后：bank 记录 0.5 gwei，alice token 余额减少 0.5 gwei
        assertEq(bank.balanceOf(alice), 0.5 gwei);
        assertEq(token.balanceOf(alice), 1 ether - 0.5 gwei);
        assertEq(token.balanceOf(address(bank)), 0.5 gwei);

        // 提取 0 金额，应该 revert
        vm.prank(alice);
        vm.expectRevert("TokenBank: withdraw amount must be greater than zero");
        bank.withdraw(0);

        // 提取超过存款余额，应该 revert
        vm.prank(alice);
        vm.expectRevert("TokenBank: insufficient deposit balance");
        bank.withdraw(0.6 gwei);

        // 正常提取 0.3 gwei
        vm.prank(alice);
        bank.withdraw(0.3 gwei);

        // 提取后：bank 记录减少 0.3 gwei，alice token 余额恢复 0.3 gwei
        assertEq(bank.balanceOf(alice), 0.5 gwei - 0.3 gwei);
        assertEq(token.balanceOf(alice), 1 ether - 0.5 gwei + 0.3 gwei);
        assertEq(token.balanceOf(address(bank)), 0.5 gwei - 0.3 gwei);
    }




}
