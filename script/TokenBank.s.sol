// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console} from "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.s.sol";
import {Script} from "forge-std/Script.sol";
import {TokenBank} from "../src/TokenBank.sol";

// 部署 TokenBank（需要先部署代币合约，通过 TOKEN_ADDRESS 环境变量指定）
//
// 使用方式：
//   1. 先部署代币：forge script script/MyToken.s.sol --rpc-url local --broadcast
//   2. 再部署 TokenBank：TOKEN_ADDRESS=<代币地址> forge script script/TokenBank.s.sol --rpc-url local --broadcast
//
// 或者在 .env 中设置 TOKEN_ADDRESS 后直接部署：
//   forge script script/TokenBank.s.sol --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast --verify
contract TokenBankScript is Script {
    TokenBank public tokenBank;

    function run() public {
        vm.startBroadcast();

        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        require(tokenAddress != address(0), "TOKEN_ADDRESS not set or zero");

        tokenBank = new TokenBank(tokenAddress);
        console.log("TokenBank deployed at:", address(tokenBank));
        console.log("TokenBank token address:", tokenAddress);

        vm.stopBroadcast();
    }
}