// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 极简的杠杆 DEX 实现， 完成 TODO 代码部分
contract SimpleLeverageDEX {

    uint public vK;  // 100000 
    uint public vETHAmount;
    uint public vUSDCAmount;

    IERC20 public USDC;  // 自己创建一个币来模拟 USDC

    struct PositionInfo {
        uint256 margin; // 保证金    // 真实的资金， 如 USDC
        uint256 borrowed; // 借入的资金（虚拟 vUSDC 等价量）
        int256 position; // 虚拟 eth 持仓：正=做多，负=做空
    }
    mapping(address => PositionInfo) public positions;

    // 清算阈值：亏损超过保证金的 80% 即可被清算
    uint public constant LIQUIDATION_THRESHOLD = 80; // /100

    event OpenPosition(address indexed user, bool long, int256 position, uint256 margin, uint256 borrowed);
    event ClosePosition(address indexed user, int256 pnl, uint256 payout);
    event Liquidate(address indexed user, address indexed liquidator, int256 pnl, uint256 reward);

    constructor(uint vEth, uint vUSDC, address _usdc) {
        vETHAmount = vEth;
        vUSDCAmount = vUSDC;
        vK = vEth * vUSDC;
        USDC = IERC20(_usdc);
    }

    /// @dev 开启杠杆头寸
    ///      amount = _margin * level（总敞口，vUSDC 计价），borrowed = amount - _margin（虚拟借入）。
    ///      做多：用 amount vUSDC 向 vAMM 买入 vETH，position 为正。
    ///      做空：向 vAMM 卖出 vETH 取出 amount vUSDC，position 为负。
    function openPosition(uint256 _margin, uint level, bool long) external {
        require(positions[msg.sender].position == 0, "Position already open");
        require(_margin > 0, "margin=0");
        require(level >= 1, "level>=1");

        PositionInfo storage pos = positions[msg.sender];

        USDC.transferFrom(msg.sender, address(this), _margin); // 用户提供保证金
        uint amount = _margin * level;
        uint256 borrowAmount = amount - _margin;

        pos.margin = _margin;
        pos.borrowed = borrowAmount;

        if (long) {
            // 做多：vUSDC 入池，vETH 出池
            vUSDCAmount += amount;
            uint256 newVETH = vK / vUSDCAmount;
            uint256 vETHBought = vETHAmount - newVETH;
            vETHAmount = newVETH;
            pos.position = int256(vETHBought);
        } else {
            // 做空：vUSDC 出池，vETH 入池（借 vETH 卖出）
            require(vUSDCAmount > amount, "vUSDC liquidity insufficient");
            vUSDCAmount -= amount;
            uint256 newVETH = vK / vUSDCAmount;
            uint256 vETHSold = newVETH - vETHAmount;
            vETHAmount = newVETH;
            pos.position = -int256(vETHSold);
        }

        emit OpenPosition(msg.sender, long, pos.position, _margin, borrowAmount);
    }

    /// @dev 关闭头寸并结算，不考虑协议亏损
    ///      1. 计算 pnl  2. 反向回滚 vAMM  3. 结算 USDC（亏空不追讨）  4. 删除仓位
    function closePosition() external {
        PositionInfo storage pos = positions[msg.sender];
        require(pos.position != 0, "No open position");

        int256 pnl = calculatePnL(msg.sender);

        // 反向回滚 vAMM
        if (pos.position > 0) {
            // 做多平仓：把 vETH 还回池子，取出 vUSDC
            vETHAmount += uint256(pos.position);
            vUSDCAmount = vK / vETHAmount;
        } else {
            // 做空平仓：从池子买回 vETH，付 vUSDC
            vETHAmount -= uint256(-pos.position);
            vUSDCAmount = vK / vETHAmount;
        }

        // 结算：权益 = 保证金 + pnl；亏空不追讨（不考虑协议亏损）
        int256 equity = int256(pos.margin) + pnl;
        uint256 payout = equity > 0 ? uint256(equity) : 0;

        delete positions[msg.sender];

        if (payout > 0) {
            USDC.transfer(msg.sender, payout);
        }
        emit ClosePosition(msg.sender, pnl, payout);
    }

    /// @dev 清算头寸，逻辑与平仓类似，但剩余权益（奖励）归清算人
    ///      校验：仓位存在、清算人不能是自己、亏损超过保证金 80%
    function liquidatePosition(address _user) external {
        PositionInfo memory position = positions[_user];
        require(position.position != 0, "No open position");
        require(msg.sender != _user, "cannot liquidate self");
        int256 pnl = calculatePnL(_user);

        // 清算条件：亏损 > 保证金 * 80 / 100  <=>  pnl < -margin*80/100
        int256 threshold = -int256(position.margin * LIQUIDATION_THRESHOLD / 100);
        require(pnl < threshold, "not liquidatable");

        // 反向回滚 vAMM（与 closePosition 相同）
        if (position.position > 0) {
            vETHAmount += uint256(position.position);
            vUSDCAmount = vK / vETHAmount;
        } else {
            vETHAmount -= uint256(-position.position);
            vUSDCAmount = vK / vETHAmount;
        }

        // 剩余权益作为清算奖励归清算人
        int256 equity = int256(position.margin) + pnl;
        uint256 reward = equity > 0 ? uint256(equity) : 0;

        delete positions[_user];

        if (reward > 0) {
            USDC.transfer(msg.sender, reward);
        }
        emit Liquidate(_user, msg.sender, pnl, reward);
    }

    /// @dev 计算盈亏：对比当前仓位的虚拟价值与入场总成本(margin + borrowed)
    ///      做多：当前卖出 position vETH 可得 vusdcOut，pnl = vusdcOut - 总成本
    ///      做空：当前买回 |position| vETH 需付 vusdcIn，pnl = 总成本 - vusdcIn
    ///      价格不变时 pnl ≈ 0
    function calculatePnL(address user) public view returns (int256) {
        PositionInfo memory pos = positions[user];
        if (pos.position == 0) {
            return 0;
        }
        uint256 totalCost = pos.margin + pos.borrowed; // 入场总敞口（vUSDC 计价）
        if (pos.position > 0) {
            // 假设卖出 position vETH 回 vAMM
            uint256 newVETH = vETHAmount + uint256(pos.position);
            uint256 newVUSDC = vK / newVETH;
            uint256 vusdcOut = vUSDCAmount - newVUSDC;
            return int256(vusdcOut) - int256(totalCost);
        } else {
            // 假设买回 |position| vETH
            uint256 vethToBuy = uint256(-pos.position);
            uint256 newVETH = vETHAmount - vethToBuy;
            uint256 newVUSDC = vK / newVETH;
            uint256 vusdcIn = newVUSDC - vUSDCAmount;
            return int256(totalCost) - int256(vusdcIn);
        }
    }
}