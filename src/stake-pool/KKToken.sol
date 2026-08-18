// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title KKToken
/// @dev stake-pool 模块自包含奖励 ERC20（不依赖第三方库），仅由 StakingPool 铸造。
///      构造时 msg.sender 即为部署者（StakingPool），写入不可变量 minter。
contract KKToken {
    string public constant name = "KK Token";
    string public constant symbol = "KK";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev 唯一可铸造者 = StakingPool 合约地址
    address public immutable minter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed tokenOwner, address indexed spender, uint256 value);

    constructor() {
        minter = msg.sender;
    }

    /// @dev 仅 StakingPool 可调用，按累计奖励铸造 KK 给质押者
    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "KK: not minter");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "KK: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "KK: insufficient balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
