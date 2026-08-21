// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {OptionToken} from "../../src/call-option-token/OptionToken.sol";
import {OptionSwapPool} from "../../src/call-option-token/OptionSwapPool.sol";
import {MockUSDT} from "../../src/call-option-token/MockUSDT.sol";

/**
 * @title CallOptionTokenTest
 * @dev 看涨期权 Token 综合测试（需求 1~5）
 *
 * 覆盖：
 *   - 部署 / 构造校验
 *   - 需求 2：项目方发行（1:1 ETH 铸期权）
 *   - 需求 3：AMM 交易对（流动性 + swap 双向 + 滑点）
 *   - 需求 4：到期日当天行权（销毁期权、付 USDT、释放 ETH）+ 窗口边界
 *   - 需求 5：过期赎回 + 销毁所有剩余期权
 *
 * 运行：forge test --match-path test/call-option-token/CallOptionToken.t.sol -vvv
 */
contract CallOptionTokenTest is Test {
    OptionToken public opt;
    OptionSwapPool public pool;
    MockUSDT public usdt;

    address public owner;     // 项目方（部署者）
    address public alice;     // 用户
    address public bob;       // 用户

    // 行权价 3000 USDT / 1 ETH，到期日 = 部署后 30 天
    uint256 public constant STRIKE_PRICE = 3000 * 1e6; // USDT 6 位精度
    uint256 public constant EXPIRY_DELAY = 30 days;
    uint256 public expiryDate;

    /// @dev 辅助：1 行权单位（1 ETH 对应的期权）需支付的 USDT
    uint256 public constant STRIKE_PER_ETH = STRIKE_PRICE; // 3000e6

    function setUp() public {
        owner = address(this);          // 测试合约自身作为项目方
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdt = new MockUSDT();
        expiryDate = block.timestamp + EXPIRY_DELAY;
        opt = new OptionToken(address(usdt), STRIKE_PRICE, expiryDate);
        pool = new OptionSwapPool(address(opt), address(usdt));

        // 给用户发放 USDT（用于购买期权 / 行权）
        usdt.mint(alice, 1_000_000 * 1e6);
        usdt.mint(bob, 1_000_000 * 1e6);
        // 项目方也持有 USDT（用于在 AMM 注入流动性）
        usdt.mint(owner, 1_000_000 * 1e6);

        // 给用户发放 ETH（用于行权调用 / 非 owner 发行测试等）
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ==================== 部署测试 ====================

    function test_Deployment() public view {
        assertEq(address(opt.usdt()), address(usdt));
        assertEq(opt.strikePrice(), STRIKE_PRICE);
        assertEq(opt.expiryDate(), expiryDate);
        assertFalse(opt.expired());
        assertEq(opt.owner(), owner);
        assertEq(opt.name(), "Call Option Token");
        assertEq(opt.symbol(), "COT");
        assertEq(opt.decimals(), 18);
        assertEq(opt.collateral(), 0);
    }

    function test_Deployment_ZeroUsdt_Reverts() public {
        vm.expectRevert("COT: zero usdt");
        new OptionToken(address(0), STRIKE_PRICE, expiryDate);
    }

    function test_Deployment_ZeroStrike_Reverts() public {
        vm.expectRevert("COT: zero strike");
        new OptionToken(address(usdt), 0, expiryDate);
    }

    function test_Deployment_PastExpiry_Reverts() public {
        vm.expectRevert("COT: past expiry");
        new OptionToken(address(usdt), STRIKE_PRICE, block.timestamp);
    }

    // ==================== 需求 2：发行（项目方） ====================

    function test_Issue_MintsOneToOne() public {
        uint256 ethBefore = address(this).balance;
        opt.issue{value: 10 ether}();

        assertEq(opt.balanceOf(owner), 10 ether);
        assertEq(opt.totalSupply(), 10 ether);
        assertEq(opt.collateral(), 10 ether);
        assertEq(address(this).balance, ethBefore - 10 ether);
    }

    function test_Issue_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit OptionToken.Issued(owner, 5 ether);
        opt.issue{value: 5 ether}();
    }

    function test_Issue_MultipleAccumulates() public {
        opt.issue{value: 3 ether}();
        opt.issue{value: 7 ether}();
        assertEq(opt.balanceOf(owner), 10 ether);
        assertEq(opt.collateral(), 10 ether);
    }

    function test_Issue_NotOwner_Reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        opt.issue{value: 1 ether}();
    }

    function test_Issue_ZeroEth_Reverts() public {
        vm.expectRevert("COT: zero eth");
        opt.issue();
    }

    function test_Issue_AfterExpired_Reverts() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate + 1 days);
        opt.expireAndReclaim();
        vm.expectRevert("COT: expired");
        opt.issue{value: 1 ether}();
    }

    // ==================== 需求 3：AMM 交易对 ====================

    /// @dev 项目方注入流动性：1 期权 = 50 USDT（较低价格），创建交易对
    function _seedLiquidity(uint256 optAmount, uint256 usdtAmount) internal {
        opt.approve(address(pool), optAmount);
        usdt.approve(address(pool), usdtAmount);
        pool.addLiquidity(optAmount, usdtAmount);
    }

    function test_AddLiquidity_UpdatesReserves() public {
        opt.issue{value: 1000 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6); // 1 期权 = 50 USDT

        assertEq(pool.reserveOption(), 1000 ether);
        assertEq(pool.reserveUsdt(), 50_000 * 1e6);
        assertEq(opt.balanceOf(address(pool)), 1000 ether);
        assertEq(usdt.balanceOf(address(pool)), 50_000 * 1e6);
    }

    function test_AddLiquidity_NotOwner_Reverts() public {
        opt.issue{value: 10 ether}();
        opt.transfer(alice, 10 ether);
        usdt.mint(alice, 500 * 1e6);

        vm.startPrank(alice);
        opt.approve(address(pool), 10 ether);
        usdt.approve(address(pool), 500 * 1e6);
        vm.expectRevert("OSP: not owner");
        pool.addLiquidity(10 ether, 500 * 1e6);
        vm.stopPrank();
    }

    function test_GetAmountOut_Correct() public view {
        // 1000 USDT in, reserves 50000 USDT / 1000 期权
        uint256 amountIn = 1000 * 1e6;
        uint256 reserveIn = 50_000 * 1e6;
        uint256 reserveOut = 1000 ether;
        uint256 withFee = amountIn * 997;
        uint256 expected = (withFee * reserveOut) / (reserveIn * 1000 + withFee);

        uint256 out = pool.getAmountOut(amountIn, reserveIn, reserveOut);
        assertEq(out, expected);
        assertGt(out, 0);
    }

    function test_SwapUSDTForOption_UserBuysOption() public {
        opt.issue{value: 1000 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6);

        uint256 optBefore = opt.balanceOf(alice);
        uint256 usdtIn = 100 * 1e6;
        uint256 expectedOut = pool.quoteUSDTForOption(usdtIn);

        vm.startPrank(alice);
        usdt.approve(address(pool), usdtIn);
        uint256 out = pool.swapUSDTForOption(usdtIn, expectedOut);
        vm.stopPrank();

        assertEq(out, expectedOut);
        assertEq(opt.balanceOf(alice), optBefore + expectedOut);
        assertEq(pool.reserveUsdt(), 50_000 * 1e6 + usdtIn);
        assertEq(pool.reserveOption(), 1000 ether - expectedOut);
    }

    function test_SwapUSDTForOption_Slippage_Reverts() public {
        opt.issue{value: 1000 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6);

        vm.startPrank(alice);
        usdt.approve(address(pool), 100 * 1e6);
        // 要求过高输出 -> revert
        vm.expectRevert("OSP: slippage");
        pool.swapUSDTForOption(100 * 1e6, type(uint256).max);
        vm.stopPrank();
    }

    function test_SwapOptionForUSDT_Reverse() public {
        // 发行 1010 期权：1000 注入池，10 留给 owner 转给 alice 用以反向卖出
        opt.issue{value: 1010 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6);

        // 给 alice 一些期权（从 owner 转入），她卖出换 USDT
        opt.transfer(alice, 10 ether);
        uint256 usdtBefore = usdt.balanceOf(alice);
        uint256 expectedOut = pool.quoteOptionForUSDT(10 ether);

        vm.startPrank(alice);
        opt.approve(address(pool), 10 ether);
        uint256 out = pool.swapOptionForUSDT(10 ether, expectedOut);
        vm.stopPrank();

        assertEq(out, expectedOut);
        assertEq(usdt.balanceOf(alice), usdtBefore + expectedOut);
        assertEq(pool.reserveOption(), 1000 ether + 10 ether);
        assertEq(pool.reserveUsdt(), 50_000 * 1e6 - expectedOut);
    }

    function test_RemoveLiquidity_OwnerRecovers() public {
        opt.issue{value: 1000 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6);

        uint256 optBefore = opt.balanceOf(owner);
        uint256 usdtBefore = usdt.balanceOf(owner);
        pool.removeLiquidity();

        assertEq(pool.reserveOption(), 0);
        assertEq(pool.reserveUsdt(), 0);
        assertEq(opt.balanceOf(owner), optBefore + 1000 ether);
        assertEq(usdt.balanceOf(owner), usdtBefore + 50_000 * 1e6);
    }

    function test_RemoveLiquidity_NotOwner_Reverts() public {
        opt.issue{value: 1000 ether}();
        _seedLiquidity(1000 ether, 50_000 * 1e6);

        vm.prank(alice);
        vm.expectRevert("OSP: not owner");
        pool.removeLiquidity();
    }

    // ==================== 需求 4：行权（到期日当天） ====================

    /// @dev 完整链路：发行 → AMM 买入 → 到期日行权
    function test_Exercise_FullFlow() public {
        opt.issue{value: 100 ether}();
        _seedLiquidity(100 ether, 5_000 * 1e6); // 1 期权 = 50 USDT（低价）

        // alice 用 5000 USDT 买光池中期权 ≈ 100 期权（略少，含手续费）
        vm.startPrank(alice);
        usdt.approve(address(pool), 5_000 * 1e6);
        uint256 bought = pool.swapUSDTForOption(5_000 * 1e6, 0);
        vm.stopPrank();
        assertGt(bought, 0);

        // 到期日当天行权
        vm.warp(expiryDate);
        uint256 usdtCost = opt.getExerciseCost(bought); // = bought/1e18 * 3000e6
        uint256 ethBefore = alice.balance;
        uint256 ownerUsdtBefore = usdt.balanceOf(owner);

        vm.startPrank(alice);
        usdt.approve(address(opt), usdtCost);
        opt.exercise(bought);
        vm.stopPrank();

        // 销毁期权、释放 ETH、USDT 转给 owner
        assertEq(opt.balanceOf(alice), 0);
        assertEq(alice.balance - ethBefore, bought); // 1:1 ETH
        assertEq(opt.collateral(), 100 ether - bought);
        assertEq(usdt.balanceOf(owner) - ownerUsdtBefore, usdtCost); // owner 收到行权 USDT
    }

    function test_Exercise_AtExpiryDate_Success() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);

        vm.warp(expiryDate);
        uint256 cost = opt.getExerciseCost(1 ether); // 3000e6
        uint256 ethBefore = alice.balance;

        vm.startPrank(alice);
        usdt.approve(address(opt), cost);
        opt.exercise(1 ether);
        vm.stopPrank();

        assertEq(opt.balanceOf(alice), 0);
        assertEq(opt.totalSupply(), 0);
        assertEq(opt.collateral(), 0);
        assertEq(alice.balance - ethBefore, 1 ether); // 1:1 释放 ETH
    }

    function test_Exercise_BeforeExpiry_Reverts() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);

        vm.warp(expiryDate - 1);
        vm.prank(alice);
        vm.expectRevert("COT: not yet expiry");
        opt.exercise(1 ether);
    }

    function test_Exercise_LastSecondOfWindow_Success() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);

        // 窗口右端点 - 1 秒仍可行权
        vm.warp(expiryDate + 1 days - 1);
        vm.startPrank(alice);
        usdt.approve(address(opt), opt.getExerciseCost(1 ether));
        opt.exercise(1 ether);
        vm.stopPrank();

        assertEq(opt.balanceOf(alice), 0);
    }

    function test_Exercise_AfterWindow_Reverts() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);

        vm.warp(expiryDate + 1 days);
        vm.prank(alice);
        vm.expectRevert("COT: exercise window closed");
        opt.exercise(1 ether);
    }

    function test_Exercise_ZeroAmount_Reverts() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate);
        vm.prank(alice);
        vm.expectRevert("COT: zero amount");
        opt.exercise(0);
    }

    function test_Exercise_InsufficientApproval_Reverts() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);

        vm.warp(expiryDate);
        vm.startPrank(alice);
        // 不 approve，USDT 不足
        vm.expectRevert();
        opt.exercise(1 ether);
        vm.stopPrank();
    }

    function test_Exercise_PartialAndMultipleUsers() public {
        opt.issue{value: 10 ether}();
        opt.transfer(alice, 5 ether);
        opt.transfer(bob, 5 ether);

        vm.warp(expiryDate);
        uint256 cost5 = opt.getExerciseCost(5 ether); // 15000e6
        uint256 ownerUsdtBefore = usdt.balanceOf(owner);
        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore = bob.balance;

        vm.startPrank(alice);
        usdt.approve(address(opt), cost5);
        opt.exercise(5 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        usdt.approve(address(opt), cost5);
        opt.exercise(5 ether);
        vm.stopPrank();

        assertEq(opt.totalSupply(), 0);
        assertEq(opt.collateral(), 0);
        assertEq(alice.balance - aliceEthBefore, 5 ether);
        assertEq(bob.balance - bobEthBefore, 5 ether);
        assertEq(usdt.balanceOf(owner) - ownerUsdtBefore, cost5 * 2); // 30000e6
    }

    function test_GetExerciseCost_Calculation() public view {
        // 1 ETH 期权 -> 3000 USDT
        assertEq(opt.getExerciseCost(1 ether), 3000 * 1e6);
        // 0.5 ETH 期权 -> 1500 USDT
        assertEq(opt.getExerciseCost(0.5 ether), 1500 * 1e6);
        // 2 ETH 期权 -> 6000 USDT
        assertEq(opt.getExerciseCost(2 ether), 6000 * 1e6);
    }

    function test_IsExerciseWindow() public {
        assertFalse(opt.isExerciseWindow());
        vm.warp(expiryDate - 1);
        assertFalse(opt.isExerciseWindow());
        vm.warp(expiryDate);
        assertTrue(opt.isExerciseWindow());
        vm.warp(expiryDate + 1 days - 1);
        assertTrue(opt.isExerciseWindow());
        vm.warp(expiryDate + 1 days);
        assertFalse(opt.isExerciseWindow());
    }

    function test_IsPastWindow() public {
        assertFalse(opt.isPastWindow());
        vm.warp(expiryDate);
        assertFalse(opt.isPastWindow());
        vm.warp(expiryDate + 1 days);
        assertTrue(opt.isPastWindow());
    }

    // ==================== 需求 5：过期销毁 / 赎回（项目方） ====================

    function test_ExpireAndReclaim_OwnerGetsEth() public {
        opt.issue{value: 10 ether}();
        // alice 持有部分期权未行权
        opt.transfer(alice, 4 ether);

        vm.warp(expiryDate + 1 days);
        uint256 ownerBefore = owner.balance;
        opt.expireAndReclaim();

        assertTrue(opt.expired());
        // 合约剩余 ETH = 10 ETH（无人行权）
        assertEq(opt.collateral(), 0);
        assertEq(owner.balance, ownerBefore + 10 ether);
    }

    function test_ExpireAndReclaim_EmitsEvent() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate + 1 days);
        vm.expectEmit(true, false, false, true);
        emit OptionToken.ExpiredAndReclaimed(owner, 1 ether);
        opt.expireAndReclaim();
    }

    function test_ExpireAndReclaim_WindowOpen_Reverts() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate); // 还在行权窗口内
        vm.expectRevert("COT: window still open");
        opt.expireAndReclaim();
    }

    function test_ExpireAndReclaim_NotOwner_Reverts() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate + 1 days);
        vm.prank(alice);
        vm.expectRevert();
        opt.expireAndReclaim();
    }

    function test_ExpireAndReclaim_Twice_Reverts() public {
        opt.issue{value: 1 ether}();
        vm.warp(expiryDate + 1 days);
        opt.expireAndReclaim();
        vm.expectRevert("COT: already expired");
        opt.expireAndReclaim();
    }

    function test_ExpireAndReclaim_AfterPartialExercise() public {
        opt.issue{value: 10 ether}();
        opt.transfer(alice, 3 ether);

        // alice 行权 3 ETH（剩 7 ETH 抵押、7 期权未销毁）
        vm.warp(expiryDate);
        vm.startPrank(alice);
        usdt.approve(address(opt), opt.getExerciseCost(3 ether));
        opt.exercise(3 ether);
        vm.stopPrank();

        // 过期后 owner 赎回剩余 7 ETH
        vm.warp(expiryDate + 1 days);
        uint256 ownerBefore = owner.balance;
        opt.expireAndReclaim();

        assertEq(opt.collateral(), 0);
        assertEq(owner.balance, ownerBefore + 7 ether);
        assertTrue(opt.expired());
    }

    function test_BurnFrom_BeforeExpired_Reverts() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);
        vm.expectRevert("COT: not expired yet");
        opt.burnFrom(alice, 1 ether);
    }

    function test_BurnFrom_AfterExpired_BurnsAnyAccount() public {
        opt.issue{value: 10 ether}();
        opt.transfer(alice, 4 ether);
        opt.transfer(bob, 4 ether);

        vm.warp(expiryDate + 1 days);
        opt.expireAndReclaim(); // owner 先赎回 ETH

        // 销毁 alice、bob 手中剩余期权（“销毁所有”）
        opt.burnFrom(alice, 4 ether);
        opt.burnFrom(bob, 4 ether);

        assertEq(opt.balanceOf(alice), 0);
        assertEq(opt.balanceOf(bob), 0);
        assertEq(opt.totalSupply(), 2 ether); // owner 自持 2 ether 未销毁（演示）
    }

    function test_BurnFrom_NotOwner_Reverts() public {
        opt.issue{value: 1 ether}();
        opt.transfer(alice, 1 ether);
        vm.warp(expiryDate + 1 days);
        opt.expireAndReclaim();

        vm.prank(alice);
        vm.expectRevert();
        opt.burnFrom(alice, 1 ether);
    }

    function test_AfterExpired_ExerciseAndIssue_Revert() public {
        opt.issue{value: 2 ether}();

        vm.warp(expiryDate + 1 days);
        opt.expireAndReclaim();

        // 过期后行权被禁（窗口已过 -> exercise window closed 先触发）
        opt.transfer(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert("COT: exercise window closed");
        opt.exercise(1 ether);

        // 过期后发行被禁
        vm.expectRevert("COT: expired");
        opt.issue{value: 1 ether}();
    }

    // ==================== 端到端 + 边界 ====================

    /// @dev 完整生命周期：发行 → AMM 买入 → 部分行权 → 过期清理池 → 销毁剩余 → 赎回
    function test_FullLifecycle() public {
        // 1. 项目方发行 100 ETH 等额期权
        opt.issue{value: 100 ether}();
        assertEq(opt.collateral(), 100 ether);

        // 2. 创建 AMM 交易对：100 期权 / 5000 USDT（1 期权 = 50 USDT 低价）
        _seedLiquidity(100 ether, 5_000 * 1e6);

        // 3. alice 用 2500 USDT 买入约 33 期权
        vm.startPrank(alice);
        usdt.approve(address(pool), 2_500 * 1e6);
        uint256 bought = pool.swapUSDTForOption(2_500 * 1e6, 0);
        vm.stopPrank();
        assertGt(bought, 30 ether);

        // 4. 到期日 alice 行权：付 strike USDT 换 ETH
        vm.warp(expiryDate);
        uint256 cost = opt.getExerciseCost(bought);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        usdt.approve(address(opt), cost);
        opt.exercise(bought);
        vm.stopPrank();
        assertEq(opt.balanceOf(alice), 0);
        assertEq(alice.balance - ethBefore, bought); // 1:1 释放 ETH

        // 5. 过期：项目方先抽回 AMM 池内剩余两币，再赎回 ETH，最后销毁剩余期权
        //    （burnFrom 要求 expired=true，故须在 expireAndReclaim 之后）
        vm.warp(expiryDate + 1 days);
        pool.removeLiquidity();
        opt.expireAndReclaim();

        // 销毁项目方自持（含池退回）+ 池中残余期权（“销毁所有”）
        uint256 ownerSelf = opt.balanceOf(owner);
        if (ownerSelf > 0) opt.burnFrom(owner, ownerSelf);
        uint256 poolSelf = opt.balanceOf(address(pool));
        if (poolSelf > 0) opt.burnFrom(address(pool), poolSelf);

        // 6. 终态：合约无 ETH、无期权流通
        assertEq(opt.collateral(), 0);
        assertEq(opt.totalSupply(), 0);
        assertTrue(opt.expired());
    }

    function test_Exercise_AllCollateral_DrainsContract() public {
        opt.issue{value: 5 ether}();
        opt.transfer(alice, 5 ether);

        vm.warp(expiryDate);
        vm.startPrank(alice);
        usdt.approve(address(opt), opt.getExerciseCost(5 ether));
        opt.exercise(5 ether);
        vm.stopPrank();

        assertEq(opt.collateral(), 0);
        assertEq(address(opt).balance, 0);
    }

    receive() external payable {}
}
