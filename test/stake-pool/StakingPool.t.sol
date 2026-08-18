// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {StakingPool} from "../../src/stake-pool/StakingPool.sol";
import {KKToken} from "../../src/stake-pool/KKToken.sol";

/// @dev WETH9 最小接口（fork 主网直接绑定地址）
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev aWETH 只读余额
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title StakingPoolTest
 * @dev Fork 主网 + 现成 Aave V3：验证 ETH 质押→Aave 存款集成、KK 奖励公平分配、
 *      unstake 取回本金、owner 利息提取权限与 happy path。
 */
contract StakingPoolTest is Test {
    // 主网地址（fork 时直接用，与 flash-loan 模块一致）
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    // Aave V3 主网 aWETH（symbol="aEthWETH"），由构造参数传入（Pool 已不暴露 getter）
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    StakingPool internal pool;
    KKToken internal kk;
    IERC20 internal aWeth;
    address internal user1 = address(0x1111);
    address internal user2 = address(0x2222);

    function setUp() public {
        // Fork 主网（不固定区块号，避免归档节点限制）
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        pool = new StakingPool(AAVE_POOL, WETH, AWETH);
        kk = KKToken(pool.kkToken());
        aWeth = IERC20(pool.aWeth());

        // 给测试用户发放 ETH
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ===== 需求 3 验证：stake 已集成 Aave supply =====

    /// @dev 质押后 aWETH 余额 == 质押量，证明 Pool.supply 成功执行
    function test_stake_supplies_to_aave() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        // aWETH 因 Aave scaled 取整可能比质押量少 1~2 wei
        assertApproxEqAbs(aWeth.balanceOf(address(pool)), 1 ether, 1000, "aWETH should ~ equal staked");
        assertEq(pool.totalStaked(), 1 ether, "totalStaked should equal staked");
        (uint256 amt1,) = pool.userInfo(user1);
        assertEq(amt1, 1 ether, "user amount mismatch");
    }

    // ===== 需求 1 验证：KK 每区块 10 个，按数量×时长公平分配 =====

    /// @dev 单人质押 10 个区块应得 100 KK（10 × 10）
    function test_reward_single_user() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        uint256 blockBefore = block.number;
        vm.roll(blockBefore + 10);

        uint256 pending = pool.pendingReward(user1);
        assertEq(pending, 100 ether, "pending should be 100 KK");

        vm.prank(user1);
        pool.claimReward();

        assertEq(kk.balanceOf(user1), 100 ether, "user1 KK should be 100");
    }

    /// @dev 两人按质押数量与时长公平分配：user1 质押全程，user2 半程加入
    ///      - 区间1（10 块）仅 user1：100 KK 全归 user1
    ///      - 区间2（10 块）两人各 1 ETH：100 KK 平分 → 各 +50
    ///      - 合计 user1=150 KK，user2=50 KK
    function test_reward_pro_rata() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        uint256 blockBefore = block.number;
        vm.roll(blockBefore + 10);

        // user2 半程加入
        vm.startPrank(user2);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        vm.roll(blockBefore + 20);

        vm.prank(user1);
        pool.claimReward();
        vm.prank(user2);
        pool.claimReward();

        assertEq(kk.balanceOf(user1), 150 ether, "user1 should get 150 KK");
        assertEq(kk.balanceOf(user2), 50 ether, "user2 should get 50 KK");

        console2.log("user1 KK:", kk.balanceOf(user1));
        console2.log("user2 KK:", kk.balanceOf(user2));
    }

    // ===== unstake 验证：取回本金 + 结算 KK + aWETH 下降 =====

    /// @dev 质押→roll→unstake：用户收回 ETH 本金，KK 已结算，aWETH 余额相应下降
    function test_unstake_returns_eth_and_settles_kk() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 2 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        uint256 blockBefore = block.number;
        vm.roll(blockBefore + 5); // 5 块 → 50 KK

        uint256 balBefore = user1.balance;
        // aWETH 因 Aave scaled 取整可能比质押量少 1~2 wei
        assertApproxEqAbs(aWeth.balanceOf(address(pool)), 2 ether, 1000, "aWETH before unstake");

        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.unstake(2 ether);
        vm.resumeGasMetering();
        vm.stopPrank();

        // 本金返还（容 1~2 wei 取整）
        assertApproxEqAbs(user1.balance - balBefore, 2 ether, 1000, "user should get ~2 ETH back");
        // aWETH 已被 Aave withdraw 抵扣
        assertEq(aWeth.balanceOf(address(pool)), 0, "aWETH should be 0 after full unstake");
        assertEq(pool.totalStaked(), 0, "totalStaked should be 0");
        (uint256 amtAfter,) = pool.userInfo(user1);
        assertEq(amtAfter, 0, "user amount should be 0");
        // KK 已结算（5 块 × 10 = 50 KK）
        assertEq(kk.balanceOf(user1), 50 ether, "user1 KK should be 50");
    }

    // ===== owner 利息提取验证 =====

    /// @dev 非 owner 调 ownerClaimInterest 应 revert
    function test_owner_claim_interest_access_control() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert(bytes("StakePool: not owner"));
        pool.ownerClaimInterest();
    }

    /// @dev 刚质押后无利息：interest=0，函数不 revert，aWETH 余额保持=本金
    function test_owner_claim_interest_happy_path() public {
        vm.startPrank(user1);
        vm.pauseGasMetering();
        pool.stake{value: 1 ether}();
        vm.resumeGasMetering();
        vm.stopPrank();

        // 此时 aWETH 因取整可能略小于本金 → interest = 0（aBal <= totalStaked）
        assertApproxEqAbs(aWeth.balanceOf(address(pool)), pool.totalStaked(), 1000, "no interest yet");

        // owner 即测试合约本身，直接调用
        pool.ownerClaimInterest(); // 不应 revert

        // 仍无变化
        assertApproxEqAbs(aWeth.balanceOf(address(pool)), 1 ether, 1000, "aWETH unchanged");
        assertEq(pool.totalStaked(), 1 ether, "totalStaked unchanged");
    }
}
