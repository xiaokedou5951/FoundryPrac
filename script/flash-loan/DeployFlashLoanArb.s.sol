// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TokenC} from "../../src/flash-loan/TokenC.sol";
import {FlashLoanArbitrage} from "../../src/flash-loan/FlashLoanArbitrage.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUniV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
interface IUniV2Router {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @title DeployFlashLoanArb
/// @dev anvil fork 主网部署：TokenC、双 Uniswap 池流动性、套利合约
///      官方 V2 Factory/Router 用 forge create 部署（solc 0.5.16/0.6.6），
///      其地址通过环境变量 FACTORY_C / FACTORY_E / ROUTER_C / ROUTER_E 传入本脚本。
contract DeployFlashLoanArb is Script {
    // 主网地址
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        address factoryC = vm.envAddress("FACTORY_C");
        address factoryE = vm.envAddress("FACTORY_E");
        address routerC = vm.envAddress("ROUTER_C");
        address routerE = vm.envAddress("ROUTER_E");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        // 1. 部署 TokenC（部署者持有全部供应量）
        TokenC tokenC = new TokenC();
        console2.log("TokenC:", address(tokenC));

        // 2. 兑换 200 WETH 作为流动性资金
        IWETH(WETH).deposit{value: 200 ether}();

        // 3. 创建并注入两个价差池流动性
        //    PoolC：1,000,000 TKC + 100 WETH（TokenC 便宜）
        //    PoolE：100,000 TKC + 100 WETH（TokenC 昂贵 10 倍）
        _setupPool(IUniV2Factory(factoryC), IUniV2Router(routerC), tokenC, 1_000_000 ether, 100 ether);
        _setupPool(IUniV2Factory(factoryE), IUniV2Router(routerE), tokenC, 100_000 ether, 100 ether);

        // 4. 部署套利合约
        FlashLoanArbitrage arb = new FlashLoanArbitrage(WETH, address(tokenC), routerC, routerE);
        console2.log("FlashLoanArbitrage:", address(arb));

        vm.stopBroadcast();

        // 5. 持久化地址到 deployments/flash-loan-arb-local.json
        string memory json = "flash-loan-arb";
        vm.serializeAddress(json, "tokenC", address(tokenC));
        vm.serializeAddress(json, "factoryC", factoryC);
        vm.serializeAddress(json, "factoryE", factoryE);
        vm.serializeAddress(json, "routerC", routerC);
        vm.serializeAddress(json, "routerE", routerE);
        vm.serializeAddress(json, "weth", WETH);
        string memory finalJson = vm.serializeAddress(json, "arb", address(arb));
        vm.writeJson(finalJson, "deployments/flash-loan-arb-local.json");
        console2.log("Addresses written to deployments/flash-loan-arb-local.json");
    }

    function _setupPool(
        IUniV2Factory factory,
        IUniV2Router router,
        TokenC tokenC,
        uint256 tkcAmount,
        uint256 wethAmount
    ) internal {
        factory.createPair(address(tokenC), WETH);
        tokenC.approve(address(router), tkcAmount);
        IWETH(WETH).approve(address(router), wethAmount);
        router.addLiquidity(
            address(tokenC), WETH, tkcAmount, wethAmount, 0, 0, msg.sender, block.timestamp + 600
        );
    }
}

/// @title ExecuteArbitrage
/// @dev anvil fork 主网执行：读取地址 JSON，真实发交易执行 Aave 闪电贷套利
contract ExecuteArbitrage is Script {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() external {
        string memory json = vm.readFile("deployments/flash-loan-arb-local.json");
        address arb = vm.parseAddress(vm.parseJsonString(json, ".arb"));
        address routerC = vm.parseAddress(vm.parseJsonString(json, ".routerC"));
        address routerE = vm.parseAddress(vm.parseJsonString(json, ".routerE"));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 borrowAmount = 5 ether;

        // 用 Router getAmountsOut 预估 minOut，留 1% 滑点余量
        address[] memory pathToC = new address[](2);
        pathToC[0] = WETH;
        (pathToC[1]) = vm.parseAddress(vm.parseJsonString(json, ".tokenC"));
        uint256[] memory outC = IUniV2Router(routerC).getAmountsOut(borrowAmount, pathToC);
        uint256 minTokenCOut = outC[1] * 99 / 100;

        address[] memory pathToWeth = new address[](2);
        pathToWeth[0] = pathToC[1];
        pathToWeth[1] = WETH;
        uint256[] memory outE = IUniV2Router(routerE).getAmountsOut(minTokenCOut, pathToWeth);
        uint256 minWethOut = outE[1] * 99 / 100;

        vm.startBroadcast(deployerPk);
        FlashLoanArbitrage(arb).startArbitrage(borrowAmount, minTokenCOut, minWethOut);
        vm.stopBroadcast();

        console2.log("Arbitrage executed. arb WETH balance:", IWETH(WETH).balanceOf(arb));
    }
}