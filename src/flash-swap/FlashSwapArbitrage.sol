// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Callee} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FlashSwapArbitrage
 * @dev 跨池闪电兑换套利合约（逻辑参考 Uniswap V2 官方 ExampleFlashSwap 示例）
 *
 * 套利流程：
 *   1. startArbitrage() 从 PoolA 闪电借出 TokenA（无需本金）
 *   2. uniswapV2Call() 回调中，把收到的 TokenA 在 PoolB 兑换成 TokenB
 *   3. 用兑得的 TokenB 偿还 PoolA（V2 的 K 值检查允许用任一侧代币还款）
 *   4. 剩余的 TokenB 留存在本合约中作为利润
 */
contract FlashSwapArbitrage is IUniswapV2Callee {
    address public immutable tokenA; // 借入的代币
    address public immutable tokenB; // 偿还/计利的代币
    address public immutable pairA; // 闪电借入 TokenA 的池（较便宜的一侧）
    address public immutable pairB; // 用 TokenA 兑换 TokenB 的池（TokenA 更值钱的一侧）
    address public immutable owner; // 部署者，可提取利润

    /**
     * @param _tokenA TokenA 地址
     * @param _tokenB TokenB 地址
     * @param _pairA  PoolA（TokenA/TokenB 交易对，闪电借入来源）
     * @param _pairB  PoolB（TokenA/TokenB 交易对，兑换目标）
     */
    constructor(address _tokenA, address _tokenB, address _pairA, address _pairB) {
        tokenA = _tokenA;
        tokenB = _tokenB;
        pairA = _pairA;
        pairB = _pairB;
        owner = msg.sender;
    }

    /**
     * @dev 发起套利：从 PoolA 闪电借出 amountTokenA 个 TokenA
     *      PoolA 会先把 TokenA 转给本合约，再触发 uniswapV2Call 回调
     */
    function startArbitrage(uint256 amountTokenA) external {
        require(amountTokenA > 0, "FlashSwap: ZERO_AMOUNT");
        // token0/token1 由地址排序决定，需动态判断借出方向
        // 注意：data 必须非空，V2 Pair 仅在 data.length > 0 时才触发 uniswapV2Call 回调
        if (IUniswapV2Pair(pairA).token0() == tokenA) {
            IUniswapV2Pair(pairA).swap(amountTokenA, 0, address(this), abi.encode(msg.sender));
        } else {
            IUniswapV2Pair(pairA).swap(0, amountTokenA, address(this), abi.encode(msg.sender));
        }
    }

    /**
     * @dev Uniswap V2 闪电兑换回调
     *      此时本合约已收到 amountBorrowed 个 TokenA，需要完成兑换与还款
     */
    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == pairA, "FlashSwap: UNAUTHORIZED");
        IUniswapV2Pair _pairA = IUniswapV2Pair(pairA);
        IUniswapV2Pair _pairB = IUniswapV2Pair(pairB);

        // 确认借出的是 TokenA 及数量
        bool borrowedToken0 = amount0 > 0;
        uint256 amountBorrowed = borrowedToken0 ? amount0 : amount1;
        require(amountBorrowed > 0, "FlashSwap: NOTHING_BORROWED");

        // ===== 步骤 1：把收到的 TokenA 在 PoolB 兑换成 TokenB =====
        (uint256 bReserve0, uint256 bReserve1,) = _pairB.getReserves();
        // 按 TokenA 在 PoolB 中的位置确定输入/输出储备
        (uint256 reserveIn, uint256 reserveOut) = _pairB.token0() == tokenA
            ? (bReserve0, bReserve1)
            : (bReserve1, bReserve0);
        uint256 amountBOut = getAmountOut(amountBorrowed, reserveIn, reserveOut);
        require(amountBOut > 0, "FlashSwap: INSUFFICIENT_OUTPUT");

        // 先把 TokenA 转入 PoolB，再调用 swap 取出 TokenB
        IERC20(tokenA).transfer(pairB, amountBorrowed);
        if (_pairB.token0() == tokenA) {
            _pairB.swap(0, amountBOut, address(this), new bytes(0));
        } else {
            _pairB.swap(amountBOut, 0, address(this), new bytes(0));
        }

        // ===== 步骤 2：计算偿还 PoolA 所需的 TokenB 数量 =====
        // 回调期间 getReserves() 返回的仍是借用前的储备（Pair 在回调之后才结算）
        (uint256 aReserve0, uint256 aReserve1,) = _pairA.getReserves();
        (uint256 reserveA_TokenA, uint256 reserveA_TokenB) = borrowedToken0
            ? (aReserve0, aReserve1)
            : (aReserve1, aReserve0);
        // 等价于"在 PoolA 内卖出 amountBorrowed 个 TokenA"的 getAmountIn 定价（含 0.3% 手续费）
        uint256 amountRepay =
            (reserveA_TokenB * amountBorrowed * 1000) / ((reserveA_TokenA - amountBorrowed) * 997) + 1;

        // 兑得的数量必须大于还款数量，否则无利可图
        require(IERC20(tokenB).balanceOf(address(this)) > amountRepay, "FlashSwap: NO_PROFIT");

        // 用 TokenB 偿还 PoolA，剩余 TokenB 留存为本合约利润
        IERC20(tokenB).transfer(pairA, amountRepay);
    }

    /// @dev 仅 owner 可提取合约内任意代币余额（利润）
    function withdraw(address token) external {
        require(msg.sender == owner, "FlashSwap: NOT_OWNER");
        IERC20(token).transfer(owner, IERC20(token).balanceOf(address(this)));
    }

    /**
     * @dev Uniswap V2 标准输出计算公式（0.3% 手续费）
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997);
    }
}
