// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {RebaseToken} from "../../src/rebase-token/RebaseToken.sol";

/**
 * @title RebaseTokenTest
 * @dev 验证通缩型 rebase ERC20：
 *   - 初始状态（1 亿发行量、deployer 持有全部）
 *   - 时间门控（未满一年 rebase revert）
 *   - 单年 / 多年复利通缩（99M → 98.01M → 97.0299M）
 *   - rebase 后 balanceOf / totalSupply 正确缩放
 *   - rebase 后转账的 raw↔elastic 换算正确
 *   - rebase 不动 _rawBalances（佐证 scaling-factor 原理）
 *   - 标准 approve / transferFrom
 *   - fuzz：n 年复利通缩一般式
 *
 * 时间说明：forge 测试环境 block.timestamp 初值为 1，故 warp 必须相对当前时间
 *           推进（block.timestamp + 365 days），否则会出现 off-by-one。
 */
contract RebaseTokenTest is Test {
    RebaseToken internal token;
    address internal deployer = vm.addr(1);
    address internal user2 = makeAddr("user2");
    address internal user3 = makeAddr("user3");

    uint256 internal constant FULL = 100_000_000 * 1e18; // 1 亿
    uint256 internal constant WAD = 1e18;

    function setUp() public {
        vm.prank(deployer);
        token = new RebaseToken();
    }

    /// @dev 推进 1 年（相对当前 block.timestamp，规避初值 off-by-one）
    function _advanceOneYear() internal {
        vm.warp(block.timestamp + 365 days);
    }

    // ===== 需求：初始发行量 1 亿 =====

    /// @dev 初始状态：name/symbol/decimals、totalSupply=1e8、deployer 持有全部、rebaseFactor=1.0
    function test_initial_state() public view {
        assertEq(token.name(), "Rebase Deflation Token");
        assertEq(token.symbol(), "RBDT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), FULL, "initial totalSupply should be 100M");
        assertEq(token.balanceOf(deployer), FULL, "deployer should hold all supply");
        assertEq(token.rebaseFactor(), WAD, "rebaseFactor should start at 1.0");
        assertEq(token.rebaseCount(), 0, "rebaseCount should be 0");
        assertEq(token.rawBalanceOf(deployer), FULL, "raw balance == full initially");
    }

    // ===== 需求：时间门控 =====

    /// @dev 构造后未满一年调用 rebase 应 revert
    function test_rebase_reverts_before_interval() public {
        vm.expectRevert(bytes("Rebase: interval not elapsed"));
        token.rebase();
    }

    /// @dev 差一秒也不行：推进 365 days - 1 仍 revert
    function test_rebase_reverts_one_sec_before() public {
        vm.warp(block.timestamp + 365 days - 1);
        vm.expectRevert(bytes("Rebase: interval not elapsed"));
        token.rebase();
    }

    // ===== 需求：单年 rebase 通缩 1% =====

    /// @dev 满 1 年 rebase：totalSupply 100M → 99M，deployer 余额同步，rebaseFactor=0.99
    function test_single_year_rebase() public {
        _advanceOneYear();
        uint256 newTotal = token.rebase();

        assertEq(newTotal, 99_000_000 * 1e18, "rebase return should be 99M");
        assertEq(token.totalSupply(), 99_000_000 * 1e18, "totalSupply should be 99M");
        assertEq(token.balanceOf(deployer), 99_000_000 * 1e18, "deployer balance should be 99M");
        assertEq(token.rebaseFactor(), 99 * WAD / 100, "rebaseFactor should be 0.99e18");
        assertEq(token.rebaseCount(), 1, "rebaseCount should be 1");
    }

    // ===== 需求：多年复利通缩（在上年基础上下降 1%） =====

    /// @dev 三年复利通缩：依次 99M / 98.01M / 97.0299M
    function test_multi_year_compounding_rebase() public {
        // 第 1 年：100M → 99M
        _advanceOneYear();
        token.rebase();
        assertEq(token.totalSupply(), 99_000_000 * 1e18, "year1 totalSupply");
        assertEq(token.balanceOf(deployer), 99_000_000 * 1e18, "year1 deployer balance");

        // 第 2 年：99M → 98.01M
        _advanceOneYear();
        token.rebase();
        assertEq(token.totalSupply(), 98_010_000 * 1e18, "year2 totalSupply");
        assertEq(token.balanceOf(deployer), 98_010_000 * 1e18, "year2 deployer balance");

        // 第 3 年：98.01M → 97.0299M
        _advanceOneYear();
        token.rebase();
        // 97,029,900 × 1e18：用容差 1 处理整数取整
        assertApproxEqAbs(token.totalSupply(), 97_029_900 * 1e18, 1, "year3 totalSupply");
        assertApproxEqAbs(token.balanceOf(deployer), 97_029_900 * 1e18, 1, "year3 deployer balance");
        assertEq(token.rebaseCount(), 3, "rebaseCount should be 3");
    }

    // ===== 需求：balanceOf 反应通缩后用户余额 =====

    /// @dev 部署者先转 50M 给 user2，再 rebase → 两端余额均按 0.99 缩放为 49.5M
    function test_balance_reflects_rebase_after_transfer() public {
        vm.prank(deployer);
        token.transfer(user2, 50_000_000 * 1e18);

        // 转账后：各 50M，总量不变
        assertEq(token.balanceOf(deployer), 50_000_000 * 1e18);
        assertEq(token.balanceOf(user2), 50_000_000 * 1e18);

        // rebase 后两端均缩放至 49.5M
        _advanceOneYear();
        token.rebase();

        assertEq(token.balanceOf(deployer), 49_500_000 * 1e18, "deployer after rebase");
        assertEq(token.balanceOf(user2), 49_500_000 * 1e18, "user2 after rebase");
        assertEq(token.totalSupply(), 99_000_000 * 1e18, "totalSupply after rebase");
    }

    // ===== 需求：rebase 后转账换算正确 =====

    /// @dev rebase 后 deployer 持 99M，转 49.5M 给 user3 → 两端正确，raw 换算无误
    function test_transfer_after_rebase() public {
        _advanceOneYear();
        token.rebase();

        assertEq(token.balanceOf(deployer), 99_000_000 * 1e18, "deployer 99M before transfer");

        vm.prank(deployer);
        token.transfer(user3, 49_500_000 * 1e18);

        assertEq(token.balanceOf(deployer), 49_500_000 * 1e18, "deployer after transfer");
        assertEq(token.balanceOf(user3), 49_500_000 * 1e18, "user3 received");
        assertEq(token.totalSupply(), 99_000_000 * 1e18, "totalSupply unchanged by transfer");

        // 原 50M raw 的 deployer 弹性应 = 49.5M（验证 raw→elastic 一致）
        assertEq(token.rawToElastic(token.rawBalanceOf(deployer)), 49_500_000 * 1e18);
    }

    // ===== 原理验证：rebase 不动 _rawBalances =====

    /// @dev rebase 前后原始余额不变，仅 rebaseFactor 变化（scaling-factor 模式核心）
    function test_raw_balance_unchanged_after_rebase() public {
        uint256 rawBefore = token.rawBalanceOf(deployer);
        uint256 elasticBefore = token.balanceOf(deployer);
        assertEq(rawBefore, FULL);
        assertEq(elasticBefore, FULL);

        _advanceOneYear();
        token.rebase();

        uint256 rawAfter = token.rawBalanceOf(deployer);
        uint256 elasticAfter = token.balanceOf(deployer);

        assertEq(rawAfter, rawBefore, "raw balance must be unchanged");
        assertEq(elasticAfter, 99_000_000 * 1e18, "elastic balance scaled down");
        assertEq(token.rawToElastic(rawAfter), 99_000_000 * 1e18, "rawToElastic consistent");
    }

    // ===== 标准 ERC20：approve / transferFrom =====

    /// @dev 标准授权 + 代扣，余额与 allowance 正确变化
    function test_approve_transferFrom() public {
        vm.prank(deployer);
        token.approve(user2, 10_000_000 * 1e18);
        assertEq(token.allowance(deployer, user2), 10_000_000 * 1e18);

        // user2 代扣 6M 给 user3
        vm.prank(user2);
        token.transferFrom(deployer, user3, 6_000_000 * 1e18);

        assertEq(token.balanceOf(deployer), 94_000_000 * 1e18, "deployer balance");
        assertEq(token.balanceOf(user3), 6_000_000 * 1e18, "user3 balance");
        assertEq(token.allowance(deployer, user2), 4_000_000 * 1e18, "remaining allowance");
    }

    /// @dev 无限授权不扣减
    function test_approve_infinite_allowance_no_decrement() public {
        vm.prank(deployer);
        token.approve(user2, type(uint256).max);

        vm.prank(user2);
        token.transferFrom(deployer, user3, 1_000_000 * 1e18);

        assertEq(token.allowance(deployer, user2), type(uint256).max, "infinite allowance unchanged");
        assertEq(token.balanceOf(user3), 1_000_000 * 1e18);
    }

    /// @dev 代扣超出授权应 revert
    function test_transferFrom_exceeds_allowance_reverts() public {
        vm.prank(deployer);
        token.approve(user2, 5_000_000 * 1e18);

        vm.prank(user2);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        token.transferFrom(deployer, user3, 6_000_000 * 1e18);
    }

    // ===== fuzz：n 年复利通缩一般式 =====

    /// @dev n 年后 totalSupply ≈ 100M × (99/100)^n（容差 1e6 wei）
    function testFuzz_rebase_n_years(uint8 n) public {
        vm.assume(n > 0 && n <= 10);

        for (uint8 i = 0; i < n; i++) {
            _advanceOneYear();
            token.rebase();
        }

        // 期望 = FULL × (0.99)^n
        uint256 expected = FULL;
        for (uint8 i = 0; i < n; i++) {
            expected = expected * 99 / 100;
        }

        assertApproxEqAbs(token.totalSupply(), expected, 1e6, "fuzz totalSupply mismatch");
        assertApproxEqAbs(token.balanceOf(deployer), expected, 1e6, "fuzz deployer balance mismatch");
        assertEq(token.rebaseCount(), n, "rebaseCount should equal n");

        console2.log("n", uint256(n));
        console2.log("totalSupply", token.totalSupply());
        console2.log("expected", expected);
    }
}
