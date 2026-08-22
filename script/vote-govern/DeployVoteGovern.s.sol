// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {VoteToken} from "../../src/vote-govern/VoteToken.sol";
import {Bank} from "../../src/vote-govern/Bank.sol";
import {Governor} from "../../src/vote-govern/Governor.sol";

/**
 * @title DeployVoteGovern
 * @dev 本地测试网（anvil）一键部署：VoteToken + Governor + Bank 三件套并注资国库。
 *
 * 运行方式：
 *   1. 启动本地链：anvil
 *   2. 执行脚本：
 *      forge script script/vote-govern/DeployVoteGovern.s.sol \
 *        --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 *
 * 部署顺序（避免循环依赖：Governor 不引用 Bank，Bank 只是把 admin 设为 Governor）：
 *   - 部署 VoteToken（1,000,000 VGT，一次性 mint 给部署者）
 *   - 部署 Governor(token, votingDelay=1, votingPeriod=1000, quorumNumerator=4)
 *   - 部署 Bank(admin=governor)
 *   - 向 Bank 注资 10 ETH（国库充值）
 *   - 部署者显式 delegate(self)（演示委托接口；未显式委托时 VoteToken 亦视作自委托）
 *
 * 治理使用示例（本脚本只负责部署；完整多选民投票演示见 test/vote-govern/demo.sh，
 * 其用 shell + cast 在真实 anvil 链上编排 propose -> 多账户各自签名 castVote
 * -> anvil_mine 推进区块 -> execute -> Bank.withdraw）：
 *   - 部署者向国库提议：targets=[bank], values=[0],
 *     calldatas=[abi.encodeWithSelector(Bank.withdraw.selector, recipient, 1 ether)]
 *   - 推进 votingDelay 个块 -> 持币者 castVote(id, 1)
 *   - 推进过 endBlock -> governor.execute(id) -> recipient 收到 ETH
 */
contract DeployVoteGovern is Script {
    // anvil 默认账户 #0，可通过环境变量 PRIVATE_KEY 覆盖
    uint256 constant ANVIL_DEFAULT_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    uint256 constant INITIAL_SUPPLY = 1_000_000 * 1e18;
    uint256 constant VOTING_DELAY = 1; // 1 块后开投票
    uint256 constant VOTING_PERIOD = 1000; // 投票持续 1000 块
    uint256 constant QUORUM_NUM = 4; // 4% 法定人数
    uint256 constant BANK_FUND = 10 ether; // 国库初始注资

    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(ANVIL_DEFAULT_PK));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // ===== 1. 部署 VoteToken（一次性 mint 给 deployer）=====
        VoteToken token = new VoteToken(INITIAL_SUPPLY);

        // ===== 2. 部署 Governor（不引用 Bank）=====
        Governor gov = new Governor(address(token), VOTING_DELAY, VOTING_PERIOD, QUORUM_NUM);

        // ===== 3. 部署 Bank，admin = governor =====
        Bank bank = new Bank(address(gov));

        // ===== 4. 向 Bank 注资（国库充值，触发 Received 事件）=====
        (bool ok,) = payable(address(bank)).call{value: BANK_FUND}("");
        require(ok, "deploy: fund bank failed");

        // ===== 5. deployer 显式自委托（演示委托接口；mint 时投票权已自动建立）=====
        token.delegate(deployer);

        vm.stopBroadcast();

        // ===== 6. 打印地址与参数 =====
        console.log("=== Deployed Vote-Govern ===");
        console.log("VoteToken:        ", address(token));
        console.log("Governor:         ", address(gov));
        console.log("Bank:             ", address(bank));
        console.log("deployer(issuer): ", deployer);
        console.log("--- token params ---");
        console.log("name/symbol:      ", token.name(), token.symbol());
        console.log("totalSupply:      ", token.totalSupply());
        console.log("--- governor params ---");
        console.log("votingDelay:      ", gov.votingDelay());
        console.log("votingPeriod:     ", gov.votingPeriod());
        console.log("quorumNumerator:  ", gov.quorumNumerator());
        console.log("--- bank ---");
        console.log("bank.admin == gov:", bank.admin() == address(gov));
        console.log("bank.balance:     ", bank.balance());
        console.log("deployer votes:   ", token.getCurrentVotes(deployer));
    }
}
