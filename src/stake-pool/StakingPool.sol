// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {KKToken} from "./KKToken.sol";

/// @dev WETH9 最小接口（fork 主网直接绑定地址）
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev ERC20 只读余额（用于查询 aWETH）
interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Aave V3 Pool 最小接口：supply / withdraw
///      注：当前主网 Pool 实现已不再暴露 getReserveTokensAddresses，故 aWETH 由构造参数传入。
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address onBehalfOf) external returns (uint256);
}

/**
 * @title StakingPool
 * @dev ETH 质押挖矿 + Aave V3 借贷利息集成（自包含模块，不引用本项目其它代码）。
 *
 *   流程：
 *   1. stake()        用户质押 ETH → 包成 WETH → approve Aave → Pool.supply() 存入借贷市场赚取利息
 *                     同时按"质押数量 × 质押时长"公平累计 KK 奖励（每区块 10 KK）。
 *   2. unstake()      从 Aave Pool.withdraw() 取回本金 → WETH 解包为 ETH → 退还用户，并结算 KK。
 *   3. claimReward()  单独领取已累计的 KK。
 *   4. ownerClaimInterest()  owner 提取 Aave 上累积的 aWETH 利息（本金不动）。
 *
 *   奖励模型：MasterChef 经典 accRewardPerShare 累计法，等价于按 (质押数量 × 持有时长) 加权分配。
 *   利息归属：Aave 利息归部署者(owner)；用户仅获 KK 奖励。
 */
contract StakingPool {
    // ===== 主网地址（fork 环境直接使用，与 flash-loan 模块一致） =====
    // Aave V3 Pool 代理 = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
    // WETH9            = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

    address public immutable aavePool; // Aave V3 Pool 代理
    address public immutable weth; // WETH9
    address public immutable aWeth; // aWETH（构造期向 Pool 动态查询）
    address public immutable owner; // 部署者，提取利息
    address public immutable kkToken; // 奖励代币 KK（构造时内部部署）

    /// @dev 每区块产出 10 KK
    uint256 public constant REWARD_PER_BLOCK = 10 * 1e18;
    /// @dev 精度放大系数，避免 accRewardPerShare 被截断
    uint256 public constant ACC_PRECISION = 1e12;

    uint256 public lastRewardBlock; // 上次更新 accRewardPerShare 的区块号
    uint256 public accRewardPerShare; // 累计每 1 wei 质押应得的 KK（×1e12）
    uint256 public totalStaked; // 当前供给 Aave 的 ETH 本金合计

    struct UserInfo {
        uint256 amount; // 用户当前质押的 ETH 本金
        uint256 rewardDebt; // 已计入的奖励基线（amount * acc / precision）
    }
    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event InterestClaimed(address indexed owner, uint256 amount);

    /**
     * @param _aavePool Aave V3 Pool 代理地址
     * @param _weth     WETH9 地址
     * @param _aWeth    Aave V3 aWETH 地址（由部署者提供；Pool 已不暴露 getter）
     */
    constructor(address _aavePool, address _weth, address _aWeth) {
        require(_aWeth != address(0), "StakePool: bad aToken");
        aavePool = _aavePool;
        weth = _weth;
        aWeth = _aWeth;
        owner = msg.sender;
        // 内部部署 KKToken：此时 msg.sender = 本合约，故 KKToken.minter = StakingPool
        kkToken = address(new KKToken());
        lastRewardBlock = block.number;
    }

    /// @dev 接收 WETH.withdraw 解包回来的 ETH
    receive() external payable {}

    // ===== 奖励会计（MasterChef 风格） =====

    /// @dev 推进 accRewardPerShare 至当前区块
    function _updateReward() internal {
        if (block.number <= lastRewardBlock) return;
        if (totalStaked == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 blocks = block.number - lastRewardBlock;
        uint256 kkReward = blocks * REWARD_PER_BLOCK;
        accRewardPerShare += (kkReward * ACC_PRECISION) / totalStaked;
        lastRewardBlock = block.number;
    }

    /// @dev 把用户已累计但未领取的 KK 铸给用户（不重置 rewardDebt，由调用方在改 amount 后重置）
    function _settlePending(address user) internal {
        UserInfo storage u = userInfo[user];
        uint256 pending = (u.amount * accRewardPerShare) / ACC_PRECISION - u.rewardDebt;
        if (pending > 0) {
            KKToken(kkToken).mint(user, pending);
            emit RewardClaimed(user, pending);
        }
    }

    /// @dev 估算用户当前可领取的 KK（含尚未结算的 acc 增量）
    function pendingReward(address user) external view returns (uint256) {
        UserInfo storage u = userInfo[user];
        uint256 acc = accRewardPerShare;
        if (block.number > lastRewardBlock && totalStaked > 0) {
            uint256 blocks = block.number - lastRewardBlock;
            acc += (blocks * REWARD_PER_BLOCK * ACC_PRECISION) / totalStaked;
        }
        return (u.amount * acc) / ACC_PRECISION - u.rewardDebt;
    }

    // ===== 用户入口 =====

    /// @dev 质押 ETH：包装为 WETH 后存入 Aave 借贷市场，同时累计 KK 奖励
    function stake() external payable {
        require(msg.value > 0, "StakePool: zero stake");

        _updateReward();
        if (userInfo[msg.sender].amount > 0) {
            _settlePending(msg.sender);
        }

        // 1. ETH -> WETH
        IWETH(weth).deposit{value: msg.value}();
        // 2. 授权 Aave Pool 划扣 WETH
        IWETH(weth).approve(aavePool, msg.value);
        // 3. 存入 Aave（onBehalfOf = 本合约，利息以 aWETH 形式累计到本合约）
        IPool(aavePool).supply(weth, msg.value, address(this), 0);

        // 4. 更新用户质押与奖励基线
        userInfo[msg.sender].amount += msg.value;
        totalStaked += msg.value;
        userInfo[msg.sender].rewardDebt =
            (userInfo[msg.sender].amount * accRewardPerShare) / ACC_PRECISION;

        emit Staked(msg.sender, msg.value);
    }

    /// @dev 解除质押：从 Aave 取回本金，解包为 ETH 退还用户，并结算 KK
    ///      注：Aave scaled-balance 在 liquidityIndex≠1e27 时存在 1~2 wei 取整，
    ///      aWETH 余额可能略小于名义质押量，故按实际收到的 WETH 计量退还。
    function unstake(uint256 amount) external {
        UserInfo storage u = userInfo[msg.sender];
        require(amount > 0 && u.amount >= amount, "StakePool: bad amount");

        _updateReward();
        _settlePending(msg.sender);

        // 1. 从 Aave 取回本金。cap 在 aWETH 余额，避免 scaled 取整触发 AMOUNT_GREATER 回滚
        uint256 aBal = IERC20Min(aWeth).balanceOf(address(this));
        uint256 toWithdraw = amount < aBal ? amount : aBal;
        if (toWithdraw > 0) {
            IPool(aavePool).withdraw(weth, toWithdraw, address(this));
        }
        // 2. 解包实际收到的 WETH（可能比 amount 少 1~2 wei）
        uint256 wethReceived = IWETH(weth).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        if (wethReceived > 0) {
            IWETH(weth).withdraw(wethReceived);
        }
        uint256 toReturn = address(this).balance - ethBefore; // == wethReceived

        // 3. CEI：先更新账目（按名义 amount 抵扣），再向用户转 ETH（防重入，沿用 TokenBank 约定）
        u.amount -= amount;
        totalStaked -= amount;
        u.rewardDebt = (u.amount * accRewardPerShare) / ACC_PRECISION;

        // 4. 退还实际收到的 ETH 给用户
        if (toReturn > 0) {
            (bool ok,) = msg.sender.call{value: toReturn}("");
            require(ok, "StakePool: eth transfer failed");
        }

        emit Unstaked(msg.sender, toReturn);
    }

    /// @dev 单独领取已累计的 KK 奖励
    function claimReward() external {
        _updateReward();
        _settlePending(msg.sender);
        userInfo[msg.sender].rewardDebt =
            (userInfo[msg.sender].amount * accRewardPerShare) / ACC_PRECISION;
    }

    // ===== Owner 入口 =====

    /// @dev owner 提取 Aave 上累积的 aWETH 利息（本金 totalStaked 不动）
    function ownerClaimInterest() external {
        require(msg.sender == owner, "StakePool: not owner");

        uint256 aBal = IERC20Min(aWeth).balanceOf(address(this));
        uint256 interest = aBal > totalStaked ? aBal - totalStaked : 0;
        if (interest > 0) {
            // 从 Aave 取回利息等额的 WETH 到本合约（按实际收到计量，容 1~2 wei 取整）
            uint256 wethBefore = IWETH(weth).balanceOf(address(this));
            IPool(aavePool).withdraw(weth, interest, address(this));
            uint256 received = IWETH(weth).balanceOf(address(this)) - wethBefore;
            if (received > 0) {
                IWETH(weth).withdraw(received);
                (bool ok,) = owner.call{value: received}("");
                require(ok, "StakePool: interest transfer failed");
            }
            emit InterestClaimed(owner, received);
        }
    }
}
