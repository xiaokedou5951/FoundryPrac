// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {TokenVesting} from "../../src/token-vesting/Vesting.sol";
import {MyERC20} from "../../src/MyERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TokenVestingTest
 * @dev TokenVesting 合约综合测试
 *
 * 释放规则：
 *   - 0~12个月（cliff锁定期）：不可释放任何代币
 *   - 13~36个月（线性释放期）：按时间线性释放
 *   - 36个月后：全部释放完毕
 *
 * 运行命令：forge test test/token-vesting/TokenVesting.t.sol -vvv
 */
contract TokenVestingTest is Test {
    TokenVesting public vesting;   // 主测试合约
    MyERC20 public token;           // 测试用ERC20代币

    address public owner;           // 合约所有者（部署者）
    address public beneficiary;    // 受益人
    address public stranger;        // 无关第三方

    // 测试参数
    uint256 public constant TOTAL_AMOUNT = 1_000_000 ether;       // 总锁仓金额
    uint256 public constant CLIFF_DURATION = 365 days;             // 12个月锁定期
    uint256 public constant VESTING_DURATION = 730 days;           // 24个月释放期
    uint256 public constant TOTAL_DURATION = CLIFF_DURATION + VESTING_DURATION; // 36个月总期限

    /**
     * @dev 测试初始化：部署代币和Vesting合约，存入代币
     * 每个测试函数执行前都会调用此函数
     */
    function setUp() public {
        // 使用测试合约自身作为owner
        owner = address(this);
        beneficiary = makeAddr("beneficiary"); // 通过地址派生创建固定地址
        stranger = makeAddr("stranger");

        // 部署测试代币（初始供应量默认给部署者）
        token = new MyERC20("Test Token", "TT");

        // 部署Vesting合约（owner = address(this)，beneficiary固定地址）
        vesting = new TokenVesting(IERC20(address(token)), beneficiary);

        // 将代币approve给Vesting合约，然后存入
        token.approve(address(vesting), TOTAL_AMOUNT);
        vesting.deposit(TOTAL_AMOUNT);

        console.log("Vesting deployed at:", address(vesting));
        console.log("Beneficiary:", beneficiary);
        console.log("Owner:", owner);
    }

    // ==================== 部署测试 ====================

    /**
     * @dev 验证合约部署后所有状态变量正确初始化
     */
    function test_Deployment() public view {
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.beneficiary(), beneficiary);
        assertEq(vesting.totalAmount(), TOTAL_AMOUNT);
        assertEq(vesting.releasedAmount(), 0);
        assertEq(vesting.cliffDuration(), CLIFF_DURATION);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertTrue(vesting.startTime() > 0);
    }

    /**
     * @dev 验证传入零地址代币时构造函数revert
     */
    function test_Deployment_ZeroTokenAddress_Reverts() public {
        vm.expectRevert("Token address cannot be zero");
        new TokenVesting(IERC20(address(0)), beneficiary);
    }

    /**
     * @dev 验证传入零地址受益人时构造函数revert
     */
    function test_Deployment_ZeroBeneficiary_Reverts() public {
        vm.expectRevert("Beneficiary cannot be zero address");
        new TokenVesting(IERC20(address(token)), address(0));
    }

    // ==================== 存款测试 ====================

    /**
     * @dev 验证非owner无法存款
     */
    function test_Deposit_NotOwner_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        vesting.deposit(100 ether);
    }

    /**
     * @dev 验证存入0金额会revert
     */
    function test_Deposit_ZeroAmount_Reverts() public {
        vm.expectRevert("Amount must be greater than 0");
        vesting.deposit(0);
    }

    /**
     * @dev 验证重复存款会revert（已存过的合约不可二次存款）
     */
    function test_Deposit_DoubleDeposit_Reverts() public {
        vm.expectRevert("Tokens already deposited");
        vesting.deposit(100 ether);
    }

    /**
     * @dev 验证存款成功时发射TokensDeposited事件
     * 使用新代币+新合约避免余额不足问题
     */
    function test_Deposit_Success_EmitsEvent() public {
        MyERC20 freshToken = new MyERC20("Fresh", "FRH");
        TokenVesting freshVesting = new TokenVesting(IERC20(address(freshToken)), beneficiary);

        freshToken.approve(address(freshVesting), 100 ether);

        // 预期事件发射
        vm.expectEmit(true, false, false, true);
        emit TokenVesting.TokensDeposited(100 ether);
        freshVesting.deposit(100 ether);

        assertEq(freshVesting.totalAmount(), 100 ether);
    }

    // ==================== Cliff锁定期测试 ====================

    /**
     * @dev 验证锁定期内vested/releasable均为0，cliff未通过
     */
    function test_CliffPeriod_GetVestedAmount_IsZero() public view {
        assertEq(vesting.getVestedAmount(), 0);
        assertEq(vesting.getReleasableAmount(), 0);
        assertFalse(vesting.isCliffPassed());
        assertFalse(vesting.isFullyVested());
    }

    /**
     * @dev 验证锁定期内调用release()会revert
     */
    function test_CliffPeriod_Release_Reverts() public {
        vm.prank(beneficiary);
        vm.expectRevert("No tokens available for release");
        vesting.release();
    }

    /**
     * @dev 验证锁定期内isCliffPassed返回false，剩余365天
     */
    function test_CliffPeriod_IsCliffPassed_False() public view {
        assertFalse(vesting.isCliffPassed());
        assertEq(vesting.getDaysUntilCliff(), 365);
    }

    /**
     * @dev 验证锁定期内释放进度为0%
     */
    function test_CliffPeriod_GetVestingProgress_Zero() public view {
        assertEq(vesting.getVestingProgress(), 0);
    }

    // ==================== Cliff边界测试 ====================

    /**
     * @dev 验证cliff到期前1秒，释放量仍为0
     */
    function test_CliffBoundary_GetVestedAmount_IsZero() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION - 1);
        assertEq(vesting.getVestedAmount(), 0);
        assertFalse(vesting.isCliffPassed());
    }

    /**
     * @dev 验证cliff到期时释放量仍为0（刚好到期），cliff+1秒后开始有释放
     */
    function test_CliffBoundary_ExactlyAtCliff_ReleasesFirstToken() public {
        // cliff到期瞬间：cliff已通过，但经过时间为0，释放量仍为0
        vm.warp(vesting.startTime() + CLIFF_DURATION);
        assertTrue(vesting.isCliffPassed());
        assertEq(vesting.getDaysUntilCliff(), 0);
        assertEq(vesting.getVestedAmount(), 0);

        // cliff + 1秒：经过1秒，应有微量释放
        vm.warp(vesting.startTime() + CLIFF_DURATION + 1);
        uint256 vested = vesting.getVestedAmount();
        console.log("At cliff + 1s, vested amount:", vested);
        assertGt(vested, 0);

        // 期望释放量 = 总金额 * 1秒 / 释放期总秒数
        uint256 expected = TOTAL_AMOUNT * 1 / VESTING_DURATION;
        assertApproxEqAbs(vested, expected, 10);
    }

    // ==================== 线性释放期测试 ====================

    /**
     * @dev 验证释放期过半时，释放量约为总金额的1/2
     */
    function test_VestingPeriod_Halfway_VestCorrectAmount() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 vested = vesting.getVestedAmount();
        uint256 expectedHalf = TOTAL_AMOUNT / 2;
        console.log("Halfway vested:", vested, "expected:", expectedHalf);
        assertApproxEqAbs(vested, expectedHalf, 1000);
    }

    /**
     * @dev 验证释放期1/4时，释放量约为总金额的1/4
     */
    function test_VestingPeriod_OneQuarter_VestCorrectAmount() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 4);

        uint256 vested = vesting.getVestedAmount();
        uint256 expectedQuarter = TOTAL_AMOUNT / 4;
        console.log("Quarter vested:", vested, "expected:", expectedQuarter);
        assertApproxEqAbs(vested, expectedQuarter, 1000);
    }

    /**
     * @dev 验证释放期中途执行release()：
     *  1. 受益人获得代币，状态正确更新
     *  2. release后releasableAmount归零
     */
    function test_VestingPeriod_Release_PartialAmount() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 releasableBefore = vesting.getReleasableAmount();
        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);

        // 模拟受益人调用release
        vm.prank(beneficiary);
        vm.expectEmit(true, false, false, true);
        emit TokenVesting.TokensReleased(releasableBefore);
        vesting.release();

        // 验证释放金额已记录
        assertEq(vesting.releasedAmount(), releasableBefore);
        // 验证受益人收到代币
        assertEq(token.balanceOf(beneficiary), beneficiaryBalanceBefore + releasableBefore);
        // 验证没有更多可释放
        assertEq(vesting.getReleasableAmount(), 0);
    }

    /**
     * @dev 验证多次部分释放：
     *  第1次在1/4处释放 -> 第2次在1/2处释放
     *  两次释放之和应等于该时间点的总释放量
     */
    function test_VestingPeriod_MultipleReleases() public {
        // 第一次：在1/4释放点释放
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 4);

        uint256 firstRelease = vesting.getReleasableAmount();
        vm.prank(beneficiary);
        vesting.release();
        assertEq(vesting.releasedAmount(), firstRelease);

        // 第二次：在1/2释放点释放（累积）
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 secondRelease = vesting.getReleasableAmount();
        uint256 totalVested = vesting.getVestedAmount();
        console.log("First release:", firstRelease);
        console.log("Second release:", secondRelease);
        console.log("Total vested:", totalVested);

        // 两次释放总和应等于该点的总释放量
        assertApproxEqAbs(firstRelease + secondRelease, totalVested, 1000);

        vm.prank(beneficiary);
        vesting.release();

        // 再次释放后，releasedAmount应等于总释放量
        assertApproxEqAbs(vesting.releasedAmount(), totalVested, 1000);
        assertEq(vesting.getReleasableAmount(), 0);
    }

    /**
     * @dev 验证释放进度百分比在50%时约为5000基点（10000=100%）
     */
    function test_VestingPeriod_GetVestingProgress_Calculated() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 progress = vesting.getVestingProgress();
        console.log("Vesting progress at halfway:", progress);
        assertApproxEqAbs(progress, 5000, 10);
    }

    // ==================== 完全释放测试 ====================

    /**
     * @dev 验证达到总期限时所有代币已可释放
     */
    function test_FullVesting_GetVestedAmount_AllTokens() public {
        vm.warp(vesting.startTime() + TOTAL_DURATION);
        assertEq(vesting.getVestedAmount(), TOTAL_AMOUNT);
        assertTrue(vesting.isFullyVested());
        assertEq(vesting.getVestingProgress(), 10000);
    }

    /**
     * @dev 验证全部释放流程：受益人领取所有代币，合约余额归零
     */
    function test_FullVesting_Release_AllTokens() public {
        vm.warp(vesting.startTime() + TOTAL_DURATION);

        uint256 releasable = vesting.getReleasableAmount();
        assertEq(releasable, TOTAL_AMOUNT);

        vm.prank(beneficiary);
        vesting.release();

        assertEq(vesting.releasedAmount(), TOTAL_AMOUNT);
        assertEq(token.balanceOf(beneficiary), TOTAL_AMOUNT);
        assertEq(vesting.getReleasableAmount(), 0);
        assertEq(vesting.getRemainingAmount(), 0);
    }

    /**
     * @dev 验证超过总期限后再次release不会释放额外代币
     */
    function test_FullVesting_AfterTotalDuration_NoMoreRelease() public {
        vm.warp(vesting.startTime() + TOTAL_DURATION + 100 days);

        vm.prank(beneficiary);
        vesting.release();

        assertEq(vesting.releasedAmount(), TOTAL_AMOUNT);
        assertEq(vesting.getReleasableAmount(), 0);
    }

    // ==================== 访问控制测试 ====================

    /**
     * @dev 验证非受益人无法release
     */
    function test_Release_Stranger_Reverts() public {
        vm.warp(vesting.startTime() + TOTAL_DURATION);

        vm.prank(stranger);
        vm.expectRevert("Only beneficiary can release tokens");
        vesting.release();
    }

    /**
     * @dev 验证未存款的合约无法release（totalAmount为0）
     */
    function test_Release_NotDeposited_Reverts() public {
        MyERC20 newToken = new MyERC20("New", "NEW");
        TokenVesting newVesting = new TokenVesting(IERC20(address(newToken)), beneficiary);

        vm.warp(block.timestamp + TOTAL_DURATION);

        vm.prank(beneficiary);
        vm.expectRevert("No tokens to release");
        newVesting.release();
    }

    // ==================== 视图函数测试 ====================

    /**
     * @dev 验证getRemainingAmount返回未释放的代币数
     */
    function test_GetRemainingAmount() public view {
        assertEq(vesting.getRemainingAmount(), TOTAL_AMOUNT);
    }

    /**
     * @dev 验证getDaysFromStart在不同时间点的返回值
     */
    function test_GetDaysFromStart() public {
        assertEq(vesting.getDaysFromStart(), 0);

        vm.warp(vesting.startTime() + 1 days);
        assertEq(vesting.getDaysFromStart(), 1);

        vm.warp(vesting.startTime() + 100 days);
        assertEq(vesting.getDaysFromStart(), 100);
    }

    /**
     * @dev 验证锁定期内剩余天数为365
     */
    function test_GetDaysUntilCliff() public view {
        assertEq(vesting.getDaysUntilCliff(), 365);
    }

    /**
     * @dev 验证cliff通过后剩余天数为0
     */
    function test_GetDaysUntilCliff_Passed() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + 1 days);
        assertEq(vesting.getDaysUntilCliff(), 0);
    }

    /**
     * @dev 验证isCliffPassed在cliff前后的布尔值切换
     */
    function test_IsCliffPassed() public {
        assertFalse(vesting.isCliffPassed());

        vm.warp(vesting.startTime() + CLIFF_DURATION);
        assertTrue(vesting.isCliffPassed());
    }

    /**
     * @dev 验证isFullyVested在总期限前后的布尔值切换
     */
    function test_IsFullyVested() public {
        assertFalse(vesting.isFullyVested());

        vm.warp(vesting.startTime() + TOTAL_DURATION);
        assertTrue(vesting.isFullyVested());
    }

    // ==================== 边界条件测试 ====================

    /**
     * @dev 验证释放期第1秒即有微量释放（防止mulDiv取整为0的边界问题）
     */
    function test_EdgeCase_VestingFirstSecond() public {
        vm.warp(vesting.startTime() + CLIFF_DURATION + 1);
        uint256 vested = vesting.getVestedAmount();
        assertGt(vested, 0);

        uint256 expected = TOTAL_AMOUNT * 1 / VESTING_DURATION;
        assertApproxEqAbs(vested, expected, 1);
    }

    /**
     * @dev 验证远超总期限（10年后）仍正确返回全量释放
     */
    function test_EdgeCase_MaximumTime() public {
        vm.warp(vesting.startTime() + TOTAL_DURATION + 3650 days);
        assertTrue(vesting.isFullyVested());
        assertEq(vesting.getVestedAmount(), TOTAL_AMOUNT);
        assertEq(vesting.getReleasableAmount(), TOTAL_AMOUNT);
    }

    /**
     * @dev 验证极小金额（2 wei）存款在释放期内能正确计算
     */
    function test_EdgeCase_DepositSmallAmount() public {
        MyERC20 smallToken = new MyERC20("Small", "SML");
        TokenVesting smallVesting = new TokenVesting(IERC20(address(smallToken)), beneficiary);

        uint256 smallAmount = 2;
        smallToken.approve(address(smallVesting), smallAmount);
        smallVesting.deposit(smallAmount);

        // 中途释放应有至少1 wei
        vm.warp(smallVesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);
        uint256 vested = smallVesting.getVestedAmount();
        console.log("Small amount vested at halfway:", vested);
        assertGe(vested, 1);

        // 到期应释放全部
        vm.warp(smallVesting.startTime() + TOTAL_DURATION);
        uint256 fullVested = smallVesting.getVestedAmount();
        assertEq(fullVested, smallAmount);
    }

    /**
     * @dev 验证较大金额（900K ether）在释放期内能正确计算，无溢出
     */
    function test_EdgeCase_LargeAmount() public {
        MyERC20 largeToken = new MyERC20("Large", "LRG");

        uint256 largeAmount = 900_000 ether;

        TokenVesting largeVesting = new TokenVesting(IERC20(address(largeToken)), beneficiary);

        largeToken.approve(address(largeVesting), largeAmount);
        largeVesting.deposit(largeAmount);

        // 中途释放应接近50%
        vm.warp(largeVesting.startTime() + CLIFF_DURATION + VESTING_DURATION / 2);
        uint256 vested = largeVesting.getVestedAmount();
        assertApproxEqAbs(vested, largeAmount / 2, 1000);

        // 到期应释放全部
        vm.warp(largeVesting.startTime() + TOTAL_DURATION);
        assertEq(largeVesting.getVestedAmount(), largeAmount);
    }

    // ==================== 所有权管理测试 ====================

    /**
     * @dev 验证合约owner为部署者
     */
    function test_Owner_IsOwner() public view {
        assertEq(vesting.owner(), owner);
    }

    /**
     * @dev 验证owner可以放弃所有权（renounceOwnership）
     */
    function test_Owner_CanRenounce() public {
        vesting.renounceOwnership();
        assertEq(vesting.owner(), address(0));
    }
}