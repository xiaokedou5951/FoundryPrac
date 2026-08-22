// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {VoteToken} from "../../src/vote-govern/VoteToken.sol";
import {Bank} from "../../src/vote-govern/Bank.sol";
import {Governor} from "../../src/vote-govern/Governor.sol";

/**
 * @title VoteGovernTest
 * @dev 基于 Token 投票治理管理 Bank 资金 —— 综合测试。
 *
 * 覆盖：
 *   - VoteToken：部署 / 委托 / 自动委托自身 / 转账移动投票权 / 历史检查点（含二分查找） /
 *     getPriorVotes 边界（future block revert、无检查点返回 0）。
 *   - Bank：部署 / receive 注资 / withdraw 仅 admin / 越权 revert / 余额与零值校验 / setAdmin。
 *   - Governor：propose（提案者须有票）/ 状态机 Pending→Active→Succeeded/Defeated /
 *     castVote（计票、重复投票、非法 support、未到/已过）/ quorum 与多数 / execute 端到端
 *     调 Bank.withdraw 把资金打给收款人 / cancel。
 *
 * 计票依赖区块号：setUp 在完成转账与委托后 vm.roll 推进若干块，使后续 getPriorVotes(block.number-1)
 * 能命中检查点。测试中以 proposalSnapshot / proposalDeadline 相对推进，避免硬编码绝对块号。
 *
 * 运行：forge test --match-path test/vote-govern/VoteGovern.t.sol -vvv
 */
contract VoteGovernTest is Test {
    VoteToken public token;
    Governor public gov;
    Bank public bank;

    // 测试账户
    address public deployer; // = address(this)，初始供应持有者 / 提案者
    address public alice; // 持 100_000e18
    address public bob; // 持 100_000e18
    address public carol; // 小额持有者 10_000e18（用于 quorum 不足场景）
    address public nobody; // 无代币

    // 参数
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 1e18; // 1,000,000 VGT
    uint256 public constant VOTING_DELAY = 1; // 1 块后开投票
    uint256 public constant VOTING_PERIOD = 10; // 投票 10 块
    uint256 public constant QUORUM_NUM = 4; // 4% => quorum = 40_000e18
    uint256 public constant BANK_FUND = 10 ether;

    // support 取值
    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;
    uint8 internal constant ABSTAIN = 2;

    function setUp() public {
        deployer = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        nobody = makeAddr("nobody");

        vm.deal(deployer, 100 ether); // 测试合约自身持 ETH，用于注资 Bank

        // 1. 部署 VoteToken（一次性 mint 给 deployer）
        token = new VoteToken(INITIAL_SUPPLY);
        // 2. 部署 Governor（Governor 不引用 Bank，Bank 只是提案 target）
        gov = new Governor(address(token), VOTING_DELAY, VOTING_PERIOD, QUORUM_NUM);
        // 3. 部署 Bank，admin = governor
        bank = new Bank(payable(address(gov)));

        // 4. 分发代币（auto-self-delegation：转账即给收款人建立投票权检查点）
        token.transfer(alice, 100_000 * 1e18);
        token.transfer(bob, 100_000 * 1e18);
        token.transfer(carol, 10_000 * 1e18); // deployer 自留 790_000e18
        // 5. 注资 Bank
        (bool ok,) = payable(address(bank)).call{value: BANK_FUND}("");
        require(ok, "setUp: fund bank failed");

        // 6. 推进区块：使后续 propose 的 getPriorVotes(block.number-1) 命中检查点
        vm.roll(block.number + 100);
    }

    // ==================== 内部辅助 ====================

    /// @dev 构造"从 Bank 提取 amount ETH 给 to"的提案动作三件套。
    function _withdrawAction(address to, uint256 amount)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(bank);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(Bank.withdraw.selector, to, amount);
    }

    /// @dev deployer 发起"从 Bank 提取"提案，返回 proposalId。
    function _proposeWithdraw(address to, uint256 amount, string memory desc) internal returns (uint256) {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _withdrawAction(to, amount);
        return gov.propose(t, v, c, desc);
    }

    /// @dev 推进到投票开始块（Active）。
    function _rollToActive(uint256 id) internal {
        uint256 start = gov.proposalSnapshot(id) + gov.votingDelay();
        vm.roll(start);
    }

    /// @dev 推进到投票结束之后。
    function _rollPastEnd(uint256 id) internal {
        vm.roll(gov.proposalDeadline(id) + 1);
    }

    // ==================== VoteToken 部署 ====================

    function test_VoteToken_Deployment() public view {
        assertEq(token.name(), "Vote Governance Token");
        assertEq(token.symbol(), "VGT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(deployer), 790_000 * 1e18);
    }

    // ==================== VoteToken 委托 / 计票 ====================

    /// @dev 自动委托自身：mint 后 deployer 持全部供应的票。
    function test_VoteToken_AutoSelfDelegation() public view {
        assertEq(token.getCurrentVotes(deployer), 790_000 * 1e18);
        assertEq(token.getCurrentVotes(alice), 100_000 * 1e18); // 转账即委托自身
        assertEq(token.getCurrentVotes(bob), 100_000 * 1e18);
        assertEq(token.getCurrentVotes(carol), 10_000 * 1e18);
    }

    /// @dev 显式委托自身：票数不变，仅记录 delegates 映射。
    function test_VoteToken_DelegateSelf() public {
        vm.expectEmit(true, true, true, false);
        emit VoteToken.DelegateChanged(alice, alice, alice);
        vm.prank(alice);
        token.delegate(alice);
        assertEq(token.delegates(alice), alice);
        assertEq(token.getCurrentVotes(alice), 100_000 * 1e18);
    }

    /// @dev 委托他人：票从 deployer 移到 alice。
    function test_VoteToken_DelegateOther_MovesVotes() public {
        uint256 depBefore = token.getCurrentVotes(deployer);
        uint256 aliBefore = token.getCurrentVotes(alice);

        token.delegate(alice); // deployer 把全部余额委托给 alice
        assertEq(token.delegates(deployer), alice);
        assertEq(token.getCurrentVotes(deployer), 0);
        assertEq(token.getCurrentVotes(alice), aliBefore + depBefore); // alice 收到 deployer 全部票
        assertEq(token.balanceOf(deployer), 790_000 * 1e18); // 余额不变
        // 撤销：委托回自身
        token.delegate(deployer);
        assertEq(token.getCurrentVotes(deployer), depBefore);
        assertEq(token.getCurrentVotes(alice), aliBefore);
    }

    /// @dev 转账在两个 self-delegatee 之间移动投票权。
    function test_VoteToken_Transfer_MovesVotingPower() public {
        uint256 aliBefore = token.getCurrentVotes(alice);
        uint256 carBefore = token.getCurrentVotes(carol);

        vm.prank(alice);
        token.transfer(carol, 30_000 * 1e18);

        assertEq(token.getCurrentVotes(alice), aliBefore - 30_000 * 1e18);
        assertEq(token.getCurrentVotes(carol), carBefore + 30_000 * 1e18);
        assertEq(token.balanceOf(carol), 40_000 * 1e18);
    }

    /// @dev 历史检查点：多检查点的二分查找正确。
    function test_VoteToken_GetPriorVotes_MultipleCheckpoints() public {
        // 推进前的过去块应返回 alice 当前的 100_000e18
        uint256 past = block.number - 1;
        assertEq(token.getPriorVotes(alice, past), 100_000 * 1e18);

        // 块 1：转 10_000 给 alice -> 110_000
        uint256 cp1 = block.number;
        vm.roll(cp1 + 1);
        token.transfer(alice, 10_000 * 1e18);
        cp1 = block.number; // 此检查点 fromBlock

        // 块 2：再转 5_000 -> 115_000
        uint256 cp2 = block.number;
        vm.roll(cp2 + 1);
        token.transfer(alice, 5_000 * 1e18);
        cp2 = block.number;

        // 推进到 cp2 之后以便查询 cp2
        vm.roll(cp2 + 1);

        assertEq(token.getPriorVotes(alice, cp1), 110_000 * 1e18); // cp1 处 = 110k
        assertEq(token.getPriorVotes(alice, cp1 - 1), 100_000 * 1e18); // cp1 前一块 = 100k
        assertEq(token.getPriorVotes(alice, cp2), 115_000 * 1e18); // cp2 处 = 115k
        assertEq(token.getPriorVotes(alice, cp2 - 1), 110_000 * 1e18); // cp2 前一块 = 110k
    }

    /// @dev 查询当前/未来块 revert。
    function test_VoteToken_GetPriorVotes_FutureBlock_Reverts() public {
        vm.expectRevert("VGT: future block");
        token.getPriorVotes(alice, block.number);
        vm.expectRevert("VGT: future block");
        token.getPriorVotes(alice, block.number + 1);
    }

    /// @dev 无检查点的账户返回 0。
    function test_VoteToken_GetPriorVotes_NoCheckpoint_ReturnsZero() public view {
        assertEq(token.getPriorVotes(nobody, block.number - 1), 0);
    }

    /// @dev 委托给 0 地址 revert。
    function test_VoteToken_DelegateZero_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("VGT: delegate to zero");
        token.delegate(address(0));
    }

    // ==================== Bank ====================

    function test_Bank_Deployment() public view {
        assertEq(bank.admin(), address(gov));
        assertEq(bank.balance(), BANK_FUND);
    }

    /// @dev receive 注资 + 事件。
    function test_Bank_ReceiveFunds() public {
        vm.expectEmit(true, false, false, true);
        emit Bank.Received(alice, 1 ether);
        vm.prank(alice);
        vm.deal(alice, 1 ether);
        (bool ok,) = payable(address(bank)).call{value: 1 ether}("");
        require(ok);
        assertEq(bank.balance(), BANK_FUND + 1 ether);
    }

    /// @dev admin（governor）提取到收款人。
    function test_Bank_Withdraw_Admin_SendsToRecipient() public {
        uint256 bankBefore = bank.balance();
        uint256 aliBal = alice.balance;

        vm.prank(address(gov));
        vm.expectEmit(true, false, false, true);
        emit Bank.Withdraw(alice, 1 ether);
        bank.withdraw(alice, 1 ether);

        assertEq(alice.balance, aliBal + 1 ether);
        assertEq(bank.balance(), bankBefore - 1 ether);
    }

    function test_Bank_Withdraw_NotAdmin_Reverts() public {
        vm.prank(alice);
        vm.expectRevert("Bank: not admin");
        bank.withdraw(alice, 1 ether);
    }

    function test_Bank_Withdraw_ZeroTo_Reverts() public {
        vm.prank(address(gov));
        vm.expectRevert("Bank: zero to");
        bank.withdraw(address(0), 1 ether);
    }

    function test_Bank_Withdraw_ZeroAmount_Reverts() public {
        vm.prank(address(gov));
        vm.expectRevert("Bank: zero amount");
        bank.withdraw(alice, 0);
    }

    function test_Bank_Withdraw_Insufficient_Reverts() public {
        vm.prank(address(gov));
        vm.expectRevert("Bank: insufficient");
        bank.withdraw(alice, BANK_FUND + 1);
    }

    /// @dev setAdmin 迁移：新 admin 可提，旧 admin 不可。
    function test_Bank_SetAdmin() public {
        vm.prank(address(gov));
        bank.setAdmin(alice);

        // 旧 admin(gov) 现在越权
        vm.prank(address(gov));
        vm.expectRevert("Bank: not admin");
        bank.withdraw(bob, 1 ether);

        // 新 admin(alice) 可提
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        bank.withdraw(bob, 2 ether);
        assertEq(bob.balance, bobBefore + 2 ether);
    }

    // ==================== Governor 提案 ====================

    function test_Propose_Success() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "withdraw 1 eth to alice");
        assertEq(id, 1);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Pending));
        // snapshot = propose 块；start = snapshot + delay；end = start + period
        assertEq(gov.proposalSnapshot(id), block.number);
        assertEq(gov.proposalDeadline(id), block.number + VOTING_DELAY + VOTING_PERIOD);
        assertEq(gov.proposer(id), deployer);
        assertEq(gov.proposalDescription(id), "withdraw 1 eth to alice");
    }

    function test_Propose_EmitsEvent() public {
        (address[] memory t, uint256[] memory v,) = _withdrawAction(alice, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Governor.ProposalCreated(
            1, deployer, t, v, "d", block.number + VOTING_DELAY, block.number + VOTING_DELAY + VOTING_PERIOD
        );
        gov.propose(t, v, new bytes[](1), "d");
    }

    function test_Propose_NoVotes_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _withdrawAction(alice, 1 ether);
        vm.prank(nobody);
        vm.expectRevert("Gov: proposer no votes");
        gov.propose(t, v, c, "no votes");
    }

    function test_Propose_LenMismatch_Reverts() public {
        address[] memory t = new address[](1);
        t[0] = address(bank);
        uint256[] memory v = new uint256[](1);
        bytes[] memory c = new bytes[](2); // 与 t/v 长度不一致
        c[0] = "";
        c[1] = "";
        vm.expectRevert("Gov: len mismatch");
        gov.propose(t, v, c, "bad len");
    }

    function test_Propose_EmptyDesc_Reverts() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _withdrawAction(alice, 1 ether);
        vm.expectRevert("Gov: empty desc");
        gov.propose(t, v, c, "");
    }

    // ==================== Governor 投票 / 状态机 ====================

    /// @dev Pending -> Active -> Succeeded。
    function test_State_Transitions_ToSucceeded() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Pending));

        _rollToActive(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Active));

        // alice + bob 赞成（200_000 票 >= quorum 40_000，且 for>against）
        vm.prank(alice);
        gov.castVote(id, FOR);
        vm.prank(bob);
        gov.castVote(id, FOR);

        _rollPastEnd(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Succeeded));
    }

    function test_CastVote_RecordsReceiptAndTally() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);

        vm.prank(alice);
        uint256 votes = gov.castVote(id, FOR);
        assertEq(votes, 100_000 * 1e18); // snapshot 时 alice 的票

        (uint256 f, uint256 a, uint256 ab) = gov.getProposalTally(id);
        assertEq(f, 100_000 * 1e18);
        assertEq(a, 0);
        assertEq(ab, 0);

        Governor.Receipt memory r = gov.getReceipt(id, alice);
        assertTrue(r.hasVoted);
        assertEq(r.support, FOR);
        assertEq(r.votes, 100_000 * 1e18);
    }

    function test_CastVote_BeforeActive_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        vm.prank(alice);
        vm.expectRevert("Gov: not active");
        gov.castVote(id, FOR);
    }

    function test_CastVote_AfterEnd_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollPastEnd(id);
        vm.prank(alice);
        vm.expectRevert("Gov: not active");
        gov.castVote(id, FOR);
    }

    function test_CastVote_DoubleVote_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.startPrank(alice);
        gov.castVote(id, FOR);
        vm.expectRevert("Gov: voted");
        gov.castVote(id, FOR);
        vm.stopPrank();
    }

    function test_CastVote_BadSupport_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        vm.expectRevert("Gov: bad support");
        gov.castVote(id, 3);
    }

    /// @dev abstain 计入 quorum 但不计入多数：仅 alice 赞成 + carol 弃权仍可达 quorum。
    function test_CastVote_Abstain_CountsQuorumOnly() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, FOR); // 100_000 for
        vm.prank(carol);
        gov.castVote(id, ABSTAIN); // 10_000 abstain
        _rollPastEnd(id);

        // for=100k >= quorum 40k，for>against => Succeeded（abstain 不影响多数）
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Succeeded));
        (uint256 f, uint256 a, uint256 ab) = gov.getProposalTally(id);
        assertEq(f, 100_000 * 1e18);
        assertEq(a, 0);
        assertEq(ab, 10_000 * 1e18);
    }

    /// @dev quorum 未达：仅 carol（10_000）赞成 < quorum 40_000。
    function test_Defeated_QuorumNotReached() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(carol);
        gov.castVote(id, FOR); // 10_000 < quorum
        _rollPastEnd(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Defeated));
    }

    /// @dev for <= against：alice 反对、bob 赞成，平票 => 不满足 for>against => Defeated。
    function test_Defeated_ForNotGreaterThanAgainst() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, AGAINST); // 100_000 against
        vm.prank(bob);
        gov.castVote(id, FOR); // 100_000 for（不大于 against）
        _rollPastEnd(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Defeated));
    }

    // ==================== Governor 执行（端到端） ====================

    /// @dev 核心：propose(withdraw alice 1 ETH) -> vote -> execute -> alice 收到 ETH、Bank 减 1 ETH。
    function test_Execute_EndToEnd_BankWithdraw() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "withdraw 1 eth to alice");

        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, FOR);
        vm.prank(bob);
        gov.castVote(id, FOR);

        _rollPastEnd(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Succeeded));

        uint256 aliBefore = alice.balance;
        uint256 bankBefore = bank.balance();

        gov.execute(id);

        assertEq(alice.balance, aliBefore + 1 ether); // 收款人到账
        assertEq(bank.balance(), bankBefore - 1 ether); // 国库扣减

        (, uint256[] memory values,) = gov.getActions(id);
        // 不直接断言 emitted target 列表（数组比较繁琐），改断言执行后状态
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Executed));

        // 避免未使用变量告警
        if (values.length == 0) {}
    }

    /// @dev execute 时 governor 作为 bank.admin 通过权限校验（已在端到端中体现，此处补一次显式断言）。
    function test_Execute_GovernorIsBankAdmin() public view {
        assertEq(bank.admin(), address(gov));
    }

    function test_Execute_NotSucceeded_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(carol);
        gov.castVote(id, FOR); // quorum 不足
        _rollPastEnd(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Defeated));
        vm.expectRevert("Gov: not succeeded");
        gov.execute(id);
    }

    function test_Execute_BeforeEnd_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, FOR);
        // 仍在投票期
        vm.expectRevert("Gov: not succeeded");
        gov.execute(id);
    }

    function test_Execute_AlreadyExecuted_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, FOR);
        vm.prank(bob);
        gov.castVote(id, FOR);
        _rollPastEnd(id);
        gov.execute(id);
        vm.expectRevert("Gov: not succeeded"); // executed 后 state()=Executed，非 Succeeded
        gov.execute(id);
    }

    // ==================== Governor 取消 ====================

    function test_Cancel_ByProposer() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        gov.cancel(id);
        assertEq(uint256(gov.state(id)), uint256(Governor.ProposalState.Canceled));
        // 取消后不可执行
        _rollPastEnd(id);
        vm.expectRevert("Gov: not succeeded");
        gov.execute(id);
    }

    function test_Cancel_EmitsEvent() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        vm.expectEmit(true, false, false, true);
        emit Governor.ProposalCanceled(id);
        gov.cancel(id);
    }

    function test_Cancel_NotProposer_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        vm.prank(alice);
        vm.expectRevert("Gov: not proposer");
        gov.cancel(id);
    }

    function test_Cancel_AfterExecute_Reverts() public {
        uint256 id = _proposeWithdraw(alice, 1 ether, "p");
        _rollToActive(id);
        vm.prank(alice);
        gov.castVote(id, FOR);
        vm.prank(bob);
        gov.castVote(id, FOR);
        _rollPastEnd(id);
        gov.execute(id);
        vm.expectRevert("Gov: executed/canceled");
        gov.cancel(id);
    }

    // ==================== 端到端全流程 ====================

    /// @dev 完整链路：提案 -> 多人投票（含弃权）-> 执行 -> 多笔提款 -> 校验资金流转。
    function test_FullLifecycle() public {
        // 提案 1：从 Bank 提 3 ETH 给 bob
        uint256 id1 = _proposeWithdraw(bob, 3 ether, "grant 3 eth to bob");
        _rollToActive(id1);
        vm.prank(alice);
        gov.castVote(id1, FOR);
        vm.prank(bob);
        gov.castVote(id1, FOR);
        vm.prank(carol);
        gov.castVote(id1, ABSTAIN); // 弃权仍计 quorum
        _rollPastEnd(id1);
        assertEq(uint256(gov.state(id1)), uint256(Governor.ProposalState.Succeeded));

        uint256 bobBefore = bob.balance;
        uint256 bankBefore = bank.balance();
        gov.execute(id1);
        assertEq(bob.balance, bobBefore + 3 ether);
        assertEq(bank.balance(), bankBefore - 3 ether);

        // 提案 2：再提 2 ETH 给 alice（验证多次提案 + 持续可用）
        uint256 id2 = _proposeWithdraw(alice, 2 ether, "grant 2 eth to alice");
        _rollToActive(id2);
        vm.prank(alice);
        gov.castVote(id2, FOR);
        vm.prank(bob);
        gov.castVote(id2, FOR);
        _rollPastEnd(id2);
        assertEq(uint256(gov.state(id2)), uint256(Governor.ProposalState.Succeeded));

        uint256 aliBefore = alice.balance;
        gov.execute(id2);
        assertEq(alice.balance, aliBefore + 2 ether);
        assertEq(bank.balance(), BANK_FUND - 3 ether - 2 ether); // 累计 5 ETH
    }

    receive() external payable {}
}
