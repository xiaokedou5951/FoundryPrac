// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title OptionSwapPool
 * @dev 看涨期权 Token ↔ USDT 的恒定乘积（x*y=k）AMM 交易对（需求 3）。
 *
 *   设计：
 *     - 无 LP 代币：流动性由 owner（项目方）独占注入/抽离，简化教学模型。
 *     - 项目方以“较低的价格”注入期权/USDT 初始流动性（USDT/期权 比例偏低），
 *       用户随后用 USDT 兑换期权 Token，模拟用户购买期权。
 *     - swap 收取 0.3% 手续费，沿用 Uniswap V2 getAmountOut 公式。
 *
 *   流程：
 *     1. owner 调 addLiquidity(optionAmount, usdtAmount) 创建/补充交易对。
 *     2. 用户调 swapUSDTForOption(usdtIn, minOptionOut) 用 USDT 买入期权。
 *     3. 用户调 swapOptionForUSDT(optionIn, minUsdtOut) 卖出期权换回 USDT。
 *     4. owner 调 removeLiquidity() 取回池内全部两币（过期清理用）。
 *
 *   注：本池独立于 OptionToken，不对行权/到期做任何限制。
 */
contract OptionSwapPool {
    IERC20 public immutable optionToken;
    IERC20 public immutable usdt;
    address public immutable owner; // 项目方（部署者）

    uint256 public reserveOption; // 池内期权 Token 储备
    uint256 public reserveUsdt;   // 池内 USDT 储备

    /// @dev 手续费系数（0.3%）：分子 997 / 1000
    uint256 public constant FEE_NUMERATOR = 997;
    uint256 public constant FEE_DENOMINATOR = 1000;

    // ===== 事件 =====
    event LiquidityAdded(uint256 optionAmount, uint256 usdtAmount);
    event LiquidityRemoved(uint256 optionAmount, uint256 usdtAmount);
    event Swap(address indexed user, address tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(address _optionToken, address _usdt) {
        require(_optionToken != address(0) && _usdt != address(0), "OSP: zero token");
        optionToken = IERC20(_optionToken);
        usdt = IERC20(_usdt);
        owner = msg.sender;
    }

    // ==================== 流动性（owner） ====================

    /**
     * @dev owner 注入期权 + USDT 流动性。调用前须对两币 approve 本池。
     *      多次调用为追加（非首次亦可）。
     */
    function addLiquidity(uint256 optionAmount, uint256 usdtAmount) external {
        require(msg.sender == owner, "OSP: not owner");
        require(optionAmount > 0 && usdtAmount > 0, "OSP: zero amount");

        require(optionToken.transferFrom(msg.sender, address(this), optionAmount), "OSP: opt in failed");
        require(usdt.transferFrom(msg.sender, address(this), usdtAmount), "OSP: usdt in failed");

        reserveOption += optionAmount;
        reserveUsdt += usdtAmount;

        emit LiquidityAdded(optionAmount, usdtAmount);
    }

    /**
     * @dev owner 一次性抽离池内全部两币（用于过期清理 / 赎回前回收）。
     */
    function removeLiquidity() external {
        require(msg.sender == owner, "OSP: not owner");

        uint256 optOut = reserveOption;
        uint256 usdtOut = reserveUsdt;
        reserveOption = 0;
        reserveUsdt = 0;

        if (optOut > 0) {
            require(optionToken.transfer(owner, optOut), "OSP: opt out failed");
        }
        if (usdtOut > 0) {
            require(usdt.transfer(owner, usdtOut), "OSP: usdt out failed");
        }

        emit LiquidityRemoved(optOut, usdtOut);
    }

    // ==================== 交易（任意人） ====================

    /**
     * @dev 用户用 USDT 买入期权 Token。
     *      调用前须对 USDT approve 本池。
     * @param usdtIn       投入的 USDT 数量
     * @param minOptionOut 期望至少得到的期权数量（滑点保护）
     */
    function swapUSDTForOption(uint256 usdtIn, uint256 minOptionOut) external returns (uint256 optionOut) {
        require(usdtIn > 0, "OSP: zero in");
        optionOut = getAmountOut(usdtIn, reserveUsdt, reserveOption);
        require(optionOut > 0, "OSP: zero out");
        require(optionOut >= minOptionOut, "OSP: slippage");

        require(usdt.transferFrom(msg.sender, address(this), usdtIn), "OSP: usdt in failed");
        reserveUsdt += usdtIn;
        reserveOption -= optionOut;
        require(optionToken.transfer(msg.sender, optionOut), "OSP: opt out failed");

        emit Swap(msg.sender, address(usdt), usdtIn, optionOut);
    }

    /**
     * @dev 用户卖出期权 Token 换回 USDT。
     *      调用前须对期权 Token approve 本池。
     * @param optionIn    投入的期权数量
     * @param minUsdtOut  期望至少得到的 USDT 数量（滑点保护）
     */
    function swapOptionForUSDT(uint256 optionIn, uint256 minUsdtOut) external returns (uint256 usdtOut) {
        require(optionIn > 0, "OSP: zero in");
        usdtOut = getAmountOut(optionIn, reserveOption, reserveUsdt);
        require(usdtOut > 0, "OSP: zero out");
        require(usdtOut >= minUsdtOut, "OSP: slippage");

        require(optionToken.transferFrom(msg.sender, address(this), optionIn), "OSP: opt in failed");
        reserveOption += optionIn;
        reserveUsdt -= usdtOut;
        require(usdt.transfer(msg.sender, usdtOut), "OSP: usdt out failed");

        emit Swap(msg.sender, address(optionToken), optionIn, usdtOut);
    }

    // ==================== 定价（view） ====================

    /**
     * @dev Uniswap V2 标准输出计算（0.3% 手续费）。
     *      amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "OSP: zero in");
        require(reserveIn > 0 && reserveOut > 0, "OSP: no liquidity");
        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }

    /// @dev 估算用 usdtIn USDT 能换到的期权数量
    function quoteUSDTForOption(uint256 usdtIn) external view returns (uint256) {
        return getAmountOut(usdtIn, reserveUsdt, reserveOption);
    }

    /// @dev 估算用 optionIn 期权能换到的 USDT 数量
    function quoteOptionForUSDT(uint256 optionIn) external view returns (uint256) {
        return getAmountOut(optionIn, reserveOption, reserveUsdt);
    }
}
