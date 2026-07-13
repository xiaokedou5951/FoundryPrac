// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {MyToken} from "../src/MyToken.sol";

// 一条命令完成部署+验证
// forge script script/MyToken.s.sol --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast --verify
contract MyTokenScript is Script {
    MyToken public myToken;

    function run() public {
        vm.startBroadcast();

        myToken = new MyToken("MyToken", "MTK");

        vm.stopBroadcast();
    }
}
