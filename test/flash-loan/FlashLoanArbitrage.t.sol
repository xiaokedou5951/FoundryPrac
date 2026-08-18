// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {TokenC} from "../../src/flash-loan/TokenC.sol";
import {FlashLoanArbitrage} from "../../src/flash-loan/FlashLoanArbitrage.sol";

/// @dev 最小 WETH9 接口（fork 主网时直接绑定地址）
interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

/// @dev Uniswap V2 Factory/Router 最小接口（跨版本外部调用）
interface IUniV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address);
}
interface IUniV2Router {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/**
 * @title FlashLoanArbitrageTest
 * @dev Fork 主网：部署两套官方 Uniswap V2 + TokenC，制造 10 倍价差，
 *      在一笔交易内完成 Aave V3 闪电贷 → 双池兑换 → 还款套利。
 */
contract FlashLoanArbitrageTest is Test {
    // 主网地址（fork 时直接用）
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    TokenC internal tokenC;
    IUniV2Factory internal factoryC; // PoolC 所在 Uniswap #1
    IUniV2Factory internal factoryE; // PoolE 所在 Uniswap #2
    IUniV2Router internal routerC;
    IUniV2Router internal routerE;
    FlashLoanArbitrage internal arb;

    function setUp() public {
        // Fork 主网（不固定区块号，避免归档节点限制）
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        // 用 vm.deployCode 跨版本部署官方 V2 合约（0.5.16 / 0.6.6）
        factoryC = IUniV2Factory(_deploy("UniswapV2Factory.sol", abi.encode(address(this))));
        factoryE = IUniV2Factory(_deploy("UniswapV2Factory.sol", abi.encode(address(this))));
        routerC = IUniV2Router(_deploy("UniswapV2Router02.sol", abi.encode(address(factoryC), WETH)));
        routerE = IUniV2Router(_deploy("UniswapV2Router02.sol", abi.encode(address(factoryE), WETH)));

        // 部署自定义 ERC20（本合约持有全部供应量）
        tokenC = new TokenC();

        // 准备流动性资金：把 ETH 兑换为主网 WETH（200 WETH）
        // 注：fork 主网时测试合约地址可能已有少量 WETH 预存余额，故用 assertGe
        vm.deal(address(this), 300 ether);
        IWETH(WETH).deposit{value: 200 ether}();
        assertGe(IWETH(WETH).balanceOf(address(this)), 200 ether, "WETH deposit failed");

        // 创建两个价差池
        _setupPoolC(); // PoolC：TokenC 便宜（1 WETH ≈ 10,000 TKC）
        _setupPoolE(); // PoolE：TokenC 昂贵（1 WETH ≈ 1,000 TKC）

        // 部署套利合约
        arb = new FlashLoanArbitrage(WETH, address(tokenC), address(routerC), address(routerE));
    }

    /// @dev PoolC：1,000,000 TKC + 100 WETH（TokenC 便宜）
    function _setupPoolC() internal {
        factoryC.createPair(address(tokenC), WETH);
        tokenC.approve(address(routerC), 1_000_000 ether);
        IWETH(WETH).approve(address(routerC), 100 ether);
        routerC.addLiquidity(
            address(tokenC),
            WETH,
            1_000_000 ether,
            100 ether,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    /// @dev PoolE：100,000 TKC + 100 WETH（TokenC 昂贵 10 倍）
    function _setupPoolE() internal {
        factoryE.createPair(address(tokenC), WETH);
        tokenC.approve(address(routerE), 100_000 ether);
        IWETH(WETH).approve(address(routerE), 100 ether);
        routerE.addLiquidity(
            address(tokenC),
            WETH,
            100_000 ether,
            100 ether,
            0,
            0,
            address(this),
            block.timestamp
        );
    }

    function test_flashLoanArbitrage_profitPositive() public {
        uint256 borrowAmount = 5 ether;

        // 套利合约初始 WETH 余额应为 0
        assertEq(IWETH(WETH).balanceOf(address(arb)), 0, "arb should start with 0 WETH");

        // 用 Router getAmountsOut 预估 minOut，留 1% 滑点余量
        address[] memory pathToC = new address[](2);
        pathToC[0] = WETH;
        pathToC[1] = address(tokenC);
        uint256[] memory outC = routerC.getAmountsOut(borrowAmount, pathToC);
        uint256 minTokenCOut = outC[1] * 99 / 100;

        address[] memory pathToWeth = new address[](2);
        pathToWeth[0] = address(tokenC);
        pathToWeth[1] = WETH;
        uint256[] memory outE = routerE.getAmountsOut(minTokenCOut, pathToWeth);
        uint256 minWethOut = outE[1] * 99 / 100;

        // 一笔交易完成：闪电贷 → PoolC 兑换 → PoolE 兑换 → 还款
        arb.startArbitrage(borrowAmount, minTokenCOut, minWethOut);

        uint256 profit = IWETH(WETH).balanceOf(address(arb));
        console2.log("Borrowed WETH:", borrowAmount);
        console2.log("TokenC bought:", outC[1]);
        console2.log("WETH received (est):", outE[1]);
        console2.log("Profit WETH:", profit);
        assertGt(profit, 0, "no profit");
        assertEq(tokenC.balanceOf(address(arb)), 0, "arb should hold no TokenC");
    }

    /// @dev 借用量过大致滑点吞噬利润，整笔回滚验证原子性
    function test_revertWhen_overBorrowMakesNoProfit() public {
        uint256 borrowAmount = 90 ether;

        address[] memory pathToC = new address[](2);
        pathToC[0] = WETH;
        pathToC[1] = address(tokenC);
        uint256[] memory outC = routerC.getAmountsOut(borrowAmount, pathToC);

        address[] memory pathToWeth = new address[](2);
        pathToWeth[0] = address(tokenC);
        pathToWeth[1] = WETH;
        uint256[] memory outE = routerE.getAmountsOut(outC[1], pathToWeth);

        // 借 90 WETH 经双池兑换后无法覆盖本息（Aave 0.05% premium），require 触发回滚
        vm.expectRevert(bytes("FlashLoan: NO_PROFIT"));
        arb.startArbitrage(borrowAmount, outC[1], outE[1]);
    }

    /// @dev 跨版本部署官方 V2 合约
    function _deploy(string memory artifact, bytes memory args) internal returns (address deployed) {
        deployed = vm.deployCode(artifact, args);
        require(deployed != address(0), "deployCode failed");
        require(deployed.code.length > 0, "deployCode: no code");
    }
}
