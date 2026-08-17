// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {TokenA} from "../../src/flash-swap/TokenA.sol";
import {TokenB} from "../../src/flash-swap/TokenB.sol";
import {FlashSwapArbitrage} from "../../src/flash-swap/FlashSwapArbitrage.sol";

// 测试命令：forge test --match-path test/flash-swap/FlashSwapArbitrage.t.sol -vvv
//
// 场景：两个独立的 Uniswap V2（两个 Factory），各自创建 TokenA/TokenB 交易对
//   PoolA（FactoryA）：10000 TokenA / 10000 TokenB  -> 价格 1:1
//   PoolB（FactoryB）：10000 TokenA / 20000 TokenB  -> 价格 1:2（TokenA 在 PoolB 更值钱）
// 套利：从 PoolA 闪电借 TokenA -> 在 PoolB 兑成 TokenB -> 用 TokenB 偿还 PoolA，剩余为利润
contract FlashSwapArbitrageTest is Test {
    TokenA public tokenA;
    TokenB public tokenB;
    IUniswapV2Factory public factoryA; // 第一个 Uniswap
    IUniswapV2Factory public factoryB; // 第二个 Uniswap
    IUniswapV2Pair public pairA; // PoolA
    IUniswapV2Pair public pairB; // PoolB
    FlashSwapArbitrage public arbitrage;

    address public alice = makeAddr("alice");

    // 流动性配置
    uint256 constant POOL_A_LIQ_TOKENA = 10_000e18;
    uint256 constant POOL_A_LIQ_TOKENB = 10_000e18;
    uint256 constant POOL_B_LIQ_TOKENA = 10_000e18;
    uint256 constant POOL_B_LIQ_TOKENB = 20_000e18;

    function setUp() public {
        tokenA = new TokenA();
        tokenB = new TokenB();

        factoryA = IUniswapV2Factory(_deployFactory());
        factoryB = IUniswapV2Factory(_deployFactory());

        pairA = IUniswapV2Pair(factoryA.createPair(address(tokenA), address(tokenB)));
        pairB = IUniswapV2Pair(factoryB.createPair(address(tokenA), address(tokenB)));

        // 添加错配流动性制造价差
        _addLiquidity(address(pairA), POOL_A_LIQ_TOKENA, POOL_A_LIQ_TOKENB);
        _addLiquidity(address(pairB), POOL_B_LIQ_TOKENA, POOL_B_LIQ_TOKENB);

        arbitrage = new FlashSwapArbitrage(address(tokenA), address(tokenB), address(pairA), address(pairB));
    }

    /// @dev 官方 UniswapV2Factory 为 Solidity 0.5.16，与 0.8.x 测试无法直接互相 import，
    ///      通过 vm.deployCode 从 artifact 跨版本部署（artifact 由 V2Core.sol 锚点编译生成）
    function _deployFactory() internal returns (address) {
        return vm.deployCode("UniswapV2Factory.sol", abi.encode(address(this)));
    }

    /// @dev 直接向 Pair 转入两种代币后 mint LP（无需 Router）
    function _addLiquidity(address pair, uint256 amountA, uint256 amountB) internal {
        tokenA.transfer(pair, amountA);
        tokenB.transfer(pair, amountB);
        IUniswapV2Pair(pair).mint(address(this));
    }

    /// @dev 返回 (token 的储备, 另一侧代币的储备)
    function _reserves(address pair, address token) internal view returns (uint256, uint256) {
        (uint256 r0, uint256 r1,) = IUniswapV2Pair(pair).getReserves();
        return IUniswapV2Pair(pair).token0() == token ? (r0, r1) : (r1, r0);
    }

    /// @dev TokenA 相对 TokenB 的价格（用储备比表示，放大 1e18）
    function _priceOfTokenA(address pair) internal view returns (uint256) {
        (uint256 rA, uint256 rB) = _reserves(pair, address(tokenA));
        return (rB * 1e18) / rA;
    }

    // ========== 套利盈利测试 ==========

    function test_Arbitrage_MakesProfit() public {
        uint256 borrowAmount = 100e18;

        uint256 priceA_Before = _priceOfTokenA(address(pairA)); // 1e18
        uint256 priceB_Before = _priceOfTokenA(address(pairB)); // 2e18

        uint256 balBefore = tokenB.balanceOf(address(arbitrage));
        assertEq(balBefore, 0, "no initial balance");

        // 发起闪电套利
        arbitrage.startArbitrage(borrowAmount);

        uint256 profit = tokenB.balanceOf(address(arbitrage));
        assertGt(profit, 0, "should make profit");

        // 期望利润 = PoolB 兑出数量 - PoolA 偿还数量（UniswapV2 标准公式）
        uint256 expectedOut =
            (borrowAmount * 997 * POOL_B_LIQ_TOKENB) / (POOL_B_LIQ_TOKENA * 1000 + borrowAmount * 997);
        uint256 expectedRepay =
            (POOL_A_LIQ_TOKENB * borrowAmount * 1000) / ((POOL_A_LIQ_TOKENA - borrowAmount) * 997) + 1;
        assertApproxEqRel(profit, expectedOut - expectedRepay, 1e15); // 0.1% 容差

        console.log("profit (TokenB):", profit / 1e18, "e18");

        // 两池价格收敛：PoolA 中 TokenA 变贵，PoolB 中 TokenA 变便宜
        uint256 priceA_After = _priceOfTokenA(address(pairA));
        uint256 priceB_After = _priceOfTokenA(address(pairB));
        assertGt(priceA_After, priceA_Before, "TokenA should be pricier in PoolA");
        assertLt(priceB_After, priceB_Before, "TokenA should be cheaper in PoolB");
        assertLt(priceA_After, priceB_After, "not fully converged but gap narrowed");
    }

    // ========== 无利润时回滚测试 ==========

    function test_RevertWhen_NoProfit() public {
        // 独立搭建价差极小（0.2%）的两池：手续费（约 0.6%）吞掉全部利润
        IUniswapV2Factory fA = IUniswapV2Factory(_deployFactory());
        IUniswapV2Factory fB = IUniswapV2Factory(_deployFactory());
        IUniswapV2Pair pA = IUniswapV2Pair(fA.createPair(address(tokenA), address(tokenB)));
        IUniswapV2Pair pB = IUniswapV2Pair(fB.createPair(address(tokenA), address(tokenB)));
        _addLiquidity(address(pA), 10_000e18, 10_000e18);
        _addLiquidity(address(pB), 10_000e18, 10_020e18); // 仅 0.2% 价差

        FlashSwapArbitrage arb =
            new FlashSwapArbitrage(address(tokenA), address(tokenB), address(pA), address(pB));

        vm.expectRevert("FlashSwap: NO_PROFIT");
        arb.startArbitrage(10e18);
    }

    // ========== 利润提取测试 ==========

    function test_Withdraw() public {
        arbitrage.startArbitrage(100e18);
        uint256 profit = tokenB.balanceOf(address(arbitrage));
        assertGt(profit, 0);

        uint256 ownerBefore = tokenB.balanceOf(address(this));
        arbitrage.withdraw(address(tokenB));

        assertEq(tokenB.balanceOf(address(arbitrage)), 0);
        assertEq(tokenB.balanceOf(address(this)) - ownerBefore, profit);
    }

    function test_Withdraw_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("FlashSwap: NOT_OWNER");
        arbitrage.withdraw(address(tokenB));
    }

    // ========== 回调鉴权测试 ==========

    function test_RevertWhen_UnauthorizedCallback() public {
        vm.prank(alice);
        vm.expectRevert("FlashSwap: UNAUTHORIZED");
        arbitrage.uniswapV2Call(alice, 1e18, 0, "");
    }
}
