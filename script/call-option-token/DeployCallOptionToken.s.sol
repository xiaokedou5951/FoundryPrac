// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {OptionToken} from "../../src/call-option-token/OptionToken.sol";
import {OptionSwapPool} from "../../src/call-option-token/OptionSwapPool.sol";
import {MockUSDT} from "../../src/call-option-token/MockUSDT.sol";

/**
 * @title DeployCallOptionToken
 * @dev 本地测试网（anvil）一键部署 + 看涨期权全流程演示脚本。
 *
 * 运行方式：
 *   1. 启动本地链：anvil
 *   2. 执行脚本：
 *      forge script script/call-option-token/DeployCallOptionToken.s.sol \
 *        --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 *
 * 演示流程：
 *   - 部署 MockUSDT、OptionToken（strikePrice=3000 USDT/ETH，7 天后到期）、OptionSwapPool
 *   - 项目方 issue(10 ETH) 铸 10 期权
 *   - 注入 AMM 流动性：500 期权 / 25000 USDT（1 期权 = 50 USDT，低价）
 *     （演示用：仅注入 5 期权 / 250 USDT，避免一次抽干）
 *   - 打印所有地址
 */
contract DeployCallOptionToken is Script {
    // anvil 默认账户 #0，可通过环境变量 PRIVATE_KEY 覆盖
    uint256 constant ANVIL_DEFAULT_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // 期权参数
    uint256 constant STRIKE_PRICE = 3000 * 1e6; // 3000 USDT / 1 ETH（USDT 6 位精度）
    uint256 constant EXPIRY_DELAY = 7 days; // 7 天后到期

    // 发行量与流动性（演示用较小数值）
    uint256 constant ISSUE_ETH = 10 ether; // 项目方抵押 10 ETH，铸 10 期权
    uint256 constant LIQ_OPTION = 5 ether; // 注入 5 期权
    uint256 constant LIQ_USDT = 250 * 1e6; // 注入 250 USDT（1 期权 = 50 USDT，低价）

    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(ANVIL_DEFAULT_PK));
        address deployer = vm.addr(pk); // 广播账户（与 msg.sender 在模拟期可能不一致，故显式派生）

        vm.startBroadcast(pk);

        // ===== 1. 部署三个合约 =====
        MockUSDT usdt = new MockUSDT();
        OptionToken opt = new OptionToken(address(usdt), STRIKE_PRICE, block.timestamp + EXPIRY_DELAY);
        OptionSwapPool pool = new OptionSwapPool(address(opt), address(usdt));

        // ===== 2. 项目方发行期权（抵押 ETH，1:1 铸期权）=====
        opt.issue{value: ISSUE_ETH}();

        // ===== 3. 项目方铸造 USDT 并注入 AMM 流动性（创建期权/USDT 交易对，低价）=====
        usdt.mint(deployer, LIQ_USDT);
        opt.approve(address(pool), LIQ_OPTION);
        usdt.approve(address(pool), LIQ_USDT);
        pool.addLiquidity(LIQ_OPTION, LIQ_USDT);

        vm.stopBroadcast();

        // ===== 4. 打印地址 =====
        console.log("=== Deployed Call-Option-Token ===");
        console.log("MockUSDT:        ", address(usdt));
        console.log("OptionToken:     ", address(opt));
        console.log("OptionSwapPool:  ", address(pool));
        console.log("strikePrice(USDT/ETH):", opt.strikePrice());
        console.log("expiryDate:      ", opt.expiryDate());
        console.log("owner/issuer:    ", deployer);
        console.log("--- AMM pool reserves ---");
        console.log("reserveOption:   ", pool.reserveOption());
        console.log("reserveUsdt:     ", pool.reserveUsdt());

        // ===== 5. 演示：用户用 50 USDT 买入期权（模拟购买期权）=====
        vm.startBroadcast(pk);
        usdt.mint(deployer, 50 * 1e6);
        usdt.approve(address(pool), 50 * 1e6);
        uint256 bought = pool.swapUSDTForOption(50 * 1e6, 0);
        vm.stopBroadcast();

        console.log("--- demo swap: 50 USDT -> option ---");
        console.log("option bought:   ", bought);
        console.log("user option bal: ", opt.balanceOf(deployer));
    }
}
