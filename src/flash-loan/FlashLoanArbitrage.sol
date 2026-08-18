// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev 最小 ERC20 接口（自包含，避免依赖旧版本库）
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

/// @dev Aave V3 Pool 闪电贷接口（仅 flashLoanSimple）
interface IAavePool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

/// @dev Uniswap V2 Router02 最小接口（调用 0.6.6 部署实例，跨版本外部调用无障碍）
interface IUniV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title FlashLoanArbitrage
 * @dev Aave V3 闪电贷 + 双 Uniswap V2 跨池套利，全流程在一笔交易内原子完成：
 *
 *   1. startArbitrage() 向 Aave V3 Pool 申请 flashLoanSimple 闪电借入 WETH
 *   2. Aave 先把 WETH 转给本合约，再回调 executeOperation()
 *   3. 回调内：在 PoolC（TokenC 便宜的池）用 WETH 兑换 TokenC
 *   4.        在 PoolE（TokenC 昂贵的池）用 TokenC 兑回 WETH
 *   5.        校验兑回量 > 借款本息（无利可图则整笔回滚）
 *   6.        approve Aave 划扣本息；Aave 在回调返回后自动完成还款
 *   7. 剩余 WETH 留存在本合约作为利润，由 owner 提取
 */
contract FlashLoanArbitrage {
    // ===== 主网地址常量（fork 环境直接使用） =====
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2; // Aave V3 Pool 代理

    // ===== 不可变量 =====
    address public immutable weth; // 主网 WETH9（Aave 借贷资产 + 两个池的计价资产）
    address public immutable tokenC; // 自定义 ERC20
    address public immutable routerC; // Uniswap #1 的 Router（PoolC：TokenC 便宜）
    address public immutable routerE; // Uniswap #2 的 Router（PoolE：TokenC 昂贵）
    address public immutable owner; // 部署者，可提取利润

    event ArbitrageExecuted(
        uint256 borrowed, uint256 premium, uint256 tokenCBought, uint256 wethReceived, uint256 profit
    );

    /**
     * @param _weth    主网 WETH 地址
     * @param _tokenC  自定义 TokenC 地址
     * @param _routerC PoolC 所在 Uniswap 的 Router02
     * @param _routerE PoolE 所在 Uniswap 的 Router02
     */
    constructor(address _weth, address _tokenC, address _routerC, address _routerE) {
        weth = _weth;
        tokenC = _tokenC;
        routerC = _routerC;
        routerE = _routerE;
        owner = msg.sender;
    }

    /**
     * @dev 发起套利：从 Aave 闪电借入 borrowAmount 个 WETH
     *      minTokenCOut / minWethOut 为两次兑换的滑点保护（通过 params 传给回调）
     */
    function startArbitrage(uint256 borrowAmount, uint256 minTokenCOut, uint256 minWethOut) external {
        IAavePool(AAVE_POOL).flashLoanSimple(
            address(this), weth, borrowAmount, abi.encode(minTokenCOut, minWethOut), 0
        );
    }

    /**
     * @dev Aave V3 闪电贷回调：此时本合约已收到 amount 个 WETH
     *      完成两池兑换并授权还款后返回 true，Aave 随后划扣 amount + premium
     */
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        require(msg.sender == AAVE_POOL, "FlashLoan: UNAUTHORIZED");
        require(asset == weth, "FlashLoan: WRONG_ASSET");
        require(initiator == address(this), "FlashLoan: WRONG_INITIATOR");

        (uint256 minTokenCOut, uint256 minWethOut) = abi.decode(params, (uint256, uint256));

        // ===== 步骤 1：在 PoolC 用闪电借来的 WETH 兑换 TokenC =====
        IERC20Minimal(asset).approve(routerC, amount);
        address[] memory pathToC = new address[](2);
        pathToC[0] = asset;
        pathToC[1] = tokenC;
        uint256[] memory amountsC =
            IUniV2Router(routerC).swapExactTokensForTokens(amount, minTokenCOut, pathToC, address(this), block.timestamp + 600);
        uint256 tokenCBought = amountsC[1];

        // ===== 步骤 2：在 PoolE 用 TokenC 兑回 WETH =====
        IERC20Minimal(tokenC).approve(routerE, tokenCBought);
        address[] memory pathToWeth = new address[](2);
        pathToWeth[0] = tokenC;
        pathToWeth[1] = asset;
        uint256[] memory amountsE =
            IUniV2Router(routerE).swapExactTokensForTokens(tokenCBought, minWethOut, pathToWeth, address(this), block.timestamp + 600);
        uint256 wethReceived = amountsE[1];

        // ===== 步骤 3：校验利润并授权还款 =====
        uint256 totalDebt = amount + premium;
        require(wethReceived > totalDebt, "FlashLoan: NO_PROFIT");

        IERC20Minimal(asset).approve(AAVE_POOL, totalDebt);

        emit ArbitrageExecuted(amount, premium, tokenCBought, wethReceived, wethReceived - totalDebt);
        return true;
    }

    /// @dev 仅 owner 可提取合约内的 WETH 利润
    function withdrawProfit() external {
        require(msg.sender == owner, "FlashLoan: NOT_OWNER");
        IERC20Minimal(weth).transfer(owner, IERC20Minimal(weth).balanceOf(address(this)));
    }
}
