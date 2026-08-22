// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @dev Governor 仅依赖 VoteToken 的计票接口，避免对具体实现的耦合（也便于测试 mock）。
 */
interface IVoteToken {
    function getPriorVotes(address account, uint256 blockNumber) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title Governor
 * @dev 手写 Compound-Governor-Bravo 风格的简化治理合约。
 *
 *   功能（对应需求二之 2、3）：作为 Bank 管理员，通过 Token 投票驱动提案执行。
 *
 *   流程：
 *   1. propose(targets, values, calldatas, description)：发起提案（提案者需有投票权）。
 *      记录 snapshotBlock = 当前块；votingDelay 后进入投票；持续 votingPeriod 个块。
 *   2. castVote(proposalId, support)：在投票期内按 snapshotBlock 的历史票数计票。
 *      support: 0=反对, 1=赞成, 2=弃权。
 *   3. execute(proposalId)：投票期结束且 (forVotes>againstVotes 且 for+abstain>=quorum) 时，
 *      依次对每个 target 执行 low-level call（如调 Bank.withdraw）。Governor 是 Bank admin，
 *      故调用通过权限校验，资金从 Bank 直达提案收款人。
 *
 *   quorum = totalSupply * quorumNumerator / 100（百分比，固定供应下当前即快照供应）。
 *   计票防闪电贷：读取 getPriorVotes(snapshot)，快照块必为过去块。
 */
contract Governor {
    enum ProposalState {
        Pending, // 投票未开始
        Active, // 投票中
        Canceled,
        Defeated,
        Succeeded,
        Executed
    }

    struct Receipt {
        bool hasVoted;
        uint8 support; // 0=against, 1=for, 2=abstain
        uint256 votes; // 投票时按 snapshot 统计的票数
    }

    struct Proposal {
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 snapshotBlock;
        uint256 startBlock;
        uint256 endBlock;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts; // 投票者 => 凭证（struct 含 mapping，故 _proposals 为 internal）
    }

    IVoteToken public immutable token;
    uint256 public immutable votingDelay; // 提案后多少块开始投票
    uint256 public immutable votingPeriod; // 投票持续块数
    uint256 public immutable quorumNumerator; // 百分比（4 => 4%）

    uint256 public proposalCount;
    mapping(uint256 => Proposal) internal _proposals;

    // ===== 事件 =====
    event ProposalCreated(
        uint256 indexed id,
        address proposer,
        address[] targets,
        uint256[] values,
        string description,
        uint256 startBlock,
        uint256 endBlock
    );
    event VoteCast(uint256 indexed id, address indexed voter, uint8 support, uint256 votes);
    event ProposalExecuted(uint256 indexed id, address[] targets, uint256[] values);
    event ProposalCanceled(uint256 indexed id);

    /**
     * @param token_           VoteToken 地址（需实现 IVoteToken）
     * @param votingDelay_     投票延迟（块数，测试可用 1）
     * @param votingPeriod_    投票期（块数，测试可用 10）
     * @param quorumNumerator_ 法定人数百分比（<=100，如 4 表示 4%）
     */
    constructor(address token_, uint256 votingDelay_, uint256 votingPeriod_, uint256 quorumNumerator_) {
        require(token_ != address(0), "Gov: zero token");
        require(votingDelay_ > 0, "Gov: zero delay");
        require(votingPeriod_ > 0, "Gov: zero period");
        require(quorumNumerator_ > 0 && quorumNumerator_ <= 100, "Gov: bad quorum");
        token = IVoteToken(token_);
        votingDelay = votingDelay_;
        votingPeriod = votingPeriod_;
        quorumNumerator = quorumNumerator_;
    }

    /// @dev 治理合约名（用于展示 / 模拟 EIP-5805）。
    function name() external pure returns (string memory) {
        return "VoteGovernor";
    }

    /// @dev 接受执行过程中可能回流到治理合约的 ETH。
    receive() external payable {}

    // ==================== 提案 ====================

    /**
     * @dev 发起提案。提案者在 block.number-1 须有 >0 投票权（鼓励委托，防垃圾）。
     * @return proposalId 自增提案 ID。
     */
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256) {
        require(
            targets.length > 0 && targets.length == values.length && targets.length == calldatas.length,
            "Gov: len mismatch"
        );
        require(bytes(description).length > 0, "Gov: empty desc");
        require(token.getPriorVotes(msg.sender, block.number - 1) > 0, "Gov: proposer no votes");

        uint256 proposalId = ++proposalCount;
        Proposal storage p = _proposals[proposalId];
        p.proposer = msg.sender;
        p.description = description;
        // 旧 codegen 不支持 bytes[] calldata 批量拷贝到 storage，逐元素 push（targets/values 同此处理，保持一致）
        for (uint256 i = 0; i < targets.length; i++) {
            p.targets.push(targets[i]);
            p.values.push(values[i]);
            p.calldatas.push(calldatas[i]);
        }
        p.snapshotBlock = block.number;
        p.startBlock = block.number + votingDelay;
        p.endBlock = p.startBlock + votingPeriod;

        emit ProposalCreated(proposalId, msg.sender, targets, values, description, p.startBlock, p.endBlock);
        return proposalId;
    }

    // ==================== 投票 ====================

    /**
     * @dev 投票。support ∈ {0 反对, 1 赞成, 2 弃权}。票数按 snapshotBlock 历史值统计。
     * @return votes 本次计入的票数。
     */
    function castVote(uint256 proposalId, uint8 support) external returns (uint256 votes) {
        require(state(proposalId) == ProposalState.Active, "Gov: not active");
        require(support <= 2, "Gov: bad support");

        Proposal storage p = _proposals[proposalId];
        require(!p.receipts[msg.sender].hasVoted, "Gov: voted");

        votes = token.getPriorVotes(msg.sender, p.snapshotBlock);

        if (support == 0) {
            p.againstVotes += votes;
        } else if (support == 1) {
            p.forVotes += votes;
        } else {
            p.abstainVotes += votes;
        }

        p.receipts[msg.sender] = Receipt({hasVoted: true, support: support, votes: votes});
        emit VoteCast(proposalId, msg.sender, support, votes);
    }

    // ==================== 执行 ====================

    /**
     * @dev 执行已通过提案。CEI：先置 executed=true 再对外 call，防重入。
     *      通过条件：forVotes > againstVotes 且 for+abstain >= quorum。
     */
    function execute(uint256 proposalId) external payable {
        require(state(proposalId) == ProposalState.Succeeded, "Gov: not succeeded");

        Proposal storage p = _proposals[proposalId];
        require(!p.executed && !p.canceled, "Gov: already executed/canceled");

        // checks-effects：先标记执行
        p.executed = true;

        // interactions：依次对每个 target 执行 low-level call
        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool ok,) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            require(ok, "Gov: call failed");
        }

        emit ProposalExecuted(proposalId, p.targets, p.values);
    }

    /// @dev 取消提案（仅提案者，未执行 / 未取消时）。
    function cancel(uint256 proposalId) external {
        Proposal storage p = _proposals[proposalId];
        require(p.proposer == msg.sender, "Gov: not proposer");
        require(!p.executed && !p.canceled, "Gov: executed/canceled");
        p.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    // ==================== 状态 / 视图 ====================

    /// @dev 提案当前状态。
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage p = _proposals[proposalId];
        require(p.proposer != address(0), "Gov: no proposal");

        if (p.canceled) return ProposalState.Canceled;
        if (p.executed) return ProposalState.Executed;
        if (block.number < p.startBlock) return ProposalState.Pending;
        if (block.number <= p.endBlock) return ProposalState.Active;

        if (_voteSucceeded(proposalId) && _quorumReached(proposalId)) {
            return ProposalState.Succeeded;
        }
        return ProposalState.Defeated;
    }

    /// @dev 赞成票 > 反对票。
    function _voteSucceeded(uint256 proposalId) internal view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        return p.forVotes > p.againstVotes;
    }

    /// @dev 赞成+弃权 >= 法定人数。
    function _quorumReached(uint256 proposalId) internal view returns (bool) {
        Proposal storage p = _proposals[proposalId];
        return p.forVotes + p.abstainVotes >= quorumVotes(proposalId);
    }

    /// @dev 法定人数阈值 = totalSupply * quorumNumerator / 100。
    function quorumVotes(uint256 proposalId) public view returns (uint256) {
        require(_proposals[proposalId].proposer != address(0), "Gov: no proposal");
        return (token.totalSupply() * quorumNumerator) / 100;
    }

    /// @dev 提案快照块。
    function proposalSnapshot(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].snapshotBlock;
    }

    /// @dev 投票截止块。
    function proposalDeadline(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].endBlock;
    }

    /// @dev 提案动作（targets / values / calldatas）。
    function getActions(uint256 proposalId)
        external
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        Proposal storage p = _proposals[proposalId];
        return (p.targets, p.values, p.calldatas);
    }

    /// @dev 提案计票结果。
    function getProposalTally(uint256 proposalId)
        external
        view
        returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes)
    {
        Proposal storage p = _proposals[proposalId];
        return (p.forVotes, p.againstVotes, p.abstainVotes);
    }

    /// @dev 某投票者的投票凭证。
    function getReceipt(uint256 proposalId, address voter) external view returns (Receipt memory) {
        return _proposals[proposalId].receipts[voter];
    }

    /// @dev 提案者。
    function proposer(uint256 proposalId) external view returns (address) {
        return _proposals[proposalId].proposer;
    }

    /// @dev 提案描述。
    function proposalDescription(uint256 proposalId) external view returns (string memory) {
        return _proposals[proposalId].description;
    }
}
