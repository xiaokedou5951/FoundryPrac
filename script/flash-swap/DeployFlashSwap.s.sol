// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {TokenA} from "../../src/flash-swap/TokenA.sol";
import {TokenB} from "../../src/flash-swap/TokenB.sol";
import {FlashSwapArbitrage} from "../../src/flash-swap/FlashSwapArbitrage.sol";

/**
 * @title DeployFlashSwap
 * @dev 本地测试网（anvil）一键部署 + 套利演示
 *
 * 运行方式：
 *   1. 启动本地链：anvil
 *   2. 执行脚本：
 *      forge script script/flash-swap/DeployFlashSwap.s.sol \
 *        --rpc-url http://127.0.0.1:8545 --broadcast -vvv
 *
 * 说明：官方 UniswapV2Factory 为 Solidity 0.5.16，与 0.8.x 脚本不能直接互相 import，
 *      因此从 out/ 下的官方 artifact 读取创建字节码，在 broadcast 中用 CREATE 部署（交易真实上链）。
 *      artifact 由 src/flash-swap/V2Core.sol 锚点编译生成，forge script 会先自动编译。
 */
contract DeployFlashSwap is Script {
    // anvil 默认账户 #0，可通过环境变量 PRIVATE_KEY 覆盖
    uint256 constant ANVIL_DEFAULT_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // 流动性配置：PoolA 1:1，PoolB 1:2，制造价差形成套利空间
    uint256 constant POOL_A_LIQ_TOKENA = 10_000e18;
    uint256 constant POOL_A_LIQ_TOKENB = 10_000e18;
    uint256 constant POOL_B_LIQ_TOKENA = 10_000e18;
    uint256 constant POOL_B_LIQ_TOKENB = 20_000e18;

    // 套利演示借入量
    uint256 constant BORROW_AMOUNT = 100e18;

    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(ANVIL_DEFAULT_PK));

        vm.startBroadcast(pk);

        // ===== 1. 部署两个 ERC20 =====
        TokenA tokenA = new TokenA();
        TokenB tokenB = new TokenB();

        // ===== 2. 部署两个 Uniswap（官方 v2-core Factory）=====
        address factoryA = _deployV2Factory();
        address factoryB = _deployV2Factory();

        // ===== 3. 创建 PoolA / PoolB =====
        address pairA = IUniswapV2Factory(factoryA).createPair(address(tokenA), address(tokenB));
        address pairB = IUniswapV2Factory(factoryB).createPair(address(tokenA), address(tokenB));

        // ===== 4. 添加错配流动性（无需 Router，直接转币后 mint LP）=====
        _addLiquidity(address(tokenA), address(tokenB), pairA, POOL_A_LIQ_TOKENA, POOL_A_LIQ_TOKENB);
        _addLiquidity(address(tokenA), address(tokenB), pairB, POOL_B_LIQ_TOKENA, POOL_B_LIQ_TOKENB);

        // ===== 5. 部署闪电套利合约 =====
        FlashSwapArbitrage arbitrage =
            new FlashSwapArbitrage(address(tokenA), address(tokenB), pairA, pairB);

        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("TokenA:           ", address(tokenA));
        console.log("TokenB:           ", address(tokenB));
        console.log("UniswapA factory: ", factoryA);
        console.log("UniswapB factory: ", factoryB);
        console.log("PoolA (pair):     ", pairA);
        console.log("PoolB (pair):     ", pairB);
        console.log("Arbitrage:        ", address(arbitrage));

        // ===== 6. 演示一次闪电套利：从 PoolA 借 TokenA -> 在 PoolB 换 TokenB -> 偿还 PoolA =====
        uint256 balanceBefore = tokenB.balanceOf(address(arbitrage));

        vm.startBroadcast(pk);
        arbitrage.startArbitrage(BORROW_AMOUNT);
        vm.stopBroadcast();

        uint256 profit = tokenB.balanceOf(address(arbitrage)) - balanceBefore;
        console.log("=== Arbitrage Done ===");
        console.log("Borrowed TokenA:  ", BORROW_AMOUNT);
        console.log("Profit TokenB:    ", profit);
    }

    /// @dev 从 out/ artifact 读取官方 UniswapV2Factory 创建字节码并部署
    function _deployV2Factory() internal returns (address) {
        string memory json = vm.readFile("out/UniswapV2Factory.sol/UniswapV2Factory.json");
        bytes memory creation =
            abi.encodePacked(vm.parseJsonBytes(json, ".bytecode.object"), abi.encode(msg.sender));
        address addr;
        assembly {
            addr := create(0, add(creation, 0x20), mload(creation))
        }
        require(addr != address(0), "DeployFlashSwap: V2_FACTORY_DEPLOY_FAILED");
        return addr;
    }

    /// @dev 直接向 Pair 转入两种代币后 mint LP
    function _addLiquidity(
        address tokenA_,
        address tokenB_,
        address pair,
        uint256 amountA,
        uint256 amountB
    ) internal {
        IERC20(tokenA_).transfer(pair, amountA);
        IERC20(tokenB_).transfer(pair, amountB);
        IUniswapV2Pair(pair).mint(msg.sender);
    }
}
