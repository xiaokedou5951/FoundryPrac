// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TokenVesting
 * @dev 代币归属锁定释放合约
 * 功能说明：
 * - 12个月的锁定期（cliff）
 * - 从第13个月开始，24个月线性释放（每月释放1/24）
 * - 受益人可以调用release()方法提取已解锁的代币
 */
contract TokenVesting is Ownable {
    using Math for uint256;

    // 事件
    event TokensReleased(uint256 amount);
    event TokensDeposited(uint256 amount);

    // 状态变量
    IERC20 public immutable token;           // 锁定的ERC20代币
    address public immutable beneficiary;    // 受益人
    uint256 public immutable startTime;     // 开始时间
    uint256 public immutable cliffDuration; // 锁定期（12个月）
    uint256 public immutable vestingDuration; // 总释放期（24个月）
    uint256 public totalAmount;             // 总锁定金额
    uint256 public releasedAmount;          // 已释放金额

    // 常量
    uint256 public constant CLIFF_DURATION = 365 days;      // 12个月锁定期
    uint256 public constant VESTING_DURATION = 730 days;    // 24个月释放期
    uint256 public constant TOTAL_DURATION = CLIFF_DURATION + VESTING_DURATION; // 总期限36个月

    /**
     * @dev 构造函数
     * @param _token 锁定的ERC20代币地址
     * @param _beneficiary 受益人地址
     */
    constructor(
        IERC20 _token,
        address _beneficiary
    ) Ownable(msg.sender) {
        require(address(_token) != address(0), "Token address cannot be zero");
        require(_beneficiary != address(0), "Beneficiary cannot be zero address");
        
        token = _token;
        beneficiary = _beneficiary;
        startTime = block.timestamp;
        cliffDuration = CLIFF_DURATION;
        vestingDuration = VESTING_DURATION;
    }

    /**
     * @dev 存入代币到Vesting合约
     * @param amount 存入的代币数量
     */
    function deposit(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(totalAmount == 0, "Tokens already deposited");
        
        totalAmount = amount;
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
        
        emit TokensDeposited(amount);
    }

    /**
     * @dev 释放已解锁的代币给受益人
     */
    function release() external {
        require(msg.sender == beneficiary, "Only beneficiary can release tokens");
        require(totalAmount > 0, "No tokens to release");
        
        uint256 releasableAmount = getReleasableAmount();
        require(releasableAmount > 0, "No tokens available for release");
        
        releasedAmount += releasableAmount;
        require(
            token.transfer(beneficiary, releasableAmount),
            "Token transfer failed"
        );
        
        emit TokensReleased(releasableAmount);
    }

    /**
     * @dev 计算当前可释放的代币数量
     * @return 可释放的代币数量
     */
    function getReleasableAmount() public view returns (uint256) {
        return getVestedAmount() - releasedAmount;
    }

    /**
     * @dev 计算当前应该释放的总代币数量（包括已释放的）
     * @return 应该释放的总代币数量
     */
    function getVestedAmount() public view returns (uint256) {
        if (block.timestamp < startTime + cliffDuration) {
            // 还在锁定期内，不能释放任何代币
            return 0;
        } else if (block.timestamp >= startTime + TOTAL_DURATION) {
            // 超过总期限，全部代币都应该释放
            return totalAmount;
        } else {
            // 在线性释放期内，计算应该释放的数量
            uint256 timeFromCliff = block.timestamp - (startTime + cliffDuration);
            return totalAmount.mulDiv(timeFromCliff, vestingDuration);
        }
    }

    /**
     * @dev 获取剩余锁定的代币数量
     * @return 剩余锁定的代币数量
     */
    function getRemainingAmount() external view returns (uint256) {
        return totalAmount - releasedAmount;
    }

    /**
     * @dev 获取当前时间距离开始时间的天数
     * @return 天数
     */
    function getDaysFromStart() external view returns (uint256) {
        if (block.timestamp <= startTime) {
            return 0;
        }
        return (block.timestamp - startTime) / 1 days;
    }

    /**
     * @dev 获取距离可以开始释放的剩余天数
     * @return 剩余天数，如果已经可以释放则返回0
     */
    function getDaysUntilCliff() external view returns (uint256) {
        uint256 cliffTime = startTime + cliffDuration;
        if (block.timestamp >= cliffTime) {
            return 0;
        }
        return (cliffTime - block.timestamp) / 1 days;
    }

    /**
     * @dev 检查是否过了锁定期
     * @return 是否过了锁定期
     */
    function isCliffPassed() external view returns (bool) {
        return block.timestamp >= startTime + cliffDuration;
    }

    /**
     * @dev 检查是否完全释放完毕
     * @return 是否完全释放完毕
     */
    function isFullyVested() external view returns (bool) {
        return block.timestamp >= startTime + TOTAL_DURATION;
    }

    /**
     * @dev 获取释放进度百分比（基点，10000 = 100%）
     * @return 释放进度百分比
     */
    function getVestingProgress() external view returns (uint256) {
        if (block.timestamp <= startTime + cliffDuration) {
            return 0;
        }
        if (block.timestamp >= startTime + TOTAL_DURATION) {
            return 10000; // 100%
        }
        
        uint256 timeFromCliff = block.timestamp - (startTime + cliffDuration);
        return (timeFromCliff * 10000) / vestingDuration;
    }
}