// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {SimpleLeverageDEX} from "../../src/simple-leverage-dex/SimpleLeverageDEX.sol";
import {MockUSDC} from "../../src/simple-leverage-dex/MockUSDC.sol";

/**
 * @title SimpleLeverageDEXTest
 * @dev 验证基于 vAMM（vK = vETH * vUSDC 恒定）的极简杠杆 DEX：
 *   - 无价格变动平仓：pnl=0、收支平衡（vAMM 反向回滚精确还原）
 *   - 做多推价上涨 → 平仓获利；做空压价下跌 → 平仓获利
 *   - 10x/5x 高杠杆 + 砸盘触发清算：亏损>80% 保证金，清算人获剩余权益奖励
 *   - 权限校验：不可清算自己、未达阈值不可清算、不可重复开仓
 *
 * 价格变动机制：由 priceMover 在同一 vAMM 开仓推动（做多推高 vUSDCAmount↑价↑，
 * 做空压低 vUSDCAmount↓价↓）。vAMM 零和：盈利方收益 = 亏损方保证金。
 */
contract SimpleLeverageDEXTest is Test {
    SimpleLeverageDEX internal dex;
    MockUSDC internal usdc;

    // 初始 vAMM：10 ETH × 30000 USDC → 价格 3000 USDC/ETH
    uint256 internal constant V_ETH = 10 ether; // 1e19
    uint256 internal constant V_USDC = 30_000 * 1e6; // 30000 USDC (6 位)

    address internal user = makeAddr("user");
    address internal priceMover = makeAddr("priceMover");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        usdc = new MockUSDC();
        dex = new SimpleLeverageDEX(V_ETH, V_USDC, address(usdc));

        // 给各账户发放 USDC 并无限授权 dex
        _fund(user, 100_000 * 1e6);
        _fund(priceMover, 100_000 * 1e6);
        _fund(liquidator, 100_000 * 1e6);
    }

    function _fund(address acct, uint256 amount) internal {
        usdc.mint(acct, amount);
        vm.startPrank(acct);
        usdc.approve(address(dex), type(uint256).max);
        vm.stopPrank();
    }

    // ===== 1. 做多：无价格变动平仓，pnl=0、收支精确平衡 =====
    function test_open_long_then_close_no_price_move() public {
        uint256 margin = 100 * 1e6;
        uint256 balBefore = usdc.balanceOf(user);

        vm.prank(user);
        dex.openPosition(margin, 2, true); // 2x 做多

        // 仓位存在，且无价格变动时 pnl == 0
        assertEq(dex.calculatePnL(user), 0, "pnl should be 0 before price move");
        // 开仓后用户已付出 margin
        assertEq(usdc.balanceOf(user), balBefore - margin, "margin deducted");

        vm.prank(user);
        dex.closePosition();

        // vAMM 精确反向回滚：用户拿回全部 margin
        assertEq(usdc.balanceOf(user), balBefore, "user should get margin back");
        (uint256 m, uint256 b, int256 p) = dex.positions(user);
        assertEq(m, 0, "position cleared: margin");
        assertEq(b, 0, "position cleared: borrowed");
        assertEq(p, 0, "position cleared: position");
    }

    // ===== 2. 做空：无价格变动平仓，pnl=0、收支精确平衡 =====
    function test_open_short_then_close_no_price_move() public {
        uint256 margin = 100 * 1e6;
        uint256 balBefore = usdc.balanceOf(user);

        vm.prank(user);
        dex.openPosition(margin, 2, false); // 2x 做空

        assertEq(dex.calculatePnL(user), 0, "pnl should be 0 before price move");
        assertEq(usdc.balanceOf(user), balBefore - margin, "margin deducted");

        vm.prank(user);
        dex.closePosition();

        assertEq(usdc.balanceOf(user), balBefore, "user should get margin back");
    }

    // ===== 3. 做多 + 价格上涨 → 平仓获利 =====
    function test_long_profit_when_price_up() public {
        uint256 margin = 100 * 1e6;
        uint256 balBefore = usdc.balanceOf(user);

        // user 3x 做多
        vm.prank(user);
        dex.openPosition(margin, 3, true);

        // priceMover 大单做多推高价格
        vm.prank(priceMover);
        dex.openPosition(5_000 * 1e6, 2, true);

        int256 pnl = dex.calculatePnL(user);
        console2.log("[long profit] pnl(USDC, 1e6=1) =", pnl / 1e6);
        assertGt(pnl, 0, "long should be in profit after price up");

        vm.prank(user);
        dex.closePosition();

        uint256 balAfter = usdc.balanceOf(user);
        // balBefore 取自开仓前；净变动 = payout - margin = pnl
        console2.log("[long profit] net gain(USDC) =", (balAfter - balBefore) / 1e6);
        assertGt(balAfter - balBefore, margin, "net gain should exceed margin (clear profit)");
    }

    // ===== 4. 做空 + 价格下跌 → 平仓获利 =====
    function test_short_profit_when_price_down() public {
        uint256 margin = 100 * 1e6;
        uint256 balBefore = usdc.balanceOf(user);

        // user 3x 做空
        vm.prank(user);
        dex.openPosition(margin, 3, false);

        // priceMover 大单做空压低价格
        vm.prank(priceMover);
        dex.openPosition(5_000 * 1e6, 2, false);

        int256 pnl = dex.calculatePnL(user);
        console2.log("[short profit] pnl(USDC, 1e6=1) =", pnl / 1e6);
        assertGt(pnl, 0, "short should be in profit after price down");

        vm.prank(user);
        dex.closePosition();

        uint256 balAfter = usdc.balanceOf(user);
        // balBefore 取自开仓前；净变动 = payout - margin = pnl
        console2.log("[short profit] net gain(USDC) =", (balAfter - balBefore) / 1e6);
        assertGt(balAfter - balBefore, margin, "net gain should exceed margin (clear profit)");
    }

    // ===== 5. 5x 做多 + 砸盘触发清算：清算人获剩余权益奖励 =====
    function test_liquidate_long_on_crash() public {
        uint256 margin = 100 * 1e6;

        // user 5x 做多（高杠杆，价格下跌 16%~20% 即落入清算区 80%~100% 亏损）
        vm.prank(user);
        dex.openPosition(margin, 5, true);

        // priceMover 做空砸盘，使 user 亏损落入 (80%, 100%) margin 区间
        vm.prank(priceMover);
        dex.openPosition(3_000 * 1e6, 1, false);

        int256 pnl = dex.calculatePnL(user);
        int256 threshold = -int256(margin * dex.LIQUIDATION_THRESHOLD() / 100);
        console2.log("[liquidate] pnl(USDC) =", pnl / 1e6);
        console2.log("[liquidate] threshold(USDC) =", threshold / 1e6);
        assertLt(pnl, threshold, "should be liquidatable (loss > 80% margin)");

        uint256 liqBalBefore = usdc.balanceOf(liquidator);

        vm.prank(liquidator);
        dex.liquidatePosition(user);

        uint256 reward = usdc.balanceOf(liquidator) - liqBalBefore;
        console2.log("[liquidate] reward(USDC) =", reward / 1e6);
        // 剩余权益 = margin + pnl，落在 (0, 20% margin)
        assertGt(reward, 0, "liquidator should get positive reward");
        assertLt(reward, margin / 5, "reward < 20% margin (loss > 80%)");

        (, , int256 posAfter) = dex.positions(user);
        assertEq(posAfter, 0, "position should be deleted after liquidation");
    }

    // ===== 6. 不可清算自己 =====
    function test_cannot_liquidate_self() public {
        vm.prank(user);
        dex.openPosition(100 * 1e6, 2, true);

        vm.prank(user);
        vm.expectRevert(bytes("cannot liquidate self"));
        dex.liquidatePosition(user);
    }

    // ===== 7. 未达清算阈值不可清算 =====
    function test_cannot_liquidate_when_not_liquidatable() public {
        // user 2x 做多，价格小幅上涨 → 反而盈利，远未达清算
        vm.prank(user);
        dex.openPosition(100 * 1e6, 2, true);

        vm.prank(priceMover);
        dex.openPosition(1_000 * 1e6, 1, true); // 推高价格，user 盈利

        vm.prank(liquidator);
        vm.expectRevert(bytes("not liquidatable"));
        dex.liquidatePosition(user);
    }

    // ===== 8. 不可重复开仓 =====
    function test_cannot_open_twice() public {
        vm.prank(user);
        dex.openPosition(100 * 1e6, 2, true);

        vm.prank(user);
        vm.expectRevert(bytes("Position already open"));
        dex.openPosition(50 * 1e6, 2, false);
    }
}
