// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OptionToken
 * @dev 看涨期权 Token（ERC20），标的为原生 ETH，行权货币为 USDT。
 *
 *   功能（对应需求 1~5）：
 *   1. 构造时确认行权价 strikePrice（USDT/ETH）与行权日 expiryDate。
 *   2. issue()：项目方（owner）转入 ETH，1:1 铸造期权 Token 给 owner。
 *   3. AMM 交易对由独立的 OptionSwapPool 实现（本合约不直接处理）。
 *   4. exercise()：在到期日当天（[expiryDate, expiryDate+1 days)），
 *      用户按 strikePrice 用 USDT 行权，换出 ETH 并销毁期权 Token。
 *   5. expireAndReclaim()：窗口结束后，owner 赎回剩余 ETH；
 *      burnFrom()：过期后 owner 可销毁任意账户剩余期权 Token（满足“销毁所有”）。
 *
 *   单位约定：
 *     - 期权 Token 18 位精度；1 wei ETH 对应 1 单位期权（1:1）。
 *     - strikePrice 以 USDT 6 位精度存储，例如 3000e6 表示 3000 USDT / 1 ETH。
 *     - 行权 USDT 成本 = optionAmount * strikePrice / 1e18。
 *
 *   资金归属：
 *     - 合约仅持有 ETH 抵押物；行权时 USDT 直接从用户转给 owner（项目方）。
 */
contract OptionToken is ERC20, Ownable {
    IERC20 public immutable usdt;          // 计价/行权货币（USDT）
    uint256 public immutable strikePrice;  // 行权价（USDT 6 位精度 / 1 ETH）
    uint256 public immutable expiryDate;   // 到期日（unix 秒）
    bool public expired;                   // 是否已执行过期赎回

    // ===== 事件 =====
    event Issued(address indexed issuer, uint256 ethAmount);
    event Exercised(address indexed user, uint256 optionAmount, uint256 usdtPaid, uint256 ethReceived);
    event ExpiredAndReclaimed(address indexed issuer, uint256 ethReclaimed);
    event ForceBurned(address indexed from, uint256 amount);

    /**
     * @param _usdt        USDT 合约地址（行权货币）
     * @param _strikePrice 行权价（USDT 6 位精度 / 1 ETH）
     * @param _expiryDate  到期日（unix 秒，须晚于当前时间）
     */
    constructor(address _usdt, uint256 _strikePrice, uint256 _expiryDate)
        ERC20("Call Option Token", "COT")
        Ownable(msg.sender)
    {
        require(_usdt != address(0), "COT: zero usdt");
        require(_strikePrice > 0, "COT: zero strike");
        require(_expiryDate > block.timestamp, "COT: past expiry");
        usdt = IERC20(_usdt);
        strikePrice = _strikePrice;
        expiryDate = _expiryDate;
    }

    /// @dev 接收 ETH（仅用于可能的退款/未来扩展，核心 ETH 来自 issue 的 msg.value）
    receive() external payable {}

    // ==================== 需求 2：发行（项目方） ====================

    /**
     * @dev 项目方转入 ETH 抵押，1:1 铸造期权 Token 给 owner。
     *      1 wei ETH = 1 单位期权（均 18 位精度）。
     */
    function issue() external payable onlyOwner {
        require(msg.value > 0, "COT: zero eth");
        require(!expired, "COT: expired");
        _mint(msg.sender, msg.value);
        emit Issued(msg.sender, msg.value);
    }

    // ==================== 需求 4：行权（用户，仅到期日当天） ====================

    /**
     * @dev 用户在到期日当天行权：按 strikePrice 支付 USDT 给 owner，换出 ETH，销毁期权。
     *      行权窗口：[expiryDate, expiryDate + 1 days)。
     *      调用前用户须对 USDT 执行 approve(optionToken, usdtCost)。
     * @param optionAmount 行权的期权 Token 数量（同时 = 释放的 ETH wei 数量）
     */
    function exercise(uint256 optionAmount) external {
        require(block.timestamp >= expiryDate, "COT: not yet expiry");
        require(block.timestamp < expiryDate + 1 days, "COT: exercise window closed");
        require(optionAmount > 0, "COT: zero amount");
        require(!expired, "COT: expired");
        require(address(this).balance >= optionAmount, "COT: insufficient collateral");

        uint256 ethAmount = optionAmount;                          // 1:1
        uint256 usdtCost = (ethAmount * strikePrice) / 1e18;       // USDT(6) per ETH(18)

        // CEI：先销毁期权 Token，再收款，最后释放 ETH
        _burn(msg.sender, optionAmount);

        require(usdt.transferFrom(msg.sender, owner(), usdtCost), "COT: usdt pay failed");

        (bool ok, ) = msg.sender.call{value: ethAmount}("");
        require(ok, "COT: eth transfer failed");

        emit Exercised(msg.sender, optionAmount, usdtCost, ethAmount);
    }

    // ==================== 需求 5：过期销毁 / 赎回（项目方） ====================

    /**
     * @dev 过期赎回：行权窗口结束后，owner 一次性取回合约内剩余 ETH 抵押物，
     *      并销毁合约自持的期权 Token（若有回流）。调用后 expired=true，发行/行权均禁用。
     */
    function expireAndReclaim() external onlyOwner {
        require(block.timestamp >= expiryDate + 1 days, "COT: window still open");
        require(!expired, "COT: already expired");
        expired = true;

        uint256 selfBal = balanceOf(address(this));
        if (selfBal > 0) {
            _burn(address(this), selfBal);
            emit ForceBurned(address(this), selfBal);
        }

        uint256 ethBal = address(this).balance;
        (bool ok, ) = owner().call{value: ethBal}("");
        require(ok, "COT: reclaim failed");

        emit ExpiredAndReclaimed(owner(), ethBal);
    }

    /**
     * @dev 销毁指定账户的剩余期权 Token（仅过期后、仅 owner）。
     *      用于清空 AMM 池 / 未行权用户手中的剩余期权，实现“销毁所有期权 Token”。
     *      注：标准 ERC20 无法由一方销毁他人代币，故作为 owner 工具函数提供。
     */
    function burnFrom(address account, uint256 amount) external onlyOwner {
        require(expired, "COT: not expired yet");
        require(amount > 0, "COT: zero amount");
        _burn(account, amount);
        emit ForceBurned(account, amount);
    }

    // ==================== 视图函数 ====================

    /// @dev 给定期权数量，计算行权需支付的 USDT 数量
    function getExerciseCost(uint256 optionAmount) external view returns (uint256) {
        return (optionAmount * strikePrice) / 1e18;
    }

    /// @dev 当前是否处于行权窗口 [expiryDate, expiryDate+1 days)
    function isExerciseWindow() external view returns (bool) {
        return block.timestamp >= expiryDate && block.timestamp < expiryDate + 1 days;
    }

    /// @dev 行权窗口是否已过（此时可过期赎回）
    function isPastWindow() external view returns (bool) {
        return block.timestamp >= expiryDate + 1 days;
    }

    /// @dev 当前 ETH 抵押物总量
    function collateral() external view returns (uint256) {
        return address(this).balance;
    }
}
