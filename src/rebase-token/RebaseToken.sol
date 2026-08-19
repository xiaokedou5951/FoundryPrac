// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title RebaseToken
 * @dev 通缩型 rebase ERC20，用于理解 rebase 型 Token 的实现原理。
 *
 * 核心思想（scaling-factor / gons 模式）：
 *   - 用户余额以 "原始量 (raw / gons)" 存储，对外暴露的弹性余额由全局 rebaseFactor 缩放
 *   - balanceOf(u)   = _rawBalances[u]   * rebaseFactor / WAD
 *   - totalSupply()  = _rawTotalSupply   * rebaseFactor / WAD
 *   - 转账时把弹性量换算为原始量：rawAmount = elasticAmount * WAD / rebaseFactor
 *   - rebase() 每过一年将 rebaseFactor 下调 1%（×= 99/100），所有持仓人余额同步通缩
 *
 * 通缩曲线（起始发行量 1 亿，18 位精度）：
 *   第 0 年（构造）：100,000,000
 *   第 1 年 rebase： 99,000,000   (= 100M × 0.99)
 *   第 2 年 rebase： 98,010,000   (= 99M  × 0.99)
 *   第 3 年 rebase： 97,029,900   (= 98.01M × 0.99)
 *   … 逐年基于上年发行量复利通缩 1%
 *
 * @dev 说明：rebase() 设为 permissionless（任何人可触发）。本代币仅通缩、无铸币风险，
 *      教学优先；生产环境应改为 owner / oracle 控制器限制触发权限。
 */
contract RebaseToken {
    // ===== 常量 =====
    string public constant name = "Rebase Deflation Token";
    string public constant symbol = "RBDT";
    uint8 public constant decimals = 18;

    uint256 public constant WAD = 1e18;                       // 缩放基准，1.0
    uint256 public constant INITIAL_SUPPLY = 100_000_000 * 1e18; // 起始发行量 1 亿
    uint256 public constant REBASE_INTERVAL = 365 days;       // 每年一次
    uint256 public constant DEFLATION_NUMERATOR = 99;          // 99 / 100 = 99%，通缩 1%
    uint256 public constant DEFLATION_DENOMINATOR = 100;

    // ===== 状态 =====
    uint256 public rebaseFactor;          // 当前缩放因子，初值 = WAD (1.0)
    uint256 public rawTotalSupply;        // 原始总量（构造后不变，仅由 rebaseFactor 影响弹性总量）
    uint256 public lastRebaseTimestamp;   // 上次 rebase 时间戳（构造时 = block.timestamp）
    uint256 public rebaseCount;           // 累计 rebase 次数

    mapping(address => uint256) private _rawBalances;                       // 原始余额（gons）
    mapping(address => mapping(address => uint256)) private _allowances;   // 授权额度

    // ===== 事件 =====
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Rebase(uint256 oldFactor, uint256 newFactor, uint256 newTotalSupply, uint256 timestamp);

    // ===== 构造 =====
    constructor() {
        rawTotalSupply = INITIAL_SUPPLY;
        _rawBalances[msg.sender] = INITIAL_SUPPLY;
        lastRebaseTimestamp = block.timestamp;
        rebaseFactor = WAD;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ===== ERC20 视图 =====

    /// @dev 弹性余额 = 原始余额 × 缩放因子。rebase 后所有持仓人余额同步缩放。
    function balanceOf(address account) public view returns (uint256) {
        return _rawBalances[account] * rebaseFactor / WAD;
    }

    /// @dev 弹性总量 = 原始总量 × 缩放因子。
    function totalSupply() public view returns (uint256) {
        return rawTotalSupply * rebaseFactor / WAD;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ===== ERC20 写操作 =====

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 current = _allowances[from][msg.sender];
        // 无限授权不扣减，避免频繁 approve
        if (current != type(uint256).max) {
            require(current >= amount, "ERC20: insufficient allowance");
            unchecked {
                _allowances[from][msg.sender] = current - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    // ===== 内部：转账 =====

    /// @dev 转账以弹性量为入参，内部换算为原始量后增减 _rawBalances。
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from zero address");
        require(to != address(0), "ERC20: transfer to zero address");

        uint256 rawAmount = elasticToRaw(amount);
        uint256 rawFrom = _rawBalances[from];
        require(rawFrom >= rawAmount, "ERC20: insufficient balance");

        unchecked {
            _rawBalances[from] = rawFrom - rawAmount;
            _rawBalances[to] += rawAmount;
        }
        emit Transfer(from, to, amount);
    }

    // ===== rebase 通缩 =====

    /**
     * @dev 每过一年触发一次通缩：rebaseFactor ×= 99/100（下调 1%）。
     *      所有持仓人 balanceOf 与 totalSupply 即刻同步缩放，无需遍历持仓人。
     *      需满足距上次 rebase 满 365 天，否则 revert。
     * @return newTotalSupply 通缩后的弹性总量
     */
    function rebase() external returns (uint256 newTotalSupply) {
        require(
            block.timestamp >= lastRebaseTimestamp + REBASE_INTERVAL,
            "Rebase: interval not elapsed"
        );

        uint256 oldFactor = rebaseFactor;
        rebaseFactor = oldFactor * DEFLATION_NUMERATOR / DEFLATION_DENOMINATOR;
        lastRebaseTimestamp = block.timestamp;
        unchecked {
            rebaseCount += 1;
        }

        newTotalSupply = totalSupply();
        emit Rebase(oldFactor, rebaseFactor, newTotalSupply, block.timestamp);
    }

    // ===== 换算工具（public，便于测试与调试观察） =====

    /// @dev 弹性量 → 原始量（地板除）。0.99^n 在 WAD 下对测试涉及的小 n 取整干净。
    function elasticToRaw(uint256 elastic) public view returns (uint256) {
        return elastic * WAD / rebaseFactor;
    }

    /// @dev 原始量 → 弹性量
    function rawToElastic(uint256 raw) public view returns (uint256) {
        return raw * rebaseFactor / WAD;
    }

    /// @dev 暴露原始余额，便于测试验证 rebase 不动 _rawBalances
    function rawBalanceOf(address account) external view returns (uint256) {
        return _rawBalances[account];
    }
}
