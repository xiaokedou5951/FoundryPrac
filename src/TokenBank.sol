pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TokenBank {
    using SafeERC20 for IERC20;

    // 代币合约地址
    IERC20 public token;

    // 记录每个用户存入的代币数量
    mapping(address => uint256) public deposits;

    // 存款和取款事件
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    // 构造函数，设置代币合约地址
    constructor(address _tokenAddress) {
        require(_tokenAddress != address(0), "TokenBank: token address cannot be zero");
        token = IERC20(_tokenAddress);
    }

    // 存入代币
    function deposit(uint256 _amount) external {
        // 检查金额是否大于0
        require(_amount > 0, "TokenBank: deposit amount must be greater than zero");

        // 检查用户是否有足够的代币
        require(token.balanceOf(msg.sender) >= _amount, "TokenBank: insufficient token balance");

        // 将代币从用户转移到合约
        // 注意：用户需要先调用token.approve(tokenBank地址, 金额)来授权TokenBank合约
        token.safeTransferFrom(msg.sender, address(this), _amount);

        // 更新用户的存款记录
        deposits[msg.sender] += _amount;

        // 触发存款事件
        emit Deposit(msg.sender, _amount);
    }

    // 提取代币
    function withdraw(uint256 _amount) external {
        // 检查金额是否大于0
        require(_amount > 0, "TokenBank: withdraw amount must be greater than zero");

        // 检查用户是否有足够的存款
        require(deposits[msg.sender] >= _amount, "TokenBank: insufficient deposit balance");

        // 更新用户的存款记录（先减少记录，再转账，防止重入攻击）
        deposits[msg.sender] -= _amount;

        // 将代币从合约转移回用户
        token.safeTransfer(msg.sender, _amount);

        // 触发提款事件
        emit Withdraw(msg.sender, _amount);
    }

    // 查询用户在银行中的存款余额
    function balanceOf(address _user) external view returns (uint256) {
        return deposits[_user];
    }
}
