// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {Counter} from "../src/Counter.sol";

// BaseScript已加载账号，部署命令如下：
// forge script script/Counter_2.s.sol --rpc-url local --broadcast
contract CounterScript is BaseScript {
    Counter public counter;

    function run() public broadcaster {
        counter = new Counter();
        console.log("Counter deployed on %s", address(counter));

        saveContract("Counter", address(counter));

        // counter.setNumber(10);
        // counter.increment();
    }
}
