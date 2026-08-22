// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title VoteToken
 * @dev 可计票的 ERC20 治理代币（固定供应）。
 *
 *   核心能力（对应需求一：可计票的 Token）：
 *   1. 委托（delegation）：每个账户可把投票权委托给自身或他人。
 *   2. 历史检查点（checkpoint）：投票权每次变化都记录 {fromBlock, votes}，
 *      可按区块号查询历史值，防止闪电贷投票（投票时读取提案快照块的票数）。
 *   3. 自动委托自身：账户未显式委托时，默认把票记给自己（与 COMP/UNI 一致），
 *      避免未委托代币无法计入法定人数 / 锁死。
 *
 *   投票权 = 各账户委托给某 delegatee 的代币数量之和。
 *   转账 / 铸造 / 销毁会自动在 from/to 各自的 delegatee 之间移动投票权。
 *
 *   Governor 通过 getPriorVotes(account, snapshotBlock) 读取历史票数计票。
 */
contract VoteToken is ERC20 {
    /// @dev 单个投票权检查点：从此区块起 votes 生效。uint32+uint224 = 一个 storage slot。
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    /// @dev 账户 => 其委托对象（address(0) 表示"尚未委托，视作委托给自身"）。
    mapping(address => address) public delegates;

    /// @dev delegatee => 投票权检查点序列（按 fromBlock 升序）。
    mapping(address => Checkpoint[]) public checkpoints;

    // ===== 事件 =====
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    /**
     * @param initialSupply 初始供应（一次性 mint 给部署者，之后不再增发 / 销毁）。
     */
    constructor(uint256 initialSupply) ERC20("Vote Governance Token", "VGT") {
        require(initialSupply > 0, "VGT: zero supply");
        _mint(msg.sender, initialSupply); // 经 _update 自动建立部署者的检查点
    }

    // ==================== 需求一：委托 ====================

    /**
     * @dev 把调用者的投票权委托给 delegatee（可委托自身或他人）。
     *      委托会从原 delegatee 移走全部余额对应的票数，转给新 delegatee。
     */
    function delegate(address delegatee) external {
        require(delegatee != address(0), "VGT: delegate to zero");
        address current = _delegateeOf(msg.sender);
        delegates[msg.sender] = delegatee;
        _moveVotingPower(current, delegatee, balanceOf(msg.sender));
        emit DelegateChanged(msg.sender, current, delegatee);
    }

    /// @dev delegatee 当前实时投票权（展示用，不计票）。
    function getCurrentVotes(address account) external view returns (uint256) {
        uint256 len = checkpoints[account].length;
        return len == 0 ? 0 : checkpoints[account][len - 1].votes;
    }

    /**
     * @dev 读取 account 在 blockNumber 区块的投票权（历史快照）。
     *      要求 blockNumber < block.number（仅可查过去的块），用于提案快照计票。
     */
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256) {
        require(blockNumber < block.number, "VGT: future block");
        Checkpoint[] storage cps = checkpoints[account];
        uint256 len = cps.length;
        if (len == 0) return 0;

        // 二分查找 fromBlock <= blockNumber 的最新条目
        uint256 lo = 0;
        uint256 hi = len - 1;
        // 早于首条 -> 0
        if (cps[0].fromBlock > blockNumber) return 0;
        if (cps[hi].fromBlock <= blockNumber) return cps[hi].votes;

        // 不变量：cps[lo].fromBlock <= blockNumber < cps[hi].fromBlock
        while (lo + 1 < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (cps[mid].fromBlock <= blockNumber) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return cps[lo].votes;
    }

    // ==================== 内部：投票权移动 ====================

    /// @dev 账户未显式委托时，视作委托给自身。
    function _delegateeOf(address account) internal view returns (address) {
        address d = delegates[account];
        return d == address(0) ? account : d;
    }

    /**
     * @dev 在 from / to 两个 delegatee 之间移动 amount 票数。
     *      from==to 或 amount==0 直接返回；address(0) 一侧跳过（mint/burn 场景）。
     *      每侧写一个新检查点（若当前块已有检查点则原地更新，避免重复 append）。
     */
    function _moveVotingPower(address from, address to, uint256 amount) internal {
        if (from == to || amount == 0) return;

        if (from != address(0)) {
            uint256 oldVotes = _latestVotes(from);
            uint256 newVotes = oldVotes - amount;
            _writeCheckpoint(from, newVotes);
            emit DelegateVotesChanged(from, oldVotes, newVotes);
        }
        if (to != address(0)) {
            uint256 oldVotes = _latestVotes(to);
            uint256 newVotes = oldVotes + amount;
            _writeCheckpoint(to, newVotes);
            emit DelegateVotesChanged(to, oldVotes, newVotes);
        }
    }

    /// @dev 取 delegatee 最新检查点 votes（无检查点返回 0）。
    function _latestVotes(address delegatee) internal view returns (uint256) {
        uint256 len = checkpoints[delegatee].length;
        return len == 0 ? 0 : checkpoints[delegatee][len - 1].votes;
    }

    /**
     * @dev 写入新票数：若最新检查点就在当前块则原地改 votes，否则 append 新条目。
     */
    function _writeCheckpoint(address delegatee, uint256 newVotes) internal {
        uint256 len = checkpoints[delegatee].length;
        if (len > 0 && checkpoints[delegatee][len - 1].fromBlock == block.number) {
            checkpoints[delegatee][len - 1].votes = uint224(newVotes);
        } else {
            checkpoints[delegatee].push(Checkpoint({fromBlock: uint32(block.number), votes: uint224(newVotes)}));
        }
    }

    // ==================== ERC20 钩子：同步投票权 ====================

    /**
     * @dev 重写 OZ ERC20._update：先做标准余额/供应变更，再在 from/to 各自 delegatee
     *      之间移动 amount 票数。覆盖 transfer / mint / burn 全路径。
     */
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        address fromDelegate = from == address(0) ? address(0) : _delegateeOf(from);
        address toDelegate = to == address(0) ? address(0) : _delegateeOf(to);
        _moveVotingPower(fromDelegate, toDelegate, value);
    }
}
